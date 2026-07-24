//! FFI over the final Orchard→Ironwood pool-migration engine
//! ([`zcash_pool_migration`] + the `zcash_client_sqlite::pool_migration` store).
//!
//! The engine is a set of free functions over traits — [`crate::migration_engine::Backend`] wires
//! this SDK's wallet database (and the account-keyed migration store living inside it) into them;
//! [`crate::migration_finalize`] proves transactions at broadcast time (ZIP 374 deferred
//! anchors/witnesses, resolved through the upstream prover — transfers against their drawn
//! ZIP 318 boundary anchor, preparations against the natural anchor; see its module doc);
//! [`crate::migration_plan_cache`] carries the previewed plan from propose to commit.
//! This module keeps the platform-facing C ABI of the v1 integration: the same entry points, the
//! same `#[repr(C)]` DTOs, the same sentinels — the engine swap is absorbed here, with two
//! deliberate exceptions (the external-signer note-split pair went plural, because the engine
//! builds N preparation transactions rather than one split transaction).
//!
//! Semantics that moved into this layer (the v1 crate did them internally):
//! - The public 5-state machine is DERIVED (see [`derive_state`]): the v1 crate's `ReadyToPropose`
//!   state and `SyncRequiredBeforeNext` attention reason are gone entirely (the engine commits the
//!   split and the schedule atomically, so that intermediate moment cannot occur). Canonical
//!   engine `Complete` is PER-RUN — "the stored run is fully mined", never "nothing left to
//!   migrate" — while the public projection additionally requires every exact resulting Ironwood
//!   output to be spendable or current-main-chain spent. After completion the platform asks
//!   `zcashlc_migration_propose_transfers` whether anything remains (an empty schedule means no).
//! - Legacy state/progress/status reads are pure projections. Canonical chain reconciliation is a
//!   separate delivery CAS that requires the Rust-owned opaque scheduled-run capability.
//! - Durable rejection, exact-artifact delivery, and immediate-lane state are owned by the
//!   additive delivery-control schema in `zcash_client_sqlite`. This shim never creates SDK-local
//!   shadow tables or records a broadcast after the fact.
//!
//! Error channel: failures land in the thread-local last-error message. Two stable prefixes let
//! the Swift layer surface dedicated errors: `MIGRATION_PLAN_STALE:` (commit without a matching
//! cached proposal — re-propose) and `MIGRATION_PROVING_UNAVAILABLE:` (proving failed hard).
//! Pointer-returning functions yield NULL on error, `bool`-returning functions `false`, and the
//! `i64` sentinels are documented per function.
//!
//! Heap ownership: every function that returns a `*mut Ffi*` (or a [`ffi::BoxedSlice`]) transfers
//! ownership to the caller, who must free it with the matching `zcashlc_free_migration_*` (or
//! `zcashlc_free_boxed_slice`) function.

use std::convert::Infallible;
use std::ffi::{CStr, CString, OsStr};
use std::os::raw::c_char;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::ptr;
use std::slice;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use pczt::{Pczt, roles::prover::Prover};
use prost::Message;
use rand::rngs::OsRng;
use rusqlite::Connection;
use zcash_client_backend::data_api::wallet::{
    SpendingKeys, TargetHeight, create_pczt_from_proposal, create_proposed_transactions,
    extract_and_store_transaction_from_pczt,
    input_selection::{LockFilter, LockedInputPolicy},
};
use zcash_client_backend::data_api::{InputSource, WalletRead, WalletWrite};
use zcash_client_backend::proto::proposal::Proposal as ProtoProposal;
use zcash_client_backend::wallet::{LockOwner, OutputRef, OvkPolicy};
use zcash_client_sqlite::AccountUuid;
use zcash_client_sqlite::pool_migration::orchard_ironwood::PoolMigrations;
use zcash_primitives::transaction::builder::{BundlePadding, cached_orchard_proving_key};
use zcash_proofs::prover::LocalTxProver;
#[cfg(test)]
use zcash_protocol::TxId;
use zcash_protocol::consensus::{
    BLOCKS_PER_HOUR, BlockHeight, BranchId, Network, NetworkConstants, NetworkUpgrade, Parameters,
};
use zcash_protocol::value::Zatoshis;
use zcash_protocol::{PoolType, ShieldedPool};

use zcash_pool_migration::delivery::{
    AccountDeletionAuthorization, AccountDeletionBlockReason, CanonicalMaterializationTransition,
    CanonicalMutationAuthorization, CanonicalMutationBlockReason, ClaimKind, ClaimStatus,
    ClaimToken, DeliveryArtifactEvidence, DeliveryArtifactIdentity, DeliveryFailureReason,
    DeliveryLane, DeliveryPhase, DeliveryRevision, DeliverySnapshot, DestinationSpendability,
    DirectTlsEndpoint, ExpiredTransferRebuild, ExternalSigningPczt,
    ImmediateMigrationDeliveryStore, ImmediateMigrationIntent, ImmediateProposal, LeaseDuration,
    LegacyCutoverStatus, LoopbackDevelopmentEndpoint, MigrationDeliveryStore, MigrationRunIdentity,
    MigrationRuntimeAvailability, MigrationRuntimeSnapshot, MigrationRuntimeStore,
    OrdinarySpendAuthorization, OrdinarySpendBlockReason, OrdinarySpendScope, PolicyFingerprint,
    PolicyValidationFailure, ReservationRollover, ReservedImmediateArtifact, RetainedMigrationRun,
    RuntimeUnavailableReason, SignerOwnership, SourceReservationOwner, StorageFinality,
    StorageRecoveryReason, SubmissionContext, SubmissionOutcome, SubmissionPolicy,
    SubmissionPolicyRequest, SubmissionTransport, TorOnionEndpoint, TorProxyTlsEndpoint,
    exact_immediate_transaction, scheduled_artifact_evidence,
};
#[cfg(test)]
use zcash_pool_migration::engine::PoolMigrationWrite;
use zcash_pool_migration::engine::{
    self, MigrationPlan, MigrationState, MigrationStatus, MigrationTransaction, MigrationTxId,
    MigrationTxKind, MigrationTxState, PoolMigrationRead,
};
use zcash_pool_migration::state::{Blocker, NextAction, TransactionStatus};
use zcash_pool_migration::wallet::{
    ActiveOrchardLock, PcztLockValidationSource, WalletMigrationProver,
};

use crate::migration_engine::{Backend, MigrationWallet, SuccessorCandidateBackend};
use crate::migration_finalize;
use crate::migration_plan_cache;
use crate::{
    NETWORK_ID_MAINNET, NETWORK_ID_TESTNET, NetworkParams, account_uuid_from_bytes, decode_usk,
    ffi, free_ptr_from_vec, free_ptr_from_vec_with, parse_network, ptr_from_vec, unwrap_exc_or,
    unwrap_exc_or_null, zcashlc_string_free,
};

// ----- error / value marshaling -----

/// The stable prefix the Swift layer maps to `ZcashError.migrationPlanStale` (ZRUST0128).
const PLAN_STALE_PREFIX: &str = "MIGRATION_PLAN_STALE";
/// The stable prefix the Swift layer maps to `ZcashError.migrationProvingUnavailable` (ZRUST0127).
const PROVING_UNAVAILABLE_PREFIX: &str = "MIGRATION_PROVING_UNAVAILABLE";

type UnsignedMigrationPczts = Vec<(MigrationTxId, Vec<u8>)>;

/// A commit was requested without a matching previewed plan (process restart between propose and
/// confirm, or the wallet changed underneath the preview). The platform re-proposes.
fn plan_stale(detail: &str) -> anyhow::Error {
    anyhow!("{PLAN_STALE_PREFIX}: {detail}")
}

/// Proving a migration transaction failed hard (as opposed to the transient "not witnessable yet"
/// state, which is reported as "nothing due"). Shared with [`crate::migration_finalize`], where
/// the prove dispatch classifies prover failures onto the two lanes.
pub(crate) fn proving_unavailable(detail: impl std::fmt::Display) -> anyhow::Error {
    anyhow!("{PROVING_UNAVAILABLE_PREFIX}: {detail}")
}

fn legacy_delivery_api_disabled(api: &str) -> anyhow::Error {
    anyhow!(
        "{api} is disabled because it lacks a Rust-owned delivery capability; use the migration delivery v1 handle API"
    )
}

/// A spendable-value amount as a signed 64-bit integer (zatoshi). Every migration amount is a
/// valid [`Zatoshis`] (`<= MAX_MONEY`, ~2.1e15), well within `i64`.
fn zat_to_i64(z: Zatoshis) -> i64 {
    u64::from(z) as i64
}

/// An optional block height as an `i64`, with `-1` standing for "none".
fn height_opt_to_i64(h: Option<BlockHeight>) -> i64 {
    h.map_or(-1, |h| i64::from(u32::from(h)))
}

/// A count as a `u32`, erroring (rather than truncating) on overflow. The engine's per-run counts
/// (crossings, layers, transactions) are bounded by the note cap, so overflow never happens in
/// practice; this keeps the marshaling honest anyway.
fn count_to_u32(v: usize, what: &str) -> anyhow::Result<u32> {
    u32::try_from(v).map_err(|_| anyhow!("{what} count {v} exceeds u32"))
}

/// Borrow an FFI array as a slice, tolerating a null pointer when `len == 0` (calling
/// `slice::from_raw_parts` with a null pointer is undefined behaviour even for a zero length).
///
/// # Safety
/// When `len > 0`, `ptr` must be non-null and valid for reads of `len` elements of `T`.
unsafe fn slice_or_empty<'a, T>(ptr: *const T, len: usize) -> &'a [T] {
    if len == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(ptr, len) }
    }
}

/// Decode the decimal transaction identifier carried by the Keystone bridge.
fn transfer_id_from_c(id: *const c_char) -> anyhow::Result<MigrationTxId> {
    if id.is_null() {
        return Err(anyhow!("transfer_id is null"));
    }

    // SAFETY: The caller contract requires `id` to point to a valid NUL-terminated C string.
    let raw = unsafe { CStr::from_ptr(id) }
        .to_str()
        .map_err(|e| anyhow!("transfer id is not valid UTF-8: {e}"))?;
    let index: u32 = raw
        .parse()
        .map_err(|e| anyhow!("invalid transfer id {raw}: {e}"))?;
    Ok(MigrationTxId::new(index))
}

/// The engine's target height for a given chain tip: `tip + 1`, the height of the next block.
/// Every [`MigrationState`] query (`next_provable`, `next_broadcastable`, `expired_transactions`)
/// is defined over this height, never the raw tip — see [`CallCtx::target`], the primary way
/// callers reach this from a live wallet handle. Exposed as a pure function too for the rare
/// caller (like [`derive_state`]) that already holds a `tip` value rather than a [`CallCtx`].
fn target_from_tip(tip: BlockHeight) -> BlockHeight {
    BlockHeight::from(u32::from(tip) + 1)
}

/// The common per-call context: the network parameters, the wallet handle, the migration-store
/// connection (a second, independent connection to the same wallet database file — the
/// account-keyed migration tables live inside it), and the raw path/account for the plan cache.
struct CallCtx {
    network: NetworkParams,
    wallet: MigrationWallet,
    store_conn: Connection,
    db_path: PathBuf,
    account: AccountUuid,
    account_bytes: [u8; 16],
}

/// Open the per-call context from the common FFI arguments. Every entry point calls this fresh and
/// drops it at the end (no persistent handle). The engine's store tables are created by the wallet
/// schema migrations during `init_data_db` (`zcash_client_sqlite::pool_migration` registers them);
/// no SDK-owned migration side tables are created here.
///
/// # Safety
/// - `db_data` must be valid for reads of `db_data_len` bytes and encode a filesystem path.
/// - `account_uuid_bytes` must be valid for reads of 16 bytes.
unsafe fn open(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> anyhow::Result<CallCtx> {
    let network = parse_network(network_id)?;
    let db_path = PathBuf::from(OsStr::from_bytes(unsafe {
        slice::from_raw_parts(db_data, db_data_len)
    }));
    let wallet = unsafe { crate::wallet_db(db_data, db_data_len, network)? };
    let store_conn = Connection::open(&db_path)
        .map_err(|e| anyhow!("Error opening migration store connection: {e}"))?;
    let account = account_uuid_from_bytes(account_uuid_bytes)
        .map_err(|e| anyhow!("account uuid must be 16 bytes: {e}"))?;
    let account_bytes = *account.expose_uuid().as_bytes();
    Ok(CallCtx {
        network,
        wallet,
        store_conn,
        db_path,
        account,
        account_bytes,
    })
}

impl CallCtx {
    /// The wallet's current chain tip.
    fn tip(&self) -> anyhow::Result<BlockHeight> {
        self.wallet
            .chain_height()
            .map_err(|e| anyhow!("chain height lookup failed: {e}"))?
            .ok_or_else(|| anyhow!("the wallet has no chain tip yet; sync first"))
    }

    /// The engine's target height (`tip + 1`; see [`target_from_tip`]): a transaction may be
    /// mined only in a block at or below its expiry (ZIP 203), so it first becomes un-mineable in
    /// the NEXT block once the tip reaches its expiry height, and a scheduled transaction first
    /// becomes due once the NEXT block reaches its scheduled height. Every call that feeds a
    /// [`MigrationState`] query (`next_provable`, `next_broadcastable`, `expired_transactions`,
    /// `commit_preparation`, `build_preparation_unsigned`) must use this, never `tip()` directly.
    /// SDK-owned, tip-based policy (the immediate lane's fallback expiry bound, display-only "now"
    /// references) keeps using `tip()`.
    fn target(&self) -> anyhow::Result<BlockHeight> {
        Ok(target_from_tip(self.tip()?))
    }
}

// ----- reconciliation, planning, committing -----

/// Reads canonical scheduled state for legacy projections without mutating delivery-owned state.
///
/// Historical SDK reads reconciled mined rows here through a generic whole-state replacement. A
/// delivery run makes that an authority bypass: chain reconciliation now requires the opaque run
/// capability and [`zcashlc_migration_reconcile_canonical_chain_v1`], whose store CAS owns both
/// canonical lifecycle and delivery evidence. Legacy projections therefore see the latest already
/// reconciled state and never write as a side effect of reading.
fn read_canonical_migration(ctx: &mut CallCtx) -> anyhow::Result<Option<MigrationState>> {
    scheduled_store(ctx)?
        .get_migration()
        .map_err(|e| anyhow!("reading canonical migration state failed: {e}"))
}

/// Computes a fresh preview plan against the account's live balance and caches it under a fresh
/// opaque [`migration_plan_cache::PlanHandle`]. A later commit passes that handle back and uses
/// exactly this plan, not an independently re-randomized one.
///
/// Returns `Ok(None)` when there is nothing to migrate (the balance is zero, or entirely below the
/// dust floor) — the "ask rust whether anything remains" answer after a completed run.
fn plan_and_cache(
    ctx: &mut CallCtx,
) -> anyhow::Result<Option<(MigrationPlan, BlockHeight, migration_plan_cache::PlanHandle)>> {
    match compute_plan(ctx)? {
        Some((plan, reference_height)) => {
            let handle =
                migration_plan_cache::set(ctx.db_path.clone(), ctx.account_bytes, plan.clone());
            Ok(Some((plan, reference_height, handle)))
        }
        None => Ok(None),
    }
}

/// Computes a fresh preview plan without caching it. Pure queries use this path so they cannot
/// silently supersede the handle of a proposal the user is currently reviewing.
fn compute_plan(ctx: &mut CallCtx) -> anyhow::Result<Option<(MigrationPlan, BlockHeight)>> {
    let backend = Backend::new(&ctx.wallet, ctx.account, None, &mut ctx.store_conn)?;
    let mut rng = OsRng;
    match engine::plan_migration(&ctx.network, &backend, &mut rng) {
        Ok(plan) => {
            // `plan_migration` itself just resolved the tip internally (`chain_tip_height`) to
            // plan against, so this can't newly fail here; it just makes the same value available
            // to every caller that encodes from it.
            let reference_height = ctx.tip()?;
            Ok(Some((plan, reference_height)))
        }
        Err(engine::MigrationError::NothingToMigrate) => Ok(None),
        Err(e) => Err(anyhow!("Error planning migration: {e}")),
    }
}

/// The row set the platform sees for a plan's transfer schedule: `(engine tx id, amount, broadcast
/// height, expiry height)`, sorted chronologically by broadcast height.
///
/// - `amount` is the engine's authoritative crossing value — `NoteSplitPlan::crossing_values()[i]`
///   (F3) — the NET value that crosses the turnstile when the funding note at the same index is
///   spent (see `crossing_values`'s doc: "the denomination values ... that will cross the
///   turnstile ... when the note at the same index is spent"). It is index-aligned with
///   `funding_notes()`/`schedule()` by construction: `funding_notes()` (`migration_outputs()`) maps
///   `crossing_values()` 1:1 (each funding note is `crossing_values()[i] + note_fee_buffer`), so
///   reading `crossing_values()[i]` directly pairs correctly with schedule entry `i` — no
///   re-derivation (`funding_notes()[i] - note_fee_buffer`) needed.
/// - The engine numbers every preparation transaction first, then transfers in `schedule()`
///   order, so transfer `i`'s real committed id is `prep_tx_count + i`.
/// - The sort makes the platform's row order chronological: ZIP 318 SHUFFLE deliberately makes
///   funding-note order differ from broadcast order.
fn schedule_rows(
    crossing_values: &[Zatoshis],
    schedule: &[zcash_pool_migration::scheduling::Schedule],
    prep_tx_count: u32,
) -> anyhow::Result<Vec<(MigrationTxId, Zatoshis, BlockHeight, BlockHeight)>> {
    if crossing_values.len() != schedule.len() {
        return Err(anyhow!(
            "migration plan invariant violated: {} crossing values but {} schedule entries",
            crossing_values.len(),
            schedule.len()
        ));
    }
    let mut rows: Vec<_> = crossing_values
        .iter()
        .zip(schedule.iter())
        .enumerate()
        .map(|(i, (crossing_value, entry))| {
            (
                MigrationTxId::new(prep_tx_count + i as u32),
                *crossing_value,
                entry.broadcast_height(),
                entry.expiry_height(),
            )
        })
        .collect();
    rows.sort_by_key(|(_, _, broadcast, _)| *broadcast);
    Ok(rows)
}

/// The schedule's duration in hours, measured from `now` — the same reference height the
/// encoder stamps into each row's `anchor_height` (`now_reference`) — to the LAST scheduled
/// broadcast (#1806: was the first-to-last broadcast span, which structurally excluded the wait
/// until the first transfer fires). Empty schedule, or every height at/behind `now`, is `0`
/// (saturating, never underflows).
fn estimated_duration_hours(
    broadcast_heights: impl Iterator<Item = BlockHeight>,
    now: BlockHeight,
) -> u32 {
    let now = u32::from(now);
    broadcast_heights
        .map(u32::from)
        .max()
        .map_or(0, |max| max.saturating_sub(now) / BLOCKS_PER_HOUR)
}

/// The number of preparation transactions a plan commits (across all layers) — the id offset of
/// the first transfer.
fn prep_tx_count(plan: &MigrationPlan) -> u32 {
    plan.preparation()
        .layers()
        .iter()
        .map(|layer| layer.len() as u32)
        .sum()
}

/// Marshal a plan into the platform's schedule DTO. `now_reference` (the tip at encode time) fills
/// the DTO's `anchor_height` field: with ZIP 374 the real anchor is drawn per transfer and
/// installed at proving time, so the field now carries the "now" height the platform's duration
/// math measures waits from — it is NOT a commitment-tree anchor.
fn encode_schedule_from_plan(
    plan: &MigrationPlan,
    now_reference: BlockHeight,
    plan_handle: migration_plan_cache::PlanHandle,
) -> anyhow::Result<*mut FfiMigrationSchedule> {
    let rows = schedule_rows(
        plan.note_split().crossing_values(),
        plan.schedule(),
        prep_tx_count(plan),
    )?;
    let transfers = rows
        .into_iter()
        .map(|(id, amount, broadcast, expiry)| {
            Ok(FfiTransferProposal {
                id: cstring_raw(&u32::from(id).to_string(), "transfer proposal id")?,
                amount: zat_to_i64(amount),
                anchor_height: i64::from(u32::from(now_reference)),
                next_executable_after_height: i64::from(u32::from(broadcast)),
                expiry_height: i64::from(u32::from(expiry)),
            })
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    let estimated = estimated_duration_hours(
        plan.schedule().iter().map(|e| e.broadcast_height()),
        now_reference,
    );
    let (transfers, transfers_len) = ptr_from_vec(transfers);
    Ok(Box::into_raw(Box::new(FfiMigrationSchedule {
        transfers,
        transfers_len,
        estimated_duration_hours: estimated,
        proposal_handle: plan_handle,
    })))
}

/// An empty schedule: the "nothing to migrate" answer (also the post-completion "nothing remains"
/// answer the platform's sequential-run check consumes).
fn encode_empty_schedule() -> *mut FfiMigrationSchedule {
    Box::into_raw(Box::new(FfiMigrationSchedule {
        transfers: ptr::null_mut(),
        transfers_len: 0,
        estimated_duration_hours: 0,
        proposal_handle: 0,
    }))
}

/// Returns the already-committed migration state if a non-terminal one exists (resume — never
/// rebuild over pre-signed, possibly broadcast transactions), otherwise commits the plan cached by
/// the most recent propose/prepare call: `sign` picks the `commit_preparation` /
/// `build_preparation_unsigned` variant. A terminal stored run is never replaced here: sequential
/// runs require an opaque predecessor capability and the typed atomic reservation-rollover API.
///
/// `plan_handle` identifies the exact cached plan the platform reviewed. A fresh commit fails
/// closed when it is missing or superseded. Resuming a non-terminal stored run does not consult
/// the handle because the durable run is already handle-verified state.
fn commit_or_resume(
    ctx: &mut CallCtx,
    usk: Option<zcash_keys::keys::UnifiedSpendingKey>,
    unsigned_out: bool,
    plan_handle: migration_plan_cache::PlanHandle,
) -> anyhow::Result<(MigrationState, UnsignedMigrationPczts)> {
    {
        let backend = Backend::new(&ctx.wallet, ctx.account, None, &mut ctx.store_conn)?;
        if let Some(state) = backend.get_migration()? {
            if !state.is_terminal() {
                let unsigned = state
                    .transactions()
                    .iter()
                    .filter(|t| matches!(t.state(), MigrationTxState::AwaitingSignature))
                    .map(|t| (t.id(), t.pczt().clone()))
                    .collect();
                return Ok((state, unsigned));
            }
            return Err(anyhow!(
                "a terminal migration can only be replaced through the successor-rollover v1 API"
            ));
        }
    }

    let cached = migration_plan_cache::get(&ctx.db_path, ctx.account_bytes, plan_handle)
        .map_err(|e| plan_stale(&e.to_string()))?;

    let target = ctx.target()?;
    let mut rng = OsRng;
    let mut backend = Backend::new(&ctx.wallet, ctx.account, usk, &mut ctx.store_conn)?;
    let (state, unsigned) = if unsigned_out {
        let (state, unsigned) = engine::build_preparation_unsigned(
            &ctx.network,
            target,
            &mut backend,
            &cached.plan,
            &mut rng,
        )
        .map_err(map_commit_err)?;
        (
            state,
            unsigned.into_iter().map(|tx| tx.into_parts()).collect(),
        )
    } else {
        let state =
            engine::commit_preparation(&ctx.network, target, &mut backend, &cached.plan, &mut rng)
                .map_err(map_commit_err)?;
        (state, Vec::new())
    };

    migration_plan_cache::clear(&ctx.db_path, ctx.account_bytes);
    Ok((state, unsigned))
}

/// Builds and atomically installs one post-terminal scheduled successor.
///
/// The upstream engine writes only to [`SuccessorCandidateBackend`]'s in-memory sink. The exact
/// predecessor state and opaque run/source-owner authority, successor state, bound policy, and
/// retained predecessor evidence reach durable storage together through `ReservationRollover`.
/// The cached plan is cleared only after that CAS commits.
fn rollover_scheduled_successor(
    ctx: &mut CallCtx,
    predecessor: &FfiMigrationRunHandle,
    cached: &migration_plan_cache::CachedPlan,
    usk: Option<zcash_keys::keys::UnifiedSpendingKey>,
    external_signer: bool,
) -> anyhow::Result<DeliverySnapshot> {
    let policy = policy_from_run_handle(&ctx.network, predecessor)?;
    let (predecessor_state, delivery) = {
        let mut store = scheduled_store(ctx)?;
        let state = scheduled_state(&store)?;
        let delivery = store
            .delivery_snapshot()
            .map_err(|e| anyhow!("reading rollover predecessor delivery failed: {e}"))?
            .ok_or_else(|| anyhow!("terminal rollover predecessor has no delivery run"))?;
        (state, delivery)
    };
    if !predecessor_state.is_terminal() {
        return Err(anyhow!(
            "successor rollover requires a terminal canonical predecessor"
        ));
    }
    if delivery.lane() != DeliveryLane::Scheduled
        || delivery.revision() != predecessor.revision
        || delivery.run_identity() != predecessor.run_identity
        || delivery.source_reservation_owner() != predecessor.source_reservation_owner
        || delivery
            .submission_policy()
            .map(SubmissionPolicy::fingerprint)
            != predecessor.policy_fingerprint
    {
        return Err(anyhow!(
            "the successor-rollover handle is stale or does not own the current predecessor"
        ));
    }

    let target = ctx.target()?;
    let successor = {
        let mut backend = SuccessorCandidateBackend::new(
            &ctx.wallet,
            ctx.account,
            usk,
            &mut ctx.store_conn,
            &predecessor_state,
        )?;
        let mut rng = OsRng;
        if external_signer {
            let (state, _unsigned_not_exposed) = engine::build_preparation_unsigned(
                &ctx.network,
                target,
                &mut backend,
                &cached.plan,
                &mut rng,
            )
            .map_err(map_commit_err)?;
            state
        } else {
            engine::commit_preparation(&ctx.network, target, &mut backend, &cached.plan, &mut rng)
                .map_err(map_commit_err)?
        }
    };

    let rollover = ReservationRollover::replace_terminal(
        predecessor.revision,
        predecessor.run_identity,
        predecessor.source_reservation_owner,
        &predecessor_state,
        successor,
    )
    .map_err(|e| anyhow!("invalid terminal migration successor: {e:?}"))?;
    let receipt = MigrationRuntimeStore::rollover_source_reservations(
        &mut ctx.wallet,
        &ctx.account,
        rollover,
        &policy,
    )
    .map_err(|e| anyhow!("committing migration successor rollover failed: {e}"))?;
    migration_plan_cache::clear(&ctx.db_path, ctx.account_bytes);
    Ok(receipt.successor().clone())
}

/// Map a commit error, routing `StalePlan` through the stable plan-stale prefix (the actionable
/// "re-propose" signal).
fn map_commit_err(e: engine::CommitError<anyhow::Error>) -> anyhow::Error {
    match e {
        engine::CommitError::StalePlan => {
            plan_stale("the previewed plan no longer matches the wallet or the build height")
        }
        other => anyhow!("Error committing migration: {other}"),
    }
}

/// Map a rebuild-on-expiry error. `FundingNoteUnavailable` gets the actionable message: the
/// expired transfer's EXACT funding note (matched by nullifier identity — the engine deliberately
/// never substitutes an equal-value note, which could be a sibling transfer's) was spent outside
/// the migration, so the caller must use the typed two-phase abandonment flow before re-proposing
/// and atomically rolling over to a successor. Everything else is a hard error carrying the
/// engine's detail.
fn map_rebuild_err(e: engine::RebuildError<anyhow::Error>) -> anyhow::Error {
    match e {
        engine::RebuildError::FundingNoteUnavailable(value) => anyhow!(
            "the expired transfer's funding note ({} zatoshi) is gone — it was spent outside the \
             migration, so the rebuilt transfer cannot re-spend it; begin and finish typed \
             abandonment with zcashlc_migration_begin_abandonment_v1 and \
             zcashlc_migration_finish_abandonment_v1 using the current run handle, then \
             re-propose and commit the remaining balance through the typed successor-rollover \
             API",
            u64::from(value)
        ),
        other => anyhow!("Error rebuilding expired migration transfer: {other}"),
    }
}

/// The id the opaque delivery lane would next claim at `target` (the engine's `chain tip + 1` —
/// see [`CallCtx::target`]), assuming every due proof succeeds: the next broadcastable row after
/// virtually proving every prove-ready `Signed` row over a scratch copy — no prover runs and
/// nothing persists (`set_transaction_proved` with the row's own bytes only flips the lifecycle
/// state). `None` when the delivery lane has nothing actionable: nothing schedule-due yet,
/// dependencies unmined, rows awaiting an external signature (the signing ceremony, not the
/// delivery lane, advances those), or everything already broadcast/mined.
///
/// The queries built on this ([`zcashlc_migration_has_overdue_transfers`],
/// [`zcashlc_migration_pending_transfer_proposal`]) deliberately assume proofs succeed: a
/// transiently unwitnessable anchor (a restored wallet mid-sync) defers the actual delivery, not
/// the report — the due work exists either way, and the delivery call stays the one place that
/// consults the prover.
fn due_assuming_proving(state: &MigrationState, target: BlockHeight) -> Option<MigrationTxId> {
    if let Some(id) = state.next_broadcastable(target) {
        return Some(id);
    }
    state.next_provable(target)?;
    let mut scratch = state.clone();
    while let Some(id) = scratch.next_provable(target) {
        let bytes = scratch
            .transactions()
            .iter()
            .find(|t| t.id() == id)
            .map(|t| t.pczt().clone())
            .unwrap_or_default();
        scratch.set_transaction_proved(id, bytes);
    }
    scratch.next_broadcastable(target)
}

// ----- public-state derivation (pure; unit-tested) -----

/// What the platform's 5-state machine derives to, before marshaling.
enum DerivedState {
    NotStarted,
    SplitPendingConfirmation,
    InProgress {
        completed_transfers: u32,
        total_transfers: u32,
        next_transfer_ready_at_height: Option<BlockHeight>,
        /// Legacy public projection field. Immediate migration is now represented only by the
        /// authoritative delivery runtime; scheduled engine runs always carry `false` here.
        is_immediate: bool,
    },
    TransferExpired,
    Complete,
}

/// Derive the legacy platform migration state from persisted canonical scheduled state.
///
/// - No stored migration -> `NotStarted`.
/// - A stored `Failed` run (our cancel) -> `NotStarted` (the platform re-plans).
/// - Canonical engine `Complete` is PER-RUN and means fully mined. The public SDK projection stays
///   `InProgress` until every exact resulting Ironwood output is either spendable under the normal
///   wallet policy or current-main-chain spent; whether anything REMAINS to migrate is answered by
///   a fresh propose.
/// - The v1 crate's "split confirmed, schedule pending" intermediate state and its matching
///   attention reason are gone: the engine commits the note split and the transfer schedule
///   atomically, so that moment cannot occur anymore.
///
/// Immediate migration and exact delivery failures are deliberately absent from this compatibility
/// projection. They are surfaced only by the revision-consistent delivery runtime, so this helper
/// cannot reconstruct a second state machine from SDK-local rows.
fn derive_state(
    persisted: Option<&MigrationState>,
    tip: BlockHeight,
    completed_run_outputs_available: bool,
) -> DerivedState {
    let active = persisted.filter(|state| {
        !matches!(
            state.status(),
            MigrationStatus::Complete | MigrationStatus::Failed
        )
    });
    let Some(state) = active else {
        return match persisted {
            Some(state)
                if matches!(state.status(), MigrationStatus::Complete)
                    && completed_run_outputs_available =>
            {
                DerivedState::Complete
            }
            Some(state) if matches!(state.status(), MigrationStatus::Complete) => {
                let total_transfers = state
                    .transactions()
                    .iter()
                    .filter(|tx| matches!(tx.kind(), MigrationTxKind::Transfer { .. }))
                    .count() as u32;
                // The canonical engine is complete once every transaction is mined. Keep the
                // public SDK projection in progress until the exact resulting Ironwood outputs
                // are spendable or current-main-chain spent. This is derived live; it does not
                // create a second persisted state machine.
                DerivedState::InProgress {
                    completed_transfers: total_transfers,
                    total_transfers,
                    next_transfer_ready_at_height: None,
                    is_immediate: false,
                }
            }
            _ => DerivedState::NotStarted,
        };
    };

    // The engine's expiry predicate is defined over `target = tip + 1` (see `target_from_tip`),
    // not the raw tip — membership in `expired_transactions` already excludes `Mined` rows and
    // treats `expiry_height == 0` as "never expires" (see `MigrationState::is_expired`'s doc).
    if !state.expired_transactions(target_from_tip(tip)).is_empty() {
        return DerivedState::TransferExpired;
    }

    let preps_all_mined = state
        .transactions()
        .iter()
        .filter(|t| matches!(t.kind(), MigrationTxKind::Preparation { .. }))
        .all(|t| matches!(t.state(), MigrationTxState::Mined { .. }));
    if !preps_all_mined {
        return DerivedState::SplitPendingConfirmation;
    }

    let transfers: Vec<&MigrationTransaction> = state
        .transactions()
        .iter()
        .filter(|t| matches!(t.kind(), MigrationTxKind::Transfer { .. }))
        .collect();
    let completed = transfers
        .iter()
        .filter(|t| matches!(t.state(), MigrationTxState::Mined { .. }))
        .count() as u32;
    // F6: min over transfers still AWAITING BROADCAST only (`AwaitingSignature`/`Signed`/
    // `Proved`) — NOT merely "not yet mined". A `Broadcast` transfer is already in the mempool;
    // there is nothing left for the platform to prepare for it, so its height must not surface
    // here even when it is numerically the smallest (see `next_transfer_ready_at_height`'s doc).
    let next_ready = transfers
        .iter()
        .filter(|t| {
            matches!(
                t.state(),
                MigrationTxState::AwaitingSignature
                    | MigrationTxState::Signed
                    | MigrationTxState::Proved
            )
        })
        .map(|t| t.scheduled_height())
        .min();
    DerivedState::InProgress {
        completed_transfers: completed,
        total_transfers: transfers.len() as u32,
        next_transfer_ready_at_height: next_ready,
        is_immediate: false,
    }
}

// ============================================================================================
// #[repr(C)] return DTOs
//
// These are named `Ffi*` in Rust because the base names would collide with the engine types this
// module marshals from; the prefix also lands the `Ffi*` C names the header convention wants
// without any `build.rs` `rename_item` entry.
// ============================================================================================

/// Live migration progress. When returned standalone (`zcashlc_migration_progress`), `is_present`
/// is `false` when no migration is in progress; as the payload of
/// [`FfiMigrationState::InProgress`] it is always `true`.
#[repr(C)]
pub struct FfiMigrationProgress {
    /// Whether the remaining fields carry a real progress snapshot.
    pub is_present: bool,
    /// The number of scheduled transfers confirmed on-chain so far.
    pub completed_transfers: u32,
    /// The total number of transfers in the current schedule.
    pub total_transfers: u32,
    /// The Orchard-pool value (zatoshi) not yet migrated to Ironwood — the account's live
    /// spendable Orchard balance.
    pub remaining_orchard_value: i64,
    /// The height at which the next transfer becomes broadcastable, or `-1` if none is scheduled.
    /// Only transfers still AWAITING broadcast count (F6): one already `Broadcast` (in the
    /// mempool, awaiting mining) has nothing left to prepare for, so it never sets this field,
    /// even when its own scheduled height is lower than another transfer's.
    pub next_transfer_ready_at_height: i64,
    /// Whether this progress belongs to the immediate (single-transaction) send-max migration lane
    /// rather than an engine-tracked schedule. The app uses it to keep the immediate aftermath
    /// quiet (no per-transfer UI). Engine-tracked runs report `false`.
    pub is_immediate: bool,
}

impl FfiMigrationProgress {
    fn absent() -> Self {
        FfiMigrationProgress {
            is_present: false,
            completed_transfers: 0,
            total_transfers: 0,
            remaining_orchard_value: 0,
            next_transfer_ready_at_height: -1,
            is_immediate: false,
        }
    }
}

/// Why a migration requires user attention (payload of [`FfiMigrationState::RequiresAttention`]).
#[repr(C, u8)]
pub enum FfiAttentionReason {
    /// The transfer identified by `transfer_id` was terminally rejected at broadcast (its input
    /// note was spent externally, or the network refused it as invalid). `transfer_id` is an owned
    /// C string, freed by [`zcashlc_free_migration_state`].
    #[allow(dead_code)]
    // Retained as part of the published C/Swift ABI even though legacy recording is disabled.
    InvalidTransfer { transfer_id: *mut c_char },
    /// A transaction's expiry elapsed before it could be broadcast (or mined).
    TransferExpired,
}

/// The top-level migration state machine surfaced to the app.
///
/// `#[allow(dead_code)]`: the data-carrying variants' payloads are read by the C consumer across
/// the FFI (cbindgen emits them into the header), which rustc cannot observe.
#[allow(dead_code)]
#[repr(C, u8)]
pub enum FfiMigrationState {
    /// No migration run is stored (none started, or a previous run was cancelled).
    NotStarted,
    /// The run is committed and its preparation (note-split) transactions are not yet all mined.
    SplitPendingConfirmation,
    /// Preparation is mined and the run's transfers are executing.
    InProgress(FfiMigrationProgress),
    /// A transfer cannot proceed automatically; the app must act.
    RequiresAttention(FfiAttentionReason),
    /// Every transaction of the STORED RUN is mined. Per-run: whether anything remains to migrate
    /// is answered by a fresh `zcashlc_migration_propose_transfers` (empty schedule = nothing).
    Complete,
}

/// A planned note split: the per-note output values (zatoshi) and the preparation fees.
#[repr(C)]
pub struct FfiNoteSplitProposal {
    /// Heap array of `output_values_len` output-note values (zatoshi).
    pub output_values: *mut i64,
    pub output_values_len: usize,
    /// The total fees (zatoshi) paid by the preparation (note-split) transactions.
    pub fee: i64,
    /// Opaque identifier of the cached plan this proposal was rendered from. `0` means no live
    /// cached plan backs the proposal.
    pub proposal_handle: u64,
}

/// Legacy prepared-transfer DTO retained for C ABI compatibility with disabled unscoped migration
/// entry points. Current delivery APIs expose artifacts only through opaque claim handles.
#[repr(C)]
pub struct FfiPreparedTransfer {
    /// The transaction's id (the engine's decimal id), as an owned C string when populated by a
    /// pre-capability implementation.
    pub id: *mut c_char,
    /// The finalized transaction's id, as raw (internal-order) 32-byte value.
    pub txid: [u8; 32],
    /// Heap `pczt_len`-byte serialized PCZT when populated by a pre-capability implementation.
    pub pczt: *mut u8,
    pub pczt_len: usize,
}

/// A single scheduled Orchard→Ironwood transfer (element of [`FfiMigrationSchedule`]).
#[repr(C)]
pub struct FfiTransferProposal {
    /// The transfer's id (the engine's decimal id), as an owned C string.
    pub id: *mut c_char,
    /// The value (zatoshi) that crosses the turnstile.
    pub amount: i64,
    /// The "now" reference height at encode time (the chain tip). With ZIP 374 the real anchor is
    /// drawn per transfer and installed at proving time; this field is NOT a commitment-tree
    /// anchor and callers must not treat it as one.
    pub anchor_height: i64,
    /// The height after which the platform may broadcast this transfer.
    pub next_executable_after_height: i64,
    /// The height after which this transfer is no longer valid.
    pub expiry_height: i64,
}

impl FfiTransferProposal {
    fn boxed(
        id: MigrationTxId,
        amount: Zatoshis,
        now_reference: BlockHeight,
        next_executable_after: BlockHeight,
        expiry: BlockHeight,
    ) -> anyhow::Result<*mut Self> {
        Ok(Box::into_raw(Box::new(FfiTransferProposal {
            id: cstring_raw(&u32::from(id).to_string(), "transfer proposal id")?,
            amount: zat_to_i64(amount),
            anchor_height: i64::from(u32::from(now_reference)),
            next_executable_after_height: i64::from(u32::from(next_executable_after)),
            expiry_height: i64::from(u32::from(expiry)),
        })))
    }
}

/// A full migration schedule presented to the user for one-time confirmation, in chronological
/// broadcast order. An empty schedule means there is nothing to migrate.
#[repr(C)]
pub struct FfiMigrationSchedule {
    /// Heap array of `transfers_len` scheduled transfers, in execution order.
    pub transfers: *mut FfiTransferProposal,
    pub transfers_len: usize,
    /// A rough estimate of how long the schedule takes to fully execute, in hours — measured
    /// from the encode-time chain tip to the last scheduled broadcast (#1806).
    pub estimated_duration_hours: u32,
    /// Opaque identifier of the cached plan this schedule was rendered from. Display fields are
    /// never accepted back as commit authority. `0` means no live cached plan backs the schedule.
    pub proposal_handle: u64,
}

/// A single run's estimate (element of [`FfiMigrationRunEstimate`]): what one migration run
/// migrates (the note-split side) and what preparing it costs (the note-preparation side), so
/// the two can be compared.
#[repr(C)]
pub struct FfiRunEstimate {
    /// The total value (zatoshi) that crosses the turnstile in this run.
    pub migratable: i64,
    /// The number of pool-crossing transfers this run makes: one per self-funding note.
    pub crossings: u32,
    /// The number of sequential note-preparation layers this run needs — its wall-clock depth,
    /// since each layer waits for the previous one to mine before it can be broadcast.
    pub prep_layers: u32,
    /// The number of note-preparation transactions this run builds across all its layers.
    pub prep_transactions: u32,
}

/// An estimate of migrating the account's whole spendable balance across successive migration
/// RUNS ("rounds"): one [`FfiRunEstimate`] per run, plus the value left un-migrated at the end.
/// `runs_len == 0` means nothing migrates (a zero or fully sub-quantum balance) — a legitimate
/// estimate, not an error.
#[repr(C)]
pub struct FfiMigrationRunEstimate {
    /// Heap array of `runs_len` per-run estimates, in run order.
    pub runs: *mut FfiRunEstimate,
    pub runs_len: usize,
    /// The value (zatoshi) left in the source pool after the last run — below the smallest
    /// self-funding note, so it never migrates. Zero when the balance divides exactly into
    /// self-funding notes and fees.
    pub final_residual: i64,
}

/// An unsigned PCZT awaiting an external signer (element of [`FfiUnsignedTransferPczts`]).
#[repr(C)]
pub struct FfiUnsignedTransferPczt {
    /// The transaction's id (the engine's decimal id), as an owned C string.
    pub id: *mut c_char,
    /// Heap `pczt_len`-byte serialized unsigned PCZT.
    pub pczt: *mut u8,
    pub pczt_len: usize,
}

/// A set of unsigned PCZTs to route to an external signer. Despite the name, this is really a
/// generic `(id, PCZT bytes)` pair set: [`zcashlc_migration_keystone_apply_batch_signatures`]
/// also returns its batch-SIGNED PCZTs through this same type, positionally paired back up with
/// the ids the caller passed in.
#[repr(C)]
pub struct FfiUnsignedTransferPczts {
    pub ptr: *mut FfiUnsignedTransferPczt,
    pub len: usize,
}

/// One migration transaction's LIVE status, as the engine computes it — an element of
/// [`FfiMigrationTransactionStatuses`]. Mirrors
/// [`zcash_pool_migration::state::TransactionStatus`] field-for-field — minus its
/// `depends_on` edge list, deliberately not marshaled so every row stays heap-pointer-free (a
/// `blocked_on = dependencies` row reports THAT it waits, not on which ids) — and nothing here
/// is derived independently of the engine's own view (see
/// [`zcashlc_migration_transaction_statuses`]).
#[repr(C)]
pub struct FfiMigrationTransactionStatus {
    /// This transaction's stable id (`MigrationTxId`'s raw ordinal). Stable across reads and
    /// across a stale-transfer rebuild (a rebuilt transfer keeps its id; only its PCZT and
    /// heights change), so a wallet may use it as a durable row key.
    pub id: u32,
    /// The transaction's kind: `true` for a phase-2 pool-crossing TRANSFER, `false` for a
    /// note-PREPARATION. See `prep_layer`/`prep_index`/`crossing` for the per-kind payload
    /// (`MigrationTxKind::Preparation { layer, index }` / `MigrationTxKind::Transfer { crossing }`).
    pub is_transfer: bool,
    /// For a preparation: its dependency-layer index. `-1` when `is_transfer` is `true`.
    pub prep_layer: i64,
    /// For a preparation: its index within `prep_layer`. `-1` when `is_transfer` is `true`.
    pub prep_index: i64,
    /// For a transfer: the funding-note crossing index. `-1` when `is_transfer` is `false`.
    pub crossing: i64,
    /// Lifecycle discriminant: `0` = AwaitingSignature, `1` = Signed, `2` = Proved,
    /// `3` = Broadcast, `4` = Mined.
    pub state: u8,
    /// The height at or after which this transaction is due to broadcast.
    pub scheduled_height: i64,
    /// The height after which this transaction can no longer be mined (ZIP 203); `0` means it
    /// never expires (the engine's own sentinel, carried through unchanged).
    pub expiry_height: i64,
    /// The height it was mined at, once `state == 4` (Mined). `-1` otherwise.
    pub mined_height: i64,
    /// The transaction id (raw internal-order bytes), meaningful only when `has_txid` is `true`.
    pub txid: [u8; 32],
    /// Whether `txid` is populated. Set only while `state == 3` (Broadcast): the engine's own
    /// [`MigrationTxState::Mined`] carries just the mined height, not a txid, so once mined this
    /// goes back to `false` — a verbatim mirror of the engine's own view, not a gap in this
    /// marshaling (see [`zcashlc_migration_transaction_statuses`]'s doc).
    pub has_txid: bool,
    /// Whether the wallet can act on this transaction right now.
    pub ready: bool,
    /// The action available now, when `ready` is `true`: `0` = none, `1` = prove, `2` = broadcast.
    pub action: u8,
    /// Why it is not yet actionable, when waiting (and not already broadcast or mined): `0` =
    /// none, `1` = dependencies, `2` = schedule, `3` = anchor_boundary, `4` = signature,
    /// `5` = expired.
    pub blocked_on: u8,
}

/// A snapshot of every committed migration transaction's LIVE status (element type
/// [`FfiMigrationTransactionStatus`]), as returned by [`zcashlc_migration_transaction_statuses`].
/// `len == 0` means no stored run, or a stored run with no transactions — not an error.
#[repr(C)]
pub struct FfiMigrationTransactionStatuses {
    /// Heap array of `len` rows, in the engine's own `transaction_statuses` order (dependency
    /// order: preparation layers first, then transfers).
    pub ptr: *mut FfiMigrationTransactionStatus,
    pub len: usize,
}

impl FfiUnsignedTransferPczts {
    fn from_pairs(pairs: Vec<(MigrationTxId, Vec<u8>)>) -> anyhow::Result<*mut Self> {
        let items = pairs
            .into_iter()
            .map(|(id, bytes)| {
                let id = cstring_raw(&u32::from(id).to_string(), "unsigned transfer pczt id")?;
                let (pczt, pczt_len) = ptr_from_vec(bytes);
                Ok(FfiUnsignedTransferPczt { id, pczt, pczt_len })
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        let (ptr, len) = ptr_from_vec(items);
        Ok(Box::into_raw(Box::new(FfiUnsignedTransferPczts {
            ptr,
            len,
        })))
    }
}
/// A set of animated multi-part QR frame strings for a Keystone batch-signing request. Element
/// order is the wire fragment order — display/scan them in that order.
///
/// This crate's first string-array FFI output type: kept intentionally minimal (unlike
/// [`FfiUnsignedTransferPczts`], there is no paired per-element id or byte blob here, just
/// strings), rather than generalizing [`ffi::BoxedSlice`] (a single binary blob, not an array) or
/// inventing a shared generic array wrapper for a need that has arisen exactly once so far.
#[repr(C)]
pub struct FfiKeystoneQrParts {
    /// Heap array of `len` owned, NUL-terminated UTF-8 strings.
    pub ptr: *mut *mut c_char,
    pub len: usize,
}

impl FfiKeystoneQrParts {
    fn from_parts(parts: Vec<String>) -> anyhow::Result<*mut Self> {
        let items = parts
            .into_iter()
            .map(|part| cstring_raw(&part, "keystone QR part"))
            .collect::<anyhow::Result<Vec<_>>>()?;
        let (ptr, len) = ptr_from_vec(items);
        Ok(Box::into_raw(Box::new(FfiKeystoneQrParts { ptr, len })))
    }
}

/// The result of feeding one scanned QR frame to
/// `zcashlc_migration_keystone_decode_sign_batch_part`, mirroring
/// [`crate::migration_keystone::DecodePartResult`].
///
/// `complete == false` means more frames are needed: `progress` is the 0-100 completion
/// percentage so far, and `data`/the firmware fields are unset (null / `false` / zeroed).
/// `complete == true` means `data` holds the serialized `BatchSignResponse` bytes to pass to
/// `zcashlc_migration_keystone_apply_batch_signatures`, and — when `has_firmware_version` — the
/// signing device's own reported firmware version is in `firmware_major`/`firmware_minor`/
/// `firmware_build`.
#[repr(C)]
pub struct FfiKeystoneBatchDecodeResult {
    pub complete: bool,
    pub progress: u32,
    /// Heap `data_len`-byte serialized `BatchSignResponse` (null unless `complete`).
    pub data: *mut u8,
    pub data_len: usize,
    pub has_firmware_version: bool,
    pub firmware_major: u8,
    pub firmware_minor: u8,
    pub firmware_build: u8,
}

impl FfiKeystoneBatchDecodeResult {
    fn from_parts(result: crate::migration_keystone::DecodePartResult) -> *mut Self {
        let (data, data_len) = match result.data {
            Some(bytes) => ptr_from_vec(bytes),
            None => (ptr::null_mut(), 0),
        };
        let (has_firmware_version, firmware_major, firmware_minor, firmware_build) =
            match result.firmware_version {
                Some([major, minor, build]) => (true, major, minor, build),
                None => (false, 0, 0, 0),
            };
        Box::into_raw(Box::new(FfiKeystoneBatchDecodeResult {
            complete: result.complete,
            progress: result.progress,
            data,
            data_len,
            has_firmware_version,
            firmware_major,
            firmware_minor,
            firmware_build,
        }))
    }
}

// ============================================================================================
// Delivery runtime ABI (v1)
//
// The DTOs below are sanitized read projections. All mutation authority stays in opaque,
// Rust-owned handles whose fields are intentionally private to cbindgen. A host may borrow an
// input handle for one call; every successful mutation returns a fresh owned handle. No host
// supplies a delivery revision, run identity, policy fingerprint, claim token, lease instant, or
// lease duration.
// ============================================================================================

/// Version of the delivery/runtime C ABI and every opaque capability handle it creates.
pub const ZCASHLC_MIGRATION_DELIVERY_ABI_VERSION: u32 = 1;

/// Bounded Rust-owned lease duration for proving, signing, and exact-byte materialization.
const MATERIALIZATION_LEASE_MILLIS: u64 = 15 * 60 * 1_000;
/// Bounded Rust-owned lease duration for one transport submission attempt.
const SUBMISSION_LEASE_MILLIS: u64 = 2 * 60 * 1_000;
/// Bounded Rust-owned lease duration for resolution of an ambiguous transport outcome.
const OUTCOME_RESOLUTION_LEASE_MILLIS: u64 = 2 * 60 * 1_000;

fn lease_duration(kind: ClaimKind) -> LeaseDuration {
    let millis = match kind {
        ClaimKind::Materialization => MATERIALIZATION_LEASE_MILLIS,
        ClaimKind::Submission => SUBMISSION_LEASE_MILLIS,
        ClaimKind::OutcomeResolution => OUTCOME_RESOLUTION_LEASE_MILLIS,
    };
    LeaseDuration::from_millis(millis).expect("delivery lease constants are non-zero")
}

/// Opaque immutable capability identifying one revision-consistent delivery run.
///
/// The private fields are never part of the generated C layout. Obtain a pointer only from this
/// module and free each owned pointer once with [`zcashlc_migration_free_run_handle_v1`].
#[derive(Clone)]
pub struct FfiMigrationRunHandle {
    abi_version: u32,
    account_uuid: [u8; 16],
    lane: DeliveryLane,
    revision: DeliveryRevision,
    run_identity: MigrationRunIdentity,
    source_reservation_owner: SourceReservationOwner,
    policy_fingerprint: Option<PolicyFingerprint>,
    policy_validation_failure: Option<PolicyValidationFailure>,
    submission_transport: Option<u8>,
    submission_endpoint: Option<String>,
}

/// Opaque immutable capability for one exact delivery artifact and, when present, its live
/// Rust-generated claim token. Exact proposal/PCZT/transaction bytes remain private and are copied
/// out only through owned accessors.
#[derive(Clone)]
pub struct FfiMigrationClaimHandle {
    abi_version: u32,
    run: FfiMigrationRunHandle,
    artifact_identity: DeliveryArtifactIdentity,
    evidence: zcash_pool_migration::delivery::DeliveryArtifactEvidence,
    signer_ownership: SignerOwnership,
    status: ClaimStatus,
    claim_kind: Option<ClaimKind>,
    token: Option<ClaimToken>,
    expiry_height: BlockHeight,
    proposal: Option<Vec<u8>>,
    external_signing_pczt: Option<Vec<u8>>,
    signed_pczt: Option<Vec<u8>>,
    exact_transaction: Option<Vec<u8>>,
    txid: Option<[u8; 32]>,
}

/// Sanitized summary of one exact artifact. It deliberately excludes capability tokens, exact
/// proposal/PCZT/transaction bytes, policy fingerprints, and clock-session identities.
#[repr(C)]
pub struct FfiMigrationClaimSummaryV1 {
    /// `0` = scheduled, `1` = immediate.
    pub artifact_lane: u8,
    /// Scheduled canonical transaction id, or `-1` for the immediate lane.
    pub scheduled_transaction_id: i64,
    /// Immediate artifact identity; all-zero for the scheduled lane.
    pub immediate_artifact_identity: [u8; 32],
    /// `0` = SDK signer, `1` = external signer.
    pub signer_ownership: u8,
    /// `0` materializing, `1` materializationFailed, `2` awaitingExternalSignature, `3` staged,
    /// `4` submitting, `5` outcomeUnknown, `6` broadcasted, `7` confirmed,
    /// `8` expiredUnmined, `9` externalSigningExpiredUnmined.
    pub status: u8,
    /// `-1` = no live claim, `0` = materialization, `1` = submission,
    /// `2` = outcome resolution.
    pub claim_kind: i8,
    /// Exact external-signing bytes have crossed the cancellation-unsafe exposure boundary.
    pub externally_exposed: bool,
    pub has_signed_pczt: bool,
    pub has_exact_transaction: bool,
    pub expiry_height: u32,
    pub has_txid: bool,
    pub txid: [u8; 32],
    /// `-1` = none; otherwise the `DeliveryFailureReason` ordering documented by
    /// `delivery_failure_tag` below.
    pub last_error: i8,
    /// Opaque Rust-owned capability for this exact reconstructed claim.
    pub claim_handle: *mut FfiMigrationClaimHandle,
}

/// Sanitized owning projection of one retained predecessor. Rollover does not erase old ambiguous
/// or externally exposed artifacts; each retained entry therefore carries its own opaque run
/// handle and claim summaries so that exact predecessor remains resumable and reconcilable.
#[repr(C)]
pub struct FfiRetainedMigrationRunV1 {
    pub has_canonical_state: bool,
    pub canonical_status: i8,
    pub canonical_transaction_count: u32,
    pub destination_spendability: u8,
    pub delivery_revision: u64,
    pub delivery_lane: u8,
    pub delivery_phase: u8,
    pub storage_finality: u8,
    pub storage_recovery_reason: i8,
    pub delivery_release_height: i64,
    pub active_source_reservation_count: u64,
    pub has_submission_policy: bool,
    pub policy_validation_failure: i8,
    pub safe_to_cancel: bool,
    pub claims: *mut FfiMigrationClaimSummaryV1,
    pub claims_len: usize,
    pub run_handle: *mut FfiMigrationRunHandle,
}

/// One owning, revision-consistent account runtime projection.
#[repr(C)]
pub struct FfiMigrationRuntimeSnapshotV1 {
    pub abi_version: u32,
    pub account_uuid: [u8; 16],
    /// `-1` none, `0` planning, `1` committed, `2` inProgress, `3` complete, `4` failed.
    pub canonical_status: i8,
    pub canonical_transaction_count: u32,
    /// `0` compatible, `1` unavailable, `2` future, `3` corrupt.
    pub schema_provenance: u8,
    /// Compatible/future schema version, otherwise zero.
    pub schema_version: u32,
    /// `0` fresh, `1` recovery required.
    pub legacy_cutover: u8,
    pub legacy_object_count: u32,
    /// `0` not spendable, `1` spendable, `2` already spent, `3` not applicable (no run).
    pub destination_spendability: u8,
    /// `0` available, `1` unavailable.
    pub availability: u8,
    /// `-1` none; otherwise `runtime_unavailable_tag`.
    pub unavailable_reason: i8,
    /// Schema version, legacy object count, or storage-recovery tag carried by the reason.
    pub unavailable_detail: u32,
    /// `0` unrestricted, `1` excluding migration sources, `2` blocked.
    pub ordinary_spend_authorization: u8,
    /// `-1` for allowed; `0` migration active, `1` destination not spendable,
    /// `2` runtime unavailable, `3` finality recovery.
    pub ordinary_spend_block_reason: i8,
    /// Release height for `excluding migration sources`, otherwise `-1`.
    pub ordinary_spend_release_height: i64,
    /// `0` allowed, `1` blocked.
    pub account_deletion_authorization: u8,
    /// `-1` allowed, `0` runtime unavailable, `1` unresolved delivery.
    pub account_deletion_block_reason: i8,
    /// `0` allowed, `1` blocked.
    pub canonical_mutation_authorization: u8,
    /// `-1` allowed, `0` runtime unavailable, `1` delivery owned.
    pub canonical_mutation_block_reason: i8,
    pub has_delivery: bool,
    pub delivery_revision: u64,
    /// `-1` no delivery, `0` scheduled, `1` immediate.
    pub delivery_lane: i8,
    /// `-1` no delivery, `0` active, `1` paused, `2` abandoning, `3` abandoned.
    pub delivery_phase: i8,
    /// `-1` no delivery, `0` noRun, `1` active, `2` completePendingFinality,
    /// `3` finalized, `4` recoveryRequired.
    pub storage_finality: i8,
    /// `-1` none; otherwise `storage_recovery_tag`.
    pub storage_recovery_reason: i8,
    pub delivery_release_height: i64,
    /// Aggregate finality across the current run and every retained predecessor. Uses the same
    /// tags as `storage_finality`, but remains meaningful when `has_delivery` is false.
    pub aggregate_storage_finality: i8,
    /// Aggregate recovery reason across current and retained runs, or `-1`.
    pub aggregate_storage_recovery_reason: i8,
    /// Aggregate release height across current and retained runs, or `-1`.
    pub aggregate_delivery_release_height: i64,
    /// Exact live source-reservation rows owned by the current run.
    pub active_source_reservation_count: u64,
    pub has_submission_policy: bool,
    /// `-1` none; otherwise `policy_failure_tag`.
    pub policy_validation_failure: i8,
    /// Rust-derived cancellation verdict, including external-PCZT exposure.
    pub safe_to_cancel: bool,
    pub claims: *mut FfiMigrationClaimSummaryV1,
    pub claims_len: usize,
    /// Opaque immutable run capability owned by this DTO; null when no delivery run exists.
    pub run_handle: *mut FfiMigrationRunHandle,
    /// Every predecessor whose reservations, finality, or exposed evidence remain authoritative.
    pub retained_runs: *mut FfiRetainedMigrationRunV1,
    pub retained_runs_len: usize,
}

/// One atomic all-account runtime read.
#[repr(C)]
pub struct FfiMigrationRuntimeBatchV1 {
    pub abi_version: u32,
    pub accounts: *mut FfiMigrationRuntimeSnapshotV1,
    pub accounts_len: usize,
}

fn delivery_lane_tag(lane: DeliveryLane) -> u8 {
    match lane {
        DeliveryLane::Scheduled => 0,
        DeliveryLane::Immediate => 1,
    }
}

fn signer_ownership_tag(signer: SignerOwnership) -> u8 {
    match signer {
        SignerOwnership::Sdk => 0,
        SignerOwnership::External => 1,
    }
}

fn claim_status_tag(status: ClaimStatus) -> u8 {
    match status {
        ClaimStatus::Materializing => 0,
        ClaimStatus::MaterializationFailed => 1,
        ClaimStatus::AwaitingExternalSignature => 2,
        ClaimStatus::Staged => 3,
        ClaimStatus::Submitting => 4,
        ClaimStatus::OutcomeUnknown => 5,
        ClaimStatus::Broadcasted => 6,
        ClaimStatus::Confirmed => 7,
        ClaimStatus::ExpiredUnmined => 8,
        ClaimStatus::ExternalSigningExpiredUnmined => 9,
    }
}

fn claim_kind_tag(kind: Option<ClaimKind>) -> i8 {
    match kind {
        None => -1,
        Some(ClaimKind::Materialization) => 0,
        Some(ClaimKind::Submission) => 1,
        Some(ClaimKind::OutcomeResolution) => 2,
    }
}

fn delivery_failure_tag(reason: Option<DeliveryFailureReason>) -> i8 {
    match reason {
        None => -1,
        Some(DeliveryFailureReason::MaterializationFailed) => 0,
        Some(DeliveryFailureReason::MaterializationLeaseExpired) => 1,
        Some(DeliveryFailureReason::SigningCancelled) => 2,
        Some(DeliveryFailureReason::TransportSetupFailed) => 3,
        Some(DeliveryFailureReason::TransportDidNotBegin) => 4,
        Some(DeliveryFailureReason::SubmissionLeaseExpired) => 5,
        Some(DeliveryFailureReason::TransportOutcomeUnknown) => 6,
    }
}

fn storage_recovery_tag(reason: StorageRecoveryReason) -> i8 {
    match reason {
        StorageRecoveryReason::TransferEvidenceLost => 0,
        StorageRecoveryReason::RewoundBeyondFinalityHorizon => 1,
        StorageRecoveryReason::CorruptFinalityEvidence => 2,
        StorageRecoveryReason::ExternalSigningExposureUnresolved => 3,
    }
}

fn runtime_unavailable_tag(reason: RuntimeUnavailableReason) -> (i8, u32) {
    match reason {
        RuntimeUnavailableReason::SchemaUnavailable => (0, 0),
        RuntimeUnavailableReason::FutureSchema(version) => (1, version.as_u32()),
        RuntimeUnavailableReason::CorruptDeliveryState => (2, 0),
        RuntimeUnavailableReason::LegacyCutoverRecovery(objects) => (3, objects.as_u32()),
        RuntimeUnavailableReason::SubmissionPolicyMissing => (4, 0),
        RuntimeUnavailableReason::SubmissionPolicyMismatch => (5, 0),
        RuntimeUnavailableReason::DeliveryInconsistent => (6, 0),
        RuntimeUnavailableReason::FinalityRecovery(reason) => {
            (7, u32::try_from(storage_recovery_tag(reason)).unwrap_or(0))
        }
        RuntimeUnavailableReason::MissingSpendAuthorization => (8, 0),
    }
}

fn policy_failure_tag(failure: Option<PolicyValidationFailure>) -> i8 {
    match failure {
        None => -1,
        Some(PolicyValidationFailure::InvalidEncoding) => 0,
        Some(PolicyValidationFailure::PolicyTooLarge) => 1,
        Some(PolicyValidationFailure::NetworkMismatch) => 2,
        Some(PolicyValidationFailure::ConsensusMismatch) => 3,
        Some(_) => 4,
    }
}

fn run_handle(account_uuid: [u8; 16], snapshot: &DeliverySnapshot) -> FfiMigrationRunHandle {
    let (submission_transport, submission_endpoint) = snapshot
        .submission_policy()
        .map(|policy| {
            let transport = policy.request().transport();
            let tag = match transport {
                SubmissionTransport::DirectTls(_) => 0,
                SubmissionTransport::TorOnion(_) => 1,
                SubmissionTransport::LoopbackDevelopment(_) => 2,
                SubmissionTransport::TorProxyTls(_) => 3,
            };
            (Some(tag), Some(transport.endpoint().to_owned()))
        })
        .unwrap_or((None, None));
    FfiMigrationRunHandle {
        abi_version: ZCASHLC_MIGRATION_DELIVERY_ABI_VERSION,
        account_uuid,
        lane: snapshot.lane(),
        revision: snapshot.revision(),
        run_identity: snapshot.run_identity(),
        source_reservation_owner: snapshot.source_reservation_owner(),
        policy_fingerprint: snapshot
            .submission_policy()
            .map(SubmissionPolicy::fingerprint),
        policy_validation_failure: snapshot.policy_validation_failure(),
        submission_transport,
        submission_endpoint,
    }
}

fn claim_summary(
    account_uuid: [u8; 16],
    snapshot: &DeliverySnapshot,
    claim: &zcash_pool_migration::delivery::DeliveryClaim,
) -> anyhow::Result<FfiMigrationClaimSummaryV1> {
    let (scheduled_transaction_id, immediate_artifact_identity) = match claim.artifact_identity() {
        DeliveryArtifactIdentity::Scheduled(identity) => {
            (i64::from(u32::from(identity.transaction_id())), [0; 32])
        }
        DeliveryArtifactIdentity::Immediate(id) => (-1, *id.as_bytes()),
    };
    let txid = claim.txid().map_or([0; 32], |txid| *txid.as_ref());
    Ok(FfiMigrationClaimSummaryV1 {
        artifact_lane: delivery_lane_tag(claim.lane()),
        scheduled_transaction_id,
        immediate_artifact_identity,
        signer_ownership: signer_ownership_tag(claim.signer_ownership()),
        status: claim_status_tag(claim.status()),
        claim_kind: claim_kind_tag(claim.claim_kind()),
        externally_exposed: claim.external_signing_pczt().is_some(),
        has_signed_pczt: claim.signed_pczt().is_some(),
        has_exact_transaction: claim.exact_transaction().is_some(),
        expiry_height: u32::from(claim.expiry_height()),
        has_txid: claim.txid().is_some(),
        txid,
        last_error: delivery_failure_tag(claim.last_error()),
        claim_handle: Box::into_raw(Box::new(claim_handle(
            account_uuid,
            snapshot,
            claim.artifact_identity(),
        )?)),
    })
}

fn claim_handle(
    account_uuid: [u8; 16],
    snapshot: &DeliverySnapshot,
    artifact_identity: DeliveryArtifactIdentity,
) -> anyhow::Result<FfiMigrationClaimHandle> {
    let claim = snapshot
        .claims()
        .iter()
        .find(|claim| claim.artifact_identity() == artifact_identity)
        .ok_or_else(|| anyhow!("delivery snapshot omitted the requested artifact"))?;
    let proposal = match claim.evidence() {
        DeliveryArtifactEvidence::Scheduled(_) => None,
        DeliveryArtifactEvidence::Immediate(evidence) => {
            let proposal = ImmediateProposal::decode(evidence.canonical_proposal())
                .map_err(|e| anyhow!("persisted immediate proposal evidence is corrupt: {e}"))?;
            Some(proposal.payload().as_bytes().to_vec())
        }
    };
    Ok(FfiMigrationClaimHandle {
        abi_version: ZCASHLC_MIGRATION_DELIVERY_ABI_VERSION,
        run: run_handle(account_uuid, snapshot),
        artifact_identity,
        evidence: claim.evidence().clone(),
        signer_ownership: claim.signer_ownership(),
        status: claim.status(),
        claim_kind: claim.claim_kind(),
        token: claim.token(),
        expiry_height: claim.expiry_height(),
        proposal,
        external_signing_pczt: claim
            .external_signing_pczt()
            .map(|pczt| pczt.bytes().to_vec()),
        signed_pczt: claim.signed_pczt().map(|pczt| pczt.bytes().to_vec()),
        exact_transaction: claim
            .exact_transaction()
            .map(|transaction| transaction.bytes().to_vec()),
        txid: claim.txid().map(|txid| *txid.as_ref()),
    })
}

fn free_claim_summary_fields(claim: &mut FfiMigrationClaimSummaryV1) {
    if !claim.claim_handle.is_null() {
        drop(unsafe { Box::from_raw(claim.claim_handle) });
        claim.claim_handle = ptr::null_mut();
    }
}

fn claim_summaries_ffi(
    account_uuid: [u8; 16],
    delivery: &DeliverySnapshot,
) -> anyhow::Result<(*mut FfiMigrationClaimSummaryV1, usize)> {
    let mut claims = Vec::with_capacity(delivery.claims().len());
    for claim in delivery.claims() {
        match claim_summary(account_uuid, delivery, claim) {
            Ok(claim) => claims.push(claim),
            Err(error) => {
                for claim in &mut claims {
                    free_claim_summary_fields(claim);
                }
                return Err(error);
            }
        }
    }
    Ok(ptr_from_vec(claims))
}

fn retained_run_ffi(
    account_uuid: [u8; 16],
    retained: &RetainedMigrationRun,
) -> anyhow::Result<FfiRetainedMigrationRunV1> {
    let (has_canonical_state, canonical_status, canonical_transaction_count) =
        match retained.canonical_state() {
            None => (false, -1, 0),
            Some(state) => {
                let status = match state.status() {
                    MigrationStatus::Planning => 0,
                    MigrationStatus::Committed => 1,
                    MigrationStatus::InProgress => 2,
                    MigrationStatus::Complete => 3,
                    MigrationStatus::Failed => 4,
                };
                (
                    true,
                    status,
                    count_to_u32(state.transactions().len(), "retained canonical transaction")?,
                )
            }
        };
    let destination_spendability = match retained.destination_spendability() {
        DestinationSpendability::NotSpendable => 0,
        DestinationSpendability::Spendable => 1,
        DestinationSpendability::AlreadySpent => 2,
        DestinationSpendability::NotApplicable => 3,
    };
    let delivery = retained.delivery();
    let delivery_phase = match delivery.phase() {
        DeliveryPhase::Active => 0,
        DeliveryPhase::Paused => 1,
        DeliveryPhase::Abandoning => 2,
        DeliveryPhase::Abandoned => 3,
    };
    let (storage_finality, storage_recovery_reason, delivery_release_height) = match delivery
        .storage_finality()
    {
        StorageFinality::NoRun => (0, -1, -1),
        StorageFinality::Active => (1, -1, -1),
        StorageFinality::CompletePendingFinality(release) => {
            (2, -1, i64::from(u32::from(release.release_at())))
        }
        StorageFinality::Finalized(release) => (3, -1, i64::from(u32::from(release.release_at()))),
        StorageFinality::RecoveryRequired(reason) => (4, storage_recovery_tag(reason), -1),
    };
    let (claims, claims_len) = claim_summaries_ffi(account_uuid, delivery)?;
    Ok(FfiRetainedMigrationRunV1 {
        has_canonical_state,
        canonical_status,
        canonical_transaction_count,
        destination_spendability,
        delivery_revision: delivery.revision().as_u64(),
        delivery_lane: delivery_lane_tag(delivery.lane()),
        delivery_phase,
        storage_finality,
        storage_recovery_reason,
        delivery_release_height,
        active_source_reservation_count: delivery.active_source_reservation_count(),
        has_submission_policy: delivery.submission_policy().is_some(),
        policy_validation_failure: policy_failure_tag(delivery.policy_validation_failure()),
        safe_to_cancel: delivery.safe_to_cancel(),
        claims,
        claims_len,
        run_handle: Box::into_raw(Box::new(run_handle(account_uuid, delivery))),
    })
}

fn free_retained_run_fields(retained: &mut FfiRetainedMigrationRunV1) {
    free_ptr_from_vec_with(retained.claims, retained.claims_len, |claim| {
        free_claim_summary_fields(claim)
    });
    retained.claims = ptr::null_mut();
    retained.claims_len = 0;
    if !retained.run_handle.is_null() {
        drop(unsafe { Box::from_raw(retained.run_handle) });
        retained.run_handle = ptr::null_mut();
    }
}

fn runtime_snapshot_ffi(
    account_uuid: [u8; 16],
    runtime: &MigrationRuntimeSnapshot,
) -> anyhow::Result<FfiMigrationRuntimeSnapshotV1> {
    let (canonical_status, canonical_transaction_count) = match runtime.canonical_state() {
        None => (-1, 0),
        Some(state) => {
            let status = match state.status() {
                MigrationStatus::Planning => 0,
                MigrationStatus::Committed => 1,
                MigrationStatus::InProgress => 2,
                MigrationStatus::Complete => 3,
                MigrationStatus::Failed => 4,
            };
            (
                status,
                count_to_u32(state.transactions().len(), "canonical transaction")?,
            )
        }
    };
    let (schema_provenance, schema_version) = match runtime.schema_provenance() {
        zcash_pool_migration::delivery::DeliverySchemaProvenance::Compatible(version) => {
            (0, version.as_u32())
        }
        zcash_pool_migration::delivery::DeliverySchemaProvenance::Unavailable => (1, 0),
        zcash_pool_migration::delivery::DeliverySchemaProvenance::Future(version) => {
            (2, version.as_u32())
        }
        zcash_pool_migration::delivery::DeliverySchemaProvenance::Corrupt => (3, 0),
    };
    let (legacy_cutover, legacy_object_count) = match runtime.legacy_cutover() {
        LegacyCutoverStatus::Fresh => (0, 0),
        LegacyCutoverStatus::RecoveryRequired(objects) => (1, objects.as_u32()),
    };
    let destination_spendability = match runtime.destination_spendability() {
        DestinationSpendability::NotSpendable => 0,
        DestinationSpendability::Spendable => 1,
        DestinationSpendability::AlreadySpent => 2,
        DestinationSpendability::NotApplicable => 3,
    };
    let (availability, unavailable_reason, unavailable_detail) = match runtime.availability() {
        MigrationRuntimeAvailability::Available => (0, -1, 0),
        MigrationRuntimeAvailability::Unavailable(reason) => {
            let (tag, detail) = runtime_unavailable_tag(reason);
            (1, tag, detail)
        }
    };
    let (ordinary_spend_authorization, ordinary_spend_block_reason, ordinary_spend_release_height) =
        match runtime.ordinary_spend_authorization() {
            OrdinarySpendAuthorization::Allowed(OrdinarySpendScope::Unrestricted) => (0, -1, -1),
            OrdinarySpendAuthorization::Allowed(OrdinarySpendScope::ExcludingMigrationSources(
                release,
            )) => (1, -1, i64::from(u32::from(release.release_at()))),
            OrdinarySpendAuthorization::Blocked(reason) => {
                let tag = match reason {
                    OrdinarySpendBlockReason::MigrationActive => 0,
                    OrdinarySpendBlockReason::DestinationNotSpendable => 1,
                    OrdinarySpendBlockReason::RuntimeUnavailable(_) => 2,
                    OrdinarySpendBlockReason::FinalityRecovery(_) => 3,
                };
                (2, tag, -1)
            }
        };
    let (account_deletion_authorization, account_deletion_block_reason) =
        match runtime.account_deletion_authorization() {
            AccountDeletionAuthorization::Allowed => (0, -1),
            AccountDeletionAuthorization::Blocked(reason) => (
                1,
                match reason {
                    AccountDeletionBlockReason::RuntimeUnavailable(_) => 0,
                    AccountDeletionBlockReason::UnresolvedDelivery(_) => 1,
                },
            ),
        };
    let (canonical_mutation_authorization, canonical_mutation_block_reason) =
        match runtime.canonical_mutation_authorization() {
            CanonicalMutationAuthorization::Allowed => (0, -1),
            CanonicalMutationAuthorization::Blocked(reason) => (
                1,
                match reason {
                    CanonicalMutationBlockReason::RuntimeUnavailable(_) => 0,
                    CanonicalMutationBlockReason::DeliveryOwned(_) => 1,
                },
            ),
        };

    let mut result = FfiMigrationRuntimeSnapshotV1 {
        abi_version: ZCASHLC_MIGRATION_DELIVERY_ABI_VERSION,
        account_uuid,
        canonical_status,
        canonical_transaction_count,
        schema_provenance,
        schema_version,
        legacy_cutover,
        legacy_object_count,
        destination_spendability,
        availability,
        unavailable_reason,
        unavailable_detail,
        ordinary_spend_authorization,
        ordinary_spend_block_reason,
        ordinary_spend_release_height,
        account_deletion_authorization,
        account_deletion_block_reason,
        canonical_mutation_authorization,
        canonical_mutation_block_reason,
        has_delivery: false,
        delivery_revision: 0,
        delivery_lane: -1,
        delivery_phase: -1,
        storage_finality: -1,
        storage_recovery_reason: -1,
        delivery_release_height: -1,
        aggregate_storage_finality: -1,
        aggregate_storage_recovery_reason: -1,
        aggregate_delivery_release_height: -1,
        active_source_reservation_count: 0,
        has_submission_policy: false,
        policy_validation_failure: -1,
        safe_to_cancel: true,
        claims: ptr::null_mut(),
        claims_len: 0,
        run_handle: ptr::null_mut(),
        retained_runs: ptr::null_mut(),
        retained_runs_len: 0,
    };

    if let Some(delivery) = runtime.delivery() {
        result.has_delivery = true;
        result.delivery_revision = delivery.revision().as_u64();
        result.delivery_lane = i8::try_from(delivery_lane_tag(delivery.lane())).unwrap();
        result.delivery_phase = match delivery.phase() {
            DeliveryPhase::Active => 0,
            DeliveryPhase::Paused => 1,
            DeliveryPhase::Abandoning => 2,
            DeliveryPhase::Abandoned => 3,
        };
        let (storage_finality, recovery, release) = match delivery.storage_finality() {
            StorageFinality::NoRun => (0, -1, -1),
            StorageFinality::Active => (1, -1, -1),
            StorageFinality::CompletePendingFinality(release) => {
                (2, -1, i64::from(u32::from(release.release_at())))
            }
            StorageFinality::Finalized(release) => {
                (3, -1, i64::from(u32::from(release.release_at())))
            }
            StorageFinality::RecoveryRequired(reason) => (4, storage_recovery_tag(reason), -1),
        };
        result.storage_finality = storage_finality;
        result.storage_recovery_reason = recovery;
        result.delivery_release_height = release;
        result.active_source_reservation_count = delivery.active_source_reservation_count();
        result.has_submission_policy = delivery.submission_policy().is_some();
        result.policy_validation_failure = policy_failure_tag(delivery.policy_validation_failure());
        result.safe_to_cancel = runtime.safe_to_cancel();
        (result.claims, result.claims_len) = claim_summaries_ffi(account_uuid, delivery)?;
        result.run_handle = Box::into_raw(Box::new(run_handle(account_uuid, delivery)));
    }
    let (storage_finality, recovery, release) = match runtime.aggregate_storage_finality() {
        StorageFinality::NoRun => (0, -1, -1),
        StorageFinality::Active => (1, -1, -1),
        StorageFinality::CompletePendingFinality(release) => {
            (2, -1, i64::from(u32::from(release.release_at())))
        }
        StorageFinality::Finalized(release) => (3, -1, i64::from(u32::from(release.release_at()))),
        StorageFinality::RecoveryRequired(reason) => (4, storage_recovery_tag(reason), -1),
    };
    result.aggregate_storage_finality = storage_finality;
    result.aggregate_storage_recovery_reason = recovery;
    result.aggregate_delivery_release_height = release;
    result.safe_to_cancel = runtime.safe_to_cancel();
    let mut retained_runs = Vec::with_capacity(runtime.retained_predecessors().len());
    for retained in runtime.retained_predecessors() {
        match retained_run_ffi(account_uuid, retained) {
            Ok(retained) => retained_runs.push(retained),
            Err(error) => {
                for retained in &mut retained_runs {
                    free_retained_run_fields(retained);
                }
                free_runtime_snapshot_fields(&mut result);
                return Err(error);
            }
        }
    }
    (result.retained_runs, result.retained_runs_len) = ptr_from_vec(retained_runs);
    Ok(result)
}

/// Returns one account's canonical-plus-delivery runtime from a single atomic wallet-store read.
///
/// # Safety
/// Common database/account pointer rules apply. Free the returned DTO with
/// [`zcashlc_free_migration_runtime_snapshot_v1`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_runtime_snapshot_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut FfiMigrationRuntimeSnapshotV1 {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let account =
            MigrationRuntimeStore::account_migration_runtime(&mut ctx.wallet, &ctx.account)
                .map_err(|e| anyhow!("reading atomic migration runtime failed: {e}"))?
                .ok_or_else(|| anyhow!("wallet account has no migration runtime"))?;
        let snapshot = runtime_snapshot_ffi(ctx.account_bytes, account.runtime())?;
        Ok(Box::into_raw(Box::new(snapshot)))
    });
    unwrap_exc_or_null(res)
}

/// Returns exactly one owning runtime per wallet account from one SQLite read transaction.
///
/// # Safety
/// Common database-path pointer rules apply. Free the result with
/// [`zcashlc_free_migration_runtime_batch_v1`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_runtime_batch_v1(
    db_data: *const u8,
    db_data_len: usize,
    network_id: u32,
) -> *mut FfiMigrationRuntimeBatchV1 {
    let res = catch_panic(|| {
        let network = parse_network(network_id)?;
        let mut wallet = unsafe { crate::wallet_db(db_data, db_data_len, network)? };
        let batch = MigrationRuntimeStore::all_account_migration_runtimes(&mut wallet)
            .map_err(|e| anyhow!("reading atomic all-account migration runtime failed: {e:?}"))?;
        let mut accounts = Vec::with_capacity(batch.accounts().len());
        for account in batch.accounts() {
            match runtime_snapshot_ffi(
                *account.account_id().expose_uuid().as_bytes(),
                account.runtime(),
            ) {
                Ok(account) => accounts.push(account),
                Err(error) => {
                    for account in &mut accounts {
                        free_runtime_snapshot_fields(account);
                    }
                    return Err(error);
                }
            }
        }
        let (accounts, accounts_len) = ptr_from_vec(accounts);
        Ok(Box::into_raw(Box::new(FfiMigrationRuntimeBatchV1 {
            abi_version: ZCASHLC_MIGRATION_DELIVERY_ABI_VERSION,
            accounts,
            accounts_len,
        })))
    });
    unwrap_exc_or_null(res)
}

fn free_runtime_snapshot_fields(snapshot: &mut FfiMigrationRuntimeSnapshotV1) {
    free_ptr_from_vec_with(snapshot.claims, snapshot.claims_len, |claim| {
        free_claim_summary_fields(claim)
    });
    snapshot.claims = ptr::null_mut();
    snapshot.claims_len = 0;
    if !snapshot.run_handle.is_null() {
        drop(unsafe { Box::from_raw(snapshot.run_handle) });
        snapshot.run_handle = ptr::null_mut();
    }
    free_ptr_from_vec_with(
        snapshot.retained_runs,
        snapshot.retained_runs_len,
        free_retained_run_fields,
    );
    snapshot.retained_runs = ptr::null_mut();
    snapshot.retained_runs_len = 0;
}

/// Frees one owning runtime DTO and its sanitized claims/run handle.
///
/// # Safety
/// `snapshot` must be null or one pointer returned by `zcashlc_migration_runtime_snapshot_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_migration_runtime_snapshot_v1(
    snapshot: *mut FfiMigrationRuntimeSnapshotV1,
) {
    if !snapshot.is_null() {
        let mut snapshot = unsafe { Box::from_raw(snapshot) };
        free_runtime_snapshot_fields(&mut snapshot);
    }
}

/// Frees one atomic batch and every nested runtime allocation.
///
/// # Safety
/// `batch` must be null or one pointer returned by `zcashlc_migration_runtime_batch_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_migration_runtime_batch_v1(
    batch: *mut FfiMigrationRuntimeBatchV1,
) {
    if !batch.is_null() {
        let batch = unsafe { Box::from_raw(batch) };
        free_ptr_from_vec_with(batch.accounts, batch.accounts_len, |snapshot| {
            free_runtime_snapshot_fields(snapshot)
        });
    }
}

/// Returns a fresh owned clone of an immutable run capability.
///
/// # Safety
/// `handle` must be null or a live pointer returned by this module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_clone_run_handle_v1(
    handle: *const FfiMigrationRunHandle,
) -> *mut FfiMigrationRunHandle {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    Box::into_raw(Box::new(handle.clone()))
}

/// Frees one opaque run capability. Null is a no-op.
///
/// # Safety
/// A non-null pointer must have been returned by this module and not already freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_free_run_handle_v1(handle: *mut FfiMigrationRunHandle) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

unsafe fn checked_run_handle<'a>(
    handle: *const FfiMigrationRunHandle,
) -> anyhow::Result<&'a FfiMigrationRunHandle> {
    let handle = unsafe { handle.as_ref() }.ok_or_else(|| anyhow!("run handle is null"))?;
    if handle.abi_version != ZCASHLC_MIGRATION_DELIVERY_ABI_VERSION {
        return Err(anyhow!("unsupported migration run handle version"));
    }
    Ok(handle)
}

/// Returns `-1` when the run has a validated bound policy; otherwise returns the stable typed
/// policy-validation-failure tag. Returns `-2` for an invalid handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_run_policy_validation_failure_v1(
    handle: *const FfiMigrationRunHandle,
) -> i32 {
    let res = catch_panic(|| {
        let handle = unsafe { checked_run_handle(handle)? };
        Ok(i32::from(policy_failure_tag(
            handle.policy_validation_failure,
        )))
    });
    unwrap_exc_or(res, -2)
}

/// Returns the validated transport tag (`0` direct TLS, `1` Tor onion, `2` loopback development,
/// `3` public TLS over Tor), or `-1` when no policy is bound / the handle is invalid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_run_submission_transport_v1(
    handle: *const FfiMigrationRunHandle,
) -> i32 {
    let res = catch_panic(|| {
        let handle = unsafe { checked_run_handle(handle)? };
        Ok(handle.submission_transport.map(i32::from).unwrap_or(-1))
    });
    unwrap_exc_or(res, -1)
}

/// Copies the exact Rust-normalized submission endpoint, or returns an empty optional slice when
/// no validated policy is bound.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_run_submission_endpoint_v1(
    handle: *const FfiMigrationRunHandle,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let handle = unsafe { checked_run_handle(handle)? };
        Ok(match handle.submission_endpoint.as_ref() {
            Some(endpoint) => ffi::BoxedSlice::some(endpoint.as_bytes().to_vec()),
            None => ffi::BoxedSlice::none(),
        })
    });
    unwrap_exc_or_null(res)
}

/// Returns a fresh owned clone of an exact immutable claim capability.
///
/// # Safety
/// `handle` must be null or a live pointer returned by this module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_clone_claim_handle_v1(
    handle: *const FfiMigrationClaimHandle,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let handle = unsafe { checked_claim_handle(handle)? };
        Ok(Box::into_raw(Box::new(handle.clone())))
    });
    unwrap_exc_or_null(res)
}

/// Frees one opaque claim capability. Null is a no-op.
///
/// # Safety
/// A non-null pointer must have been returned by this module and not already freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_free_claim_handle_v1(
    handle: *mut FfiMigrationClaimHandle,
) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

unsafe fn checked_claim_handle<'a>(
    handle: *const FfiMigrationClaimHandle,
) -> anyhow::Result<&'a FfiMigrationClaimHandle> {
    let handle = unsafe { handle.as_ref() }.ok_or_else(|| anyhow!("claim handle is null"))?;
    if handle.abi_version != ZCASHLC_MIGRATION_DELIVERY_ABI_VERSION {
        return Err(anyhow!("unsupported migration claim handle version"));
    }
    Ok(handle)
}

/// Returns a fresh owned run capability carrying the claim's latest revision.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_claim_run_handle_v1(
    handle: *const FfiMigrationClaimHandle,
) -> *mut FfiMigrationRunHandle {
    let res = catch_panic(|| {
        let handle = unsafe { checked_claim_handle(handle)? };
        Ok(Box::into_raw(Box::new(handle.run.clone())))
    });
    unwrap_exc_or_null(res)
}

unsafe fn claim_bytes(
    handle: *const FfiMigrationClaimHandle,
    select: impl FnOnce(&FfiMigrationClaimHandle) -> Option<&[u8]> + std::panic::UnwindSafe,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let handle = unsafe { checked_claim_handle(handle)? };
        Ok(match select(handle) {
            Some(bytes) => ffi::BoxedSlice::some(bytes.to_vec()),
            None => ffi::BoxedSlice::none(),
        })
    });
    unwrap_exc_or_null(res)
}

/// Copies the post-commit canonical immediate wallet proposal, if this handle owns one.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_claim_proposal_v1(
    handle: *const FfiMigrationClaimHandle,
) -> *mut ffi::BoxedSlice {
    unsafe { claim_bytes(handle, |handle| handle.proposal.as_deref()) }
}

/// Copies exact PCZT bytes already staged before external exposure, if present.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_claim_external_signing_pczt_v1(
    handle: *const FfiMigrationClaimHandle,
) -> *mut ffi::BoxedSlice {
    unsafe { claim_bytes(handle, |handle| handle.external_signing_pczt.as_deref()) }
}

/// Copies exact canonical merged signed-PCZT bytes, if present.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_claim_signed_pczt_v1(
    handle: *const FfiMigrationClaimHandle,
) -> *mut ffi::BoxedSlice {
    unsafe { claim_bytes(handle, |handle| handle.signed_pczt.as_deref()) }
}

/// Copies exact network transaction bytes, if materialization is complete.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_claim_exact_transaction_v1(
    handle: *const FfiMigrationClaimHandle,
) -> *mut ffi::BoxedSlice {
    unsafe { claim_bytes(handle, |handle| handle.exact_transaction.as_deref()) }
}

/// Copies the exact transaction id, if materialization is complete.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_claim_txid_v1(
    handle: *const FfiMigrationClaimHandle,
) -> *mut ffi::BoxedSlice {
    unsafe {
        claim_bytes(handle, |handle| {
            handle.txid.as_ref().map(<[u8; 32]>::as_slice)
        })
    }
}

/// Returns the stable claim-status tag, or `-1` on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_claim_status_v1(
    handle: *const FfiMigrationClaimHandle,
) -> i32 {
    let res = catch_panic(|| {
        let handle = unsafe { checked_claim_handle(handle)? };
        Ok(i32::from(claim_status_tag(handle.status)))
    });
    unwrap_exc_or(res, -1)
}

/// Returns the consensus expiry height, or `-1` on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_claim_expiry_height_v1(
    handle: *const FfiMigrationClaimHandle,
) -> i64 {
    let res = catch_panic(|| {
        let handle = unsafe { checked_claim_handle(handle)? };
        Ok(i64::from(u32::from(handle.expiry_height)))
    });
    unwrap_exc_or(res, -1)
}

/// Returns the consensus branch id sealed into the claim's canonical Rust evidence, or `-1` when
/// the handle or its evidence is invalid.
///
/// Swift uses this typed projection only for selected-endpoint preflight. It never infers the
/// transaction branch from the expiry height (an upgrade can activate inside the expiry window),
/// and it never parses or accepts caller-authored proposal or transaction bytes. Scheduled claims
/// read the branch from their canonical PCZT; immediate claims read it from their sealed proposal.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_claim_consensus_branch_id_v1(
    handle: *const FfiMigrationClaimHandle,
) -> i64 {
    let res = catch_panic(|| {
        let handle = unsafe { checked_claim_handle(handle)? };
        let branch_id = match &handle.evidence {
            DeliveryArtifactEvidence::Scheduled(evidence) => {
                let pczt = Pczt::parse(evidence.canonical_pczt())
                    .map_err(|e| anyhow!("decoding sealed scheduled PCZT failed: {e:?}"))?;
                BranchId::try_from(*pczt.global().consensus_branch_id()).map_err(|_| {
                    anyhow!("sealed scheduled PCZT has an invalid consensus branch id")
                })?
            }
            DeliveryArtifactEvidence::Immediate(evidence) => {
                let proposal = ImmediateProposal::decode(evidence.canonical_proposal())
                    .map_err(|e| anyhow!("decoding sealed immediate proposal failed: {e}"))?;
                proposal.branch_id()
            }
        };
        Ok(i64::from(u32::from(branch_id)))
    });
    unwrap_exc_or(res, -1)
}

fn ensure_handle_account(expected: &[u8; 16], actual: &[u8; 16]) -> anyhow::Result<()> {
    if expected == actual {
        Ok(())
    } else {
        Err(anyhow!(
            "migration capability belongs to a different account"
        ))
    }
}

fn scheduled_store(ctx: &mut CallCtx) -> anyhow::Result<PoolMigrations<&mut Connection>> {
    PoolMigrations::for_account(&mut ctx.store_conn, ctx.account)
        .map_err(|e| anyhow!("opening the account delivery store failed: {e}"))
}

fn scheduled_state<S: PoolMigrationRead>(store: &S) -> anyhow::Result<MigrationState>
where
    S::Error: std::fmt::Display,
{
    store
        .get_migration()
        .map_err(|e| anyhow!("reading canonical migration state failed: {e}"))?
        .ok_or_else(|| anyhow!("no canonical scheduled migration is stored"))
}

fn policy_from_transport_intent(
    network: &NetworkParams,
    transport_tag: u8,
    endpoint: &str,
) -> Result<SubmissionPolicy, PolicyValidationFailure> {
    let transport = match transport_tag {
        0 => DirectTlsEndpoint::try_from(endpoint.to_owned()).map(SubmissionTransport::DirectTls),
        1 => TorOnionEndpoint::try_from(endpoint.to_owned()).map(SubmissionTransport::TorOnion),
        2 => LoopbackDevelopmentEndpoint::try_from(endpoint.to_owned())
            .map(SubmissionTransport::LoopbackDevelopment),
        3 => {
            TorProxyTlsEndpoint::try_from(endpoint.to_owned()).map(SubmissionTransport::TorProxyTls)
        }
        _ => return Err(PolicyValidationFailure::InvalidEncoding),
    }
    .map_err(|_| PolicyValidationFailure::InvalidEncoding)?;
    let context = SubmissionContext::from_parameters(network);
    SubmissionPolicy::validate(SubmissionPolicyRequest::new(context, transport), context)
}

fn policy_from_run_handle(
    network: &NetworkParams,
    handle: &FfiMigrationRunHandle,
) -> anyhow::Result<SubmissionPolicy> {
    let transport = handle
        .submission_transport
        .ok_or_else(|| anyhow!("the migration run has no validated submission transport"))?;
    let endpoint = handle
        .submission_endpoint
        .as_deref()
        .ok_or_else(|| anyhow!("the migration run has no validated submission endpoint"))?;
    let policy = policy_from_transport_intent(network, transport, endpoint).map_err(|failure| {
        anyhow!("the persisted migration submission policy is invalid: {failure:?}")
    })?;
    if handle.policy_fingerprint != Some(policy.fingerprint()) {
        return Err(anyhow!(
            "the migration run handle carries inconsistent submission-policy evidence"
        ));
    }
    Ok(policy)
}

fn signer_ownership(tag: u8) -> anyhow::Result<SignerOwnership> {
    match tag {
        0 => Ok(SignerOwnership::Sdk),
        1 => Ok(SignerOwnership::External),
        _ => Err(anyhow!("unknown migration signer ownership tag {tag}")),
    }
}

fn submission_outcome(tag: u8) -> anyhow::Result<SubmissionOutcome> {
    match tag {
        0 => Ok(SubmissionOutcome::Accepted),
        1 => Ok(SubmissionOutcome::KnownUnsent),
        2 => Ok(SubmissionOutcome::Unknown),
        _ => Err(anyhow!("unknown migration submission outcome tag {tag}")),
    }
}

fn delivery_failure(tag: u8) -> anyhow::Result<DeliveryFailureReason> {
    match tag {
        0 => Ok(DeliveryFailureReason::MaterializationFailed),
        1 => Ok(DeliveryFailureReason::MaterializationLeaseExpired),
        2 => Ok(DeliveryFailureReason::SigningCancelled),
        3 => Ok(DeliveryFailureReason::TransportSetupFailed),
        4 => Ok(DeliveryFailureReason::TransportDidNotBegin),
        5 => Ok(DeliveryFailureReason::SubmissionLeaseExpired),
        6 => Ok(DeliveryFailureReason::TransportOutcomeUnknown),
        _ => Err(anyhow!("unknown migration delivery failure tag {tag}")),
    }
}

fn required_policy_fingerprint(
    handle: &FfiMigrationRunHandle,
) -> anyhow::Result<PolicyFingerprint> {
    handle
        .policy_fingerprint
        .ok_or_else(|| anyhow!("the migration run has no validated submission policy"))
}

fn required_claim_token(handle: &FfiMigrationClaimHandle) -> anyhow::Result<ClaimToken> {
    handle
        .token
        .ok_or_else(|| anyhow!("the migration artifact has no live claim token"))
}

unsafe fn require_run<'a>(
    ctx: &CallCtx,
    handle: *const FfiMigrationRunHandle,
) -> anyhow::Result<&'a FfiMigrationRunHandle> {
    let handle = unsafe { checked_run_handle(handle)? };
    ensure_handle_account(&ctx.account_bytes, &handle.account_uuid)?;
    Ok(handle)
}

unsafe fn require_scheduled_run<'a>(
    ctx: &CallCtx,
    handle: *const FfiMigrationRunHandle,
) -> anyhow::Result<&'a FfiMigrationRunHandle> {
    let handle = unsafe { require_run(ctx, handle)? };
    if handle.lane != DeliveryLane::Scheduled {
        return Err(anyhow!(
            "a scheduled delivery operation received an immediate run handle"
        ));
    }
    Ok(handle)
}

unsafe fn require_claim<'a>(
    ctx: &CallCtx,
    handle: *const FfiMigrationClaimHandle,
) -> anyhow::Result<&'a FfiMigrationClaimHandle> {
    let handle = unsafe { checked_claim_handle(handle)? };
    ensure_handle_account(&ctx.account_bytes, &handle.run.account_uuid)?;
    Ok(handle)
}

/// Validates and binds raw transport intent entirely in Rust. A typed validation failure is
/// persisted and returned as a fresh run handle with no bound policy; only storage/ABI errors
/// return null. The input capability is borrowed and remains caller-owned.
///
/// # Safety
/// Common database/account pointer rules apply; `run_handle` must be a live borrowed handle and
/// `endpoint` must be a non-null UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_bind_submission_policy_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    run_handle_ptr: *const FfiMigrationRunHandle,
    transport_tag: u8,
    endpoint: *const c_char,
) -> *mut FfiMigrationRunHandle {
    let res = catch_panic(|| {
        if endpoint.is_null() {
            return Err(anyhow!("submission endpoint is null"));
        }
        let endpoint = unsafe { CStr::from_ptr(endpoint) }
            .to_str()
            .map_err(|e| anyhow!("submission endpoint is not UTF-8: {e}"))?;
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_scheduled_run(&ctx, run_handle_ptr)? };
        let expected_revision = handle.revision;
        let run_identity = handle.run_identity;
        let policy = policy_from_transport_intent(&ctx.network, transport_tag, endpoint);
        let account_uuid = ctx.account_bytes;
        let mut store = scheduled_store(&mut ctx)?;
        let state = scheduled_state(&store)?;
        let snapshot = match policy {
            Ok(policy) => store
                .bind_submission_policy(&state, expected_revision, run_identity, &policy)
                .map_err(|e| anyhow!("binding migration submission policy failed: {e}"))?,
            Err(failure) => store
                .record_policy_validation_failure(&state, expected_revision, run_identity, failure)
                .map_err(|e| anyhow!("recording migration policy failure failed: {e}"))?,
        };
        Ok(Box::into_raw(Box::new(run_handle(account_uuid, &snapshot))))
    });
    unwrap_exc_or_null(res)
}

/// Retained only as a disabled C ABI compatibility symbol.
///
/// The original, unreleased-WIP v1 ABI did not accept a gross-amount authorization. It therefore
/// cannot safely reserve spend authority under the current migration contract. The signature must
/// remain stable for already-generated headers and binaries, but every invocation fails closed
/// before reading caller data or opening wallet state. New callers must use v2.
///
/// # Safety
/// All arguments are ignored and no caller pointers are dereferenced. The function always returns
/// NULL and sets the last-error channel.
#[deprecated(note = "use zcashlc_migration_reserve_immediate_v2")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_reserve_immediate_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    signer_tag: u8,
    transport_tag: u8,
    endpoint: *const c_char,
) -> *mut FfiMigrationClaimHandle {
    let _ = (
        db_data,
        db_data_len,
        account_uuid_bytes,
        network_id,
        signer_tag,
        transport_tag,
        endpoint,
    );
    let res = catch_panic(|| {
        Err(anyhow!(
            "zcashlc_migration_reserve_immediate_v1 is disabled because its legacy ABI lacks a gross-amount authorization; use zcashlc_migration_reserve_immediate_v2"
        ))
    });
    unwrap_exc_or_null(res)
}

/// Atomically derives and reserves an immediate Orchard-to-Ironwood proposal, binds its validated
/// submission policy, enforces the user-confirmed maximum gross amount against the exact selected
/// Orchard inputs, and acquires the initial bounded materialization claim. Proposal bytes are
/// unavailable to the host until this call commits successfully.
///
/// # Safety
/// Common database/account pointer rules apply; `endpoint` must be a non-null UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_reserve_immediate_v2(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    signer_tag: u8,
    maximum_gross_amount: i64,
    transport_tag: u8,
    endpoint: *const c_char,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        if endpoint.is_null() {
            return Err(anyhow!("submission endpoint is null"));
        }
        let endpoint = unsafe { CStr::from_ptr(endpoint) }
            .to_str()
            .map_err(|e| anyhow!("submission endpoint is not UTF-8: {e}"))?;
        let signer = signer_ownership(signer_tag)?;
        let maximum_gross_amount = Zatoshis::from_nonnegative_i64(maximum_gross_amount)
            .map_err(|_| anyhow!("maximum immediate migration gross amount is invalid"))?;
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let policy = policy_from_transport_intent(&ctx.network, transport_tag, endpoint)
            .map_err(|failure| anyhow!("immediate submission policy is invalid: {failure:?}"))?;
        let artifact = ImmediateMigrationDeliveryStore::reserve_immediate_delivery(
            &mut ctx.wallet,
            ImmediateMigrationIntent::new(ctx.account, signer, maximum_gross_amount),
            &policy,
            lease_duration(ClaimKind::Materialization),
        )
        .map_err(|e| anyhow!("reserving immediate migration delivery failed: {e}"))?;
        let artifact_identity = DeliveryArtifactIdentity::Immediate(artifact.evidence().identity());
        let handle = claim_handle(ctx.account_bytes, artifact.snapshot(), artifact_identity)?;
        Ok(Box::into_raw(Box::new(handle)))
    });
    unwrap_exc_or_null(res)
}

/// Acquires bounded materialization authority for one canonical scheduled transaction.
///
/// A null return with no last error means no claim was eligible. Lease duration is selected by
/// Rust and never crosses the ABI.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_claim_materialization_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    run_handle_ptr: *const FfiMigrationRunHandle,
    transaction_id: u32,
    signer_tag: u8,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_scheduled_run(&ctx, run_handle_ptr)? };
        let policy_fingerprint = required_policy_fingerprint(handle)?;
        let signer = signer_ownership(signer_tag)?;
        let account_uuid = ctx.account_bytes;
        let mut store = scheduled_store(&mut ctx)?;
        let state = scheduled_state(&store)?;
        let id = MigrationTxId::new(transaction_id);
        let evidence = scheduled_artifact_evidence(&state, id)
            .map(DeliveryArtifactEvidence::Scheduled)
            .ok_or_else(|| anyhow!("scheduled migration transaction {transaction_id} not found"))?;
        let artifact_identity = evidence.identity();
        let Some(snapshot) = store
            .claim_materialization(
                &state,
                handle.revision,
                handle.run_identity,
                &evidence,
                signer,
                lease_duration(ClaimKind::Materialization),
                policy_fingerprint,
            )
            .map_err(|e| anyhow!("claiming migration materialization failed: {e}"))?
        else {
            return Ok(ptr::null_mut());
        };
        Ok(Box::into_raw(Box::new(claim_handle(
            account_uuid,
            &snapshot,
            artifact_identity,
        )?)))
    });
    unwrap_exc_or_null(res)
}

fn prove_immediate_pczt(pczt: Pczt, expected_branch_id: BranchId) -> anyhow::Result<Pczt> {
    let branch_id = BranchId::try_from(*pczt.global().consensus_branch_id())
        .map_err(|_| anyhow!("immediate PCZT has an invalid consensus branch id"))?;
    if branch_id != expected_branch_id {
        return Err(anyhow!(
            "immediate PCZT consensus branch differs from sealed proposal evidence"
        ));
    }

    let mut prover = Prover::new(pczt);
    if prover.requires_orchard_proof() {
        let circuit_version =
            zcash_primitives::transaction::components::orchard::bundle_version_for_branch(
                branch_id,
                orchard::ValuePool::Orchard,
            )
            .ok_or_else(|| anyhow!("immediate PCZT branch does not support Orchard"))?
            .circuit_version();
        prover = prover
            .create_orchard_proof(cached_orchard_proving_key(circuit_version))
            .map_err(|e| anyhow!("creating immediate Orchard proof failed: {e:?}"))?;
    }
    if prover.requires_ironwood_proof() {
        prover = prover
            .create_ironwood_proof(cached_orchard_proving_key(
                orchard::circuit::OrchardCircuitVersion::PostNu6_3,
            ))
            .map_err(|e| anyhow!("creating immediate Ironwood proof failed: {e:?}"))?;
    }
    if prover.requires_sapling_proofs() {
        return Err(anyhow!(
            "reserved Orchard-to-Ironwood proposal unexpectedly requires Sapling proofs"
        ));
    }
    Ok(prover.finish())
}

/// Builds and proves the exact PCZT sealed by an immediate external-signer claim, then stages it
/// durably before returning a handle that can expose those bytes to the signer.
///
/// Swift supplies no proposal or PCZT. The proposal target, consensus branch, expiry, sources,
/// destination, amount, and fee all come from the post-reservation Rust evidence. The returned
/// handle is the first point at which external-signing bytes are accessible.
///
/// # Safety
/// Common database/account pointer rules apply. `claim_handle_ptr` must be a live borrowed claim
/// handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_prepare_immediate_external_signing_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_claim(&ctx, claim_handle_ptr)? };
        if handle.signer_ownership != SignerOwnership::External {
            return Err(anyhow!(
                "immediate external preparation requires an external-signer claim"
            ));
        }
        if handle.claim_kind != Some(ClaimKind::Materialization) {
            return Err(anyhow!(
                "immediate external preparation requires a materialization claim"
            ));
        }
        let evidence = match &handle.evidence {
            DeliveryArtifactEvidence::Immediate(evidence) => evidence.clone(),
            DeliveryArtifactEvidence::Scheduled(_) => {
                return Err(anyhow!(
                    "immediate external preparation received a scheduled claim"
                ));
            }
        };
        let envelope = ImmediateProposal::decode(evidence.canonical_proposal())
            .map_err(|e| anyhow!("decoding sealed immediate proposal envelope failed: {e}"))?;
        let artifact_identity = DeliveryArtifactIdentity::Immediate(evidence.identity());
        if handle.artifact_identity != artifact_identity
            || handle.expiry_height != envelope.expiry_height()
            || BranchId::for_height(&ctx.network, envelope.target_height()) != envelope.branch_id()
        {
            return Err(anyhow!(
                "immediate claim identity, expiry, or branch does not match sealed evidence"
            ));
        }
        let proposal_bytes = handle
            .proposal
            .clone()
            .ok_or_else(|| anyhow!("immediate claim omitted its post-commit wallet proposal"))?;
        if proposal_bytes != envelope.payload().as_bytes() {
            return Err(anyhow!(
                "immediate claim proposal payload differs from sealed evidence"
            ));
        }
        let token = required_claim_token(handle)?;
        let policy_fingerprint = required_policy_fingerprint(&handle.run)?;
        let expected_revision = handle.run.revision;
        let run_identity = handle.run.run_identity;
        let account = ctx.account;
        let account_uuid = ctx.account_bytes;
        let network = ctx.network;
        let target_height = envelope.target_height();
        let expiry_height = envelope.expiry_height();
        let branch_id = envelope.branch_id();

        let snapshot = ctx.wallet.transactionally(|wallet| -> anyhow::Result<_> {
            let proposal = ProtoProposal::decode(proposal_bytes.as_slice())
                .map_err(|e| anyhow!("decoding reserved immediate proposal failed: {e}"))?
                .try_into_standard_proposal(&network, wallet)
                .map_err(|e| anyhow!("reconstructing reserved immediate proposal failed: {e:?}"))?;
            if proposal.steps().len() != 1
                || BlockHeight::from(proposal.min_target_height()) != target_height
                || ProtoProposal::from_standard_proposal(&proposal).encode_to_vec()
                    != proposal_bytes
            {
                return Err(anyhow!(
                    "reserved immediate proposal differs from its canonical sealed payload"
                ));
            }
            let pczt = create_pczt_from_proposal::<_, _, Infallible, _, Infallible, _>(
                wallet,
                &network,
                account,
                OvkPolicy::Sender,
                &proposal,
                Some(expiry_height),
                BundlePadding::DEFAULT,
            )
            .map_err(|e| anyhow!("building reserved immediate PCZT failed: {e}"))?;
            let pczt = prove_immediate_pczt(pczt, branch_id)?;
            let pczt = ExternalSigningPczt::parse(
                pczt.serialize()
                    .map_err(|e| anyhow!("serializing immediate PCZT failed: {e:?}"))?,
            )
            .map_err(|e| anyhow!("validating immediate external-signing PCZT failed: {e}"))?;
            ImmediateMigrationDeliveryStore::stage_immediate_external_signing_pczt(
                wallet,
                &account,
                expected_revision,
                run_identity,
                evidence.identity(),
                token,
                &pczt,
                policy_fingerprint,
            )
            .map_err(|e| anyhow!("staging immediate external-signing PCZT failed: {e}"))
        })?;

        Ok(Box::into_raw(Box::new(claim_handle(
            account_uuid,
            &snapshot,
            artifact_identity,
        )?)))
    });
    unwrap_exc_or_null(res)
}

/// Stages exact PCZT bytes durably before an external signer can observe them.
///
/// For scheduled migration artifacts, `pczt_ptr` must be null and `pczt_len` zero: Rust derives
/// the exact canonical unsigned PCZT from the claimed generation and persists it under the live
/// token before the returned handle can expose bytes. Immediate claims are rejected before the
/// pointer is read; they use [`zcashlc_migration_prepare_immediate_external_signing_v1`] so no
/// host-authored PCZT can cross the reservation boundary.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_stage_external_signing_pczt_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
    pczt_ptr: *const u8,
    pczt_len: usize,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_claim(&ctx, claim_handle_ptr)? };
        if handle.signer_ownership != SignerOwnership::External {
            return Err(anyhow!("external PCZT requires an external-signer claim"));
        }
        let token = required_claim_token(handle)?;
        let policy_fingerprint = required_policy_fingerprint(&handle.run)?;
        let artifact_identity = handle.artifact_identity;
        let account_uuid = ctx.account_bytes;
        let snapshot = match artifact_identity {
            DeliveryArtifactIdentity::Scheduled(identity) => {
                if !pczt_ptr.is_null() || pczt_len != 0 {
                    return Err(anyhow!(
                        "scheduled external signing rejects caller-supplied PCZT bytes"
                    ));
                }
                let mut store = scheduled_store(&mut ctx)?;
                let state = scheduled_state(&store)?;
                let evidence = scheduled_artifact_evidence(&state, identity.transaction_id())
                    .ok_or_else(|| anyhow!("the claimed scheduled transaction is absent"))?;
                if DeliveryArtifactIdentity::Scheduled(evidence.identity()) != artifact_identity {
                    return Err(anyhow!(
                        "the external-signing claim belongs to an archived transaction attempt"
                    ));
                }
                let pczt = ExternalSigningPczt::parse(evidence.canonical_pczt().to_vec())
                    .map_err(|e| anyhow!("canonical external-signing PCZT is invalid: {e}"))?;
                store
                    .stage_external_signing_pczt(
                        &state,
                        handle.run.revision,
                        handle.run.run_identity,
                        artifact_identity,
                        token,
                        &pczt,
                        policy_fingerprint,
                    )
                    .map_err(|e| anyhow!("staging external-signing PCZT failed: {e}"))?
            }
            DeliveryArtifactIdentity::Immediate(identity) => {
                let _ = identity;
                return Err(anyhow!(
                    "immediate external signing must use zcashlc_migration_prepare_immediate_external_signing_v1; caller-supplied PCZT bytes are not authorized"
                ));
            }
        };
        Ok(Box::into_raw(Box::new(claim_handle(
            account_uuid,
            &snapshot,
            artifact_identity,
        )?)))
    });
    unwrap_exc_or_null(res)
}

/// Validates a signer response as the canonical merge of the exact staged PCZT, then stages that
/// merge durably. A late response never creates a replacement artifact.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_stage_signed_pczt_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
    signer_pczt_ptr: *const u8,
    signer_pczt_len: usize,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_claim(&ctx, claim_handle_ptr)? };
        let staged = handle
            .external_signing_pczt
            .as_ref()
            .ok_or_else(|| anyhow!("no exact external-signing PCZT is staged"))?;
        let staged = ExternalSigningPczt::parse(staged.clone())
            .map_err(|e| anyhow!("staged external-signing PCZT is corrupt: {e}"))?;
        let signed = staged
            .merge_signed(unsafe { slice_or_empty(signer_pczt_ptr, signer_pczt_len) }.to_vec())
            .map_err(|e| {
                anyhow!("external signer response is not bound to the staged PCZT: {e}")
            })?;
        let token = required_claim_token(handle)?;
        let policy_fingerprint = required_policy_fingerprint(&handle.run)?;
        let artifact_identity = handle.artifact_identity;
        let account_uuid = ctx.account_bytes;
        let snapshot = match artifact_identity {
            DeliveryArtifactIdentity::Scheduled(_) => {
                let mut store = scheduled_store(&mut ctx)?;
                let state = scheduled_state(&store)?;
                store
                    .stage_signed_pczt(
                        &state,
                        handle.run.revision,
                        handle.run.run_identity,
                        artifact_identity,
                        token,
                        &signed,
                        policy_fingerprint,
                    )
                    .map_err(|e| anyhow!("staging signed migration PCZT failed: {e}"))?
            }
            DeliveryArtifactIdentity::Immediate(identity) => {
                ImmediateMigrationDeliveryStore::stage_immediate_signed_pczt(
                    &mut ctx.wallet,
                    &ctx.account,
                    handle.run.revision,
                    handle.run.run_identity,
                    identity,
                    token,
                    &signed,
                    policy_fingerprint,
                )
                .map_err(|e| anyhow!("staging immediate signed PCZT failed: {e}"))?
            }
        };
        Ok(Box::into_raw(Box::new(claim_handle(
            account_uuid,
            &snapshot,
            artifact_identity,
        )?)))
    });
    unwrap_exc_or_null(res)
}

/// Finalizes the exact signed PCZT bound to an immediate external-signer claim, stores the
/// resulting wallet transaction, and stages exact delivery evidence in one SQLite transaction.
///
/// The signer response must first pass [`zcashlc_migration_stage_signed_pczt_v1`], which persists
/// the canonical merge against the Rust-built PCZT. This call accepts no PCZT or transaction bytes
/// from Swift; it consumes only that opaque claim and exposes exact network bytes only through the
/// fresh post-commit handle.
///
/// # Safety
/// Common database/account pointer rules apply. `claim_handle_ptr` must be a live borrowed claim
/// handle returned after staging a signer response.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_finalize_immediate_external_signing_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_claim(&ctx, claim_handle_ptr)? };
        if handle.signer_ownership != SignerOwnership::External {
            return Err(anyhow!(
                "immediate external finalization requires an external-signer claim"
            ));
        }
        if handle.claim_kind != Some(ClaimKind::Materialization) {
            return Err(anyhow!(
                "immediate external finalization requires a materialization claim"
            ));
        }
        let evidence = match &handle.evidence {
            DeliveryArtifactEvidence::Immediate(evidence) => evidence.clone(),
            DeliveryArtifactEvidence::Scheduled(_) => {
                return Err(anyhow!(
                    "immediate external finalization received a scheduled claim"
                ));
            }
        };
        let envelope = ImmediateProposal::decode(evidence.canonical_proposal())
            .map_err(|e| anyhow!("decoding sealed immediate proposal envelope failed: {e}"))?;
        let artifact_identity = DeliveryArtifactIdentity::Immediate(evidence.identity());
        if handle.artifact_identity != artifact_identity
            || handle.expiry_height != envelope.expiry_height()
            || BranchId::for_height(&ctx.network, envelope.target_height()) != envelope.branch_id()
        {
            return Err(anyhow!(
                "immediate claim identity, expiry, or branch does not match sealed evidence"
            ));
        }
        let proposal_bytes = handle
            .proposal
            .clone()
            .ok_or_else(|| anyhow!("immediate claim omitted its post-commit wallet proposal"))?;
        if proposal_bytes != envelope.payload().as_bytes() {
            return Err(anyhow!(
                "immediate claim proposal payload differs from sealed evidence"
            ));
        }
        let signed_pczt = handle
            .signed_pczt
            .as_ref()
            .ok_or_else(|| anyhow!("immediate claim has no staged signer merge"))?;
        let pczt = Pczt::parse(signed_pczt)
            .map_err(|e| anyhow!("staged immediate signed PCZT is corrupt: {e:?}"))?;
        let pczt_branch_id = BranchId::try_from(*pczt.global().consensus_branch_id())
            .map_err(|_| anyhow!("signed immediate PCZT has an invalid consensus branch id"))?;
        if pczt_branch_id != envelope.branch_id() {
            return Err(anyhow!(
                "signed immediate PCZT branch differs from sealed proposal evidence"
            ));
        }
        let prover = Prover::new(pczt);
        if prover.requires_orchard_proof()
            || prover.requires_ironwood_proof()
            || prover.requires_sapling_proofs()
        {
            return Err(anyhow!(
                "signed immediate PCZT lost proofs that were staged before signer exposure"
            ));
        }
        let pczt = prover.finish();
        let token = required_claim_token(handle)?;
        let policy_fingerprint = required_policy_fingerprint(&handle.run)?;
        let expected_revision = handle.run.revision;
        let run_identity = handle.run.run_identity;
        let account = ctx.account;
        let account_uuid = ctx.account_bytes;
        let network = ctx.network;
        let target_height = envelope.target_height();

        let snapshot = ctx.wallet.transactionally(|wallet| -> anyhow::Result<_> {
            let proposal = ProtoProposal::decode(proposal_bytes.as_slice())
                .map_err(|e| anyhow!("decoding reserved immediate proposal failed: {e}"))?
                .try_into_standard_proposal(&network, wallet)
                .map_err(|e| anyhow!("reconstructing reserved immediate proposal failed: {e:?}"))?;
            if proposal.steps().len() != 1
                || BlockHeight::from(proposal.min_target_height()) != target_height
                || ProtoProposal::from_standard_proposal(&proposal).encode_to_vec()
                    != proposal_bytes
            {
                return Err(anyhow!(
                    "reserved immediate proposal differs from its canonical sealed payload"
                ));
            }
            let txid = extract_and_store_transaction_from_pczt::<_, ()>(wallet, pczt, None, None)
                .map_err(|e| anyhow!("extracting signed immediate PCZT failed: {e:?}"))?;
            let transaction = wallet
                .get_transaction(txid)
                .map_err(|e| anyhow!("reading finalized immediate transaction failed: {e}"))?
                .ok_or_else(|| {
                    anyhow!("finalized immediate transaction was not stored atomically")
                })?;
            let exact = exact_immediate_transaction(&evidence, &transaction).map_err(|e| {
                anyhow!("binding finalized transaction to reserved evidence failed: {e}")
            })?;
            ImmediateMigrationDeliveryStore::stage_immediate_transaction(
                wallet,
                &account,
                expected_revision,
                run_identity,
                token,
                &exact,
                policy_fingerprint,
            )
            .map_err(|e| anyhow!("staging finalized immediate transaction failed: {e}"))
        })?;

        Ok(Box::into_raw(Box::new(claim_handle(
            account_uuid,
            &snapshot,
            artifact_identity,
        )?)))
    });
    unwrap_exc_or_null(res)
}

fn scheduled_identity_in_state(
    state: &MigrationState,
    transaction_id: MigrationTxId,
) -> anyhow::Result<DeliveryArtifactIdentity> {
    scheduled_artifact_evidence(state, transaction_id)
        .map(|evidence| DeliveryArtifactIdentity::Scheduled(evidence.identity()))
        .ok_or_else(|| {
            anyhow!(
                "scheduled migration transaction {} is absent from canonical state",
                u32::from(transaction_id)
            )
        })
}

/// Validates the durable generation authority carried by an expired-transfer handle.
///
/// Lease tokens are deliberately irrelevant: they are cleared when an attempt terminalizes. The
/// immutable `(row id, attempt fingerprint)` must still identify the current canonical attempt,
/// and the handle itself must have observed a positively expired terminal claim status. This
/// rejects both a formerly-live handle and a terminal handle replayed after a same-row rebuild.
fn validate_expired_rebuild_generation(
    artifact_identity: DeliveryArtifactIdentity,
    status: ClaimStatus,
    state: &MigrationState,
) -> anyhow::Result<zcash_pool_migration::delivery::ScheduledArtifactIdentity> {
    let DeliveryArtifactIdentity::Scheduled(prior_artifact) = artifact_identity else {
        return Err(anyhow!(
            "expired-transfer rebuild requires a scheduled claim"
        ));
    };
    if !matches!(
        status,
        ClaimStatus::ExpiredUnmined | ClaimStatus::ExternalSigningExpiredUnmined
    ) {
        return Err(anyhow!(
            "expired-transfer rebuild requires a positively expired unmined claim"
        ));
    }
    if scheduled_identity_in_state(state, prior_artifact.transaction_id())? != artifact_identity {
        return Err(anyhow!(
            "the expired claim belongs to an archived or replaced transaction attempt"
        ));
    }
    Ok(prior_artifact)
}

/// Applies the exact already-staged external signer merge to scheduled canonical state under the
/// same live materialization token. Swift supplies no successor state, revision, row identity, or
/// PCZT bytes; Rust derives the sole AwaitingSignature -> Signed successor from the opaque claim.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_advance_external_signature_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_claim(&ctx, claim_handle_ptr)? };
        let DeliveryArtifactIdentity::Scheduled(identity) = handle.artifact_identity else {
            return Err(anyhow!(
                "canonical signature advancement requires a scheduled claim"
            ));
        };
        if handle.claim_kind != Some(ClaimKind::Materialization) {
            return Err(anyhow!(
                "canonical signature advancement requires a materialization claim"
            ));
        }
        let signed_pczt = handle
            .signed_pczt
            .as_ref()
            .ok_or_else(|| anyhow!("the claim has no exact staged signed PCZT"))?;
        let token = required_claim_token(handle)?;
        let policy_fingerprint = required_policy_fingerprint(&handle.run)?;
        let account_uuid = ctx.account_bytes;
        let mut store = scheduled_store(&mut ctx)?;
        let state = scheduled_state(&store)?;
        if scheduled_identity_in_state(&state, identity.transaction_id())?
            != handle.artifact_identity
        {
            return Err(anyhow!(
                "the scheduled signer callback belongs to a replaced transaction attempt"
            ));
        }
        let mut successor = state.clone();
        if !successor.apply_signature(identity.transaction_id(), signed_pczt.clone()) {
            return Err(anyhow!(
                "the scheduled transaction is not awaiting this external signature"
            ));
        }
        let transition = CanonicalMaterializationTransition::new(
            handle.run.revision,
            handle.run.run_identity,
            &state,
            handle.artifact_identity,
            token,
            policy_fingerprint,
            successor,
        )
        .map_err(|e| anyhow!("invalid canonical signature transition: {e:?}"))?;
        let receipt = store
            .advance_canonical_materialization(transition)
            .map_err(|e| anyhow!("advancing canonical external signature failed: {e}"))?;
        let artifact_identity =
            scheduled_identity_in_state(receipt.canonical_state(), identity.transaction_id())?;
        Ok(Box::into_raw(Box::new(claim_handle(
            account_uuid,
            receipt.delivery(),
            artifact_identity,
        )?)))
    });
    unwrap_exc_or_null(res)
}

/// Proves one exact scheduled materialization claim with the wallet-owned prover, advances the
/// sole Signed -> Proved canonical successor under CAS, derives the exact network transaction, and
/// stages those bytes before returning them through the fresh claim handle. A restored Proved
/// claim resumes at exact-byte staging without reproving or replanning.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_prove_claim_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_claim(&ctx, claim_handle_ptr)? };
        let DeliveryArtifactIdentity::Scheduled(identity) = handle.artifact_identity else {
            return Err(anyhow!("wallet proving requires a scheduled claim"));
        };
        if handle.claim_kind != Some(ClaimKind::Materialization) {
            return Err(anyhow!("wallet proving requires a materialization claim"));
        }
        let token = required_claim_token(handle)?;
        let policy_fingerprint = required_policy_fingerprint(&handle.run)?;
        let transaction_id = identity.transaction_id();
        let state = {
            let store = scheduled_store(&mut ctx)?;
            scheduled_state(&store)?
        };
        if scheduled_identity_in_state(&state, transaction_id)? != handle.artifact_identity {
            return Err(anyhow!(
                "the proving claim belongs to a replaced scheduled transaction attempt"
            ));
        }

        let (canonical_state, delivery) = match state
            .transactions()
            .iter()
            .find(|transaction| transaction.id() == transaction_id)
            .map(MigrationTransaction::state)
        {
            Some(MigrationTxState::Signed) => {
                let mut successor = state.clone();
                let transaction = successor
                    .transactions()
                    .iter()
                    .find(|transaction| transaction.id() == transaction_id)
                    .expect("identity validation found the scheduled transaction");
                let natural_anchor = match transaction.kind() {
                    MigrationTxKind::Preparation { .. } => {
                        Some(migration_finalize::natural_anchor_height(&ctx.wallet)?)
                    }
                    MigrationTxKind::Transfer { .. } => None,
                };
                let fvk = Backend::new(&ctx.wallet, ctx.account, None, &mut ctx.store_conn)?
                    .stored_orchard_fvk()?;
                let mut prover = WalletMigrationProver::new(&mut ctx.wallet, ctx.account, fvk);
                if migration_finalize::prove_due_transaction(
                    &mut prover,
                    &mut successor,
                    transaction_id,
                    natural_anchor,
                )?
                .is_none()
                {
                    return Ok(ptr::null_mut());
                }
                let transition = CanonicalMaterializationTransition::new(
                    handle.run.revision,
                    handle.run.run_identity,
                    &state,
                    handle.artifact_identity,
                    token,
                    policy_fingerprint,
                    successor,
                )
                .map_err(|e| anyhow!("invalid canonical proof transition: {e:?}"))?;
                let receipt = scheduled_store(&mut ctx)?
                    .advance_canonical_materialization(transition)
                    .map_err(|e| anyhow!("advancing canonical migration proof failed: {e}"))?;
                (
                    receipt.canonical_state().clone(),
                    receipt.delivery().clone(),
                )
            }
            Some(MigrationTxState::Proved) => {
                let snapshot = scheduled_store(&mut ctx)?
                    .delivery_snapshot()
                    .map_err(|e| anyhow!("reading proved delivery snapshot failed: {e}"))?
                    .ok_or_else(|| anyhow!("proved canonical state has no delivery snapshot"))?;
                if snapshot.revision() != handle.run.revision
                    || snapshot.run_identity() != handle.run.run_identity
                {
                    return Err(anyhow!("the proved materialization handle is stale"));
                }
                let staged = snapshot
                    .claims()
                    .iter()
                    .find(|claim| claim.artifact_identity() == handle.artifact_identity)
                    .is_some_and(|claim| {
                        claim.status() == ClaimStatus::Staged
                            && claim.exact_transaction().is_some()
                            && claim.txid().is_some()
                    });
                if !staged {
                    return Err(anyhow!(
                        "canonical migration is proved without atomically staged exact bytes; recovery is required"
                    ));
                }
                (state, snapshot)
            }
            Some(other) => {
                return Err(anyhow!(
                    "scheduled transaction {} cannot be proved from state {}",
                    u32::from(transaction_id),
                    other.as_ref()
                ));
            }
            None => return Err(anyhow!("scheduled proving transaction is absent")),
        };

        let artifact_identity = scheduled_identity_in_state(&canonical_state, transaction_id)?;
        Ok(Box::into_raw(Box::new(claim_handle(
            ctx.account_bytes,
            &delivery,
            artifact_identity,
        )?)))
    });
    unwrap_exc_or_null(res)
}

/// Materializes the exact proposal already sealed by an immediate SDK-signer claim, stores the
/// resulting wallet transaction, and stages its exact delivery evidence in one SQLite transaction.
///
/// The host supplies no proposal, sources, destination, amount, expiry, transaction bytes, or
/// delivery identity. Rust reconstructs the post-reservation proposal from the opaque claim,
/// applies the claim's immutable expiry, builds exactly one transaction with the wallet key, and
/// asks the wallet store to validate the complete proposal/transaction binding before either the
/// wallet transaction or delivery state can commit. Exact bytes become visible only through the
/// fresh returned claim handle after that commit.
///
/// # Safety
/// Common database/account pointer rules apply. `claim_handle_ptr` must be a live borrowed claim
/// handle. `usk_ptr`, `spend_params`, and `output_params` must be non-null and valid for reads of
/// their respective lengths for the duration of this call.
#[allow(clippy::too_many_arguments)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_materialize_immediate_sdk_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
    usk_ptr: *const u8,
    usk_len: usize,
    spend_params: *const u8,
    spend_params_len: usize,
    output_params: *const u8,
    output_params_len: usize,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        if usk_ptr.is_null() {
            return Err(anyhow!(
                "immediate SDK materialization requires a spending key"
            ));
        }
        if spend_params.is_null() || output_params.is_null() {
            return Err(anyhow!(
                "immediate SDK materialization requires Sapling parameter paths"
            ));
        }

        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_claim(&ctx, claim_handle_ptr)? };
        if handle.signer_ownership != SignerOwnership::Sdk {
            return Err(anyhow!(
                "immediate SDK materialization requires an SDK-signer claim"
            ));
        }
        if handle.claim_kind != Some(ClaimKind::Materialization) {
            return Err(anyhow!(
                "immediate SDK materialization requires a materialization claim"
            ));
        }
        let evidence = match &handle.evidence {
            DeliveryArtifactEvidence::Immediate(evidence) => evidence.clone(),
            DeliveryArtifactEvidence::Scheduled(_) => {
                return Err(anyhow!(
                    "immediate SDK materialization received a scheduled claim"
                ));
            }
        };
        let envelope = ImmediateProposal::decode(evidence.canonical_proposal())
            .map_err(|e| anyhow!("decoding sealed immediate proposal envelope failed: {e}"))?;
        let artifact_identity = DeliveryArtifactIdentity::Immediate(evidence.identity());
        if handle.artifact_identity != artifact_identity
            || handle.expiry_height != envelope.expiry_height()
            || BranchId::for_height(&ctx.network, envelope.target_height()) != envelope.branch_id()
        {
            return Err(anyhow!(
                "immediate claim identity, expiry, or branch does not match sealed evidence"
            ));
        }
        let proposal_bytes = handle
            .proposal
            .clone()
            .ok_or_else(|| anyhow!("immediate claim omitted its post-commit wallet proposal"))?;
        if proposal_bytes != envelope.payload().as_bytes() {
            return Err(anyhow!(
                "immediate claim proposal payload differs from sealed evidence"
            ));
        }
        let token = required_claim_token(handle)?;
        let policy_fingerprint = required_policy_fingerprint(&handle.run)?;
        let expected_revision = handle.run.revision;
        let run_identity = handle.run.run_identity;
        let target_height = envelope.target_height();
        let expiry_height = envelope.expiry_height();
        let account = ctx.account;
        let account_uuid = ctx.account_bytes;
        let network = ctx.network;
        let usk = unsafe { decode_usk(usk_ptr, usk_len)? };
        let spend_params = Path::new(OsStr::from_bytes(unsafe {
            slice::from_raw_parts(spend_params, spend_params_len)
        }));
        let output_params = Path::new(OsStr::from_bytes(unsafe {
            slice::from_raw_parts(output_params, output_params_len)
        }));
        let prover = LocalTxProver::new(spend_params, output_params);

        let snapshot = ctx.wallet.transactionally(|wallet| -> anyhow::Result<_> {
            let proposal = ProtoProposal::decode(proposal_bytes.as_slice())
                .map_err(|e| anyhow!("decoding reserved immediate proposal failed: {e}"))?
                .try_into_standard_proposal(&network, wallet)
                .map_err(|e| anyhow!("reconstructing reserved immediate proposal failed: {e:?}"))?;
            if proposal.steps().len() != 1
                || BlockHeight::from(proposal.min_target_height()) != target_height
                || ProtoProposal::from_standard_proposal(&proposal).encode_to_vec()
                    != proposal_bytes
            {
                return Err(anyhow!(
                    "reserved immediate proposal differs from its canonical sealed payload"
                ));
            }

            let txids = create_proposed_transactions::<_, _, Infallible, _, Infallible, _>(
                wallet,
                &network,
                &prover,
                &prover,
                &SpendingKeys::from_unified_spending_key(usk),
                OvkPolicy::Sender,
                &proposal,
                Some(expiry_height),
            )
            .map_err(|e| anyhow!("materializing reserved immediate proposal failed: {e}"))?;
            if txids.len() != 1 {
                return Err(anyhow!(
                    "reserved immediate proposal materialized more than one transaction"
                ));
            }
            let txid = *txids.first();
            let transaction = wallet
                .get_transaction(txid)
                .map_err(|e| anyhow!("reading materialized immediate transaction failed: {e}"))?
                .ok_or_else(|| {
                    anyhow!("materialized immediate transaction was not stored atomically")
                })?;
            let exact = exact_immediate_transaction(&evidence, &transaction).map_err(|e| {
                anyhow!("binding materialized transaction to reserved evidence failed: {e}")
            })?;
            ImmediateMigrationDeliveryStore::stage_immediate_transaction(
                wallet,
                &account,
                expected_revision,
                run_identity,
                token,
                &exact,
                policy_fingerprint,
            )
            .map_err(|e| anyhow!("staging exact immediate transaction failed: {e}"))
        })?;

        Ok(Box::into_raw(Box::new(claim_handle(
            account_uuid,
            &snapshot,
            artifact_identity,
        )?)))
    });
    unwrap_exc_or_null(res)
}

/// Retired raw-byte staging ABI retained only for binary compatibility.
///
/// Exact scheduled bytes are staged by [`zcashlc_migration_prove_claim_v1`], while exact immediate
/// bytes are built, stored, and staged atomically by
/// [`zcashlc_migration_materialize_immediate_sdk_v1`]. Accepting host-authored transaction bytes
/// here would reopen a post-reservation mutation seam, so every call fails before reading caller
/// memory or opening storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_stage_materialized_transaction_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
    transaction_ptr: *const u8,
    transaction_len: usize,
) -> *mut FfiMigrationClaimHandle {
    let _ = (
        db_data,
        db_data_len,
        account_uuid_bytes,
        network_id,
        claim_handle_ptr,
        transaction_ptr,
        transaction_len,
    );
    let res = catch_panic(|| {
        Err(legacy_delivery_api_disabled(
            "zcashlc_migration_stage_materialized_transaction_v1",
        ))
    });
    unwrap_exc_or_null(res)
}

/// Acquires the one-shot bounded submission capability for exact staged bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_claim_submission_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_claim(&ctx, claim_handle_ptr)? };
        let policy_fingerprint = required_policy_fingerprint(&handle.run)?;
        let artifact_identity = handle.artifact_identity;
        let account_uuid = ctx.account_bytes;
        let snapshot = match artifact_identity {
            DeliveryArtifactIdentity::Scheduled(_) => {
                let mut store = scheduled_store(&mut ctx)?;
                let state = scheduled_state(&store)?;
                store
                    .claim_submission(
                        &state,
                        handle.run.revision,
                        handle.run.run_identity,
                        artifact_identity,
                        lease_duration(ClaimKind::Submission),
                        policy_fingerprint,
                    )
                    .map_err(|e| anyhow!("claiming migration submission failed: {e}"))?
            }
            DeliveryArtifactIdentity::Immediate(identity) => {
                ImmediateMigrationDeliveryStore::claim_immediate_submission(
                    &mut ctx.wallet,
                    &ctx.account,
                    handle.run.revision,
                    handle.run.run_identity,
                    identity,
                    lease_duration(ClaimKind::Submission),
                    policy_fingerprint,
                )
                .map_err(|e| anyhow!("claiming immediate migration submission failed: {e}"))?
            }
        };
        let Some(snapshot) = snapshot else {
            return Ok(ptr::null_mut());
        };
        Ok(Box::into_raw(Box::new(claim_handle(
            account_uuid,
            &snapshot,
            artifact_identity,
        )?)))
    });
    unwrap_exc_or_null(res)
}

/// Acquires bounded resolution-only authority for an outcome-unknown artifact. The returned handle
/// cannot authorize resubmission.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_claim_outcome_resolution_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_claim(&ctx, claim_handle_ptr)? };
        let policy_fingerprint = required_policy_fingerprint(&handle.run)?;
        let artifact_identity = handle.artifact_identity;
        let account_uuid = ctx.account_bytes;
        let snapshot = match artifact_identity {
            DeliveryArtifactIdentity::Scheduled(_) => {
                let mut store = scheduled_store(&mut ctx)?;
                let state = scheduled_state(&store)?;
                store
                    .claim_outcome_resolution(
                        &state,
                        handle.run.revision,
                        handle.run.run_identity,
                        artifact_identity,
                        lease_duration(ClaimKind::OutcomeResolution),
                        policy_fingerprint,
                    )
                    .map_err(|e| anyhow!("claiming migration outcome resolution failed: {e}"))?
            }
            DeliveryArtifactIdentity::Immediate(identity) => {
                ImmediateMigrationDeliveryStore::claim_immediate_outcome_resolution(
                    &mut ctx.wallet,
                    &ctx.account,
                    handle.run.revision,
                    handle.run.run_identity,
                    identity,
                    lease_duration(ClaimKind::OutcomeResolution),
                    policy_fingerprint,
                )
                .map_err(|e| {
                    anyhow!("claiming immediate migration outcome resolution failed: {e}")
                })?
            }
        };
        let Some(snapshot) = snapshot else {
            return Ok(ptr::null_mut());
        };
        Ok(Box::into_raw(Box::new(claim_handle(
            account_uuid,
            &snapshot,
            artifact_identity,
        )?)))
    });
    unwrap_exc_or_null(res)
}

/// Resumes the same still-live Rust-generated claim. It never mints a replacement token.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_resume_claim_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_claim(&ctx, claim_handle_ptr)? };
        let token = required_claim_token(handle)?;
        let policy_fingerprint = required_policy_fingerprint(&handle.run)?;
        let artifact_identity = handle.artifact_identity;
        let account_uuid = ctx.account_bytes;
        let snapshot = match artifact_identity {
            DeliveryArtifactIdentity::Scheduled(_) => {
                let mut store = scheduled_store(&mut ctx)?;
                let state = scheduled_state(&store)?;
                store
                    .resume_claim(
                        &state,
                        handle.run.revision,
                        handle.run.run_identity,
                        artifact_identity,
                        token,
                        policy_fingerprint,
                    )
                    .map_err(|e| anyhow!("resuming migration claim failed: {e}"))?
            }
            DeliveryArtifactIdentity::Immediate(identity) => {
                ImmediateMigrationDeliveryStore::resume_immediate_claim(
                    &mut ctx.wallet,
                    &ctx.account,
                    handle.run.revision,
                    handle.run.run_identity,
                    identity,
                    token,
                    policy_fingerprint,
                )
                .map_err(|e| anyhow!("resuming immediate migration claim failed: {e}"))?
            }
        };
        let Some(snapshot) = snapshot else {
            return Ok(ptr::null_mut());
        };
        Ok(Box::into_raw(Box::new(claim_handle(
            account_uuid,
            &snapshot,
            artifact_identity,
        )?)))
    });
    unwrap_exc_or_null(res)
}

/// Reacquires a fresh bounded materialization token for the same unexposed immediate artifact
/// after a known-unsent materialization failure. The persisted proposal must remain within the
/// caller's current explicit gross-amount authorization; this operation never replans.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_reacquire_failed_immediate_materialization_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
    signer_tag: u8,
    maximum_gross_amount: i64,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let signer = signer_ownership(signer_tag)?;
        let maximum_gross_amount = Zatoshis::from_nonnegative_i64(maximum_gross_amount)
            .map_err(|_| anyhow!("maximum immediate migration gross amount is invalid"))?;
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_claim(&ctx, claim_handle_ptr)? };
        let DeliveryArtifactIdentity::Immediate(artifact_identity) = handle.artifact_identity
        else {
            return Err(anyhow!(
                "failed immediate materialization reacquisition requires an immediate artifact"
            ));
        };
        if handle.signer_ownership != signer
            || handle.status != ClaimStatus::MaterializationFailed
            || handle.claim_kind.is_some()
            || handle.token.is_some()
            || handle.external_signing_pczt.is_some()
            || handle.signed_pczt.is_some()
            || handle.exact_transaction.is_some()
            || handle.txid.is_some()
        {
            return Err(anyhow!(
                "failed immediate materialization reacquisition requires the same unexposed known-unsent artifact"
            ));
        }
        let policy_fingerprint = required_policy_fingerprint(&handle.run)?;
        let account_uuid = ctx.account_bytes;
        let snapshot = ImmediateMigrationDeliveryStore::reacquire_failed_immediate_materialization(
            &mut ctx.wallet,
            &ctx.account,
            handle.run.revision,
            handle.run.run_identity,
            artifact_identity,
            signer,
            maximum_gross_amount,
            lease_duration(ClaimKind::Materialization),
            policy_fingerprint,
        )
        .map_err(|e| anyhow!("reacquiring failed immediate materialization failed: {e}"))?;
        Ok(Box::into_raw(Box::new(claim_handle(
            account_uuid,
            &snapshot,
            DeliveryArtifactIdentity::Immediate(artifact_identity),
        )?)))
    });
    unwrap_exc_or_null(res)
}

/// Reacquires a fresh bounded materialization token for the same externally staged artifact after
/// expiry/relaunch. Exact staged PCZT bytes, source reservations, and artifact identity are
/// retained; this operation never replans.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_reacquire_external_signing_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_claim(&ctx, claim_handle_ptr)? };
        if handle.signer_ownership != SignerOwnership::External
            || handle.external_signing_pczt.is_none()
        {
            return Err(anyhow!(
                "external-signing reacquisition requires the same staged external artifact"
            ));
        }
        let policy_fingerprint = required_policy_fingerprint(&handle.run)?;
        let artifact_identity = handle.artifact_identity;
        let account_uuid = ctx.account_bytes;
        let snapshot = match artifact_identity {
            DeliveryArtifactIdentity::Scheduled(_) => {
                let mut store = scheduled_store(&mut ctx)?;
                let state = scheduled_state(&store)?;
                store
                    .claim_materialization(
                        &state,
                        handle.run.revision,
                        handle.run.run_identity,
                        &handle.evidence,
                        SignerOwnership::External,
                        lease_duration(ClaimKind::Materialization),
                        policy_fingerprint,
                    )
                    .map_err(|e| {
                        anyhow!("reacquiring scheduled external-signing claim failed: {e}")
                    })?
            }
            DeliveryArtifactIdentity::Immediate(identity) => {
                ImmediateMigrationDeliveryStore::reacquire_immediate_external_signing(
                    &mut ctx.wallet,
                    &ctx.account,
                    handle.run.revision,
                    handle.run.run_identity,
                    identity,
                    lease_duration(ClaimKind::Materialization),
                    policy_fingerprint,
                )
                .map_err(|e| anyhow!("reacquiring immediate external-signing claim failed: {e}"))?
            }
        };
        let Some(snapshot) = snapshot else {
            return Ok(ptr::null_mut());
        };
        Ok(Box::into_raw(Box::new(claim_handle(
            account_uuid,
            &snapshot,
            artifact_identity,
        )?)))
    });
    unwrap_exc_or_null(res)
}

/// Renews a live claim using the bounded Rust-owned duration selected by its exact claim kind.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_renew_claim_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_claim(&ctx, claim_handle_ptr)? };
        let kind = handle
            .claim_kind
            .ok_or_else(|| anyhow!("the migration artifact has no renewable live claim"))?;
        let token = required_claim_token(handle)?;
        let policy_fingerprint = required_policy_fingerprint(&handle.run)?;
        let artifact_identity = handle.artifact_identity;
        let account_uuid = ctx.account_bytes;
        let snapshot = match artifact_identity {
            DeliveryArtifactIdentity::Scheduled(_) => {
                let mut store = scheduled_store(&mut ctx)?;
                let state = scheduled_state(&store)?;
                store
                    .renew_claim(
                        &state,
                        handle.run.revision,
                        handle.run.run_identity,
                        artifact_identity,
                        token,
                        lease_duration(kind),
                        policy_fingerprint,
                    )
                    .map_err(|e| anyhow!("renewing migration claim failed: {e}"))?
            }
            DeliveryArtifactIdentity::Immediate(identity) => {
                ImmediateMigrationDeliveryStore::renew_immediate_claim(
                    &mut ctx.wallet,
                    &ctx.account,
                    handle.run.revision,
                    handle.run.run_identity,
                    identity,
                    token,
                    lease_duration(kind),
                    policy_fingerprint,
                )
                .map_err(|e| anyhow!("renewing immediate migration claim failed: {e}"))?
            }
        };
        let Some(snapshot) = snapshot else {
            return Ok(ptr::null_mut());
        };
        Ok(Box::into_raw(Box::new(claim_handle(
            account_uuid,
            &snapshot,
            artifact_identity,
        )?)))
    });
    unwrap_exc_or_null(res)
}

/// Records exactly one typed transport outcome under a live submission capability.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_record_submission_outcome_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
    outcome_tag: u8,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_claim(&ctx, claim_handle_ptr)? };
        if handle.claim_kind != Some(ClaimKind::Submission) {
            return Err(anyhow!("submission outcome requires a submission claim"));
        }
        let token = required_claim_token(handle)?;
        let outcome = submission_outcome(outcome_tag)?;
        let policy_fingerprint = required_policy_fingerprint(&handle.run)?;
        let artifact_identity = handle.artifact_identity;
        let account_uuid = ctx.account_bytes;
        let snapshot = match artifact_identity {
            DeliveryArtifactIdentity::Scheduled(_) => {
                let mut store = scheduled_store(&mut ctx)?;
                let state = scheduled_state(&store)?;
                store
                    .record_submission_outcome(
                        &state,
                        handle.run.revision,
                        handle.run.run_identity,
                        artifact_identity,
                        token,
                        outcome,
                        policy_fingerprint,
                    )
                    .map_err(|e| anyhow!("recording migration submission outcome failed: {e}"))?
                    .delivery()
                    .clone()
            }
            DeliveryArtifactIdentity::Immediate(identity) => {
                ImmediateMigrationDeliveryStore::record_immediate_submission_outcome(
                    &mut ctx.wallet,
                    &ctx.account,
                    handle.run.revision,
                    handle.run.run_identity,
                    identity,
                    token,
                    outcome,
                    policy_fingerprint,
                )
                .map_err(|e| anyhow!("recording immediate submission outcome failed: {e}"))?
            }
        };
        Ok(Box::into_raw(Box::new(claim_handle(
            account_uuid,
            &snapshot,
            artifact_identity,
        )?)))
    });
    unwrap_exc_or_null(res)
}

/// Resolves chain evidence under an outcome-resolution claim without granting resubmission.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_reconcile_submission_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_claim(&ctx, claim_handle_ptr)? };
        if handle.claim_kind != Some(ClaimKind::OutcomeResolution) {
            return Err(anyhow!(
                "submission reconciliation requires an outcome-resolution claim"
            ));
        }
        let token = required_claim_token(handle)?;
        let artifact_identity = handle.artifact_identity;
        let account_uuid = ctx.account_bytes;
        let snapshot = match artifact_identity {
            DeliveryArtifactIdentity::Scheduled(_) => {
                let mut store = scheduled_store(&mut ctx)?;
                let state = scheduled_state(&store)?;
                store
                    .reconcile_submission(
                        &state,
                        handle.run.revision,
                        handle.run.run_identity,
                        artifact_identity,
                        token,
                    )
                    .map_err(|e| anyhow!("reconciling migration submission failed: {e}"))?
                    .delivery()
                    .clone()
            }
            DeliveryArtifactIdentity::Immediate(identity) => {
                ImmediateMigrationDeliveryStore::reconcile_immediate_submission(
                    &mut ctx.wallet,
                    &ctx.account,
                    handle.run.revision,
                    handle.run.run_identity,
                    identity,
                    token,
                )
                .map_err(|e| anyhow!("reconciling immediate submission failed: {e}"))?
            }
        };
        Ok(Box::into_raw(Box::new(claim_handle(
            account_uuid,
            &snapshot,
            artifact_identity,
        )?)))
    });
    unwrap_exc_or_null(res)
}

/// Atomically reconciles every scheduled canonical artifact against the store-owned fully scanned
/// active-chain view. No lifecycle, height, txid, or clock input crosses the ABI. A no-op still
/// returns a fresh equivalent owned handle; a committed reconciliation returns the next-revision
/// handle from the canonical-plus-delivery receipt.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_reconcile_canonical_chain_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    run_handle_ptr: *const FfiMigrationRunHandle,
) -> *mut FfiMigrationRunHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_scheduled_run(&ctx, run_handle_ptr)? };
        let expected_revision = handle.revision;
        let run_identity = handle.run_identity;
        let unchanged = handle.clone();
        let account_uuid = ctx.account_bytes;
        let mut store = scheduled_store(&mut ctx)?;
        let state = scheduled_state(&store)?;
        let reconciled = store
            .reconcile_canonical_chain(&state, expected_revision, run_identity)
            .map_err(|e| anyhow!("reconciling canonical migration chain state failed: {e}"))?;
        Ok(Box::into_raw(Box::new(match reconciled {
            Some(receipt) => run_handle(account_uuid, receipt.delivery()),
            None => unchanged,
        })))
    });
    unwrap_exc_or_null(res)
}

/// Atomically replaces one positively expired scheduled transfer attempt inside its existing run.
///
/// Rust derives the complete successor from the exact generation-safe claim, current canonical
/// state, wallet chain view, and a CSPRNG. The host chooses only the signer lane and, for the SDK
/// lane, supplies the account spending key. No schedule, height, revision, fingerprint, owner, or
/// token is accepted from the host. The store CAS archives the old attempt's durable fingerprint
/// and revision; its expired lease token is intentionally absent and is never reconstructed or
/// treated as generation authority. The returned handle owns the fresh replacement identity and
/// materialization token.
///
/// # Safety
/// See [`open`]. `claim_handle_ptr` must be a live handle returned by this module. For signer tag
/// `0` (SDK), `usk_ptr` must be valid for `usk_len` bytes. For tag `1` (external), `usk_ptr` must be
/// null and `usk_len` zero. Free the returned handle with
/// [`zcashlc_migration_free_claim_handle_v1`].
#[allow(clippy::too_many_arguments)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_rebuild_expired_transfer_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
    signer_ownership_tag: u8,
    usk_ptr: *const u8,
    usk_len: usize,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_claim(&ctx, claim_handle_ptr)? };
        let DeliveryArtifactIdentity::Scheduled(prior_artifact) = handle.artifact_identity else {
            return Err(anyhow!(
                "expired-transfer rebuild requires a scheduled claim"
            ));
        };
        if !matches!(
            handle.status,
            ClaimStatus::ExpiredUnmined | ClaimStatus::ExternalSigningExpiredUnmined
        ) {
            return Err(anyhow!(
                "expired-transfer rebuild requires a positively expired unmined claim"
            ));
        }
        let signer = signer_ownership(signer_ownership_tag)?;
        let usk = match signer {
            SignerOwnership::Sdk => {
                if usk_ptr.is_null() {
                    return Err(anyhow!(
                        "SDK-signed expired-transfer rebuild requires a spending key"
                    ));
                }
                Some(unsafe { crate::decode_usk(usk_ptr, usk_len)? })
            }
            SignerOwnership::External => {
                if !usk_ptr.is_null() || usk_len != 0 {
                    return Err(anyhow!(
                        "external-signer expired-transfer rebuild must not receive a spending key"
                    ));
                }
                None
            }
        };
        let policy = policy_from_run_handle(&ctx.network, &handle.run)?;
        let state = {
            let store = scheduled_store(&mut ctx)?;
            scheduled_state(&store)?
        };
        let validated_artifact =
            validate_expired_rebuild_generation(handle.artifact_identity, handle.status, &state)?;
        debug_assert_eq!(validated_artifact, prior_artifact);

        let mut successor = state.clone();
        let rebuilt_successor = {
            // This adapter only derives the upstream successor. It deliberately performs no
            // generic canonical write; the typed store operation below owns the sole mutation.
            let backend = Backend::for_delivery_rebuild(
                &ctx.wallet,
                ctx.account,
                usk,
                &mut ctx.store_conn,
                &state,
            )?;
            let mut rng = OsRng;
            match signer {
                SignerOwnership::Sdk => engine::rebuild_expired_transfer_with_successor(
                    &ctx.network,
                    &backend,
                    &mut successor,
                    prior_artifact.transaction_id(),
                    &mut rng,
                )
                .map_err(map_rebuild_err)?,
                SignerOwnership::External => {
                    let (_unsigned, rebuilt_successor) =
                        engine::rebuild_expired_transfer_unsigned_with_successor(
                            &ctx.network,
                            &backend,
                            &mut successor,
                            prior_artifact.transaction_id(),
                            &mut rng,
                        )
                        .map_err(map_rebuild_err)?;
                    rebuilt_successor
                }
            }
        };

        let request = ExpiredTransferRebuild::new(
            handle.run.revision,
            handle.run.run_identity,
            handle.run.source_reservation_owner,
            &state,
            prior_artifact,
            signer,
            rebuilt_successor,
        )
        .map_err(|e| anyhow!("invalid expired-transfer rebuild successor: {e:?}"))?;
        let receipt = MigrationRuntimeStore::rebuild_expired_transfer_attempt(
            &mut ctx.wallet,
            &ctx.account,
            request,
            &policy,
        )
        .map_err(|e| anyhow!("committing expired-transfer rebuild failed: {e}"))?;
        Ok(Box::into_raw(Box::new(claim_handle(
            ctx.account_bytes,
            receipt.delivery(),
            DeliveryArtifactIdentity::Scheduled(receipt.replacement_attempt()),
        )?)))
    });
    unwrap_exc_or_null(res)
}

/// Releases a claim only for a Rust-validated known-unsent failure. Once exact external-signing
/// bytes have been staged, the artifact is cancellation-unsafe and this wrapper rejects release
/// before consulting storage; the same artifact must be resumed through its terminal resolution.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_release_claim_known_unsent_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    claim_handle_ptr: *const FfiMigrationClaimHandle,
    failure_tag: u8,
) -> *mut FfiMigrationClaimHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handle = unsafe { require_claim(&ctx, claim_handle_ptr)? };
        if handle.external_signing_pczt.is_some() {
            return Err(anyhow!(
                "an externally exposed PCZT cannot be released or replanned; resume the same artifact"
            ));
        }
        let token = required_claim_token(handle)?;
        let failure = delivery_failure(failure_tag)?;
        let policy_fingerprint = required_policy_fingerprint(&handle.run)?;
        let artifact_identity = handle.artifact_identity;
        let account_uuid = ctx.account_bytes;
        let snapshot = match artifact_identity {
            DeliveryArtifactIdentity::Scheduled(_) => {
                let mut store = scheduled_store(&mut ctx)?;
                let state = scheduled_state(&store)?;
                store
                    .release_claim_known_unsent(
                        &state,
                        handle.run.revision,
                        handle.run.run_identity,
                        artifact_identity,
                        token,
                        failure,
                        policy_fingerprint,
                    )
                    .map_err(|e| anyhow!("releasing known-unsent migration claim failed: {e}"))?
            }
            DeliveryArtifactIdentity::Immediate(identity) => {
                ImmediateMigrationDeliveryStore::release_immediate_claim_known_unsent(
                    &mut ctx.wallet,
                    &ctx.account,
                    handle.run.revision,
                    handle.run.run_identity,
                    identity,
                    token,
                    failure,
                    policy_fingerprint,
                )
                .map_err(|e| anyhow!("releasing immediate known-unsent claim failed: {e}"))?
            }
        };
        Ok(Box::into_raw(Box::new(claim_handle(
            account_uuid,
            &snapshot,
            artifact_identity,
        )?)))
    });
    unwrap_exc_or_null(res)
}

#[derive(Clone, Copy)]
enum RunTransition {
    Pause,
    Resume,
    BeginAbandonment,
    FinishAbandonment,
}

unsafe fn transition_delivery_run(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    run_handle_ptr: *const FfiMigrationRunHandle,
    transition: RunTransition,
) -> anyhow::Result<*mut FfiMigrationRunHandle> {
    let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
    let handle = unsafe { require_run(&ctx, run_handle_ptr)? };
    let lane = handle.lane;
    let expected_revision = handle.revision;
    let run_identity = handle.run_identity;
    let account_uuid = ctx.account_bytes;
    let snapshot = match lane {
        DeliveryLane::Scheduled => {
            let mut store = scheduled_store(&mut ctx)?;
            let state = scheduled_state(&store)?;
            match transition {
                RunTransition::Pause => {
                    store.pause_delivery(&state, expected_revision, run_identity)
                }
                RunTransition::Resume => {
                    store.resume_delivery(&state, expected_revision, run_identity)
                }
                RunTransition::BeginAbandonment => {
                    store.begin_abandonment(&state, expected_revision, run_identity)
                }
                RunTransition::FinishAbandonment => {
                    store.finish_abandonment(&state, expected_revision, run_identity)
                }
            }
            .map_err(|e| anyhow!("scheduled migration delivery transition failed: {e}"))?
        }
        DeliveryLane::Immediate => match transition {
            RunTransition::Pause => ImmediateMigrationDeliveryStore::pause_immediate_delivery(
                &mut ctx.wallet,
                &ctx.account,
                expected_revision,
                run_identity,
            ),
            RunTransition::Resume => ImmediateMigrationDeliveryStore::resume_immediate_delivery(
                &mut ctx.wallet,
                &ctx.account,
                expected_revision,
                run_identity,
            ),
            RunTransition::BeginAbandonment => {
                ImmediateMigrationDeliveryStore::begin_immediate_abandonment(
                    &mut ctx.wallet,
                    &ctx.account,
                    expected_revision,
                    run_identity,
                )
            }
            RunTransition::FinishAbandonment => {
                ImmediateMigrationDeliveryStore::finish_immediate_abandonment(
                    &mut ctx.wallet,
                    &ctx.account,
                    expected_revision,
                    run_identity,
                )
            }
        }
        .map_err(|e| anyhow!("immediate migration delivery transition failed: {e}"))?,
    };
    Ok(Box::into_raw(Box::new(run_handle(account_uuid, &snapshot))))
}

/// Pauses delivery without releasing source reservations or exposed evidence.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_pause_delivery_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    run_handle_ptr: *const FfiMigrationRunHandle,
) -> *mut FfiMigrationRunHandle {
    let res = catch_panic(|| unsafe {
        transition_delivery_run(
            db_data,
            db_data_len,
            account_uuid_bytes,
            network_id,
            run_handle_ptr,
            RunTransition::Pause,
        )
    });
    unwrap_exc_or_null(res)
}

/// Resumes a paused delivery run.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_resume_delivery_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    run_handle_ptr: *const FfiMigrationRunHandle,
) -> *mut FfiMigrationRunHandle {
    let res = catch_panic(|| unsafe {
        transition_delivery_run(
            db_data,
            db_data_len,
            account_uuid_bytes,
            network_id,
            run_handle_ptr,
            RunTransition::Resume,
        )
    });
    unwrap_exc_or_null(res)
}

/// Begins abandonment while retaining every possibly exposed artifact and source reservation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_begin_abandonment_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    run_handle_ptr: *const FfiMigrationRunHandle,
) -> *mut FfiMigrationRunHandle {
    let res = catch_panic(|| unsafe {
        transition_delivery_run(
            db_data,
            db_data_len,
            account_uuid_bytes,
            network_id,
            run_handle_ptr,
            RunTransition::BeginAbandonment,
        )
    });
    unwrap_exc_or_null(res)
}

/// Finishes abandonment only after Rust proves every exposed artifact terminally safe.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_finish_abandonment_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    run_handle_ptr: *const FfiMigrationRunHandle,
) -> *mut FfiMigrationRunHandle {
    let res = catch_panic(|| unsafe {
        transition_delivery_run(
            db_data,
            db_data_len,
            account_uuid_bytes,
            network_id,
            run_handle_ptr,
            RunTransition::FinishAbandonment,
        )
    });
    unwrap_exc_or_null(res)
}

/// Build an owned C string from `s`, erroring (rather than panicking across the FFI) if it
/// contains an interior NUL byte.
fn cstring_raw(s: &str, what: &str) -> anyhow::Result<*mut c_char> {
    Ok(CString::new(s)
        .map_err(|_| anyhow!("{what} contains an interior NUL byte"))?
        .into_raw())
}

// ----- free functions -----

/// Frees a [`FfiMigrationState`], including the attention transfer id if present.
///
/// # Safety
/// `ptr` must be null or point to a [`FfiMigrationState`] handed out by this module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_migration_state(ptr: *mut FfiMigrationState) {
    if !ptr.is_null() {
        let boxed = unsafe { Box::from_raw(ptr) };
        if let FfiMigrationState::RequiresAttention(FfiAttentionReason::InvalidTransfer {
            transfer_id,
        }) = &*boxed
            && !transfer_id.is_null()
        {
            unsafe { zcashlc_string_free(*transfer_id) }
        }
        drop(boxed);
    }
}

/// Frees a [`FfiMigrationProgress`].
///
/// # Safety
/// `ptr` must be null or point to a [`FfiMigrationProgress`] handed out by this module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_migration_progress(ptr: *mut FfiMigrationProgress) {
    if !ptr.is_null() {
        drop(unsafe { Box::from_raw(ptr) });
    }
}

/// Frees a [`FfiNoteSplitProposal`], including its output-values array.
///
/// # Safety
/// `ptr` must be null or point to a [`FfiNoteSplitProposal`] handed out by this module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_migration_note_split_proposal(
    ptr: *mut FfiNoteSplitProposal,
) {
    if !ptr.is_null() {
        let boxed = unsafe { Box::from_raw(ptr) };
        free_ptr_from_vec(boxed.output_values, boxed.output_values_len);
        drop(boxed);
    }
}

/// Frees a [`FfiPreparedTransfer`], including its id string and PCZT bytes.
///
/// # Safety
/// `ptr` must be null or point to a [`FfiPreparedTransfer`] handed out by this module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_migration_prepared_transfer(ptr: *mut FfiPreparedTransfer) {
    if !ptr.is_null() {
        let boxed = unsafe { Box::from_raw(ptr) };
        if !boxed.id.is_null() {
            unsafe { zcashlc_string_free(boxed.id) }
        }
        free_ptr_from_vec(boxed.pczt, boxed.pczt_len);
        drop(boxed);
    }
}

/// Frees a [`FfiMigrationSchedule`], including every transfer's id string.
///
/// # Safety
/// `ptr` must be null or point to a [`FfiMigrationSchedule`] handed out by this module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_migration_schedule(ptr: *mut FfiMigrationSchedule) {
    if !ptr.is_null() {
        let boxed = unsafe { Box::from_raw(ptr) };
        free_ptr_from_vec_with(boxed.transfers, boxed.transfers_len, |t| {
            if !t.id.is_null() {
                unsafe { zcashlc_string_free(t.id) }
            }
        });
        drop(boxed);
    }
}

/// Frees a standalone [`FfiTransferProposal`] (as returned by
/// `zcashlc_migration_pending_transfer_proposal`), including its id string.
///
/// # Safety
/// `ptr` must be null or point to a [`FfiTransferProposal`] handed out by this module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_migration_transfer_proposal(ptr: *mut FfiTransferProposal) {
    if !ptr.is_null() {
        let boxed = unsafe { Box::from_raw(ptr) };
        if !boxed.id.is_null() {
            unsafe { zcashlc_string_free(boxed.id) }
        }
        drop(boxed);
    }
}

/// Frees a [`FfiMigrationRunEstimate`], including its runs array.
///
/// # Safety
/// `ptr` must be null or point to a [`FfiMigrationRunEstimate`] handed out by this module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_migration_run_estimate(ptr: *mut FfiMigrationRunEstimate) {
    if !ptr.is_null() {
        let boxed = unsafe { Box::from_raw(ptr) };
        free_ptr_from_vec(boxed.runs, boxed.runs_len);
        drop(boxed);
    }
}

/// Frees a [`FfiUnsignedTransferPczts`], including every element's id string and PCZT bytes.
///
/// # Safety
/// `ptr` must be null or point to a [`FfiUnsignedTransferPczts`] handed out by this module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_migration_unsigned_transfer_pczts(
    ptr: *mut FfiUnsignedTransferPczts,
) {
    if !ptr.is_null() {
        let boxed = unsafe { Box::from_raw(ptr) };
        free_ptr_from_vec_with(boxed.ptr, boxed.len, |u| {
            if !u.id.is_null() {
                unsafe { zcashlc_string_free(u.id) }
            }
            free_ptr_from_vec(u.pczt, u.pczt_len);
        });
        drop(boxed);
    }
}

/// Frees a [`FfiMigrationTransactionStatuses`] container. Every row is a fixed-size value (the
/// `txid` is an inline `[u8; 32]`, not a heap pointer), so freeing the array itself is enough —
/// no per-row free callback, unlike [`zcashlc_free_migration_unsigned_transfer_pczts`].
///
/// # Safety
/// `ptr` must be null or point to a [`FfiMigrationTransactionStatuses`] handed out by this
/// module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_migration_transaction_statuses(
    ptr: *mut FfiMigrationTransactionStatuses,
) {
    if !ptr.is_null() {
        let boxed = unsafe { Box::from_raw(ptr) };
        free_ptr_from_vec(boxed.ptr, boxed.len);
        drop(boxed);
    }
}

/// Frees a [`FfiKeystoneQrParts`], including every element string.
///
/// # Safety
/// `ptr` must be null or point to a [`FfiKeystoneQrParts`] handed out by this module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_migration_keystone_qr_parts(ptr: *mut FfiKeystoneQrParts) {
    if !ptr.is_null() {
        let boxed = unsafe { Box::from_raw(ptr) };
        free_ptr_from_vec_with(boxed.ptr, boxed.len, |s| {
            if !s.is_null() {
                unsafe { zcashlc_string_free(*s) }
            }
        });
        drop(boxed);
    }
}

/// Frees a [`FfiKeystoneBatchDecodeResult`], including its data bytes.
///
/// # Safety
/// `ptr` must be null or point to a [`FfiKeystoneBatchDecodeResult`] handed out by this module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_migration_keystone_batch_decode_result(
    ptr: *mut FfiKeystoneBatchDecodeResult,
) {
    if !ptr.is_null() {
        let boxed = unsafe { Box::from_raw(ptr) };
        free_ptr_from_vec(boxed.data, boxed.data_len);
        drop(boxed);
    }
}

// ============================================================================================
// State
// ============================================================================================

/// Marshal a derived state (plus its progress inputs) into the boxed C DTO.
fn marshal_state(
    derived: DerivedState,
    remaining_orchard: Zatoshis,
) -> anyhow::Result<*mut FfiMigrationState> {
    let value = match derived {
        DerivedState::NotStarted => FfiMigrationState::NotStarted,
        DerivedState::SplitPendingConfirmation => FfiMigrationState::SplitPendingConfirmation,
        DerivedState::InProgress {
            completed_transfers,
            total_transfers,
            next_transfer_ready_at_height,
            is_immediate,
        } => FfiMigrationState::InProgress(FfiMigrationProgress {
            is_present: true,
            completed_transfers,
            total_transfers,
            remaining_orchard_value: zat_to_i64(remaining_orchard),
            next_transfer_ready_at_height: height_opt_to_i64(next_transfer_ready_at_height),
            is_immediate,
        }),
        DerivedState::TransferExpired => {
            FfiMigrationState::RequiresAttention(FfiAttentionReason::TransferExpired)
        }
        DerivedState::Complete => FfiMigrationState::Complete,
    };
    Ok(Box::into_raw(Box::new(value)))
}

/// The account's live spendable Orchard balance (what is still in the old pool).
fn remaining_orchard(ctx: &mut CallCtx) -> anyhow::Result<Zatoshis> {
    let backend = Backend::new(&ctx.wallet, ctx.account, None, &mut ctx.store_conn)?;
    let values = backend.ordinarily_spendable_orchard_note_values()?;
    values
        .into_iter()
        .try_fold(Zatoshis::ZERO, |acc, v| acc + v)
        .ok_or_else(|| anyhow!("spendable Orchard balance overflows"))
}

fn completion_availability_for_derivation(
    ctx: &mut CallCtx,
    state: Option<&MigrationState>,
    tip: BlockHeight,
) -> anyhow::Result<bool> {
    // Exact tuple derivation, availability classification, and provisional-owner release all live
    // in the canonical Rust finalizer. Call it even when an immediate run masks the engine state;
    // otherwise a provisional Complete run could retain its owner and locks indefinitely.
    let outputs_available = match state {
        Some(state) if matches!(state.status(), MigrationStatus::Complete) => {
            let mut backend = Backend::new(&ctx.wallet, ctx.account, None, &mut ctx.store_conn)?;
            backend.finalize_completed_migration(TargetHeight::from(u32::from(tip) + 1))?
        }
        _ => true,
    };

    Ok(outputs_available)
}

/// Requires the same strict, derived `Complete` state that the public Swift API exposes.
///
/// This deliberately reads canonical state and runs the exact-output finalizer before checking the
/// public projection. In particular, an engine `Complete` that still retains
/// its provisional migration owner or has unavailable exact outputs is not sufficient. The finalizer clears the provisional
/// migration owner before residual locking can acquire its distinct permanent owner.
fn require_strict_public_complete(ctx: &mut CallCtx) -> anyhow::Result<()> {
    let engine_state = read_canonical_migration(ctx)?;
    let tip = ctx.tip()?;
    let outputs_available =
        completion_availability_for_derivation(ctx, engine_state.as_ref(), tip)?;
    if matches!(
        derive_state(engine_state.as_ref(), tip, outputs_available),
        DerivedState::Complete
    ) {
        Ok(())
    } else {
        Err(anyhow!(
            "the migration residual can be locked only after strict migration completion"
        ))
    }
}

/// The current migration-state projection. Canonical chain reconciliation is a separate typed CAS
/// requiring an opaque scheduled-run capability. `Complete` is PER-RUN (see the module doc).
///
/// # Safety
/// See [`open`]. Free the returned pointer with [`zcashlc_free_migration_state`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_state(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut FfiMigrationState {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let engine_state = read_canonical_migration(&mut ctx)?;
        if engine_state.is_none() {
            // No scheduled run: nothing to derive, and (crucially) no need to touch the chain tip,
            // which a not-yet-synced wallet lacks. Immediate state is read through the delivery
            // runtime rather than reconstructed here.
            return marshal_state(DerivedState::NotStarted, Zatoshis::ZERO);
        }
        let tip = ctx.tip()?;
        let outputs_available =
            completion_availability_for_derivation(&mut ctx, engine_state.as_ref(), tip)?;
        let derived = derive_state(engine_state.as_ref(), tip, outputs_available);
        let remaining = match derived {
            DerivedState::InProgress { .. } => remaining_orchard(&mut ctx)?,
            _ => Zatoshis::ZERO,
        };
        marshal_state(derived, remaining)
    });
    unwrap_exc_or_null(res)
}

/// Migration progress, present only while a migration run is in progress. On success the returned
/// pointer is non-null; its `is_present` flag is `false` when there is no progress to report. A
/// NULL return signals an error.
///
/// # Safety
/// See [`open`]. Free the returned pointer with [`zcashlc_free_migration_progress`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_progress(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut FfiMigrationProgress {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let engine_state = read_canonical_migration(&mut ctx)?;
        if engine_state.is_none() {
            // No scheduled run. Immediate progress is read through the delivery runtime.
            return Ok(Box::into_raw(Box::new(FfiMigrationProgress::absent())));
        }
        let tip = ctx.tip()?;
        let outputs_available =
            completion_availability_for_derivation(&mut ctx, engine_state.as_ref(), tip)?;
        let value = match derive_state(engine_state.as_ref(), tip, outputs_available) {
            DerivedState::InProgress {
                completed_transfers,
                total_transfers,
                next_transfer_ready_at_height,
                is_immediate,
            } => FfiMigrationProgress {
                is_present: true,
                completed_transfers,
                total_transfers,
                remaining_orchard_value: zat_to_i64(remaining_orchard(&mut ctx)?),
                next_transfer_ready_at_height: height_opt_to_i64(next_transfer_ready_at_height),
                is_immediate,
            },
            _ => FfiMigrationProgress::absent(),
        };
        Ok(Box::into_raw(Box::new(value)))
    });
    unwrap_exc_or_null(res)
}

/// An empty transaction-statuses container: the "no stored run" / "stored run with no
/// transactions" answer (mirrors [`encode_empty_schedule`]'s convention for the schedule DTO).
fn encode_empty_transaction_statuses() -> *mut FfiMigrationTransactionStatuses {
    Box::into_raw(Box::new(FfiMigrationTransactionStatuses {
        ptr: ptr::null_mut(),
        len: 0,
    }))
}

/// Marshal one engine [`TransactionStatus`] row verbatim into the FFI DTO — see
/// [`zcashlc_migration_transaction_statuses`] for the field-by-field contract.
fn encode_transaction_status(ts: &TransactionStatus) -> FfiMigrationTransactionStatus {
    let (is_transfer, prep_layer, prep_index, crossing) = match ts.kind() {
        MigrationTxKind::Preparation { layer, index } => (false, layer as i64, index as i64, -1i64),
        MigrationTxKind::Transfer { crossing } => (true, -1i64, -1i64, crossing as i64),
    };
    let state = match ts.state() {
        MigrationTxState::AwaitingSignature => 0,
        MigrationTxState::Signed => 1,
        MigrationTxState::Proved => 2,
        MigrationTxState::Broadcast { .. } => 3,
        MigrationTxState::Mined { .. } => 4,
    };
    let action = match ts.action() {
        None => 0,
        Some(NextAction::Prove) => 1,
        Some(NextAction::Broadcast) => 2,
    };
    let blocked_on = match ts.blocked_on() {
        None => 0,
        Some(Blocker::Dependencies) => 1,
        Some(Blocker::Schedule) => 2,
        Some(Blocker::AnchorBoundary) => 3,
        Some(Blocker::Signature) => 4,
        Some(Blocker::Expired) => 5,
    };
    let (txid, has_txid) = match ts.txid() {
        Some(txid) => (<[u8; 32]>::from(txid), true),
        None => ([0u8; 32], false),
    };
    FfiMigrationTransactionStatus {
        id: u32::from(ts.id()),
        is_transfer,
        prep_layer,
        prep_index,
        crossing,
        state,
        scheduled_height: i64::from(u32::from(ts.scheduled_height())),
        expiry_height: i64::from(u32::from(ts.expiry_height())),
        mined_height: height_opt_to_i64(ts.mined_height()),
        txid,
        has_txid,
        ready: ts.ready(),
        action,
        blocked_on,
    }
}

/// The LIVE status of every committed migration transaction, keyed by its stable id — a verbatim
/// marshal of `MigrationState::transaction_statuses(target)` at `target = tip + 1` (see
/// [`CallCtx::target`]), the engine's own per-transaction view a wallet renders progress from and
/// decides what to sign/prove/broadcast next. The read is side-effect free: callers must reconcile
/// canonical chain evidence first through the opaque-run delivery CAS. No stored run, or a stored
/// run with no transactions, returns an EMPTY container (`len == 0`) — not an error, the same
/// convention as [`encode_empty_schedule`].
///
/// This is a pure read: it never claims an artifact or drives a prove-ready `Signed` row through
/// proving — a `Signed` row ready to prove is reported via `ready`/`action` (`action == 1`), not
/// silently advanced to `Proved`.
///
/// # Safety
/// See [`open`]. Free the returned pointer with [`zcashlc_free_migration_transaction_statuses`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_transaction_statuses(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut FfiMigrationTransactionStatuses {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let Some(state) = read_canonical_migration(&mut ctx)? else {
            return Ok(encode_empty_transaction_statuses());
        };
        if state.transactions().is_empty() {
            return Ok(encode_empty_transaction_statuses());
        }
        let target = ctx.target()?;
        let rows: Vec<FfiMigrationTransactionStatus> = state
            .transaction_statuses(target)
            .into_iter()
            .map(|ts| encode_transaction_status(&ts))
            .collect();
        let (ptr, len) = ptr_from_vec(rows);
        Ok(Box::into_raw(Box::new(FfiMigrationTransactionStatuses {
            ptr,
            len,
        })))
    });
    unwrap_exc_or_null(res)
}

/// Whether the account's balance needs preparation (note-split) transactions before it can
/// migrate. Plans fresh against the live balance without changing any reviewed proposal's cache
/// handle. Returns `false` both
/// when no split is needed and when there is nothing to migrate at all; returns `false` on error
/// too (see `zcashlc_last_error_message` — the Swift layer disambiguates).
///
/// # Safety
/// See [`open`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_is_note_split_needed(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> bool {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        Ok(match compute_plan(&mut ctx)? {
            Some((plan, _)) => plan.preparation().transaction_count() > 0,
            None => false,
        })
    });
    unwrap_exc_or(res, false)
}

/// Whether any transaction of the stored run is due-and-unbroadcast at the current tip — that
/// is, whether the delivery lane has actionable work: an already-`Proved` transaction due for
/// broadcast, or a due, dependency-satisfied, prove-ready `Signed` one the opaque claim lane can
/// drive through proving (proofs are assumed to succeed — a transiently unwitnessable anchor
/// defers the delivery, not this report; see [`due_assuming_proving`]). A row awaiting an EXTERNAL
/// signature is not delivery work (the signing ceremony advances it). Returns `false` on error
/// (see `zcashlc_last_error_message`).
///
/// # Safety
/// See [`open`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_has_overdue_transfers(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> bool {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let Some(state) = read_canonical_migration(&mut ctx)? else {
            return Ok(false);
        };
        if state.is_terminal() {
            return Ok(false);
        }
        let target = ctx.target()?;
        Ok(due_assuming_proving(&state, target).is_some())
    });
    unwrap_exc_or(res, false)
}

/// Whether the stored canonical run has an expired, unmined transaction. Durable local and
/// transport failure classification belongs to the delivery-control runtime and is intentionally
/// not reconstructed by this compatibility query.
///
/// # Safety
/// See [`open`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_has_invalid_transfers(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> bool {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let Some(state) = read_canonical_migration(&mut ctx)? else {
            return Ok(false);
        };
        if matches!(state.status(), MigrationStatus::Complete) {
            return Ok(false);
        }
        // The engine's expiry predicate is defined over `target = tip + 1`, not the raw tip (see
        // `CallCtx::target`); membership in `expired_transactions` already excludes `Mined` rows
        // and treats `expiry_height == 0` as "never expires".
        let target = ctx.target()?;
        Ok(!state.expired_transactions(target).is_empty())
    });
    unwrap_exc_or(res, false)
}

/// The note-split preview for the account's live balance: the preparation output values and the
/// preparation fees. Plans fresh (and caches the preview for the later commit). An empty proposal
/// (zero outputs) means there is nothing to migrate.
///
/// # Safety
/// See [`open`]. Free the returned pointer with [`zcashlc_free_migration_note_split_proposal`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_prepare_note_split(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut FfiNoteSplitProposal {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let (values, fee, proposal_handle) = match plan_and_cache(&mut ctx)? {
            Some((plan, _, handle)) => {
                let split = plan.note_split();
                let values: Vec<i64> = split
                    .migration_outputs()
                    .iter()
                    .map(|v| zat_to_i64(*v))
                    .collect();
                (values, zat_to_i64(split.prep_fees()), handle)
            }
            None => (Vec::new(), 0, 0),
        };
        let (output_values, output_values_len) = ptr_from_vec(values);
        Ok(Box::into_raw(Box::new(FfiNoteSplitProposal {
            output_values,
            output_values_len,
            fee,
            proposal_handle,
        })))
    });
    unwrap_exc_or_null(res)
}

/// Retained only as a disabled C ABI compatibility symbol. This entry point always fails closed
/// before reading caller data or opening wallet state because it cannot bind the returned
/// transaction to a Rust-owned delivery capability. Callers must use the current typed migration
/// scheduling and opaque delivery-v1 handle APIs.
///
/// # Safety
/// All arguments are ignored and no caller pointers are dereferenced. The function always returns
/// NULL and sets the last-error channel.
#[allow(clippy::too_many_arguments)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_sign_note_split(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    output_values: *const i64,
    output_values_len: usize,
    fee: i64,
    usk_ptr: *const u8,
    usk_len: usize,
) -> *mut FfiPreparedTransfer {
    let _ = (
        db_data,
        db_data_len,
        account_uuid_bytes,
        network_id,
        output_values,
        output_values_len,
        fee,
        usk_ptr,
        usk_len,
    );
    let res = catch_panic(|| {
        Err(legacy_delivery_api_disabled(
            "zcashlc_migration_sign_note_split",
        ))
    });
    unwrap_exc_or_null(res)
}

/// The residual (zatoshi) that stays in Orchard after the migration: the note split's change,
/// below the migratable dust floor. Pre-commit this is read from a fresh preview; post-commit
/// from the stored run. Returns `-1` for "none" (and on error — see `zcashlc_last_error_message`;
/// the Swift layer disambiguates).
///
/// # Safety
/// See [`open`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_residual_after_migration(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> i64 {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        {
            let backend = Backend::new(&ctx.wallet, ctx.account, None, &mut ctx.store_conn)?;
            if let Some(state) = backend.get_migration()?
                && !state.is_terminal()
            {
                return Ok(state.note_split().change().map_or(-1, zat_to_i64));
            }
        }
        Ok(match compute_plan(&mut ctx)? {
            Some((plan, _)) => plan.note_split().change().map_or(-1, zat_to_i64),
            None => -1,
        })
    });
    unwrap_exc_or(res, -1)
}

/// After strict public migration `Complete`, locks EVERY currently-spendable,
/// not-already-locked legacy-Orchard note of the account until explicit unlock, and returns the
/// TOTAL LOCKED VALUE in zatoshi. `0` is a legitimate result (nothing was spendable, or everything
/// spendable is already locked); `-1` signals an error (see `zcashlc_last_error_message`).
///
/// The strict-completion gate first reconciles reorgs and invokes the centralized exact-output
/// finalizer. This ensures the provisional migration owner is gone before the distinct residual
/// owner is acquired; an engine-only/provisional `Complete` is rejected. The lock expiry is
/// permanent (`u32::MAX`), so no chain height ever releases it — only an explicit
/// `zcashlc_migration_unlock_residual` does. Note selection excludes already-locked notes, so
/// repeating the call is idempotent-additive: it locks only notes that became spendable since
/// (and returns only their value). Locks are keyed to the deterministic per-account
/// [`residual_lock_owner`], so a retry re-locks under the same owner instead of conflicting with
/// itself. Selection and locking share one wallet transaction, so another database writer cannot
/// interleave between them; an already-conflicting foreign lock fails the whole transaction.
///
/// # Safety
/// See [`open`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_lock_residual(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> i64 {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        require_strict_public_complete(&mut ctx)?;

        // Selection targets the next block, mirroring `Backend::selection_target`.
        let target = TargetHeight::from(u32::from(ctx.tip()?) + 1);
        let account = ctx.account;
        let owner = residual_lock_owner(account);
        ctx.wallet.transactionally(|wallet| -> anyhow::Result<i64> {
            let received = wallet
                .select_unspent_notes(
                    account,
                    &[ShieldedPool::Orchard],
                    target,
                    &[],
                    LockFilter::Policy(&LockedInputPolicy::Exclude),
                )
                .map_err(|e| anyhow!("spendable-note selection failed: {e}"))?;
            let mut refs = Vec::new();
            let mut total = Zatoshis::ZERO;
            for rn in received.orchard() {
                refs.push(OutputRef::new(
                    *rn.txid(),
                    PoolType::Shielded(ShieldedPool::Orchard),
                    u32::from(rn.output_index()),
                ));
                let value = Zatoshis::from_u64(rn.note().value().inner())
                    .map_err(|_| anyhow!("a spendable note has an out-of-range value"))?;
                total =
                    (total + value).ok_or_else(|| anyhow!("locked Orchard balance overflows"))?;
            }
            if refs.is_empty() {
                return Ok(0);
            }
            wallet
                .lock_outputs(&refs, owner, BlockHeight::from(u32::MAX))
                .map_err(|e| anyhow!("locking the migration residual failed: {e}"))?;
            Ok(zat_to_i64(total))
        })
    });
    unwrap_exc_or(res, -1)
}

/// The deterministic [`LockOwner`] under which [`zcashlc_migration_lock_residual`] locks the
/// account's residual notes: the 16 account-UUID bytes followed by a fixed 16-byte tag. A
/// stable owner keeps re-locking idempotent across retries (a same-owner re-lock refreshes the
/// permanent expiry instead of failing as a conflict). Migration owners are independent random
/// durable tokens; ordinary proposal owners may use other schemes, but owner-checked storage
/// mutations ensure this residual path never releases either kind.
fn residual_lock_owner(account: AccountUuid) -> LockOwner {
    let mut bytes = [0u8; 32];
    bytes[..16].copy_from_slice(&account.expose_uuid().into_bytes());
    bytes[16..].copy_from_slice(b"zodl.residual.lk");
    LockOwner::new(bytes)
}

/// Unlocks only active locks held by `owner`, invoking `unlock` with each exact output reference.
/// Keeping the owner predicate in this small helper makes the isolation contract directly
/// testable: migration, ordinary-PCZT, and other accounts' lock owners are never passed to the
/// storage mutation at all.
fn unlock_owned_active_locks<E>(
    locks: &[ActiveOrchardLock],
    owner: LockOwner,
    mut unlock: impl FnMut(&OutputRef, LockOwner) -> Result<bool, E>,
) -> Result<usize, E> {
    let mut count = 0;
    for output in locks
        .iter()
        .filter(|lock| lock.owner() == owner)
        .map(ActiveOrchardLock::output)
    {
        if unlock(&output, owner)? {
            count += 1;
        }
    }
    Ok(count)
}

/// Unlocks only the exact active Orchard outputs held by this account's deterministic
/// [`residual_lock_owner`] — the release half of `zcashlc_migration_lock_residual` — and returns
/// the number of outputs unlocked (`0` when nothing was locked; `-1` signals an error, see
/// `zcashlc_last_error_message`). Migration locks, ordinary-PCZT locks, and every foreign owner
/// are deliberately preserved. The active-lock query and every exact owner-checked unlock share
/// one wallet transaction.
///
/// # Safety
/// See [`open`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_unlock_residual(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> i64 {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let owner = residual_lock_owner(ctx.account);
        let cleared = ctx
            .wallet
            .transactionally(|wallet| -> anyhow::Result<usize> {
                let locks = wallet
                    .active_orchard_locks()
                    .map_err(|e| anyhow!("reading active Orchard locks failed: {e}"))?;
                unlock_owned_active_locks(&locks, owner, |output, owner| {
                    wallet
                        .unlock_output(output, owner)
                        .map_err(|e| anyhow!("unlocking the migration residual failed: {e}"))
                })
            })?;
        Ok(cleared as i64)
    });
    unwrap_exc_or(res, -1)
}

/// Estimates how the account migrates its whole spendable balance: the number of migration RUNS
/// ("rounds") it takes, and for each run BOTH what it migrates (the note-split crossings) and
/// what preparing it costs (the note-preparation layers and transactions), so the platform can
/// preview and compare the two before anything is planned or committed. A balance beyond one
/// run's capacity migrates over several runs; the estimate depends on the wallet's NOTE
/// STRUCTURE, not just its total value (each run is decomposed with the real planners, and the
/// notes a run spends plus the residuals it leaves form the next run's structure).
///
/// An external signer's per-session capacity is NOT part of the estimate: the SDK evaluates
/// signing sessions from the returned per-run transaction counts for any signer capacity,
/// without re-running the planners. A zero (or fully sub-quantum) balance yields the ZERO-RUN
/// estimate (`runs_len == 0`) — a legitimate result, not an error. NULL signals an error (see
/// `zcashlc_last_error_message`).
///
/// # Safety
/// See [`open`]. Free the returned pointer with [`zcashlc_free_migration_run_estimate`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_estimate_runs(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut FfiMigrationRunEstimate {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let backend = Backend::new(&ctx.wallet, ctx.account, None, &mut ctx.store_conn)?;
        let mut rng = OsRng;
        let estimate = match engine::estimate_migration_runs(&ctx.network, &backend, &mut rng) {
            Ok(estimate) => Some(estimate),
            // The estimator answers a zero balance with the zero-run estimate rather than this
            // error, so this arm should never fire; map it to the same zero-run answer anyway,
            // for symmetry with the propose path's empty schedule.
            Err(engine::MigrationError::NothingToMigrate) => None,
            Err(e) => return Err(anyhow!("Error estimating migration runs: {e}")),
        };
        let (runs, final_residual) = match &estimate {
            Some(est) => (
                est.runs()
                    .iter()
                    .map(|run| {
                        Ok(FfiRunEstimate {
                            migratable: zat_to_i64(run.migratable()),
                            crossings: count_to_u32(run.crossings(), "crossings")?,
                            prep_layers: count_to_u32(run.prep_layers(), "prep-layers")?,
                            prep_transactions: count_to_u32(
                                run.prep_transactions(),
                                "prep-transactions",
                            )?,
                        })
                    })
                    .collect::<anyhow::Result<Vec<_>>>()?,
                zat_to_i64(est.final_residual()),
            ),
            None => (Vec::new(), 0),
        };
        let (runs, runs_len) = ptr_from_vec(runs);
        Ok(Box::into_raw(Box::new(FfiMigrationRunEstimate {
            runs,
            runs_len,
            final_residual,
        })))
    });
    unwrap_exc_or_null(res)
}

/// The migration schedule preview for the account's live balance, in chronological broadcast
/// order. Plans fresh (drawing new ZIP 318 randomness) and caches the preview — a later commit
/// signs exactly this plan. An EMPTY schedule means there is nothing to migrate: after a
/// completed run this is the "does anything remain" answer.
///
/// # Safety
/// See [`open`]. Free the returned pointer with [`zcashlc_free_migration_schedule`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_propose_transfers(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut FfiMigrationSchedule {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        match plan_and_cache(&mut ctx)? {
            Some((plan, reference_height, handle)) => {
                encode_schedule_from_plan(&plan, reference_height, handle)
            }
            None => Ok(encode_empty_schedule()),
        }
    });
    unwrap_exc_or_null(res)
}

/// Commits the previewed migration with the spending key if nothing is committed yet. A matching
/// non-terminal run resumes as a no-op; a terminal run must use the typed successor-rollover API.
///
/// `proposal_handle` is the only proposal authority accepted from the caller. It identifies the
/// exact Rust-cached plan the user reviewed. A fresh commit fails with `MIGRATION_PLAN_STALE` when
/// the plan is missing or superseded; a durable resume does not consult the handle.
///
/// # Safety
/// See [`open`]; `usk_ptr` must be valid for reads of `usk_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_sign_and_store_schedule(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    proposal_handle: u64,
    usk_ptr: *const u8,
    usk_len: usize,
) -> bool {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let usk = unsafe { crate::decode_usk(usk_ptr, usk_len)? };
        commit_or_resume(&mut ctx, Some(usk), false, proposal_handle)?;
        Ok(true)
    });
    unwrap_exc_or(res, false)
}

/// Commits the reviewed schedule for external signing without exposing unsigned PCZT bytes.
/// `proposal_handle` is the only proposal authority accepted from the caller; Rust builds and
/// atomically locks the exact cached plan it identifies, initializes delivery, and returns only
/// an opaque run handle. A non-terminal durable run resumes without consulting the handle.
///
/// # Safety
/// See [`open`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_commit_external_schedule_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    proposal_handle: u64,
) -> *mut FfiMigrationRunHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let (_state, _unsigned_not_exposed) =
            commit_or_resume(&mut ctx, None, true, proposal_handle)?;
        let account_uuid = ctx.account_bytes;
        let snapshot = scheduled_store(&mut ctx)?
            .delivery_snapshot()
            .map_err(|e| anyhow!("reading committed external delivery run failed: {e}"))?
            .ok_or_else(|| anyhow!("external schedule commit did not create a delivery run"))?;
        Ok(Box::into_raw(Box::new(run_handle(account_uuid, &snapshot))))
    });
    unwrap_exc_or_null(res)
}

/// Atomically replaces a terminal scheduled predecessor with a fresh SDK-signed successor.
///
/// The host supplies only an opaque current predecessor capability, the opaque handle from the
/// most recent Rust preview, and the account spending key. Rust rebuilds the successor with
/// the unchanged upstream engine and generates every successor identity in the wallet-store CAS;
/// the predecessor archive and its source reservations remain retained.
///
/// # Safety
/// See [`open`]. `predecessor_run_handle` must be a live borrowed handle, and `usk_ptr` must be
/// valid for `usk_len` bytes.
/// Free the returned handle with [`zcashlc_migration_free_run_handle_v1`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_rollover_internal_schedule_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    predecessor_run_handle: *const FfiMigrationRunHandle,
    proposal_handle: u64,
    usk_ptr: *const u8,
    usk_len: usize,
) -> *mut FfiMigrationRunHandle {
    let res = catch_panic(|| {
        if usk_ptr.is_null() {
            return Err(anyhow!(
                "SDK-signed successor rollover requires a spending key"
            ));
        }
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let predecessor = unsafe { require_scheduled_run(&ctx, predecessor_run_handle)? };
        let usk = unsafe { crate::decode_usk(usk_ptr, usk_len)? };
        let cached = migration_plan_cache::get(&ctx.db_path, ctx.account_bytes, proposal_handle)
            .map_err(|e| plan_stale(&e.to_string()))?;
        let account_uuid = ctx.account_bytes;
        let successor =
            rollover_scheduled_successor(&mut ctx, predecessor, &cached, Some(usk), false)?;
        Ok(Box::into_raw(Box::new(run_handle(
            account_uuid,
            &successor,
        ))))
    });
    unwrap_exc_or_null(res)
}

/// Atomically replaces a terminal scheduled predecessor with a fresh externally-signed successor.
///
/// No spending key or caller-built successor crosses this ABI. Rust uses the account's stored
/// UFVK and the unchanged upstream unsigned builder, discards the unsigned output before return,
/// and exposes canonical PCZT bytes only after a later delivery claim atomically stages them.
///
/// # Safety
/// See [`open`]. `predecessor_run_handle` must be a live borrowed handle. Free the returned handle
/// with [`zcashlc_migration_free_run_handle_v1`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_rollover_external_schedule_v1(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    predecessor_run_handle: *const FfiMigrationRunHandle,
    proposal_handle: u64,
) -> *mut FfiMigrationRunHandle {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let predecessor = unsafe { require_scheduled_run(&ctx, predecessor_run_handle)? };
        let cached = migration_plan_cache::get(&ctx.db_path, ctx.account_bytes, proposal_handle)
            .map_err(|e| plan_stale(&e.to_string()))?;
        let account_uuid = ctx.account_bytes;
        let successor = rollover_scheduled_successor(&mut ctx, predecessor, &cached, None, true)?;
        Ok(Box::into_raw(Box::new(run_handle(
            account_uuid,
            &successor,
        ))))
    });
    unwrap_exc_or_null(res)
}

/// Retained only as a disabled C ABI compatibility symbol. Standalone delivery cannot prove that
/// the caller owns the exact artifact, so this entry point always fails closed before reading
/// caller data or opening wallet state. Callers must use the opaque delivery-v1 claim APIs.
///
/// # Safety
/// All arguments are ignored and no caller pointers are dereferenced. The function always returns
/// NULL and sets the last-error channel.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_next_due_transfer(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut FfiPreparedTransfer {
    let _ = (db_data, db_data_len, account_uuid_bytes, network_id);
    let res = catch_panic(|| {
        Err(legacy_delivery_api_disabled(
            "zcashlc_migration_next_due_transfer",
        ))
    });
    unwrap_exc_or_null(res)
}

/// The next due-and-unbroadcast TRANSFER of the stored run as a proposal row (id, amount, its
/// scheduled and expiry heights), or NULL with no error when there is none. Distinguish the two
/// NULL meanings via `zcashlc_last_error_length`.
///
/// "Due-and-unbroadcast" matches what the opaque delivery claim lane is being driven toward: an
/// already-`Proved` due transfer, or a due, prove-ready `Signed` one the delivery flow first proves
/// (see [`due_assuming_proving`] — this query itself never proves and assumes the later proof
/// succeeds). NULL when the next claimable transaction is a preparation, when due rows still
/// await an external signature, or when nothing is due.
///
/// # Safety
/// See [`open`]. Free the returned pointer with [`zcashlc_free_migration_transfer_proposal`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_pending_transfer_proposal(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut FfiTransferProposal {
    let res = catch_panic(|| {
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let Some(state) = read_canonical_migration(&mut ctx)? else {
            return Ok(ptr::null_mut());
        };
        if state.is_terminal() {
            return Ok(ptr::null_mut());
        }
        // `tip` is the display-only "now" reference the DTO carries (see
        // `FfiTransferProposal::anchor_height`'s doc); `target` (`tip + 1`) is what the engine
        // query below is actually defined over — see `CallCtx::target`.
        let tip = ctx.tip()?;
        let target = target_from_tip(tip);
        let next_transfer = due_assuming_proving(&state, target)
            .and_then(|id| state.transactions().iter().find(|t| t.id() == id))
            .filter(|t| matches!(t.kind(), MigrationTxKind::Transfer { .. }));
        match next_transfer {
            Some(tx) => {
                let amount = state
                    .transfer_amount(tx)
                    .ok_or_else(|| anyhow!("stored transfer has no valid net crossing amount"))?;
                FfiTransferProposal::boxed(
                    tx.id(),
                    amount,
                    tip,
                    tx.scheduled_height(),
                    tx.expiry_height(),
                )
            }
            None => Ok(ptr::null_mut()),
        }
    });
    unwrap_exc_or_null(res)
}

/// Retained only as a disabled C ABI compatibility symbol. This unscoped extraction entry point
/// predates delivery ownership and carries neither the exact source-reservation owner nor the
/// canonical wallet-lock owner required to authorize migration inputs, so it always fails closed.
/// Callers must use the token-bound materialization flow under the owning run and claim.
///
/// # Safety
/// All arguments are ignored and no caller pointers are dereferenced. The function always returns
/// NULL and sets the last-error channel.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_extract_broadcast_tx(
    _db_data: *const u8,
    _db_data_len: usize,
    _account_uuid_bytes: *const u8,
    _network_id: u32,
    _pczt_ptr: *const u8,
    _pczt_len: usize,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        Err(anyhow!(
            "legacy migration PCZT extraction is unauthorized; use the token-bound migration materialization API"
        ))
    });
    unwrap_exc_or_null(res)
}

/// Retained only as a disabled C ABI compatibility symbol. This unscoped callback cannot prove
/// ownership of the canonical artifact or delivery claim, so it always fails closed before
/// reading caller data or opening wallet state. Callers must record exact transport outcomes and
/// failures through the token-bound delivery-v1 API.
///
/// # Safety
/// All arguments are ignored and no caller pointers are dereferenced. The function always returns
/// `false` and sets the last-error channel.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_record_transfer_result(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    transfer_id: *const c_char,
    result_tag: i32,
    txid_bytes: *const u8,
) -> bool {
    let _ = (
        db_data,
        db_data_len,
        account_uuid_bytes,
        network_id,
        transfer_id,
        result_tag,
        txid_bytes,
    );
    let res = catch_panic(|| {
        Err(legacy_delivery_api_disabled(
            "zcashlc_migration_record_transfer_result",
        ))
    });
    unwrap_exc_or(res, false)
}

/// Retained only as a disabled C ABI compatibility symbol. This entry point cannot safely release
/// delivery-owned source reservations, so it always fails closed before opening wallet state.
/// Callers must use [`zcashlc_migration_begin_abandonment_v1`] followed by
/// [`zcashlc_migration_finish_abandonment_v1`], re-propose, and commit through the appropriate
/// typed successor-rollover API.
///
/// # Safety
/// All arguments are ignored and no caller pointers are dereferenced. The function always returns
/// NULL and sets the last-error channel.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_restart_step(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut FfiMigrationSchedule {
    let _ = (db_data, db_data_len, account_uuid_bytes, network_id);
    let res = catch_panic(|| {
        Err(legacy_delivery_api_disabled(
            "zcashlc_migration_restart_step",
        ))
    });
    unwrap_exc_or_null(res)
}

/// Retained only as a disabled C ABI compatibility symbol. This bulk, unscoped refresh entry point
/// cannot bind a rebuild to the exact current artifact and claim, so it always fails closed before
/// reading caller data or opening wallet state. Callers must use
/// [`zcashlc_migration_rebuild_expired_transfer_v1`] with the current opaque claim handle.
///
/// # Safety
/// All arguments are ignored and no caller pointers are dereferenced. The function always returns
/// NULL and sets the last-error channel.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_refresh_stale_transfers(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    usk_ptr: *const u8,
    usk_len: usize,
) -> *mut FfiMigrationSchedule {
    let _ = (
        db_data,
        db_data_len,
        account_uuid_bytes,
        network_id,
        usk_ptr,
        usk_len,
    );
    let res = catch_panic(|| {
        Err(legacy_delivery_api_disabled(
            "zcashlc_migration_refresh_stale_transfers",
        ))
    });
    unwrap_exc_or_null(res)
}

/// Fetches the account's ZIP 32 seed fingerprint and account index, required to annotate
/// external-signer (Keystone) migration PCZTs with `spend_zip32_derivation` — see
/// [`crate::migration_keystone::annotate_spend_zip32_derivation`]'s doc comment for why this is
/// needed.
///
/// Zend's typed delivery lane retains the exact canonical PCZT unchanged in durable claim evidence.
/// The account derivation is therefore applied only to the transient copy encoded for Keystone by
/// `zcashlc_migration_keystone_build_sign_batch_qr_parts_v2`; signatures are applied back to the
/// original staged bytes by the unchanged upstream batch combiner. This keeps both the device's
/// account-discovery requirement and the exact-artifact delivery binding.
fn account_zip32_derivation(
    wallet: &MigrationWallet,
    account: AccountUuid,
) -> anyhow::Result<([u8; 32], zip32::AccountId)> {
    use zcash_client_backend::data_api::Account;

    let account_info = wallet
        .get_account(account)
        .map_err(|e| anyhow!("account lookup failed: {}", e))?
        .ok_or_else(|| anyhow!("Account not found"))?;
    let derivation = account_info.source().key_derivation().ok_or_else(|| {
        anyhow!(
            "Account has no known ZIP 32 seed fingerprint/account index — cannot annotate \
             migration PCZTs for external-signer batch signing"
        )
    })?;
    Ok((
        derivation.seed_fingerprint().to_bytes(),
        derivation.account_index(),
    ))
}

/// Retained only as a disabled C ABI compatibility symbol. This entry point would expose unsigned
/// transactions without a Rust-owned delivery claim, so it always fails closed before opening
/// wallet state. Callers must commit an external schedule with
/// [`zcashlc_migration_commit_external_schedule_v1`] and expose canonical bytes only through the
/// typed external-signing claim flow.
///
/// # Safety
/// All arguments are ignored and no caller pointers are dereferenced. The function always returns
/// NULL and sets the last-error channel.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_create_unsigned_note_split_pczts(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut FfiUnsignedTransferPczts {
    let _ = (db_data, db_data_len, account_uuid_bytes, network_id);
    let res = catch_panic(|| {
        Err(legacy_delivery_api_disabled(
            "zcashlc_migration_create_unsigned_note_split_pczts",
        ))
    });
    unwrap_exc_or_null(res)
}

/// Retained only as a disabled C ABI compatibility symbol. This entry point accepts signed bytes
/// without an owning Rust delivery claim, so it always fails closed before reading caller data or
/// opening wallet state. Callers must advance the exact staged external-signing claim with
/// [`zcashlc_migration_advance_external_signature_v1`].
///
/// # Safety
/// All arguments are ignored and no caller pointers are dereferenced. The function always returns
/// NULL and sets the last-error channel.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_store_signed_note_split_pczts(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    ids: *const *const c_char,
    ids_len: usize,
    pczts: *const *const u8,
    pczt_lens: *const usize,
) -> *mut FfiPreparedTransfer {
    let _ = (
        db_data,
        db_data_len,
        account_uuid_bytes,
        network_id,
        ids,
        ids_len,
        pczts,
        pczt_lens,
    );
    let res = catch_panic(|| {
        Err(legacy_delivery_api_disabled(
            "zcashlc_migration_store_signed_note_split_pczts",
        ))
    });
    unwrap_exc_or_null(res)
}

/// Retained only as a disabled C ABI compatibility symbol. This entry point would expose unsigned
/// transfer PCZTs without an owning Rust delivery claim, so it always fails closed before reading
/// caller data or opening wallet state. Callers must use the typed external-signing claim flow.
/// # Safety
/// All arguments are ignored and no caller pointers are dereferenced. The function always returns
/// NULL and sets the last-error channel.
#[allow(clippy::too_many_arguments)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_create_unsigned_transfer_pczts(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    ids: *const *const c_char,
    ids_len: usize,
    amounts: *const i64,
    anchor_heights: *const i64,
    next_executable_after_heights: *const i64,
    expiry_heights: *const i64,
    estimated_duration_hours: u32,
) -> *mut FfiUnsignedTransferPczts {
    let _ = (
        db_data,
        db_data_len,
        account_uuid_bytes,
        network_id,
        ids,
        ids_len,
        amounts,
        anchor_heights,
        next_executable_after_heights,
        expiry_heights,
        estimated_duration_hours,
    );
    let res = catch_panic(|| {
        Err(legacy_delivery_api_disabled(
            "zcashlc_migration_create_unsigned_transfer_pczts",
        ))
    });
    unwrap_exc_or_null(res)
}

/// Retained only as a disabled C ABI compatibility symbol. This entry point accepts signed bytes
/// without an owning Rust delivery claim, so it always fails closed before reading caller data or
/// opening wallet state. Callers must advance the exact staged external-signing claim with
/// [`zcashlc_migration_advance_external_signature_v1`].
///
/// # Safety
/// All arguments are ignored and no caller pointers are dereferenced. The function always returns
/// `false` and sets the last-error channel.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_store_signed_schedule_pczts(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    ids: *const *const c_char,
    ids_len: usize,
    pczts: *const *const u8,
    pczt_lens: *const usize,
) -> bool {
    let _ = (
        db_data,
        db_data_len,
        account_uuid_bytes,
        network_id,
        ids,
        ids_len,
        pczts,
        pczt_lens,
    );
    let res = catch_panic(|| {
        Err(legacy_delivery_api_disabled(
            "zcashlc_migration_store_signed_schedule_pczts",
        ))
    });
    unwrap_exc_or(res, false)
}

/// Decode the platform's parallel `(id, pczt)` arrays into owned pairs.
///
/// # Safety
/// `ids`/`pczts`/`pczt_lens` must be valid for reads of `len` elements; every `ids[i]` must be a
/// valid C string and every `pczts[i]` valid for `pczt_lens[i]` bytes.
unsafe fn decode_signed_pairs(
    ids: *const *const c_char,
    len: usize,
    pczts: *const *const u8,
    pczt_lens: *const usize,
) -> anyhow::Result<Vec<(MigrationTxId, Vec<u8>)>> {
    let id_ptrs = unsafe { slice_or_empty(ids, len) };
    let pczt_ptrs = unsafe { slice_or_empty(pczts, len) };
    let lens = unsafe { slice_or_empty(pczt_lens, len) };
    let mut out = Vec::with_capacity(len);
    for i in 0..len {
        let id = transfer_id_from_c(id_ptrs[i])?;
        if pczt_ptrs[i].is_null() {
            return Err(anyhow!("signed pczt at index {i} is null"));
        }
        let bytes = unsafe { slice::from_raw_parts(pczt_ptrs[i], lens[i]) }.to_vec();
        out.push((id, bytes));
    }
    Ok(out)
}

// ----- Keystone batch-signing UR bridge (crate::migration_keystone) -----
//
// Pure PCZT/UR operations over caller-held bytes — no wallet database, no migration engine.

/// Decode the platform's parallel `(pczt, pczt_len)` arrays into owned PCZT byte vectors.
///
/// # Safety
/// `pczts`/`pczt_lens` must be valid for reads of `len` elements; every `pczts[i]` must be valid
/// for `pczt_lens[i]` bytes.
unsafe fn decode_pczt_list(
    pczts: *const *const u8,
    pczt_lens: *const usize,
    len: usize,
) -> anyhow::Result<Vec<Vec<u8>>> {
    let pczt_ptrs = unsafe { slice_or_empty(pczts, len) };
    let lens = unsafe { slice_or_empty(pczt_lens, len) };
    let mut out = Vec::with_capacity(len);
    for i in 0..len {
        if pczt_ptrs[i].is_null() {
            return Err(anyhow!("pczt at index {i} is null"));
        }
        out.push(unsafe { slice::from_raw_parts(pczt_ptrs[i], lens[i]) }.to_vec());
    }
    Ok(out)
}

/// Builds the animated multi-part QR frames for a Keystone batch-signing request covering every
/// PCZT in `pczts`, in the given order (preparation PCZTs first, then transfer PCZTs — see
/// [`crate::migration_keystone`]'s module doc). `ids` is deliberately NOT a parameter: the build
/// step has no use for them — only [`zcashlc_migration_keystone_apply_batch_signatures`] echoes
/// ids back out, since that is what the caller matches signed PCZTs to stored transactions by.
///
/// # Safety
/// `request_id` must be valid for reads of `request_id_len` bytes. `pczts`/`pczt_lens` must be
/// valid for reads of `pczts_len` elements, and each `pczts[i]` valid for `pczt_lens[i]` bytes.
/// Free the returned pointer with [`zcashlc_free_migration_keystone_qr_parts`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_keystone_build_sign_batch_qr_parts(
    request_id: *const u8,
    request_id_len: usize,
    pczts: *const *const u8,
    pczt_lens: *const usize,
    pczts_len: usize,
    max_fragment_len: usize,
) -> *mut FfiKeystoneQrParts {
    let res = catch_panic(|| {
        let request_id = unsafe { slice_or_empty(request_id, request_id_len) }.to_vec();
        let pczts = unsafe { decode_pczt_list(pczts, pczt_lens, pczts_len)? };
        let parts = crate::migration_keystone::build_sign_batch_qr_parts(
            request_id,
            &pczts,
            max_fragment_len,
        )
        .map_err(|e| anyhow!("Error building Keystone sign-batch QR parts: {e}"))?;
        FfiKeystoneQrParts::from_parts(parts)
    });
    unwrap_exc_or_null(res)
}

/// Resolves live, claim-owned scheduled PCZTs for the Zend Keystone wrapper. The returned bytes
/// are exact clones of the durable canonical artifacts; callers may annotate only those clones.
fn validated_keystone_claim_pczts(
    state: &MigrationState,
    delivery: &DeliverySnapshot,
    handles: &[&FfiMigrationClaimHandle],
) -> anyhow::Result<Vec<Vec<u8>>> {
    if delivery.lane() != DeliveryLane::Scheduled {
        return Err(anyhow!("Keystone batch requires a scheduled delivery run"));
    }

    let mut transaction_ids = Vec::with_capacity(handles.len());
    let mut pczts = Vec::with_capacity(handles.len());
    for handle in handles {
        if handle.run.lane != DeliveryLane::Scheduled
            || handle.run.revision != delivery.revision()
            || handle.run.run_identity != delivery.run_identity()
            || handle.run.source_reservation_owner != delivery.source_reservation_owner()
            || handle.run.policy_fingerprint
                != delivery
                    .submission_policy()
                    .map(SubmissionPolicy::fingerprint)
        {
            return Err(anyhow!(
                "Keystone batch received a stale or foreign delivery capability"
            ));
        }
        if handle.signer_ownership != SignerOwnership::External
            || handle.status != ClaimStatus::AwaitingExternalSignature
            || handle.claim_kind != Some(ClaimKind::Materialization)
        {
            return Err(anyhow!(
                "Keystone batch requires a live external-signing materialization claim"
            ));
        }
        let token = required_claim_token(handle)?;
        let staged = handle
            .external_signing_pczt
            .as_deref()
            .ok_or_else(|| anyhow!("Keystone claim has no staged canonical PCZT"))?;
        let transaction_id = match handle.artifact_identity {
            DeliveryArtifactIdentity::Scheduled(identity) => identity.transaction_id(),
            DeliveryArtifactIdentity::Immediate(_) => {
                return Err(anyhow!(
                    "Keystone migration batching does not accept immediate-lane claims"
                ));
            }
        };
        if transaction_ids.contains(&transaction_id) {
            return Err(anyhow!(
                "Keystone batch repeats scheduled transaction {}",
                u32::from(transaction_id)
            ));
        }

        let canonical = scheduled_artifact_evidence(state, transaction_id)
            .ok_or_else(|| anyhow!("Keystone claim's canonical transaction is absent"))?;
        if DeliveryArtifactIdentity::Scheduled(canonical.identity()) != handle.artifact_identity
            || canonical.canonical_pczt() != staged
        {
            return Err(anyhow!(
                "Keystone claim no longer owns the current canonical PCZT"
            ));
        }

        let live = delivery
            .claims()
            .iter()
            .find(|claim| claim.artifact_identity() == handle.artifact_identity)
            .ok_or_else(|| anyhow!("Keystone claim is absent from the current delivery run"))?;
        if live.signer_ownership() != SignerOwnership::External
            || live.status() != ClaimStatus::AwaitingExternalSignature
            || live.claim_kind() != Some(ClaimKind::Materialization)
            || live.token() != Some(token)
            || live.expiry_height() != handle.expiry_height
            || live.external_signing_pczt().map(|pczt| pczt.bytes()) != Some(staged)
        {
            return Err(anyhow!(
                "Keystone claim is stale or differs from current durable delivery state"
            ));
        }

        transaction_ids.push(transaction_id);
        pczts.push(staged.to_vec());
    }
    Ok(pczts)
}

/// Builds Keystone batch-signing QR frames for exact PCZTs owned by Zend's opaque delivery lane.
///
/// This versioned wrapper preserves the upstream pure codec above, but accepts only current
/// scheduled external-signing claim capabilities — never caller-supplied PCZT bytes. It reloads
/// and validates each claim against the same live delivery snapshot and canonical migration state,
/// derives the account's ZIP 32 metadata inside Rust, and annotates only transient QR-input copies.
/// The durable staged PCZTs remain byte-for-byte canonical, and
/// [`zcashlc_migration_keystone_apply_batch_signatures`] applies the returned signatures to those
/// original bytes in the same order.
///
/// # Safety
/// The database and account pointers follow [`open`]. `request_id` must be valid for reads of
/// `request_id_len` bytes. `claim_handles` must be valid for reads of `claim_handles_len` elements,
/// and each element must be a live borrowed handle returned by this module. Free the returned
/// pointer with [`zcashlc_free_migration_keystone_qr_parts`].
#[allow(clippy::too_many_arguments)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_keystone_build_sign_batch_qr_parts_v2(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    request_id: *const u8,
    request_id_len: usize,
    claim_handles: *const *const FfiMigrationClaimHandle,
    claim_handles_len: usize,
    max_fragment_len: usize,
) -> *mut FfiKeystoneQrParts {
    let res = catch_panic(|| {
        let request_id = unsafe { slice_or_empty(request_id, request_id_len) }.to_vec();
        if request_id.is_empty() {
            return Err(anyhow!("Keystone batch request id is empty"));
        }
        let claim_ptrs = unsafe { slice_or_empty(claim_handles, claim_handles_len) };
        if claim_ptrs.is_empty() {
            return Err(anyhow!("Keystone batch contains no migration claims"));
        }
        let mut ctx = unsafe { open(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let handles = claim_ptrs
            .iter()
            .map(|handle| unsafe { require_claim(&ctx, *handle) })
            .collect::<anyhow::Result<Vec<_>>>()?;
        let (seed_fingerprint, account_index) = account_zip32_derivation(&ctx.wallet, ctx.account)?;
        let state = scheduled_state(&scheduled_store(&mut ctx)?)?;
        let delivery = scheduled_store(&mut ctx)?
            .delivery_snapshot()
            .map_err(|e| anyhow!("reading Keystone delivery snapshot failed: {e}"))?
            .ok_or_else(|| anyhow!("Keystone batch has no current scheduled delivery run"))?;
        let pczts = validated_keystone_claim_pczts(&state, &delivery, &handles)?
            .into_iter()
            .map(|pczt| {
                crate::migration_keystone::annotate_spend_zip32_derivation(
                    &pczt,
                    seed_fingerprint,
                    ctx.network.coin_type(),
                    account_index,
                )
                .map_err(|e| anyhow!("Error annotating Keystone batch PCZT derivation: {e:?}"))
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        let parts = crate::migration_keystone::build_sign_batch_qr_parts(
            request_id,
            &pczts,
            max_fragment_len,
        )
        .map_err(|e| anyhow!("Error building Keystone sign-batch QR parts: {e}"))?;
        FfiKeystoneQrParts::from_parts(parts)
    });
    unwrap_exc_or_null(res)
}
/// Discards any in-flight multi-part Keystone sign-batch-response scan session. Callers should
/// invoke this on scan-screen entry so a new attempt always starts from a clean slate regardless
/// of how a previous attempt ended (cancel, back button, mid-stream error). Void and infallible.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_migration_keystone_reset_sign_batch_decoder() {
    crate::migration_keystone::reset_sign_batch_decoder();
}

/// Feeds one scanned QR frame into the active (or a freshly started) Keystone sign-batch-response
/// decode session, pinned to the `"zcash-batch-sig-result"` UR type. `expected_request_id` must
/// match the decoded response's own request id once complete, or this errors (a scan of an
/// unrelated/stale response) instead of silently accepting it. See
/// [`crate::migration_keystone::decode_sign_batch_part`].
///
/// # Safety
/// `part` must be a valid, NUL-terminated C string. `expected_request_id` must be valid for reads
/// of `expected_request_id_len` bytes. Free the returned pointer with
/// [`zcashlc_free_migration_keystone_batch_decode_result`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_keystone_decode_sign_batch_part(
    part: *const c_char,
    expected_request_id: *const u8,
    expected_request_id_len: usize,
) -> *mut FfiKeystoneBatchDecodeResult {
    let res = catch_panic(|| {
        if part.is_null() {
            return Err(anyhow!("part is null"));
        }
        let part = unsafe { CStr::from_ptr(part) }
            .to_str()
            .map_err(|e| anyhow!("part is not valid UTF-8: {e}"))?;
        let expected_request_id =
            unsafe { slice_or_empty(expected_request_id, expected_request_id_len) };
        let result = crate::migration_keystone::decode_sign_batch_part(part, expected_request_id)
            .map_err(|e| anyhow!("Error decoding Keystone sign-batch QR part: {e}"))?;
        Ok(FfiKeystoneBatchDecodeResult::from_parts(result))
    });
    unwrap_exc_or_null(res)
}

/// Applies the ceremony's Keystone batch signatures to the caller-held unsigned PCZTs,
/// positionally (see [`crate::migration_keystone::apply_batch_signatures`]) — `ids`/`pczts` must
/// be the SAME PCZTs, in the SAME order, passed to
/// [`zcashlc_migration_keystone_build_sign_batch_qr_parts`]. `ids` pass through positionally onto
/// the returned signed PCZTs, reusing [`FfiUnsignedTransferPczts`] as a generic `(id, PCZT
/// bytes)` pair set (see its doc) and [`decode_signed_pairs`] to decode the parallel input
/// arrays.
///
/// # Safety
/// See [`decode_signed_pairs`]. `response` must be valid for reads of `response_len` bytes. Free
/// the returned pointer with [`zcashlc_free_migration_unsigned_transfer_pczts`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_keystone_apply_batch_signatures(
    ids: *const *const c_char,
    ids_len: usize,
    pczts: *const *const u8,
    pczt_lens: *const usize,
    response: *const u8,
    response_len: usize,
) -> *mut FfiUnsignedTransferPczts {
    let res = catch_panic(|| {
        let unsigned = unsafe { decode_signed_pairs(ids, ids_len, pczts, pczt_lens)? };
        let (ids, pczts): (Vec<MigrationTxId>, Vec<Vec<u8>>) = unsigned.into_iter().unzip();
        let response = unsafe { slice_or_empty(response, response_len) };
        let signed = crate::migration_keystone::apply_batch_signatures(&pczts, response)
            .map_err(|e| anyhow!("Error applying Keystone batch signatures: {e}"))?;
        FfiUnsignedTransferPczts::from_pairs(ids.into_iter().zip(signed).collect())
    });
    unwrap_exc_or_null(res)
}

/// The Ironwood (NU6.3) activation height for a standard network, or `-1` when unset/unknown (and
/// on error — see `zcashlc_last_error_message`).
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_ironwood_activation_height(network_id: u32) -> i64 {
    let res = catch_panic(|| {
        let network = match network_id {
            NETWORK_ID_TESTNET => Network::TestNetwork,
            NETWORK_ID_MAINNET => Network::MainNetwork,
            other => {
                return Err(anyhow!(
                    "Invalid network id for Ironwood activation height: {other}. Expected {NETWORK_ID_TESTNET} (testnet) or {NETWORK_ID_MAINNET} (mainnet)."
                ));
            }
        };
        Ok(height_opt_to_i64(
            network.activation_height(NetworkUpgrade::Nu6_3),
        ))
    });
    unwrap_exc_or(res, -1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::SeedableRng;
    use rand::rngs::StdRng;
    use zcash_pool_migration::note_splitting::NoteSplitPlan;
    use zcash_pool_migration::preparation::PreparationPlan;
    use zcash_pool_migration::scheduling;

    fn zat(v: u64) -> Zatoshis {
        Zatoshis::from_u64(v).unwrap()
    }

    fn h(v: u32) -> BlockHeight {
        BlockHeight::from_u32(v)
    }

    /// Creates a real account in the initialized wallet database at `path` and returns its uuid
    /// bytes plus its unified spending key encoded for the FFI (`Era::Orchard`, the encoding
    /// `decode_usk` expects). The account-keyed migration store resolves the account row up front
    /// (`PoolMigrations::for_account` errors on an unknown uuid), so fixtures must register the
    /// account they query — exactly like a real caller, where the uuid always comes from a
    /// previously created account.
    fn create_fixture_account_with_usk(path: &std::path::Path) -> ([u8; 16], Vec<u8>) {
        use secrecy::SecretVec;
        use zcash_client_backend::data_api::AccountBirthday;
        use zcash_client_backend::proto::service::TreeState;
        use zcash_client_sqlite::WalletDb;
        use zcash_client_sqlite::util::SystemClock;
        use zcash_keys::keys::Era;
        use zcash_protocol::consensus::MAIN_NETWORK;

        let mut db = WalletDb::for_path(path, MAIN_NETWORK, SystemClock, OsRng)
            .expect("the wallet database must open");
        let seed = SecretVec::new(vec![7u8; 32]);
        let treestate = TreeState {
            // `to_chain_state` requires a valid 32-byte block hash; everything else can stay
            // at the proto defaults (height 0, empty tree frontiers).
            hash: "00".repeat(32),
            ..TreeState::default()
        };
        let birthday = match AccountBirthday::from_treestate(treestate, None) {
            Ok(birthday) => birthday,
            Err(_) => panic!("the fixture treestate must convert to a birthday"),
        };
        let (account, usk) = db
            .create_account("fixture", &seed, &birthday, None)
            .expect("account creation must succeed");
        (
            account.expose_uuid().into_bytes(),
            usk.to_bytes(Era::Orchard),
        )
    }

    /// [`create_fixture_account_with_usk`] for the fixtures that never sign.
    fn create_fixture_account(path: &std::path::Path) -> [u8; 16] {
        create_fixture_account_with_usk(path).0
    }

    /// A view-only account imported by UFVK (no seed) — the negative-path counterpart to
    /// [`create_fixture_account_with_usk`], which only ever produces seed-derived accounts.
    /// Returns the wallet handle itself (not just the uuid bytes), since the caller exercises
    /// [`account_zip32_derivation`] directly, off the FFI boundary.
    fn create_fixture_view_only_account(path: &std::path::Path) -> (MigrationWallet, AccountUuid) {
        use zcash_client_backend::data_api::{Account, AccountBirthday, AccountPurpose};
        use zcash_client_backend::proto::service::TreeState;
        use zcash_keys::keys::UnifiedSpendingKey;
        use zcash_protocol::consensus::MAIN_NETWORK;

        let path_bytes = path.to_str().unwrap().as_bytes();
        let mut wallet = unsafe {
            crate::wallet_db(
                path_bytes.as_ptr(),
                path_bytes.len(),
                parse_network(NETWORK_ID_MAINNET).expect("mainnet parses"),
            )
        }
        .expect("the wallet database must open");

        // A throwaway seed, only to derive SOME validly-shaped UFVK to import — the wallet is
        // never given this seed (that is the entire point of `import_account_ufvk`), so it has
        // no ZIP 32 path to recover from it later.
        let usk = UnifiedSpendingKey::from_seed(&MAIN_NETWORK, &[9u8; 32], zip32::AccountId::ZERO)
            .expect("valid ZIP 32 seed derivation");
        let ufvk = usk.to_unified_full_viewing_key();
        let treestate = TreeState {
            hash: "00".repeat(32),
            ..TreeState::default()
        };
        let birthday = match AccountBirthday::from_treestate(treestate, None) {
            Ok(birthday) => birthday,
            Err(_) => panic!("the fixture treestate must convert to a birthday"),
        };
        let account = wallet
            .import_account_ufvk(
                "fixture-view-only",
                &ufvk,
                &birthday,
                AccountPurpose::ViewOnly,
                None,
            )
            .expect("ufvk import must succeed");
        let account_id = account.id();
        (wallet, account_id)
    }

    /// `account_zip32_derivation` is this SDK's own addition (annotating Keystone migration
    /// PCZTs with the spend derivation path — see its doc comment), so it has no Android
    /// original to mirror. A UFVK-imported (view-only) account is exactly the case its error
    /// branch guards: the wallet was never given a seed for it, so there is no ZIP 32 path to
    /// annotate with, and Keystone has no way to recognize which of its accounts a spend belongs
    /// to.
    #[test]
    fn account_zip32_derivation_errors_for_a_view_only_account() {
        let path = init_fixture_db("zcashlc_migration_account_zip32_derivation_view_only");
        let (wallet, account) = create_fixture_view_only_account(&path);

        let result = account_zip32_derivation(&wallet, account);
        let err = match result {
            Ok(_) => panic!("a view-only account must have no known ZIP 32 derivation"),
            Err(e) => e,
        };
        assert!(
            err.to_string()
                .contains("Account has no known ZIP 32 seed fingerprint/account index"),
            "unexpected error message: {err}"
        );
        let _ = std::fs::remove_file(&path);
    }

    /// A minimal stored migration: `n_preps` preparation transactions then `n_transfers`
    /// transfers, all ids engine-ordered (preps first), with the given lifecycle states.
    fn test_state(
        status: MigrationStatus,
        prep_states: &[MigrationTxState],
        transfer_states: &[MigrationTxState],
        scheduled: u32,
        expiry: u32,
    ) -> MigrationState {
        let mut transactions = Vec::new();
        for (i, s) in prep_states.iter().enumerate() {
            transactions.push(MigrationTransaction::from_parts(
                MigrationTxId::new(i as u32),
                MigrationTxKind::Preparation { layer: 0, index: i },
                vec![0u8],
                Vec::new(),
                h(scheduled),
                h(expiry),
                None,
                *s,
                None,
            ));
        }
        let offset = prep_states.len() as u32;
        for (i, s) in transfer_states.iter().enumerate() {
            transactions.push(MigrationTransaction::from_parts(
                MigrationTxId::new(offset + i as u32),
                MigrationTxKind::Transfer { crossing: i },
                vec![0u8],
                Vec::new(),
                h(scheduled),
                h(expiry),
                Some(h(scheduled)),
                *s,
                None,
            ));
        }
        let funding: Vec<Zatoshis> = transfer_states.iter().map(|_| zat(100_000_000)).collect();
        MigrationState::from_parts(
            status,
            NoteSplitPlan::from_stored_parts(
                funding.clone(),
                zat(10_000),
                None,
                zat(20_000),
                zat(1_000_000_000),
                zat(999_000_000),
            )
            .unwrap(),
            PreparationPlan::from_parts(Vec::new(), Vec::new()),
            transactions,
        )
    }

    const MINED: MigrationTxState = MigrationTxState::Mined {
        height: BlockHeight::from_u32(100),
    };

    #[test]
    fn expired_rebuild_rejects_old_live_and_terminal_handles_after_same_row_rebuild() {
        let prior = test_state(
            MigrationStatus::Committed,
            &[],
            &[MigrationTxState::Signed],
            50,
            10_000,
        );
        let prior_tx = &prior.transactions()[0];
        let prior_identity = DeliveryArtifactIdentity::Scheduled(
            scheduled_artifact_evidence(&prior, prior_tx.id())
                .expect("prior artifact evidence")
                .identity(),
        );
        let replacement_tx = MigrationTransaction::from_parts(
            prior_tx.id(),
            prior_tx.kind(),
            vec![0x7a],
            prior_tx.depends_on().clone(),
            h(100),
            h(20_000),
            prior_tx.anchor_boundary(),
            MigrationTxState::Signed,
            prior_tx.lock_owner(),
        );
        let current = MigrationState::from_parts(
            prior.status(),
            prior.note_split().clone(),
            prior.preparation().clone(),
            vec![replacement_tx],
        );
        let current_identity = DeliveryArtifactIdentity::Scheduled(
            scheduled_artifact_evidence(&current, prior_tx.id())
                .expect("replacement artifact evidence")
                .identity(),
        );
        assert_ne!(prior_identity, current_identity);

        let live_error = validate_expired_rebuild_generation(
            prior_identity,
            ClaimStatus::Materializing,
            &current,
        )
        .unwrap_err();
        assert!(
            live_error
                .to_string()
                .contains("positively expired unmined")
        );

        let terminal_error = validate_expired_rebuild_generation(
            prior_identity,
            ClaimStatus::ExpiredUnmined,
            &current,
        )
        .unwrap_err();
        assert!(
            terminal_error
                .to_string()
                .contains("archived or replaced transaction attempt")
        );

        assert_eq!(
            validate_expired_rebuild_generation(
                current_identity,
                ClaimStatus::ExpiredUnmined,
                &current,
            )
            .unwrap(),
            match current_identity {
                DeliveryArtifactIdentity::Scheduled(identity) => identity,
                DeliveryArtifactIdentity::Immediate(_) => unreachable!(),
            }
        );
    }

    #[test]
    fn derive_no_migration_is_not_started() {
        assert!(matches!(
            derive_state(None, h(100), true),
            DerivedState::NotStarted
        ));
    }

    #[test]
    fn derive_failed_run_is_not_started() {
        let state = test_state(
            MigrationStatus::Failed,
            &[MigrationTxState::Signed],
            &[MigrationTxState::Signed],
            50,
            10_000,
        );
        assert!(matches!(
            derive_state(Some(&state), h(100), true),
            DerivedState::NotStarted
        ));
    }

    #[test]
    fn derive_complete_is_per_run_complete() {
        let state = test_state(MigrationStatus::Complete, &[MINED], &[MINED], 50, 10_000);
        assert!(matches!(
            derive_state(Some(&state), h(100), true),
            DerivedState::Complete
        ));
    }

    #[test]
    fn derive_mined_run_waits_for_exact_resulting_outputs_to_be_available() {
        let state = test_state(
            MigrationStatus::Complete,
            &[MINED],
            &[MINED, MINED],
            50,
            10_000,
        );
        assert!(matches!(
            derive_state(Some(&state), h(100), false),
            DerivedState::InProgress {
                completed_transfers: 2,
                total_transfers: 2,
                next_transfer_ready_at_height: None,
                is_immediate: false,
            }
        ));
        assert!(matches!(
            derive_state(Some(&state), h(100), true),
            DerivedState::Complete
        ));
    }

    #[test]
    fn derive_unmined_prep_is_split_pending() {
        let state = test_state(
            MigrationStatus::InProgress,
            &[MigrationTxState::Signed],
            &[MigrationTxState::Signed],
            50,
            10_000,
        );
        assert!(matches!(
            derive_state(Some(&state), h(100), true),
            DerivedState::SplitPendingConfirmation
        ));
    }

    #[test]
    fn derive_mined_preps_is_in_progress_with_transfer_counts() {
        let state = test_state(
            MigrationStatus::InProgress,
            &[MINED, MINED],
            &[MINED, MigrationTxState::Signed, MigrationTxState::Signed],
            50,
            10_000,
        );
        match derive_state(Some(&state), h(100), true) {
            DerivedState::InProgress {
                completed_transfers,
                total_transfers,
                next_transfer_ready_at_height,
                is_immediate,
            } => {
                assert_eq!(completed_transfers, 1);
                assert_eq!(total_transfers, 3);
                assert_eq!(next_transfer_ready_at_height, Some(h(50)));
                assert!(
                    !is_immediate,
                    "an engine-tracked run must carry is_immediate = false"
                );
            }
            _ => panic!("expected InProgress"),
        }
    }

    /// F6: `next_transfer_ready_at_height` must be the min `scheduled_height()` over transfers
    /// that are still awaiting broadcast (`AwaitingSignature`/`Signed`/`Proved`), not merely "not
    /// yet mined". A `Broadcast` transfer is already in the mempool — there is nothing left for
    /// the platform to prepare or broadcast for it — so its height must not win even when it is
    /// numerically the smallest. Two transfers at DIFFERENT scheduled heights (the low one
    /// `Broadcast`, the high one `Signed`) pin the exact bug: today's `!= Mined` filter still
    /// counts the `Broadcast` row, reporting its LOWER height instead of the `Signed` row's.
    #[test]
    fn derive_next_ready_height_excludes_already_broadcast_transfers() {
        let transactions = vec![
            // Broadcast (in-mempool) at the LOW height — must be excluded.
            MigrationTransaction::from_parts(
                MigrationTxId::new(0),
                MigrationTxKind::Transfer { crossing: 0 },
                vec![0u8],
                Vec::new(),
                h(50),
                h(10_000),
                Some(h(50)),
                MigrationTxState::Broadcast {
                    txid: TxId::from_bytes([0u8; 32]),
                },
                None,
            ),
            // Signed (still awaiting broadcast) at the HIGHER height — must win.
            MigrationTransaction::from_parts(
                MigrationTxId::new(1),
                MigrationTxKind::Transfer { crossing: 1 },
                vec![0u8],
                Vec::new(),
                h(150),
                h(10_000),
                Some(h(150)),
                MigrationTxState::Signed,
                None,
            ),
        ];
        let state = MigrationState::from_parts(
            MigrationStatus::InProgress,
            NoteSplitPlan::from_stored_parts(
                vec![zat(100_000_000), zat(100_000_000)],
                zat(10_000),
                None,
                zat(20_000),
                zat(1_000_000_000),
                zat(999_000_000),
            )
            .unwrap(),
            PreparationPlan::from_parts(Vec::new(), Vec::new()),
            transactions,
        );
        match derive_state(Some(&state), h(200), true) {
            DerivedState::InProgress {
                next_transfer_ready_at_height,
                ..
            } => {
                assert_eq!(
                    next_transfer_ready_at_height,
                    Some(h(150)),
                    "a Broadcast (in-mempool) transfer must not count as 'next ready' even when \
                     its scheduled height is numerically lower than a not-yet-broadcast \
                     transfer's"
                );
            }
            _ => panic!("expected InProgress"),
        }
    }

    /// F6: once every transfer is `Broadcast` or `Mined`, nothing remains awaiting broadcast, so
    /// there is no "next ready" height at all (the field's `-1`/`None` sentinel).
    #[test]
    fn derive_next_ready_height_is_none_when_all_transfers_are_broadcast_or_mined() {
        let transactions = vec![
            MigrationTransaction::from_parts(
                MigrationTxId::new(0),
                MigrationTxKind::Transfer { crossing: 0 },
                vec![0u8],
                Vec::new(),
                h(50),
                h(10_000),
                Some(h(50)),
                MigrationTxState::Broadcast {
                    txid: TxId::from_bytes([0u8; 32]),
                },
                None,
            ),
            MigrationTransaction::from_parts(
                MigrationTxId::new(1),
                MigrationTxKind::Transfer { crossing: 1 },
                vec![0u8],
                Vec::new(),
                h(150),
                h(10_000),
                Some(h(150)),
                MINED,
                None,
            ),
        ];
        let state = MigrationState::from_parts(
            MigrationStatus::InProgress,
            NoteSplitPlan::from_stored_parts(
                vec![zat(100_000_000), zat(100_000_000)],
                zat(10_000),
                None,
                zat(20_000),
                zat(1_000_000_000),
                zat(999_000_000),
            )
            .unwrap(),
            PreparationPlan::from_parts(Vec::new(), Vec::new()),
            transactions,
        );
        match derive_state(Some(&state), h(200), true) {
            DerivedState::InProgress {
                next_transfer_ready_at_height,
                ..
            } => {
                assert_eq!(next_transfer_ready_at_height, None);
            }
            _ => panic!("expected InProgress"),
        }
    }

    #[test]
    fn derive_expired_unmined_requires_attention() {
        let state = test_state(
            MigrationStatus::InProgress,
            &[MINED],
            &[MigrationTxState::Signed],
            50,
            90,
        );
        assert!(matches!(
            derive_state(Some(&state), h(100), true),
            DerivedState::TransferExpired
        ));
    }

    /// ZIP 203 / engine semantics (`zcash_pool_migration::state::MigrationState::is_expired`):
    /// a transaction may be mined only in a block at or below its `expiry_height`, so it is
    /// expired as soon as the NEXT block (`target = tip + 1`) would exceed that height — i.e.
    /// exactly when `tip == expiry_height`, one block EARLIER than a naive `tip > expiry_height`
    /// check would catch it. Pins the exact boundary the old hand-rolled check in `derive_state`
    /// missed.
    #[test]
    fn derive_expired_at_exact_tip_boundary_requires_attention() {
        let state = test_state(
            MigrationStatus::InProgress,
            &[MINED],
            &[MigrationTxState::Signed],
            50,
            100, // expiry_height == tip
        );
        assert!(
            matches!(
                derive_state(Some(&state), h(100), true),
                DerivedState::TransferExpired
            ),
            "expiry_height == tip can no longer be mined in the next block and must derive \
             TransferExpired, not InProgress"
        );
    }

    /// `expiry_height == 0` is the engine's "never expires" sentinel (see
    /// `MigrationState::is_expired`'s doc); it must not be caught by any expiry check, however
    /// large the tip grows.
    #[test]
    fn derive_never_expires_when_expiry_height_is_zero() {
        let state = test_state(
            MigrationStatus::InProgress,
            &[MINED],
            &[MigrationTxState::Signed],
            50,
            0, // expiry_height == 0: never expires
        );
        assert!(
            matches!(
                derive_state(Some(&state), h(1_000_000), true),
                DerivedState::InProgress { .. }
            ),
            "expiry_height == 0 must never expire, even at a huge tip"
        );
    }

    #[test]
    fn canonical_transfer_amount_is_net_of_fee_buffer() {
        let state = test_state(
            MigrationStatus::InProgress,
            &[MINED],
            &[MigrationTxState::Signed],
            50,
            10_000,
        );
        let tx = state
            .transactions()
            .iter()
            .find(|t| matches!(t.kind(), MigrationTxKind::Transfer { .. }))
            .unwrap();
        // test_state's note split stores zat(100_000_000) CROSSING (net) values against a
        // zat(10_000) fee buffer; `funding_notes()` derives the gross 100_010_000 note and
        // `transfer_amount` nets the buffer back off, landing on the stored crossing value.
        assert_eq!(state.transfer_amount(tx), Some(zat(100_000_000)));
    }

    #[test]
    fn schedule_rows_sort_chronologically_with_prep_offset() {
        let mut rng = StdRng::seed_from_u64(7);
        let schedule = scheduling::schedule(h(1_000), 5, &mut rng);
        // `crossing_values` mirrors a real plan's `note_split().crossing_values()`: the NET
        // turnstile value at each index (F3 — `schedule_rows` reads this directly, it no longer
        // takes a gross funding note plus a fee buffer to subtract).
        let buffer = zat(10_000);
        let crossing_values: Vec<Zatoshis> = (1..=5)
            .map(|i| (zat(i * 100_000_000) - buffer).unwrap())
            .collect();
        let rows = schedule_rows(&crossing_values, &schedule, 3).unwrap();
        assert_eq!(rows.len(), 5);
        // Chronological by broadcast height.
        for pair in rows.windows(2) {
            assert!(pair[0].2 <= pair[1].2);
        }
        // Ids are offset by the preparation count and cover exactly the transfer range.
        let mut ids: Vec<u32> = rows.iter().map(|(id, _, _, _)| u32::from(*id)).collect();
        ids.sort_unstable();
        assert_eq!(ids, vec![3, 4, 5, 6, 7]);
        // Amount pairing survives the sort: each id maps back to the crossing value at the same
        // index — the engine's authoritative NET value, not a re-derived one.
        for (id, amount, _, _) in &rows {
            let crossing = u32::from(*id) - 3;
            assert_eq!(*amount, crossing_values[crossing as usize]);
        }
    }

    #[test]
    fn schedule_rows_net_amounts_are_stable_across_reshuffled_schedules() {
        // Two different draws (different rng seeds -> different shuffled broadcast order) of the
        // same crossing values must still report the same total (and the same multiset) of NET
        // amounts, even though the rows themselves may come back in a different order.
        let crossing_values: Vec<Zatoshis> = (1..=5).map(|i| zat(i * 100_000_000)).collect();
        let expected_total: u64 = crossing_values.iter().map(|z| u64::from(*z)).sum();

        let mut rng_a = StdRng::seed_from_u64(1);
        let schedule_a = scheduling::schedule(h(1_000), 5, &mut rng_a);
        let rows_a = schedule_rows(&crossing_values, &schedule_a, 0).unwrap();

        let mut rng_b = StdRng::seed_from_u64(99);
        let schedule_b = scheduling::schedule(h(1_000), 5, &mut rng_b);
        let rows_b = schedule_rows(&crossing_values, &schedule_b, 0).unwrap();

        let total_a: u64 = rows_a
            .iter()
            .map(|(_, amount, _, _)| u64::from(*amount))
            .sum();
        let total_b: u64 = rows_b
            .iter()
            .map(|(_, amount, _, _)| u64::from(*amount))
            .sum();
        assert_eq!(total_a, expected_total);
        assert_eq!(total_b, expected_total);

        let mut sorted_a: Vec<u64> = rows_a
            .iter()
            .map(|(_, amount, _, _)| u64::from(*amount))
            .collect();
        let mut sorted_b: Vec<u64> = rows_b
            .iter()
            .map(|(_, amount, _, _)| u64::from(*amount))
            .collect();
        sorted_a.sort_unstable();
        sorted_b.sort_unstable();
        assert_eq!(sorted_a, sorted_b);
    }

    #[test]
    fn schedule_rows_reject_length_mismatch() {
        let mut rng = StdRng::seed_from_u64(7);
        let schedule = scheduling::schedule(h(1_000), 3, &mut rng);
        let crossing_values = vec![zat(100)];
        assert!(schedule_rows(&crossing_values, &schedule, 0).is_err());
    }

    /// F3 pin: `schedule_rows`' amount is BOTH the engine's authoritative
    /// `note_split().crossing_values()[crossing]` (trivially — that is now its input) AND the
    /// legacy `funding_notes()[crossing] - note_fee_buffer` computation it replaces, proven equal
    /// for a real `NoteSplitPlan`. Pure refactor: values are identical, so this is green
    /// immediately (no red phase — see F3's task doc).
    #[test]
    fn schedule_rows_amount_matches_engine_crossing_values_and_legacy_subtraction() {
        let mut rng = StdRng::seed_from_u64(11);
        let crossing_values = vec![zat(100_000_000), zat(250_000_000), zat(40_000_000)];
        let note_split = NoteSplitPlan::from_stored_parts(
            crossing_values.clone(),
            zat(10_000),
            None,
            zat(20_000),
            zat(1_000_000_000),
            zat(999_000_000),
        )
        .unwrap();
        let schedule = scheduling::schedule(h(1_000), crossing_values.len(), &mut rng);
        let rows = schedule_rows(note_split.crossing_values(), &schedule, 0).unwrap();
        assert_eq!(rows.len(), crossing_values.len());
        for (id, amount, _, _) in &rows {
            let crossing = u32::from(*id) as usize;
            // Side 1 of the identity: the engine's authoritative crossing value.
            assert_eq!(*amount, note_split.crossing_values()[crossing]);
            // Side 2: the legacy `funding_notes()[crossing] - note_fee_buffer` computation F3
            // replaced — provably the same value, never re-derived at runtime anymore.
            let legacy = (note_split.migration_outputs()[crossing] - note_split.note_fee_buffer())
                .expect("a real plan's funding note is never smaller than its own fee buffer");
            assert_eq!(*amount, legacy);
        }
    }

    // ----- schedule-duration semantics (#1806): from `now` to the LAST scheduled broadcast -----

    /// The headline case: `now` before both broadcast heights, so the wait until the FIRST
    /// transfer fires is included — the old first-to-last span math would have said
    /// `(1_000_432 - 1_000_336) / 48 == 2`; measuring from `now` instead gives `9`.
    #[test]
    fn estimated_duration_hours_is_measured_from_now_to_the_last_broadcast() {
        let heights = [h(1_000_336), h(1_000_432)];
        assert_eq!(
            estimated_duration_hours(heights.into_iter(), h(1_000_000)),
            9
        );
    }

    #[test]
    fn estimated_duration_hours_empty_schedule_is_zero() {
        assert_eq!(
            estimated_duration_hours(std::iter::empty(), h(1_000_000)),
            0
        );
    }

    #[test]
    fn estimated_duration_hours_all_overdue_is_zero() {
        // Every broadcast height is at or behind `now`: the saturating subtraction must clamp to
        // `0` rather than underflowing.
        let heights = [h(900_000), h(950_000), h(1_000_000)];
        assert_eq!(
            estimated_duration_hours(heights.into_iter(), h(1_000_000)),
            0
        );
    }

    #[test]
    fn plan_cache_round_trip_and_clear() {
        let path = PathBuf::from("/tmp/zcashlc-plan-cache-test");
        let account = [3u8; 16];
        assert!(matches!(
            migration_plan_cache::get(&path, account, 1),
            Err(migration_plan_cache::PlanLookupError::Missing),
        ));
        // A real plan is unconstructible here; the cache API is exercised end-to-end by the
        // welding offline tests. This pins the miss behavior only.
        migration_plan_cache::clear(&path, account);
        assert!(matches!(
            migration_plan_cache::get(&path, account, 0),
            Err(migration_plan_cache::PlanLookupError::Missing),
        ));
    }

    #[test]
    fn residual_unlock_preserves_migration_and_foreign_locks() {
        fn nullifier(low_byte: u8) -> orchard::note::Nullifier {
            let mut bytes = [0; 32];
            bytes[0] = low_byte;
            Option::from(orchard::note::Nullifier::from_bytes(&bytes))
                .expect("small canonical field element is a valid Orchard nullifier")
        }

        let account = AccountUuid::from_uuid(uuid::Uuid::from_bytes([0x11; 16]));
        let residual_owner = residual_lock_owner(account);
        let migration_owner = LockOwner::new([0x22; 32]);
        let foreign_owner = LockOwner::new([0x33; 32]);
        let residual_output = OutputRef::new(
            TxId::from_bytes([0x44; 32]),
            PoolType::Shielded(ShieldedPool::Orchard),
            0,
        );
        let migration_output = OutputRef::new(
            TxId::from_bytes([0x55; 32]),
            PoolType::Shielded(ShieldedPool::Orchard),
            1,
        );
        let foreign_output = OutputRef::new(
            TxId::from_bytes([0x66; 32]),
            PoolType::Shielded(ShieldedPool::Orchard),
            2,
        );
        let locks = vec![
            ActiveOrchardLock::new(residual_output, Some(nullifier(0x71)), residual_owner),
            ActiveOrchardLock::new(migration_output, Some(nullifier(0x72)), migration_owner),
            ActiveOrchardLock::new(foreign_output, Some(nullifier(0x73)), foreign_owner),
        ];
        let mut held = vec![
            (residual_output, residual_owner),
            (migration_output, migration_owner),
            (foreign_output, foreign_owner),
        ];

        let cleared = unlock_owned_active_locks(
            &locks,
            residual_owner,
            |output, requested_owner| -> Result<bool, ()> {
                let Some(index) = held.iter().position(|(held_output, held_owner)| {
                    held_output == output && *held_owner == requested_owner
                }) else {
                    return Ok(false);
                };
                held.remove(index);
                Ok(true)
            },
        )
        .unwrap();

        assert_eq!(cleared, 1);
        assert_eq!(
            held,
            vec![
                (migration_output, migration_owner),
                (foreign_output, foreign_owner)
            ],
            "owner-scoped residual unlock must leave migration and foreign locks untouched"
        );
    }

    #[test]
    fn legacy_migration_pczt_extraction_fails_before_touching_caller_data_or_storage() {
        // This symbol predates typed delivery ownership, so it cannot safely authorize a migration
        // reservation. It remains ABI-compatible but must never parse caller bytes, open the
        // wallet, or expose consensus bytes. The token-bound materialization API is the sole path.
        let source = include_str!("migration.rs");
        let body = source
            .split_once("pub unsafe extern \"C\" fn zcashlc_migration_extract_broadcast_tx(")
            .expect("migration extraction FFI must exist")
            .1
            .split_once("\n#[unsafe(no_mangle)]")
            .map(|(body, _)| body)
            .expect("migration extraction FFI must be isolatable");
        assert!(body.contains("legacy migration PCZT extraction is unauthorized"));
        for forbidden in ["open(", "slice_or_empty(", "Pczt::parse", "extract_tx("] {
            assert!(
                !body.contains(forbidden),
                "legacy extraction must not invoke {forbidden}"
            );
        }
    }

    #[test]
    fn every_legacy_delivery_mutator_is_fail_closed_before_data_or_storage() {
        let source = include_str!("migration.rs");
        for name in [
            "zcashlc_migration_sign_note_split",
            "zcashlc_migration_next_due_transfer",
            "zcashlc_migration_extract_broadcast_tx",
            "zcashlc_migration_record_transfer_result",
            "zcashlc_migration_restart_step",
            "zcashlc_migration_refresh_stale_transfers",
            "zcashlc_migration_create_unsigned_note_split_pczts",
            "zcashlc_migration_store_signed_note_split_pczts",
            "zcashlc_migration_create_unsigned_transfer_pczts",
            "zcashlc_migration_store_signed_schedule_pczts",
        ] {
            let marker = format!("fn {name}(");
            let body = source
                .split_once(&marker)
                .unwrap_or_else(|| panic!("{name} must remain exported"))
                .1
                .split_once("\n}\n\n")
                .map(|(body, _)| body)
                .unwrap_or_else(|| panic!("{name} must be isolatable"));
            assert!(
                body.contains("legacy_delivery_api_disabled(")
                    || body.contains("legacy migration PCZT extraction is unauthorized"),
                "{name} must fail closed"
            );
            for forbidden in [
                "open(",
                "slice_or_empty(",
                "Pczt::parse",
                "replace_migration(",
                "stage_materialized_transaction(",
            ] {
                assert!(
                    !body.contains(forbidden),
                    "{name} must not invoke {forbidden}"
                );
            }
        }
    }

    #[test]
    fn scheduled_proof_is_one_atomic_canonical_and_exact_byte_transition() {
        let source = include_str!("migration.rs");
        let body = source
            .split_once("fn zcashlc_migration_prove_claim_v1(")
            .expect("proof FFI must exist")
            .1
            .split_once("\n#[unsafe(no_mangle)]")
            .map(|(body, _)| body)
            .expect("proof FFI must be isolatable");
        assert!(body.contains("advance_canonical_materialization(transition)"));
        assert!(!body.contains("stage_materialized_transaction("));

        let legacy_stage = source
            .split_once("fn zcashlc_migration_stage_materialized_transaction_v1(")
            .expect("legacy shared staging symbol must remain ABI-compatible")
            .1
            .split_once("\n#[unsafe(no_mangle)]")
            .map(|(body, _)| body)
            .expect("legacy stage FFI must be isolatable");
        assert!(legacy_stage.contains("legacy_delivery_api_disabled("));
        for forbidden in [
            "open(",
            "slice_or_empty(",
            "Transaction::read",
            "stage_immediate_transaction(",
        ] {
            assert!(
                !legacy_stage.contains(forbidden),
                "retired raw staging must not invoke {forbidden}"
            );
        }
    }

    #[test]
    fn immediate_materialization_is_claim_consuming_and_atomic() {
        let source = include_str!("migration.rs");
        let sdk = source
            .split_once("fn zcashlc_migration_materialize_immediate_sdk_v1(")
            .expect("SDK immediate materializer must exist")
            .1
            .split_once("\n#[unsafe(no_mangle)]")
            .map(|(body, _)| body)
            .expect("SDK immediate materializer must be isolatable");
        for required in [
            "require_claim(",
            "ImmediateProposal::decode(",
            "transactionally(",
            "create_proposed_transactions",
            "get_transaction(",
            "exact_immediate_transaction(",
            "stage_immediate_transaction(",
        ] {
            assert!(
                sdk.contains(required),
                "SDK materializer must invoke {required}"
            );
        }
        for forbidden in [
            "transaction_ptr",
            "proposal_ptr",
            "destination_output_index",
            "amount:",
        ] {
            assert!(
                !sdk.contains(forbidden),
                "SDK materializer must not accept host authority via {forbidden}"
            );
        }

        let external_prepare = source
            .split_once("fn zcashlc_migration_prepare_immediate_external_signing_v1(")
            .expect("external immediate preparation must exist")
            .1
            .split_once("\n#[unsafe(no_mangle)]")
            .map(|(body, _)| body)
            .expect("external preparation must be isolatable");
        for required in [
            "require_claim(",
            "transactionally(",
            "create_pczt_from_proposal",
            "prove_immediate_pczt(",
            "stage_immediate_external_signing_pczt(",
        ] {
            assert!(
                external_prepare.contains(required),
                "external preparation must invoke {required}"
            );
        }
        let external_prepare_signature = external_prepare
            .split_once('{')
            .map(|(signature, _)| signature)
            .expect("external preparation signature must be isolatable");
        assert!(!external_prepare_signature.contains("pczt_ptr"));

        let external_finalize = source
            .split_once("fn zcashlc_migration_finalize_immediate_external_signing_v1(")
            .expect("external immediate finalizer must exist")
            .1
            .split_once("\n#[unsafe(no_mangle)]")
            .map(|(body, _)| body)
            .expect("external finalizer must be isolatable");
        for required in [
            "signed_pczt",
            "transactionally(",
            "extract_and_store_transaction_from_pczt",
            "get_transaction(",
            "exact_immediate_transaction(",
            "stage_immediate_transaction(",
        ] {
            assert!(
                external_finalize.contains(required),
                "external finalizer must invoke {required}"
            );
        }
        for forbidden in ["pczt_ptr", "transaction_ptr", "destination_output_index"] {
            assert!(
                !external_finalize.contains(forbidden),
                "external finalizer must not accept host authority via {forbidden}"
            );
        }

        let generic_external_stage = source
            .split_once("fn zcashlc_migration_stage_external_signing_pczt_v1(")
            .expect("generic external staging ABI must exist")
            .1
            .split_once("\n#[unsafe(no_mangle)]")
            .map(|(body, _)| body)
            .expect("generic external staging must be isolatable");
        assert!(generic_external_stage.contains("caller-supplied PCZT bytes are not authorized"));
    }

    #[test]
    fn failed_immediate_reacquisition_preserves_the_exact_artifact_and_current_gross_authority() {
        let source = include_str!("migration.rs");
        let body = source
            .split_once("fn zcashlc_migration_reacquire_failed_immediate_materialization_v1(")
            .expect("failed immediate materialization reacquisition FFI must exist")
            .1
            .split_once("\n#[unsafe(no_mangle)]")
            .map(|(body, _)| body)
            .expect("failed immediate materialization reacquisition FFI must be isolatable");
        for required in [
            "require_claim(",
            "signer_ownership(signer_tag)",
            "Zatoshis::from_nonnegative_i64(maximum_gross_amount)",
            "ClaimStatus::MaterializationFailed",
            "handle.claim_kind.is_some()",
            "handle.external_signing_pczt.is_some()",
            "handle.signed_pczt.is_some()",
            "handle.exact_transaction.is_some()",
            "handle.txid.is_some()",
            "reacquire_failed_immediate_materialization(",
        ] {
            assert!(
                body.contains(required),
                "failed immediate reacquisition must invoke {required}"
            );
        }
        for forbidden in [
            "reserve_immediate_delivery(",
            "ImmediateMigrationIntent::new(",
            "propose_send_max_transfer_unlocked(",
            "ImmediateProposal::decode(",
        ] {
            assert!(
                !body.contains(forbidden),
                "failed immediate reacquisition must never invoke {forbidden}"
            );
        }
    }

    #[test]
    fn successor_rollover_uses_only_opaque_predecessor_and_typed_atomic_store_seam() {
        let source = include_str!("migration.rs");
        let helper = source
            .split_once("fn rollover_scheduled_successor(")
            .expect("rollover helper must exist")
            .1
            .split_once("\n/// Map a commit error")
            .map(|(body, _)| body)
            .expect("rollover helper must be isolatable");
        assert!(helper.contains("SuccessorCandidateBackend::new("));
        assert!(helper.contains("ReservationRollover::replace_terminal("));
        assert!(helper.contains("MigrationRuntimeStore::rollover_source_reservations("));
        assert!(!helper.contains("replace_migration("));
        assert!(
            helper.find("rollover_source_reservations(")
                < helper.find("migration_plan_cache::clear(")
        );

        for name in [
            "zcashlc_migration_rollover_internal_schedule_v1",
            "zcashlc_migration_rollover_external_schedule_v1",
        ] {
            let marker = format!("fn {name}(");
            let body = source
                .split_once(&marker)
                .unwrap_or_else(|| panic!("{name} must exist"))
                .1
                .split_once("\n#[unsafe(no_mangle)]")
                .map(|(body, _)| body)
                .unwrap_or_else(|| panic!("{name} must be isolatable"));
            assert!(body.contains("require_scheduled_run"));
            assert!(body.contains("proposal_handle: u64"));
            assert!(body.contains("migration_plan_cache::get("));
            assert!(body.contains("rollover_scheduled_successor"));
            for forbidden in [
                "ids: *const",
                "amounts: *const",
                "estimated_duration_hours",
                "validate_schedule_echo",
                "DeliveryRevision",
                "MigrationRunIdentity",
                "SourceReservationOwner",
                "PolicyFingerprint",
                "MigrationState",
                "ClaimToken",
            ] {
                assert!(
                    !body.contains(forbidden),
                    "{name} must not accept caller-provided {forbidden}"
                );
            }
        }
    }

    /// On a freshly initialized wallet database with a chain tip but no completed migration,
    /// residual locking is rejected even though no spendable notes exist: the residual owner may
    /// be acquired only after the same strict `Complete` projection exposed to Swift. Unlocking
    /// remains an idempotent no-op (`0`).
    #[test]
    fn migration_lock_residual_requires_strict_complete_on_fresh_db() {
        let path = std::env::temp_dir().join(format!(
            "zcashlc_migration_lock_residual_{}.sqlite",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        let path_bytes = path.to_str().unwrap().as_bytes();
        let init = unsafe {
            crate::zcashlc_init_data_database(
                path_bytes.as_ptr(),
                path_bytes.len(),
                std::ptr::null(),
                0,
                NETWORK_ID_MAINNET,
            )
        };
        assert!(init >= 0, "wallet-db initialization must succeed");
        assert!(
            unsafe {
                crate::zcashlc_update_chain_tip(
                    path_bytes.as_ptr(),
                    path_bytes.len(),
                    3_000_000,
                    NETWORK_ID_MAINNET,
                )
            },
            "chain-tip update must succeed"
        );
        let account = [7u8; 16];
        let locked = unsafe {
            zcashlc_migration_lock_residual(
                path_bytes.as_ptr(),
                path_bytes.len(),
                account.as_ptr(),
                NETWORK_ID_MAINNET,
            )
        };
        assert_eq!(
            locked, -1,
            "an engine-less fresh wallet is not strict migration Complete"
        );
        let unlocked = unsafe {
            zcashlc_migration_unlock_residual(
                path_bytes.as_ptr(),
                path_bytes.len(),
                account.as_ptr(),
                NETWORK_ID_MAINNET,
            )
        };
        assert_eq!(unlocked, 0, "the rejected lock attempt must leave no lock");
        let _ = std::fs::remove_file(&path);
    }

    /// On a freshly initialized wallet database with a chain tip but no spendable notes, the
    /// run-count estimate is the ZERO-RUN estimate (`runs_len == 0`, `final_residual == 0`) —
    /// a legitimate answer marshaled as a non-null pointer, not an error — and the free
    /// function round-trips it (the empty runs array uses the null-for-empty `ptr_from_vec`
    /// convention, which `free_ptr_from_vec` handles).
    #[test]
    fn migration_estimate_runs_on_fresh_db_is_zero_runs() {
        let path = std::env::temp_dir().join(format!(
            "zcashlc_migration_estimate_runs_{}.sqlite",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        let path_bytes = path.to_str().unwrap().as_bytes();
        let init = unsafe {
            crate::zcashlc_init_data_database(
                path_bytes.as_ptr(),
                path_bytes.len(),
                std::ptr::null(),
                0,
                NETWORK_ID_MAINNET,
            )
        };
        assert!(init >= 0, "wallet-db initialization must succeed");
        assert!(
            unsafe {
                crate::zcashlc_update_chain_tip(
                    path_bytes.as_ptr(),
                    path_bytes.len(),
                    3_000_000,
                    NETWORK_ID_MAINNET,
                )
            },
            "chain-tip update must succeed"
        );
        let account = create_fixture_account(&path);
        let ptr = unsafe {
            zcashlc_migration_estimate_runs(
                path_bytes.as_ptr(),
                path_bytes.len(),
                account.as_ptr(),
                NETWORK_ID_MAINNET,
            )
        };
        assert!(
            !ptr.is_null(),
            "estimate pointer must be non-null on success"
        );
        let est = unsafe { &*ptr };
        assert_eq!(est.runs_len, 0, "nothing to migrate estimates zero runs");
        assert_eq!(est.final_residual, 0, "a zero balance leaves no residual");
        unsafe { zcashlc_free_migration_run_estimate(ptr) };
        let _ = std::fs::remove_file(&path);
    }

    /// Both locking entry points report `-1` (with the last-error channel set) on a wallet
    /// database that was never initialized: the error-path smoke for the `i64` sentinel.
    #[test]
    fn migration_lock_and_unlock_residual_on_uninitialized_db_are_errors() {
        let path = std::env::temp_dir().join(format!(
            "zcashlc_migration_lock_residual_uninit_{}.sqlite",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        let path_bytes = path.to_str().unwrap().as_bytes();
        let account = [7u8; 16];
        let locked = unsafe {
            zcashlc_migration_lock_residual(
                path_bytes.as_ptr(),
                path_bytes.len(),
                account.as_ptr(),
                NETWORK_ID_MAINNET,
            )
        };
        assert_eq!(locked, -1, "an uninitialized database must error");
        let unlocked = unsafe {
            zcashlc_migration_unlock_residual(
                path_bytes.as_ptr(),
                path_bytes.len(),
                account.as_ptr(),
                NETWORK_ID_MAINNET,
            )
        };
        assert_eq!(unlocked, -1, "an uninitialized database must error");
        let _ = std::fs::remove_file(&path);
    }

    /// A freshly initialized wallet database has no stored migration, so its state marshals as
    /// `NotStarted`. The store tables come from the wallet schema migrations (they are no longer
    /// created by `open`), so the fixture runs `zcashlc_init_data_database` first, exactly like a
    /// real caller — and creates the account it queries, since the account-keyed store resolves
    /// the account row up front. This exercises `open` (path decode, `parse_network`, store read)
    /// end to end over the FFI.
    #[test]
    fn migration_state_on_fresh_db_is_not_started() {
        let path = std::env::temp_dir().join(format!(
            "zcashlc_migration_state_{}.sqlite",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        let path_bytes = path.to_str().unwrap().as_bytes();
        let init = unsafe {
            crate::zcashlc_init_data_database(
                path_bytes.as_ptr(),
                path_bytes.len(),
                std::ptr::null(),
                0,
                NETWORK_ID_MAINNET,
            )
        };
        assert!(init >= 0, "wallet-db initialization must succeed");
        let account = create_fixture_account(&path);
        let ptr = unsafe {
            zcashlc_migration_state(
                path_bytes.as_ptr(),
                path_bytes.len(),
                account.as_ptr(),
                NETWORK_ID_MAINNET,
            )
        };
        assert!(!ptr.is_null(), "state pointer must be non-null on success");
        assert!(
            matches!(unsafe { &*ptr }, FfiMigrationState::NotStarted),
            "a fresh database must report NotStarted"
        );
        unsafe { zcashlc_free_migration_state(ptr) };
        let _ = std::fs::remove_file(&path);
    }

    // ----- refresh stale transfers (rebuild-on-expiry lanes over the FFI) -----

    use zcash_client_sqlite::pool_migration::orchard_ironwood::PoolMigrations;

    /// Initializes a wallet database at a unique temp path (removing any leftover), returning the
    /// path. The refresh fixtures all start here, mirroring a real caller's `init_data_db`.
    fn init_fixture_db(prefix: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("{prefix}_{}.sqlite", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let path_bytes = path.to_str().unwrap().as_bytes();
        let init = unsafe {
            crate::zcashlc_init_data_database(
                path_bytes.as_ptr(),
                path_bytes.len(),
                std::ptr::null(),
                0,
                NETWORK_ID_MAINNET,
            )
        };
        assert!(init >= 0, "wallet-db initialization must succeed");
        path
    }

    /// Stores `state` for `account` through the same account-keyed store the FFI reads — the
    /// fixture-side counterpart of the entry points' `replace_migration` write path.
    fn store_fixture_state(path: &std::path::Path, account: &[u8; 16], state: &MigrationState) {
        let mut conn = Connection::open(path).expect("the fixture store connection opens");
        let account = account_uuid_from_bytes(account.as_ptr()).expect("16 uuid bytes");
        let mut store = PoolMigrations::for_account(&mut conn, account)
            .expect("the account-keyed store resolves the fixture account");
        store
            .replace_migration(state)
            .expect("the fixture state stores");
    }

    /// Persists one live transfer through the same source-bound atomic start seam production uses.
    /// The PCZT spends a real fixture-owned Orchard note whose nullifier is stored in the wallet,
    /// every canonical row carries one owner, and the exact source is locked and reserved together
    /// with the state. This intentionally refuses the old shortcut of writing an unowned live row
    /// through `replace_migration`, which delivery-enabled stores reject.
    fn store_source_bound_transfer_fixture(
        path: &std::path::Path,
        account: &[u8; 16],
        transaction_state: MigrationTxState,
        scheduled: u32,
        expiry: u32,
        marker: u8,
    ) -> MigrationState {
        use orchard::keys::{FullViewingKey, Scope, SpendingKey};
        use orchard::note::{Note, NoteVersion, RandomSeed, Rho};
        use orchard::value::NoteValue;
        use rand::RngCore;
        use zcash_pool_migration::build::build_transfer_pczt;
        use zcash_pool_migration::note_splitting::RESIDUAL_MIGRATION_MIN;
        use zcash_pool_migration::wallet::PoolMigrationLockStore;
        use zcash_primitives::transaction::fees::zip317::MARGINAL_FEE;
        use zcash_protocol::consensus::MAIN_NETWORK;

        fn draw_bytes(rng: &mut StdRng) -> [u8; 32] {
            let mut bytes = [0u8; 32];
            rng.fill_bytes(&mut bytes);
            bytes
        }

        let mut rng = StdRng::seed_from_u64(u64::from(marker));
        let spending_key = loop {
            if let Some(key) = SpendingKey::from_bytes(draw_bytes(&mut rng)).into_option() {
                break key;
            }
        };
        let fvk = FullViewingKey::from(&spending_key);
        let recipient = fvk.address_at(0u32, Scope::External);
        let rho = loop {
            if let Some(rho) = Rho::from_bytes(&draw_bytes(&mut rng)).into_option() {
                break rho;
            }
        };
        let rseed = loop {
            if let Some(rseed) = RandomSeed::from_bytes(draw_bytes(&mut rng), &rho).into_option() {
                break rseed;
            }
        };
        let crossing = RESIDUAL_MIGRATION_MIN;
        let note_fee_buffer = Zatoshis::from_u64(3 * MARGINAL_FEE.into_u64()).unwrap();
        let source_value = u64::from(crossing) + u64::from(note_fee_buffer);
        let note = Note::from_parts(
            recipient,
            NoteValue::from_raw(source_value),
            rho,
            rseed,
            NoteVersion::V2,
        )
        .into_option()
        .expect("fixture note parts are valid");
        let nullifier = note.nullifier(&fvk);
        let pczt = build_transfer_pczt(
            &MAIN_NETWORK,
            3_500_000,
            expiry,
            &fvk,
            note,
            crossing,
            StdRng::seed_from_u64(u64::from(marker) ^ 0x5a5a),
        )
        .expect("build source-bound transfer PCZT")
        .serialize()
        .expect("serialize source-bound transfer PCZT");

        let owner = LockOwner::new([marker.wrapping_add(0x40); 32]);
        let txid = TxId::from_bytes([marker; 32]);
        let mut conn = Connection::open(path).expect("the fixture store connection opens");
        let account_uuid = account_uuid_from_bytes(account.as_ptr()).expect("16 uuid bytes");
        let account_id: i64 = conn
            .query_row(
                "SELECT id FROM accounts WHERE uuid = ?",
                rusqlite::params![account_uuid.expose_uuid()],
                |row| row.get(0),
            )
            .expect("fixture account row exists");
        conn.execute(
            "INSERT INTO transactions (txid, min_observed_height) VALUES (?1, 0)",
            rusqlite::params![txid.as_ref()],
        )
        .expect("insert fixture source transaction");
        let transaction_id = conn.last_insert_rowid();
        conn.execute(
            "INSERT INTO orchard_received_notes (
                 transaction_id, action_index, account_id, diversifier, value, rho, rseed, nf,
                 is_change, recipient_key_scope, note_version
             ) VALUES (?1, 0, ?2, ?3, ?4, ?5, ?6, ?7, 0, 0, 2)",
            rusqlite::params![
                transaction_id,
                account_id,
                recipient.diversifier().as_array(),
                source_value,
                rho.to_bytes(),
                rseed.as_bytes(),
                nullifier.to_bytes(),
            ],
        )
        .expect("insert fixture-owned Orchard source");
        let output = OutputRef::new(txid, PoolType::Shielded(ShieldedPool::Orchard), 0);
        let state = MigrationState::from_parts(
            MigrationStatus::Committed,
            NoteSplitPlan::from_stored_parts(
                vec![crossing],
                note_fee_buffer,
                None,
                Zatoshis::ZERO,
                Zatoshis::from_u64(source_value).unwrap(),
                crossing,
            )
            .expect("one-crossing fixture plan is valid"),
            PreparationPlan::from_parts(Vec::new(), Vec::new()),
            vec![MigrationTransaction::from_parts(
                MigrationTxId::new(0),
                MigrationTxKind::Transfer { crossing: 0 },
                pczt,
                Vec::new(),
                h(scheduled),
                h(expiry),
                Some(h(scheduled.saturating_sub(1))),
                transaction_state,
                Some(*owner.as_bytes()),
            )],
        );
        let mut store =
            PoolMigrations::for_account_with_parameters(&mut conn, account_uuid, &MAIN_NETWORK)
                .expect("the account-keyed delivery store resolves the fixture account");
        store
            .lock_outputs_and_replace_migration(
                None,
                &state,
                &[output],
                owner,
                BlockHeight::from_u32(u32::MAX),
            )
            .expect("the source-bound fixture delivery starts atomically");
        state
    }

    /// Reads the account-scoped migration row through the same typed store used by the FFI.
    fn read_fixture_state(path: &std::path::Path, account: &[u8; 16]) -> MigrationState {
        let mut conn = Connection::open(path).expect("the verification connection opens");
        let account = account_uuid_from_bytes(account.as_ptr()).expect("16 uuid bytes");
        let store = PoolMigrations::for_account(&mut conn, account)
            .expect("the account-keyed store resolves the fixture account");
        store
            .get_migration()
            .expect("the store reads")
            .expect("a migration is stored")
    }

    /// The old bulk refresh entry point no longer performs any database-dependent special cases;
    /// even null caller pointers are safe because it fails closed before reading them.
    #[test]
    fn legacy_refresh_stale_transfers_is_disabled_before_reading_arguments() {
        let schedule_ptr = unsafe {
            zcashlc_migration_refresh_stale_transfers(
                std::ptr::null(),
                usize::MAX,
                std::ptr::null(),
                u32::MAX,
                std::ptr::null(),
                usize::MAX,
            )
        };
        assert!(schedule_ptr.is_null(), "the disabled API must fail closed");
        let message = ffi_helpers::error_handling::error_message()
            .expect("the disabled API must set the last-error channel");
        assert!(
            message.contains("zcashlc_migration_refresh_stale_transfers")
                && message.contains("is disabled"),
            "the error must identify the disabled compatibility symbol, got: {message}"
        );
    }

    #[test]
    #[allow(deprecated)]
    fn legacy_immediate_reservation_ffi_fails_closed_before_database_access() {
        let claim = unsafe {
            zcashlc_migration_reserve_immediate_v1(
                std::ptr::null(),
                usize::MAX,
                std::ptr::null(),
                u32::MAX,
                u8::MAX,
                u8::MAX,
                std::ptr::null(),
            )
        };
        assert!(claim.is_null());
        let message = ffi_helpers::error_handling::error_message()
            .expect("the legacy reservation ABI must set the last-error channel");
        assert!(
            message.contains("zcashlc_migration_reserve_immediate_v1")
                && message.contains("is disabled")
                && message.contains("zcashlc_migration_reserve_immediate_v2"),
            "the error must identify the disabled legacy ABI and its replacement, got: {message}"
        );
    }

    #[test]
    #[allow(deprecated)]
    fn immediate_reservation_ffi_signatures_remain_versioned() {
        let _: unsafe extern "C" fn(
            *const u8,
            usize,
            *const u8,
            u32,
            u8,
            u8,
            *const c_char,
        ) -> *mut FfiMigrationClaimHandle = zcashlc_migration_reserve_immediate_v1;
        let _: unsafe extern "C" fn(
            *const u8,
            usize,
            *const u8,
            u32,
            u8,
            i64,
            u8,
            *const c_char,
        ) -> *mut FfiMigrationClaimHandle = zcashlc_migration_reserve_immediate_v2;
    }

    #[test]
    fn keystone_claim_owned_ffi_signature_rejects_unbound_input_before_database_access() {
        let _: unsafe extern "C" fn(
            *const u8,
            usize,
            *const u8,
            u32,
            *const u8,
            usize,
            *const *const FfiMigrationClaimHandle,
            usize,
            usize,
        ) -> *mut FfiKeystoneQrParts = zcashlc_migration_keystone_build_sign_batch_qr_parts_v2;

        let result = unsafe {
            zcashlc_migration_keystone_build_sign_batch_qr_parts_v2(
                std::ptr::null(),
                usize::MAX,
                std::ptr::null(),
                u32::MAX,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                400,
            )
        };
        assert!(result.is_null());
        let message = ffi_helpers::error_handling::error_message()
            .expect("an empty request id must set the last-error channel");
        assert!(
            message.contains("Keystone batch request id is empty"),
            "request binding must fail before database access, got: {message}"
        );

        let request_id = [7u8; 16];
        let result = unsafe {
            zcashlc_migration_keystone_build_sign_batch_qr_parts_v2(
                std::ptr::null(),
                usize::MAX,
                std::ptr::null(),
                u32::MAX,
                request_id.as_ptr(),
                request_id.len(),
                std::ptr::null(),
                0,
                400,
            )
        };
        assert!(result.is_null());
        let message = ffi_helpers::error_handling::error_message()
            .expect("an empty claim set must set the last-error channel");
        assert!(
            message.contains("Keystone batch contains no migration claims"),
            "claim ownership must fail before database access, got: {message}"
        );
    }

    #[test]
    fn immediate_ffi_rejects_an_invalid_gross_ceiling_before_database_access() {
        let endpoint = std::ffi::CString::new("https://lightwalletd.example:9067").unwrap();
        let claim = unsafe {
            zcashlc_migration_reserve_immediate_v2(
                std::ptr::null(),
                usize::MAX,
                std::ptr::null(),
                u32::MAX,
                0,
                -1,
                0,
                endpoint.as_ptr(),
            )
        };
        assert!(claim.is_null());
        let message = ffi_helpers::error_handling::error_message()
            .expect("an invalid maximum must set the last-error channel");
        assert!(
            message.contains("maximum immediate migration gross amount is invalid"),
            "gross authorization must be validated before database access, got: {message}"
        );

        let claim = unsafe {
            zcashlc_migration_reacquire_failed_immediate_materialization_v1(
                std::ptr::null(),
                usize::MAX,
                std::ptr::null(),
                u32::MAX,
                std::ptr::null(),
                0,
                -1,
            )
        };
        assert!(claim.is_null());
        let message = ffi_helpers::error_handling::error_message()
            .expect("an invalid reacquisition maximum must set the last-error channel");
        assert!(
            message.contains("maximum immediate migration gross amount is invalid"),
            "reacquisition gross authorization must be validated before database access, got: {message}"
        );
    }

    #[test]
    fn public_tls_over_tor_is_a_distinct_validated_policy_transport() {
        let network = parse_network(NETWORK_ID_MAINNET).expect("mainnet parameters");
        let policy = policy_from_transport_intent(&network, 3, "https://lightwalletd.example:9067")
            .expect("a canonical public TLS endpoint is valid over Tor");
        assert!(matches!(
            policy.request().transport(),
            SubmissionTransport::TorProxyTls(_)
        ));
        assert!(
            policy_from_transport_intent(&network, 3, "http://lightwalletd.example:9067").is_err()
        );
        assert!(policy_from_transport_intent(&network, 3, "https://service.onion:9067").is_err());
    }

    /// A rebuild that cannot recover the exact funding note names only the current typed recovery
    /// sequence. The retired unscoped restart symbol must never return as actionable guidance.
    #[test]
    fn funding_note_unavailable_names_typed_abandonment_and_successor_rollover() {
        let message = map_rebuild_err(
            engine::RebuildError::<anyhow::Error>::FundingNoteUnavailable(zat(100_000_000)),
        )
        .to_string();
        assert!(
            message.contains("funding note"),
            "the error must tell the caller the funding note is gone, got: {message}"
        );
        assert!(
            message.contains("zcashlc_migration_begin_abandonment_v1"),
            "the error must name the first typed abandonment phase, got: {message}"
        );
        assert!(
            message.contains("zcashlc_migration_finish_abandonment_v1"),
            "the error must name the second typed abandonment phase, got: {message}"
        );
        assert!(
            message.contains("typed successor-rollover API"),
            "the error must direct replanning through typed rollover, got: {message}"
        );
        assert!(
            !message.contains("restartCurrentMigrationStep")
                && !message.contains("zcashlc_migration_restart_step"),
            "the disabled restart API must not be recommended, got: {message}"
        );
    }

    // ----- prove dispatch (kind routing + transient/hard error mapping) -----

    use zcash_pool_migration::engine::MigrationProver;
    use zcash_pool_migration::wallet::WalletProveError;
    use zcash_protocol::consensus::BranchId;

    /// The prover error type the dispatch tests fail with: the REAL upstream
    /// [`WalletProveError`] (so the classification under test is the production one), with unit
    /// tree/note/chain-state error parameters.
    type TestProveError = WalletProveError<(), (), ()>;

    /// Which prover method the dispatch routed a transaction to, and with which anchor.
    #[derive(Debug, PartialEq, Eq)]
    enum ProveCall {
        Transfer(BlockHeight),
        Preparation(BlockHeight),
    }

    /// A recording test prover: captures every call and "proves" by returning the PCZT unchanged.
    struct RecordingProver {
        calls: Vec<ProveCall>,
    }

    impl MigrationProver for RecordingProver {
        type Error = TestProveError;

        fn prove_transfer(
            &mut self,
            pczt: pczt::Pczt,
            anchor_boundary: BlockHeight,
        ) -> Result<pczt::Pczt, Self::Error> {
            self.calls.push(ProveCall::Transfer(anchor_boundary));
            Ok(pczt)
        }

        fn prove_preparation(
            &mut self,
            pczt: pczt::Pczt,
            anchor: BlockHeight,
        ) -> Result<pczt::Pczt, Self::Error> {
            self.calls.push(ProveCall::Preparation(anchor));
            Ok(pczt)
        }
    }

    /// A test prover that fails its one expected call with the configured error.
    struct FailingProver {
        error: Option<TestProveError>,
    }

    impl MigrationProver for FailingProver {
        type Error = TestProveError;

        fn prove_transfer(
            &mut self,
            _pczt: pczt::Pczt,
            _anchor_boundary: BlockHeight,
        ) -> Result<pczt::Pczt, Self::Error> {
            Err(self.error.take().expect("the prover is consulted once"))
        }

        fn prove_preparation(
            &mut self,
            _pczt: pczt::Pczt,
            _anchor: BlockHeight,
        ) -> Result<pczt::Pczt, Self::Error> {
            Err(self.error.take().expect("the prover is consulted once"))
        }
    }

    /// Minimal valid PCZT bytes (an empty NU6.3 v6 PCZT). The engine's prove path parses the
    /// stored PCZT before consulting the prover, so prove fixtures need bytes that parse — unlike
    /// the state-derivation fixtures' `vec![0u8]` placeholder.
    fn minimal_pczt_bytes() -> Vec<u8> {
        pczt::roles::creator::Creator::new(u32::from(BranchId::Nu6_3), 10_000, 133, None, None)
            .expect("an NU6.3 PCZT creator")
            .build()
            .expect("an empty v6 PCZT builds")
            .serialize()
            .expect("an empty v6 PCZT serializes")
    }

    /// The [`test_state`] skeleton (`InProgress`, scheduled 50, expiry 10_000) with parseable
    /// PCZT bytes on every transaction and the given drawn boundary on every TRANSFER row
    /// (preparation rows keep `None` — they never carry one).
    fn provable_state(
        prep_states: &[MigrationTxState],
        transfer_states: &[MigrationTxState],
        transfer_boundary: Option<BlockHeight>,
    ) -> MigrationState {
        let base = test_state(
            MigrationStatus::InProgress,
            prep_states,
            transfer_states,
            50,
            10_000,
        );
        let bytes = minimal_pczt_bytes();
        let transactions = base
            .transactions()
            .iter()
            .map(|t| {
                MigrationTransaction::from_parts(
                    t.id(),
                    t.kind(),
                    bytes.clone(),
                    t.depends_on().clone(),
                    t.scheduled_height(),
                    t.expiry_height(),
                    match t.kind() {
                        MigrationTxKind::Transfer { .. } => transfer_boundary,
                        MigrationTxKind::Preparation { .. } => None,
                    },
                    t.state(),
                    t.lock_owner(),
                )
            })
            .collect();
        MigrationState::from_parts(
            base.status(),
            base.note_split().clone(),
            base.preparation().clone(),
            transactions,
        )
    }

    /// A TRANSFER proves via `prove_transfer` with EXACTLY the boundary persisted on its row —
    /// the caller resolves NO natural anchor for it (`None`, the lazy per-kind contract: a wallet
    /// whose natural anchor is not resolvable yet must still prove transfers) — and the proven
    /// bytes persist through the engine's `Proved` state.
    #[test]
    fn prove_dispatch_routes_a_transfer_to_its_stored_boundary() {
        let mut state = provable_state(&[MINED], &[MigrationTxState::Signed], Some(h(1440)));
        let mut prover = RecordingProver { calls: Vec::new() };
        let res = migration_finalize::prove_due_transaction(
            &mut prover,
            &mut state,
            MigrationTxId::new(1),
            None,
        )
        .expect("a boundary-carrying transfer proves");
        assert_eq!(res, Some(()), "the transfer must prove, not defer");
        assert_eq!(
            prover.calls,
            vec![ProveCall::Transfer(h(1440))],
            "the prover must receive the row's drawn boundary, never the natural anchor"
        );
        let tx = state
            .transactions()
            .iter()
            .find(|t| t.id() == MigrationTxId::new(1))
            .expect("the transfer row remains");
        assert!(
            matches!(tx.state(), MigrationTxState::Proved),
            "the engine must persist Signed -> Proved"
        );
        let expected = pczt::Pczt::parse(&minimal_pczt_bytes())
            .expect("fixture bytes parse")
            .serialize()
            .expect("fixture pczt re-serializes");
        assert_eq!(
            tx.pczt(),
            &expected,
            "the stored artifact must be the proven PCZT the prover returned"
        );
    }

    /// A PREPARATION proves via `prove_preparation` with the caller-supplied natural anchor (a
    /// preparation carries no drawn boundary).
    #[test]
    fn prove_dispatch_routes_a_preparation_to_the_natural_anchor() {
        let mut state = provable_state(
            &[MigrationTxState::Signed],
            &[MigrationTxState::Signed],
            Some(h(1440)),
        );
        let mut prover = RecordingProver { calls: Vec::new() };
        let res = migration_finalize::prove_due_transaction(
            &mut prover,
            &mut state,
            MigrationTxId::new(0),
            Some(h(777)),
        )
        .expect("a signed preparation proves");
        assert_eq!(res, Some(()), "the preparation must prove, not defer");
        assert_eq!(
            prover.calls,
            vec![ProveCall::Preparation(h(777))],
            "the prover must receive the natural anchor"
        );
        let tx = state
            .transactions()
            .iter()
            .find(|t| t.id() == MigrationTxId::new(0))
            .expect("the preparation row remains");
        assert!(
            matches!(tx.state(), MigrationTxState::Proved),
            "the engine must persist Signed -> Proved"
        );
    }

    /// A TRANSFER whose row carries NO drawn boundary is a corrupt store: a hard error on the
    /// proving-unavailable route — never a silent fallback to the natural anchor (the prover is
    /// not consulted at all).
    #[test]
    fn prove_dispatch_transfer_without_boundary_is_a_hard_error() {
        let mut state = provable_state(&[MINED], &[MigrationTxState::Signed], None);
        let mut prover = RecordingProver { calls: Vec::new() };
        let err = migration_finalize::prove_due_transaction(
            &mut prover,
            &mut state,
            MigrationTxId::new(1),
            None,
        )
        .expect_err("a boundary-less transfer must not prove");
        assert!(
            err.to_string().starts_with(PROVING_UNAVAILABLE_PREFIX),
            "the corrupt store must surface on the proving-unavailable route, got: {err}"
        );
        assert!(
            prover.calls.is_empty(),
            "the prover must never be consulted without a boundary"
        );
        let tx = state
            .transactions()
            .iter()
            .find(|t| t.id() == MigrationTxId::new(1))
            .expect("the transfer row remains");
        assert!(
            matches!(tx.state(), MigrationTxState::Signed),
            "the transaction must stay Signed"
        );
    }

    /// Every prover failure meaning "the wallet has not scanned or retained that boundary yet"
    /// (a restored wallet mid-sync, or a transfer due before the wallet scanned past its
    /// boundary) maps to the transient nothing-due `Ok(None)`, leaving the transaction `Signed`
    /// for a later retry.
    #[test]
    fn prove_dispatch_maps_every_transient_prover_error_to_nothing_due() {
        let transients: Vec<TestProveError> = vec![
            WalletProveError::AnchorNotFound(h(1440)),
            WalletProveError::WitnessNotFound(h(1440)),
            WalletProveError::ChainTipUnknown,
            WalletProveError::IronwoodTreeUnavailable,
        ];
        for error in transients {
            let label = format!("{error}");
            let mut state = provable_state(&[MINED], &[MigrationTxState::Signed], Some(h(1440)));
            let mut prover = FailingProver { error: Some(error) };
            let res = migration_finalize::prove_due_transaction(
                &mut prover,
                &mut state,
                MigrationTxId::new(1),
                None,
            )
            .unwrap_or_else(|e| panic!("{label} must be transient, got hard error: {e}"));
            assert_eq!(res, None, "{label} must map to the nothing-due lane");
            let tx = state
                .transactions()
                .iter()
                .find(|t| t.id() == MigrationTxId::new(1))
                .expect("the transfer row remains");
            assert!(
                matches!(tx.state(), MigrationTxState::Signed),
                "{label} must leave the transaction Signed for a retry"
            );
        }
    }

    /// Every other prover failure is HARD and carries the stable proving-unavailable prefix the
    /// Swift layer maps to `migrationProvingUnavailable`.
    #[test]
    fn prove_dispatch_routes_hard_prover_errors_through_the_proving_unavailable_prefix() {
        let nullifier = Option::from(orchard::note::Nullifier::from_bytes(&[0u8; 32]))
            .expect("zero is a valid nullifier encoding");
        let hards: Vec<TestProveError> = vec![
            WalletProveError::UnknownSpentNote(nullifier),
            WalletProveError::Notes(()),
            WalletProveError::Tree(shardtree::error::ShardTreeError::Query(
                shardtree::error::QueryError::CheckpointPruned,
            )),
            WalletProveError::Prove("proof backend failure".into()),
        ];
        for error in hards {
            let label = format!("{error}");
            let mut state = provable_state(&[MINED], &[MigrationTxState::Signed], Some(h(1440)));
            let mut prover = FailingProver { error: Some(error) };
            let err = migration_finalize::prove_due_transaction(
                &mut prover,
                &mut state,
                MigrationTxId::new(1),
                None,
            )
            .expect_err(&format!("{label} must be a hard error"));
            assert!(
                err.to_string().starts_with(PROVING_UNAVAILABLE_PREFIX),
                "{label} must carry the proving-unavailable prefix, got: {err}"
            );
        }
    }

    /// A PREPARATION reaching the dispatch WITHOUT a resolved natural anchor is a caller bug and
    /// a hard proving-unavailable error — never a silent prove against a wrong anchor (the prover
    /// is not consulted at all). This is the guard behind the lazy per-kind resolution: only the
    /// preparation arm may demand the natural anchor.
    #[test]
    fn prove_dispatch_preparation_without_a_natural_anchor_is_a_hard_error() {
        let mut state = provable_state(
            &[MigrationTxState::Signed],
            &[MigrationTxState::Signed],
            Some(h(1440)),
        );
        let mut prover = RecordingProver { calls: Vec::new() };
        let err = migration_finalize::prove_due_transaction(
            &mut prover,
            &mut state,
            MigrationTxId::new(0),
            None,
        )
        .expect_err("a preparation without a natural anchor must not prove");
        assert!(
            err.to_string().starts_with(PROVING_UNAVAILABLE_PREFIX),
            "the missing anchor must surface on the proving-unavailable route, got: {err}"
        );
        assert!(
            prover.calls.is_empty(),
            "the prover must never be consulted without an anchor"
        );
    }

    // ----- due-work projection over scheduled rows -----

    /// A [`provable_state`]-style row set with EXPLICIT per-transfer scheduling: each transfer is
    /// `(state, scheduled, boundary)` with parseable PCZT bytes and expiry 10_000. Preparation
    /// rows keep [`provable_state`]'s shape (scheduled 50, no boundary).
    fn scheduled_state(
        prep_states: &[MigrationTxState],
        transfers: &[(MigrationTxState, u32, Option<BlockHeight>)],
    ) -> MigrationState {
        let transfer_states: Vec<MigrationTxState> = transfers.iter().map(|(s, _, _)| *s).collect();
        let base = test_state(
            MigrationStatus::InProgress,
            prep_states,
            &transfer_states,
            50,
            10_000,
        );
        let bytes = minimal_pczt_bytes();
        let offset = prep_states.len();
        let transactions = base
            .transactions()
            .iter()
            .map(|t| {
                let (scheduled, boundary) = match t.kind() {
                    MigrationTxKind::Transfer { .. } => {
                        let (_, scheduled, boundary) =
                            &transfers[u32::from(t.id()) as usize - offset];
                        (h(*scheduled), *boundary)
                    }
                    MigrationTxKind::Preparation { .. } => (t.scheduled_height(), None),
                };
                MigrationTransaction::from_parts(
                    t.id(),
                    t.kind(),
                    bytes.clone(),
                    t.depends_on().clone(),
                    scheduled,
                    t.expiry_height(),
                    boundary,
                    t.state(),
                    t.lock_owner(),
                )
            })
            .collect();
        MigrationState::from_parts(
            base.status(),
            base.note_split().clone(),
            base.preparation().clone(),
            transactions,
        )
    }

    /// [`due_assuming_proving`] mirrors the drive without a prover: a due `Signed` transfer
    /// behind an undue one IS reported, an undue-only schedule is NOT, and a row awaiting an
    /// external signature never is (the signing ceremony, not the delivery lane, advances it).
    #[test]
    fn due_assuming_proving_reports_due_signed_rows_and_only_those() {
        // A due Signed transfer behind an undue one: reported (the drive would serve it).
        let state = scheduled_state(
            &[MINED],
            &[
                (MigrationTxState::Signed, 9_000, Some(h(40))),
                (MigrationTxState::Signed, 90, Some(h(40))),
            ],
        );
        assert_eq!(
            due_assuming_proving(&state, h(100)),
            Some(MigrationTxId::new(2)),
            "a due-but-unproved transfer is due delivery work"
        );
        assert!(
            state
                .transactions()
                .iter()
                .all(|t| !matches!(t.state(), MigrationTxState::Proved)),
            "the virtual drive must not mutate the caller's state"
        );

        // Provable but nothing schedule-due: not reported (proving alone is not overdue work).
        let undue = scheduled_state(&[MINED], &[(MigrationTxState::Signed, 9_000, Some(h(40)))]);
        assert_eq!(due_assuming_proving(&undue, h(100)), None);

        // Awaiting an external signature, schedule-due: not delivery work.
        let awaiting = scheduled_state(
            &[MINED],
            &[(MigrationTxState::AwaitingSignature, 90, Some(h(40)))],
        );
        assert_eq!(due_assuming_proving(&awaiting, h(100)), None);

        // Already Proved and due: reported exactly as before the drive existed.
        let proved = scheduled_state(&[MINED], &[(MigrationTxState::Proved, 90, Some(h(40)))]);
        assert_eq!(
            due_assuming_proving(&proved, h(100)),
            Some(MigrationTxId::new(1))
        );
    }

    /// A stored run whose next transaction is `Signed`, schedule-due, dependency-satisfied, and
    /// prove-ready is OVERDUE WORK over the real FFI: commit stores rows `Signed`, and proving is
    /// the delivery lane's own job, so answering only for already-`Proved` rows would report
    /// "nothing to do" forever on a run whose transfers were never proved.
    #[test]
    fn has_overdue_transfers_reports_a_due_signed_transfer() {
        let path = init_fixture_db("zcashlc_migration_overdue_signed");
        let path_bytes = path.to_str().unwrap().as_bytes();
        let account = create_fixture_account(&path);
        assert!(
            unsafe {
                crate::zcashlc_update_chain_tip(
                    path_bytes.as_ptr(),
                    path_bytes.len(),
                    3_600_000,
                    NETWORK_ID_MAINNET,
                )
            },
            "chain-tip update must succeed"
        );
        // Signed, scheduled below the tip (due), expiry above the target (valid), boundary
        // settled (`test_state` draws the boundary at the scheduled height, strictly below the
        // tip).
        store_source_bound_transfer_fixture(
            &path,
            &account,
            MigrationTxState::Signed,
            3_499_000,
            4_000_000,
            0x11,
        );
        let overdue = unsafe {
            zcashlc_migration_has_overdue_transfers(
                path_bytes.as_ptr(),
                path_bytes.len(),
                account.as_ptr(),
                NETWORK_ID_MAINNET,
            )
        };
        assert!(
            overdue,
            "a due-but-unproved Signed transfer is overdue delivery work"
        );
        let _ = std::fs::remove_file(&path);
    }

    // ----- engine target-height boundary (F2): `next_broadcastable`/`next_provable`/
    // `expired_transactions` are all defined over `target = tip + 1`, never the raw tip -----

    /// Engine semantics: `next_broadcastable` is defined over `target = tip + 1` (the height of
    /// the NEXT block), with schedule test `scheduled_height <= target` — so a `Proved` transfer
    /// scheduled at EXACTLY `tip + 1` is due for broadcast right now, one block earlier than a
    /// raw-tip check (`scheduled_height <= tip`) would have admitted it.
    #[test]
    fn has_overdue_transfers_reports_scheduled_at_target_as_due() {
        let path = init_fixture_db("zcashlc_migration_overdue_target_boundary");
        let path_bytes = path.to_str().unwrap().as_bytes();
        let account = create_fixture_account(&path);
        assert!(
            unsafe {
                crate::zcashlc_update_chain_tip(
                    path_bytes.as_ptr(),
                    path_bytes.len(),
                    3_600_000,
                    NETWORK_ID_MAINNET,
                )
            },
            "chain-tip update must succeed"
        );
        // Proved, scheduled at exactly tip + 1 (the target height), expiry comfortably above.
        store_source_bound_transfer_fixture(
            &path,
            &account,
            MigrationTxState::Proved,
            3_600_001, // scheduled_height == tip + 1
            4_000_000,
            0x12,
        );
        let overdue = unsafe {
            zcashlc_migration_has_overdue_transfers(
                path_bytes.as_ptr(),
                path_bytes.len(),
                account.as_ptr(),
                NETWORK_ID_MAINNET,
            )
        };
        assert!(
            overdue,
            "a Proved transfer scheduled at tip + 1 must be due (engine: scheduled_height <= target)"
        );
        let _ = std::fs::remove_file(&path);
    }

    /// An engine-expired `Proved` transfer (`expiry_height == tip`, so it can no longer be mined
    /// in the next block) must never be reported as due delivery work — a node would reject its
    /// broadcast outright. This already holds once the target fix lands (`next_broadcastable`
    /// already excludes expired rows when fed the right height); kept as an explicit regression
    /// pin on the exact boundary the old raw-tip call missed.
    #[test]
    fn has_overdue_transfers_does_not_report_an_expired_proved_transfer_at_the_tip() {
        let path = init_fixture_db("zcashlc_migration_overdue_expired_at_tip");
        let path_bytes = path.to_str().unwrap().as_bytes();
        let account = create_fixture_account(&path);
        assert!(
            unsafe {
                crate::zcashlc_update_chain_tip(
                    path_bytes.as_ptr(),
                    path_bytes.len(),
                    3_600_000,
                    NETWORK_ID_MAINNET,
                )
            },
            "chain-tip update must succeed"
        );
        // Proved, schedule-due, but expiry == tip: expired per the engine, and must not be
        // offered for broadcast even though it is otherwise ready.
        store_source_bound_transfer_fixture(
            &path,
            &account,
            MigrationTxState::Proved,
            3_499_000,
            3_600_000, // expiry_height == tip
            0x13,
        );
        let overdue = unsafe {
            zcashlc_migration_has_overdue_transfers(
                path_bytes.as_ptr(),
                path_bytes.len(),
                account.as_ptr(),
                NETWORK_ID_MAINNET,
            )
        };
        assert!(
            !overdue,
            "an expired (expiry_height == tip) transfer must never be reported as due delivery work"
        );
        let _ = std::fs::remove_file(&path);
    }

    /// ZIP 203 / engine semantics pin for the hand-rolled expiry check inside
    /// `zcashlc_migration_has_invalid_transfers`: `expiry_height == tip` can no longer be mined
    /// in the next block and must report as an invalid/attention-worthy transfer, one block
    /// earlier than the old `tip > expiry_height` check would catch it.
    #[test]
    fn has_invalid_transfers_reports_expiry_equal_to_tip_as_expired() {
        let path = init_fixture_db("zcashlc_migration_has_invalid_expiry_eq_tip");
        let path_bytes = path.to_str().unwrap().as_bytes();
        let account = create_fixture_account(&path);
        assert!(
            unsafe {
                crate::zcashlc_update_chain_tip(
                    path_bytes.as_ptr(),
                    path_bytes.len(),
                    3_600_000,
                    NETWORK_ID_MAINNET,
                )
            },
            "chain-tip update must succeed"
        );
        store_source_bound_transfer_fixture(
            &path,
            &account,
            MigrationTxState::Signed,
            3_499_000,
            3_600_000, // expiry_height == tip
            0x14,
        );
        let invalid = unsafe {
            zcashlc_migration_has_invalid_transfers(
                path_bytes.as_ptr(),
                path_bytes.len(),
                account.as_ptr(),
                NETWORK_ID_MAINNET,
            )
        };
        assert!(
            invalid,
            "a transfer with expiry_height == tip can no longer be mined in the next block and \
             must report as an invalid transfer"
        );
        let _ = std::fs::remove_file(&path);
    }

    /// `expiry_height == 0` is the engine's "never expires" sentinel; the hand-rolled check
    /// inside `zcashlc_migration_has_invalid_transfers` must not treat it as expired at any tip.
    #[test]
    fn has_invalid_transfers_ignores_expiry_zero_never_expires() {
        let path = init_fixture_db("zcashlc_migration_has_invalid_expiry_zero");
        let path_bytes = path.to_str().unwrap().as_bytes();
        let account = create_fixture_account(&path);
        assert!(
            unsafe {
                crate::zcashlc_update_chain_tip(
                    path_bytes.as_ptr(),
                    path_bytes.len(),
                    3_600_000,
                    NETWORK_ID_MAINNET,
                )
            },
            "chain-tip update must succeed"
        );
        store_source_bound_transfer_fixture(
            &path,
            &account,
            MigrationTxState::Signed,
            3_499_000,
            0, // expiry_height == 0: never expires
            0x15,
        );
        let invalid = unsafe {
            zcashlc_migration_has_invalid_transfers(
                path_bytes.as_ptr(),
                path_bytes.len(),
                account.as_ptr(),
                NETWORK_ID_MAINNET,
            )
        };
        assert!(
            !invalid,
            "expiry_height == 0 must never expire, even at a huge tip"
        );
        let _ = std::fs::remove_file(&path);
    }

    // ----- per-transaction status view (`zcashlc_migration_transaction_statuses`) -----
    //
    // `zcashlc_migration_transaction_statuses` marshals `MigrationState::transaction_statuses`
    // verbatim, so these fixtures build heterogeneous rows directly (unlike `test_state`/
    // `scheduled_state`, which apply one uniform scheduled/expiry pair across the whole state),
    // at the file's usual 3,600,000-scale heights.

    /// A single migration-transaction row for [`custom_state`], with its own kind, dependencies,
    /// heights, and boundary — full control, unlike [`test_state`]/[`scheduled_state`].
    fn tx_row(
        id: u32,
        kind: MigrationTxKind,
        depends_on: &[u32],
        scheduled: u32,
        expiry: u32,
        anchor_boundary: Option<u32>,
        state: MigrationTxState,
    ) -> MigrationTransaction {
        MigrationTransaction::from_parts(
            MigrationTxId::new(id),
            kind,
            vec![0u8],
            depends_on.iter().map(|&d| MigrationTxId::new(d)).collect(),
            h(scheduled),
            h(expiry),
            anchor_boundary.map(h),
            state,
            None,
        )
    }

    /// A [`MigrationState`] built from explicit [`tx_row`]s. The note split's crossing values
    /// are throwaway placeholders (one per TRANSFER row, matching [`test_state`]'s own
    /// convention) — `transaction_statuses` never reads `note_split`.
    fn custom_state(status: MigrationStatus, rows: Vec<MigrationTransaction>) -> MigrationState {
        let funding: Vec<Zatoshis> = rows
            .iter()
            .filter(|t| matches!(t.kind(), MigrationTxKind::Transfer { .. }))
            .map(|_| zat(100_000_000))
            .collect();
        MigrationState::from_parts(
            status,
            NoteSplitPlan::from_stored_parts(
                funding,
                zat(10_000),
                None,
                zat(20_000),
                zat(1_000_000_000),
                zat(999_000_000),
            )
            .unwrap(),
            PreparationPlan::from_parts(Vec::new(), Vec::new()),
            rows,
        )
    }

    /// 1. No stored migration at all: an empty container, not an error — the same convention as
    ///    [`encode_empty_schedule`] and answerable before any chain-tip lookup.
    #[test]
    fn migration_transaction_statuses_on_fresh_db_is_an_empty_container() {
        let path = init_fixture_db("zcashlc_migration_tx_statuses_fresh");
        let path_bytes = path.to_str().unwrap().as_bytes();
        let account = create_fixture_account(&path);
        let statuses_ptr = unsafe {
            zcashlc_migration_transaction_statuses(
                path_bytes.as_ptr(),
                path_bytes.len(),
                account.as_ptr(),
                NETWORK_ID_MAINNET,
            )
        };
        assert!(!statuses_ptr.is_null(), "no stored run is not an error");
        let statuses = unsafe { &*statuses_ptr };
        assert_eq!(statuses.len, 0, "no stored run yields an empty container");
        assert!(
            statuses.ptr.is_null(),
            "an empty container carries no heap array, mirroring encode_empty_schedule"
        );
        unsafe { zcashlc_free_migration_transaction_statuses(statuses_ptr) };
        let _ = std::fs::remove_file(&path);
    }

    /// 2. A mixed stored run — a MINED preparation, a BROADCAST transfer, a READY (prove) SIGNED
    ///    transfer, and a SIGNED transfer blocked on its anchor boundary — marshaled verbatim from
    ///    the engine. Every field is checked against `MigrationState::transaction_statuses` computed
    ///    directly on the SAME state object, not a second hand-derivation.
    ///
    /// The task sketch that seeded this test named the fourth row "blocked on schedule"; the
    /// pinned engine (`zcash_pool_migration::state`) makes that unreachable for a
    /// TRANSFER — `anchor_boundary` is always `Some` for a transfer (only a preparation's is
    /// `None`), so a not-yet-prove-ready `Signed` transfer is always `Blocker::AnchorBoundary`,
    /// never `Blocker::Schedule` (`Schedule` is reported for a `Proved` row awaiting its
    /// broadcast height, or a `Signed` PREPARATION awaiting its own schedule). Row 3 below pins
    /// the real transfer-blocking case instead.
    #[test]
    fn migration_transaction_statuses_marshals_mixed_rows_verbatim_from_the_engine() {
        let path = init_fixture_db("zcashlc_migration_tx_statuses_mixed");
        let path_bytes = path.to_str().unwrap().as_bytes();
        let account = create_fixture_account(&path);
        assert!(
            unsafe {
                crate::zcashlc_update_chain_tip(
                    path_bytes.as_ptr(),
                    path_bytes.len(),
                    3_600_000,
                    NETWORK_ID_MAINNET,
                )
            },
            "chain-tip update must succeed"
        );

        let broadcast_txid = [7u8; 32];
        let rows = vec![
            tx_row(
                0,
                MigrationTxKind::Preparation { layer: 0, index: 0 },
                &[],
                3_000_000,
                4_000_000,
                None,
                MigrationTxState::Mined {
                    height: h(3_000_000),
                },
            ),
            tx_row(
                1,
                MigrationTxKind::Transfer { crossing: 0 },
                &[],
                3_100_000,
                4_000_000,
                Some(3_100_000),
                MigrationTxState::Broadcast {
                    txid: TxId::from_bytes(broadcast_txid),
                },
            ),
            tx_row(
                2,
                MigrationTxKind::Transfer { crossing: 1 },
                &[],
                3_200_000,
                4_000_000,
                Some(3_000_000), // settled: boundary + 1 < target (3_600_001)
                MigrationTxState::Signed,
            ),
            tx_row(
                3,
                MigrationTxKind::Transfer { crossing: 2 },
                &[],
                3_600_000,
                4_000_000,
                Some(3_600_000), // not settled: boundary + 1 == target
                MigrationTxState::Signed,
            ),
        ];
        // This is a pure DTO-marshaling fixture, so keep it terminal. Live rows must be created
        // through the source-bound delivery start seam; transaction status projection itself does
        // not depend on the aggregate terminal marker.
        let state = custom_state(MigrationStatus::Failed, rows);
        store_fixture_state(&path, &account, &state);

        // The expectation: computed directly from the engine, on the very same state.
        let target = h(3_600_001);
        let expected = state.transaction_statuses(target);
        assert_eq!(expected.len(), 4, "sanity: every row got a status");

        let statuses_ptr = unsafe {
            zcashlc_migration_transaction_statuses(
                path_bytes.as_ptr(),
                path_bytes.len(),
                account.as_ptr(),
                NETWORK_ID_MAINNET,
            )
        };
        assert!(
            !statuses_ptr.is_null(),
            "a mixed stored run is not an error"
        );
        let statuses = unsafe { &*statuses_ptr };
        assert_eq!(statuses.len, 4, "every stored row must get a status");
        let ffi_rows = unsafe { std::slice::from_raw_parts(statuses.ptr, statuses.len) };

        for exp in &expected {
            let id = u32::from(exp.id());
            let actual = ffi_rows
                .iter()
                .find(|r| r.id == id)
                .unwrap_or_else(|| panic!("row {id} must be present in the FFI output"));

            let (exp_is_transfer, exp_prep_layer, exp_prep_index, exp_crossing) = match exp.kind() {
                MigrationTxKind::Preparation { layer, index } => {
                    (false, layer as i64, index as i64, -1i64)
                }
                MigrationTxKind::Transfer { crossing } => (true, -1i64, -1i64, crossing as i64),
            };
            assert_eq!(
                actual.is_transfer, exp_is_transfer,
                "row {id}: kind discriminant"
            );
            assert_eq!(actual.prep_layer, exp_prep_layer, "row {id}: prep_layer");
            assert_eq!(actual.prep_index, exp_prep_index, "row {id}: prep_index");
            assert_eq!(actual.crossing, exp_crossing, "row {id}: crossing");

            let exp_state = match exp.state() {
                MigrationTxState::AwaitingSignature => 0,
                MigrationTxState::Signed => 1,
                MigrationTxState::Proved => 2,
                MigrationTxState::Broadcast { .. } => 3,
                MigrationTxState::Mined { .. } => 4,
            };
            assert_eq!(actual.state, exp_state, "row {id}: state");
            assert_eq!(
                actual.scheduled_height,
                i64::from(u32::from(exp.scheduled_height())),
                "row {id}: scheduled_height"
            );
            assert_eq!(
                actual.expiry_height,
                i64::from(u32::from(exp.expiry_height())),
                "row {id}: expiry_height"
            );
            assert_eq!(
                actual.mined_height,
                height_opt_to_i64(exp.mined_height()),
                "row {id}: mined_height"
            );
            assert_eq!(actual.ready, exp.ready(), "row {id}: ready");
            let exp_action = match exp.action() {
                None => 0,
                Some(NextAction::Prove) => 1,
                Some(NextAction::Broadcast) => 2,
            };
            assert_eq!(actual.action, exp_action, "row {id}: action");
            let exp_blocked_on = match exp.blocked_on() {
                None => 0,
                Some(Blocker::Dependencies) => 1,
                Some(Blocker::Schedule) => 2,
                Some(Blocker::AnchorBoundary) => 3,
                Some(Blocker::Signature) => 4,
                Some(Blocker::Expired) => 5,
            };
            assert_eq!(actual.blocked_on, exp_blocked_on, "row {id}: blocked_on");

            match exp.txid() {
                Some(txid) => {
                    assert!(actual.has_txid, "row {id}: has_txid must be true");
                    assert_eq!(actual.txid, <[u8; 32]>::from(txid), "row {id}: txid bytes");
                }
                None => assert!(!actual.has_txid, "row {id}: has_txid must be false"),
            }
        }

        // Pin the specific scenarios the doc comment calls out by id, so a coincidental pass of
        // the loop above (matching on both sides in the same wrong way) cannot hide a
        // regression.
        let mined_prep = ffi_rows.iter().find(|r| r.id == 0).unwrap();
        assert_eq!(mined_prep.state, 4, "row 0 must be Mined");
        assert_eq!(
            mined_prep.mined_height, 3_000_000,
            "row 0 must carry its mined height"
        );
        assert!(
            !mined_prep.has_txid,
            "a Mined row carries no txid: the engine's own Mined state has none"
        );

        let broadcast_transfer = ffi_rows.iter().find(|r| r.id == 1).unwrap();
        assert_eq!(broadcast_transfer.state, 3, "row 1 must be Broadcast");
        assert!(
            broadcast_transfer.has_txid,
            "row 1 must carry its broadcast txid"
        );
        assert_eq!(broadcast_transfer.txid, broadcast_txid);
        assert_eq!(
            broadcast_transfer.mined_height, -1,
            "row 1 has no mined height yet"
        );

        let ready_transfer = ffi_rows.iter().find(|r| r.id == 2).unwrap();
        assert!(ready_transfer.ready, "row 2 must be ready");
        assert_eq!(ready_transfer.action, 1, "row 2's action must be Prove");
        assert_eq!(ready_transfer.blocked_on, 0, "row 2 must report no blocker");

        let blocked_transfer = ffi_rows.iter().find(|r| r.id == 3).unwrap();
        assert!(!blocked_transfer.ready, "row 3 must not be ready");
        assert_eq!(blocked_transfer.action, 0, "row 3 must report no action");
        assert_eq!(
            blocked_transfer.blocked_on, 3,
            "row 3 must be blocked on its anchor boundary"
        );

        unsafe { zcashlc_free_migration_transaction_statuses(statuses_ptr) };
        let _ = std::fs::remove_file(&path);
    }

    /// 3. The low-level status read is a pure projection: wallet chain evidence cannot mutate a
    ///    delivery-owned canonical row without the opaque run capability. The high-level Swift API
    ///    performs the typed reconciliation CAS before calling this projection.
    #[test]
    fn migration_transaction_statuses_is_pure_until_opaque_reconciliation() {
        let path = init_fixture_db("zcashlc_migration_tx_statuses_reconcile");
        let path_bytes = path.to_str().unwrap().as_bytes();
        let account = create_fixture_account(&path);
        assert!(
            unsafe {
                crate::zcashlc_update_chain_tip(
                    path_bytes.as_ptr(),
                    path_bytes.len(),
                    3_600_000,
                    NETWORK_ID_MAINNET,
                )
            },
            "chain-tip update must succeed"
        );

        let txid = [3u8; 32];
        let mined_at = 3_500_000u32;
        // The wallet's own view: this txid mined at `mined_at`, independent of the migration
        // store (`reconcile_mined` cross-references the two).
        {
            let conn = Connection::open(&path).expect("the wallet connection opens");
            conn.execute(
                "INSERT INTO transactions (txid, mined_height, min_observed_height) \
                 VALUES (?1, ?2, ?3)",
                rusqlite::params![&txid[..], mined_at, mined_at],
            )
            .expect("the fixture mined-transaction row inserts");
        }

        let rows = vec![tx_row(
            0,
            MigrationTxKind::Transfer { crossing: 0 },
            &[],
            3_100_000,
            4_000_000,
            Some(3_000_000),
            MigrationTxState::Broadcast {
                txid: TxId::from_bytes(txid),
            },
        )];
        let state = custom_state(MigrationStatus::Failed, rows);
        store_fixture_state(&path, &account, &state);

        let statuses_ptr = unsafe {
            zcashlc_migration_transaction_statuses(
                path_bytes.as_ptr(),
                path_bytes.len(),
                account.as_ptr(),
                NETWORK_ID_MAINNET,
            )
        };
        assert!(!statuses_ptr.is_null());
        let statuses = unsafe { &*statuses_ptr };
        assert_eq!(statuses.len, 1);
        let row = unsafe { &*statuses.ptr };
        assert_eq!(row.state, 3, "the pure read must preserve Broadcast");
        assert_eq!(
            row.mined_height, -1,
            "the pure projection has no mined height before typed reconciliation"
        );
        assert!(
            row.has_txid,
            "the Broadcast projection must retain its canonical txid"
        );
        assert_eq!(row.txid, txid);
        unsafe { zcashlc_free_migration_transaction_statuses(statuses_ptr) };

        // Most importantly, the read cannot persist a lifecycle transition without delivery CAS
        // authority. The opaque-run reconciliation path is covered at the high-level Swift seam.
        let stored = read_fixture_state(&path, &account);
        let stored_tx = stored
            .transactions()
            .iter()
            .find(|t| t.id() == MigrationTxId::new(0))
            .expect("the row remains stored");
        assert!(
            matches!(stored_tx.state(), MigrationTxState::Broadcast { txid: stored } if stored == TxId::from_bytes(txid)),
            "the pure read must not persist Broadcast -> Mined"
        );

        let _ = std::fs::remove_file(&path);
    }

    /// 4. ZIP 203 / engine semantics: `expiry_height == tip` can no longer be mined in the next
    ///    block (`target = tip + 1`), so the engine reports `Blocker::Expired` ahead of any other
    ///    blocker. Ties the DTO to the same target-height semantics already pinned elsewhere in
    ///    this file (F2: `has_overdue_transfers_does_not_report_an_expired_proved_transfer_at_the_tip`,
    ///    `has_invalid_transfers_reports_expiry_equal_to_tip_as_expired`). A second row with
    ///    `expiry_height == 0` (the engine's "never expires" sentinel) pins the contrast.
    #[test]
    fn migration_transaction_statuses_reports_expired_at_the_tip_boundary() {
        let path = init_fixture_db("zcashlc_migration_tx_statuses_expired");
        let path_bytes = path.to_str().unwrap().as_bytes();
        let account = create_fixture_account(&path);
        assert!(
            unsafe {
                crate::zcashlc_update_chain_tip(
                    path_bytes.as_ptr(),
                    path_bytes.len(),
                    3_600_000,
                    NETWORK_ID_MAINNET,
                )
            },
            "chain-tip update must succeed"
        );

        let rows = vec![
            tx_row(
                0,
                MigrationTxKind::Transfer { crossing: 0 },
                &[],
                3_000_000,
                3_600_000, // expiry_height == tip
                Some(3_000_000),
                MigrationTxState::Signed,
            ),
            tx_row(
                1,
                MigrationTxKind::Transfer { crossing: 1 },
                &[],
                3_000_000,
                0, // never expires
                Some(3_000_000),
                MigrationTxState::Signed,
            ),
        ];
        let state = custom_state(MigrationStatus::Failed, rows);
        store_fixture_state(&path, &account, &state);

        let statuses_ptr = unsafe {
            zcashlc_migration_transaction_statuses(
                path_bytes.as_ptr(),
                path_bytes.len(),
                account.as_ptr(),
                NETWORK_ID_MAINNET,
            )
        };
        assert!(!statuses_ptr.is_null());
        let statuses = unsafe { &*statuses_ptr };
        assert_eq!(statuses.len, 2);
        let ffi_rows = unsafe { std::slice::from_raw_parts(statuses.ptr, statuses.len) };

        let expired = ffi_rows.iter().find(|r| r.id == 0).unwrap();
        assert!(!expired.ready, "an expired row is never ready");
        assert_eq!(expired.action, 0, "an expired row offers no action");
        assert_eq!(
            expired.blocked_on, 5,
            "expiry_height == tip must report Expired"
        );

        let never_expires = ffi_rows.iter().find(|r| r.id == 1).unwrap();
        assert!(
            never_expires.ready,
            "expiry_height == 0 must never expire, even at a huge tip"
        );
        assert_eq!(
            never_expires.action, 1,
            "the never-expiring row is prove-ready"
        );
        assert_eq!(never_expires.blocked_on, 0);

        unsafe { zcashlc_free_migration_transaction_statuses(statuses_ptr) };
        let _ = std::fs::remove_file(&path);
    }
}
