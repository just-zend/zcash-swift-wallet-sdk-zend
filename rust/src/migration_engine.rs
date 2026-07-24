//! The adapter wiring this SDK's wallet database into the pool-migration engine's traits.
//!
//! [`zcash_pool_migration`]'s engine works over four traits — `MigrationBackend` (notes and
//! chain tip), `MigrationCrypto` (viewing key, note plaintexts, signing), and `PoolMigrationRead` /
//! `PoolMigrationWrite` (the store). The crate ships its own `wallet::WalletMigration` adapter, but
//! that adapter requires a `UnifiedSpendingKey` unconditionally (it derives the Orchard FVK from
//! it), which cannot serve an imported hardware-wallet account whose spending key never exists on
//! this device. This adapter instead derives the FVK from the account's STORED unified full viewing
//! key, takes the spending key as an `Option` (present only on the in-process signing paths), and
//! scopes the store to the account via `PoolMigrations::for_account` — so one wallet database
//! hosting several accounts (a seed-derived software account next to a UFVK-imported Keystone
//! account) migrates them independently.
//!
//! Proving (`engine::MigrationProver`) is deliberately NOT implemented on this adapter: resolving
//! witnesses needs mutable access to the wallet's note commitment tree, which the shared borrow
//! this adapter holds cannot provide. The proving entry points instead construct the upstream
//! `wallet::WalletMigrationProver` over a separate mutable wallet borrow, dispatched per
//! transaction kind (boundary anchor for transfers, natural anchor for preparations) in
//! [`crate::migration_finalize`].

use std::collections::BTreeSet;

use anyhow::anyhow;
use incrementalmerkletree::Position;
use orchard::keys::{FullViewingKey, SpendAuthorizingKey};
use orchard::note::Note as OrchardNote;
use rand::rngs::OsRng;
use zcash_client_backend::data_api::wallet::{
    ConfirmationsPolicy, TargetHeight,
    input_selection::{LockFilter, LockedInputPolicy, NonEmptyBTreeSet},
};
use zcash_client_backend::data_api::{Account, InputSource, WalletRead};
use zcash_client_backend::wallet::LockOwner;
use zcash_client_sqlite::AccountUuid;
use zcash_client_sqlite::pool_migration::orchard_ironwood::PoolMigrations;
use zcash_client_sqlite::util::SystemClock;
use zcash_keys::keys::UnifiedSpendingKey;
use zcash_pool_migration::build::sign_pczt;
use zcash_pool_migration::engine::{
    MigrationBackend, MigrationCrypto, MigrationState, MigrationStatus, MigrationTxId,
    MigrationTxState, PoolMigrationRead, PoolMigrationWrite,
};
use zcash_pool_migration::wallet::{
    MigrationCompletion, finalize_completed_migration, persist_migration_with_locks,
    update_migration_transaction_with_locks,
};
use zcash_protocol::ShieldedPool;
use zcash_protocol::consensus::BlockHeight;
use zcash_protocol::value::Zatoshis;

use crate::NetworkParams;

/// The concrete wallet type every migration entry point operates over.
pub(crate) type MigrationWallet =
    zcash_client_sqlite::WalletDb<rusqlite::Connection, NetworkParams, SystemClock, OsRng>;

/// A spendable Orchard note as the adapter tracks it: the note, its note-commitment-tree position,
/// and its value in zatoshi. The vector's order (sorted by tree position) is the index space the
/// engine's `PrepInput::Wallet { index }` refers into, so it must be stable across calls.
pub(crate) type SpendableNote = (OrchardNote, Position, u64);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum OwnerRecovery {
    None,
    Existing(LockOwner),
    Bootstrap,
}

/// Classifies the canonical state/owner pair without mutating it. Engine Complete has two valid
/// representations: provisional with exactly one owner, and strictly finalized with none. A
/// nonterminal state with none is a legacy state or a finalized-Complete reorg that must bootstrap
/// a fresh owner through the expected-state CAS boundary.
fn owner_recovery(
    status: Option<MigrationStatus>,
    owners: &BTreeSet<LockOwner>,
) -> anyhow::Result<OwnerRecovery> {
    match (status, owners.len()) {
        (None | Some(MigrationStatus::Failed), 0) => Ok(OwnerRecovery::None),
        (None, count) => Err(anyhow!(
            "migration has {count} lock owners without a canonical state"
        )),
        (Some(MigrationStatus::Failed), count) => {
            Err(anyhow!("failed migration retains {count} lock owner(s)"))
        }
        (Some(MigrationStatus::Complete), 0) => Ok(OwnerRecovery::None),
        (Some(MigrationStatus::Complete), 1) => Ok(OwnerRecovery::Existing(
            *owners.first().expect("one owner by match"),
        )),
        (Some(MigrationStatus::Complete), count) => Err(anyhow!(
            "complete migration has {count} distinct lock owners; refusing ambiguous recovery"
        )),
        (Some(_), 0) => Ok(OwnerRecovery::Bootstrap),
        (Some(_), 1) => Ok(OwnerRecovery::Existing(
            *owners.first().expect("one owner by match"),
        )),
        (Some(_), count) => Err(anyhow!(
            "migration has {count} distinct lock owners; refusing ambiguous recovery"
        )),
    }
}

/// The migration backend for one account of this SDK's wallet database.
pub(crate) struct Backend<'a> {
    wallet: &'a MigrationWallet,
    account: AccountUuid,
    usk: Option<UnifiedSpendingKey>,
    store: PoolMigrations<&'a mut rusqlite::Connection>,
    owner: Option<LockOwner>,
    /// The exact canonical state this backend read or last persisted. Every whole-state replace
    /// compares against this value inside the lock/store transaction, preventing a stale clone
    /// from overwriting another writer's newer lifecycle transition.
    canonical: Option<MigrationState>,
}

impl<'a> Backend<'a> {
    /// Wrap the wallet, an account, an optional spending key (present only for in-process signing
    /// paths — the external-signer and read/plan paths pass `None`), and the store connection.
    pub(crate) fn new(
        wallet: &'a MigrationWallet,
        account: AccountUuid,
        usk: Option<UnifiedSpendingKey>,
        store_conn: &'a mut rusqlite::Connection,
    ) -> anyhow::Result<Self> {
        let mut backend = Self {
            wallet,
            account,
            usk,
            store: PoolMigrations::for_account(store_conn, account)
                .map_err(|e| anyhow!("opening the account-scoped migration store failed: {e}"))?,
            owner: None,
            canonical: None,
        };

        let state = backend
            .store
            .get_migration()
            .map_err(|e| anyhow!("migration store read failed while recovering locks: {e}"))?;
        let owners = backend
            .store
            .migration_lock_owners()
            .map_err(|e| anyhow!("migration lock-owner recovery failed: {e}"))?;

        backend.canonical = state.clone();
        match owner_recovery(state.as_ref().map(MigrationState::status), &owners)? {
            OwnerRecovery::None => {}
            OwnerRecovery::Existing(owner) => {
                let state = state
                    .as_ref()
                    .expect("existing lock owner requires a canonical migration state");
                // Owner tokens can outlive their concrete locks across an expiry, crash, or
                // legacy restart. Refresh every still-pending exact input before this backend can
                // serve a read or delivery operation. Same-owner locking is idempotent, and the
                // expected-state comparison prevents a stale restart from overwriting a newer
                // lifecycle transition. Broadcast/Mined inputs are protected by active spend
                // records instead of being re-locked; provisional Complete keeps its owner but
                // ordinarily has no unresolved inputs.
                let orchard_fvk = backend.stored_orchard_fvk()?;
                let persisted = persist_migration_with_locks(
                    backend.wallet,
                    backend.account,
                    &orchard_fvk,
                    &mut backend.store,
                    owner,
                    Some(state),
                    state,
                )
                .map_err(|e| anyhow!("refreshing recovered migration input locks failed: {e}"))?;
                backend.owner = Some(owner);
                backend.canonical = Some(persisted);
            }
            OwnerRecovery::Bootstrap => {
                let state = state
                    .as_ref()
                    .expect("owner bootstrap requires a canonical nonterminal state");
                // Upgrade an ownerless pre-lock migration, or a finalized Complete demoted by a
                // reorg, at its first access. The generated owner is stamped into the canonical
                // migration through expected-state CAS in the same transaction as exact locks.
                let owner = LockOwner::random(&mut OsRng);
                let orchard_fvk = backend.stored_orchard_fvk()?;
                let persisted = persist_migration_with_locks(
                    backend.wallet,
                    backend.account,
                    &orchard_fvk,
                    &mut backend.store,
                    owner,
                    Some(state),
                    state,
                )
                .map_err(|e| anyhow!("bootstrapping migration input locks failed: {e}"))?;
                backend.owner = Some(owner);
                backend.canonical = Some(persisted);
            }
        }

        Ok(backend)
    }

    /// Constructs the read-only engine adapter used to derive one delivery-owned expired-transfer
    /// successor. Unlike [`Self::new`], this performs no generic canonical write or lock refresh:
    /// the caller commits the derived successor only through the typed delivery CAS seam. The
    /// exact expected state and its single durable lock owner must still match storage so a stale,
    /// ownerless, or ambiguously-owned rebuild fails before any artifact is derived.
    pub(crate) fn for_delivery_rebuild(
        wallet: &'a MigrationWallet,
        account: AccountUuid,
        usk: Option<UnifiedSpendingKey>,
        store_conn: &'a mut rusqlite::Connection,
        expected: &MigrationState,
    ) -> anyhow::Result<Self> {
        let store = PoolMigrations::for_account(store_conn, account)
            .map_err(|e| anyhow!("opening the account-scoped migration store failed: {e}"))?;
        let canonical = store
            .get_migration()
            .map_err(|e| anyhow!("migration store read failed for delivery rebuild: {e}"))?
            .ok_or_else(|| anyhow!("no canonical migration exists for delivery rebuild"))?;
        if &canonical != expected {
            return Err(anyhow!(
                "the delivery rebuild capability belongs to a stale canonical migration"
            ));
        }
        let owners = store
            .migration_lock_owners()
            .map_err(|e| anyhow!("migration lock-owner read failed for delivery rebuild: {e}"))?;
        let owner = match owner_recovery(Some(canonical.status()), &owners)? {
            OwnerRecovery::Existing(owner) => owner,
            OwnerRecovery::None | OwnerRecovery::Bootstrap => {
                return Err(anyhow!(
                    "delivery-owned rebuild requires one existing canonical input-lock owner"
                ));
            }
        };
        Ok(Self {
            wallet,
            account,
            usk,
            store,
            owner: Some(owner),
            canonical: Some(canonical),
        })
    }

    /// Constructs the read-only wallet half of a successor-rollover build.
    ///
    /// The upstream commit functions require a `PoolMigrationWrite`, but a rollover must not
    /// replace the predecessor through that generic seam. [`SuccessorCandidateBackend`] therefore
    /// delegates only wallet reads and cryptography to this adapter and captures the built state
    /// in memory. This constructor proves the opaque predecessor's exact canonical state is still
    /// current and recovers its existing lock owner without refreshing locks or writing anything.
    fn for_successor_candidate(
        wallet: &'a MigrationWallet,
        account: AccountUuid,
        usk: Option<UnifiedSpendingKey>,
        store_conn: &'a mut rusqlite::Connection,
        expected_predecessor: &MigrationState,
    ) -> anyhow::Result<Self> {
        if !expected_predecessor.is_terminal() {
            return Err(anyhow!(
                "a successor rollover requires a terminal canonical predecessor"
            ));
        }
        let store = PoolMigrations::for_account(store_conn, account)
            .map_err(|e| anyhow!("opening the account-scoped migration store failed: {e}"))?;
        let canonical = store
            .get_migration()
            .map_err(|e| anyhow!("migration store read failed for successor rollover: {e}"))?
            .ok_or_else(|| anyhow!("no canonical predecessor exists for successor rollover"))?;
        if &canonical != expected_predecessor {
            return Err(anyhow!(
                "the successor-rollover capability belongs to a stale canonical predecessor"
            ));
        }
        let owners = store
            .migration_lock_owners()
            .map_err(|e| anyhow!("migration lock-owner read failed for successor rollover: {e}"))?;
        let owner = match owner_recovery(Some(canonical.status()), &owners)? {
            OwnerRecovery::None => None,
            OwnerRecovery::Existing(owner) => Some(owner),
            OwnerRecovery::Bootstrap => {
                return Err(anyhow!(
                    "terminal successor-rollover predecessor unexpectedly requires lock bootstrap"
                ));
            }
        };
        Ok(Self {
            wallet,
            account,
            usk,
            store,
            owner,
            canonical: Some(canonical),
        })
    }

    /// Returns the current migration's durable lock owner, failing closed when a delivery path is
    /// invoked without one. New migrations generate their owner lazily at the first atomic persist;
    /// provisional Complete retains its owner, while Failed and finalized Complete are ownerless.
    pub(crate) fn required_lock_owner(&self) -> anyhow::Result<LockOwner> {
        self.owner
            .ok_or_else(|| anyhow!("the active migration has no durable input-lock owner"))
    }

    fn owner_for_persist(&mut self) -> LockOwner {
        match self.owner {
            Some(owner) => owner,
            None => {
                let owner = LockOwner::random(&mut OsRng);
                self.owner = Some(owner);
                owner
            }
        }
    }

    /// The target height for note selection (the chain tip plus one).
    fn selection_target(&self) -> anyhow::Result<TargetHeight> {
        let tip = self
            .wallet
            .chain_height()
            .map_err(|e| anyhow!("chain height lookup failed: {e}"))?
            .ok_or_else(|| anyhow!("the wallet has no chain tip yet; sync first"))?;
        Ok(TargetHeight::from(u32::from(tip) + 1))
    }

    fn spendable_orchard_notes_with_policy(
        &self,
        policy: &LockedInputPolicy,
    ) -> anyhow::Result<Vec<SpendableNote>> {
        let target = self.selection_target()?;
        let received = self
            .wallet
            .select_unspent_notes(
                self.account,
                &[ShieldedPool::Orchard],
                target,
                &[],
                LockFilter::Policy(policy),
            )
            .map_err(|e| anyhow!("spendable-note selection failed: {e}"))?;
        let mut notes: Vec<SpendableNote> = received
            .orchard()
            .iter()
            .map(|rn| {
                let note = *rn.note();
                let value = note.value().inner();
                (note, rn.note_commitment_tree_position(), value)
            })
            .collect();
        notes.sort_by_key(|(_, pos, _)| *pos);
        Ok(notes)
    }

    /// The account's Orchard notes available to the migration as `(note, tree position, value)`,
    /// sorted by tree position so the engine's value index and note index remain identical.
    ///
    /// A new migration has no owner and uses ordinary `Exclude` selection. An active migration
    /// must admit the exact notes it already reserved, otherwise expiry rebuilding would hide its
    /// own funding note and incorrectly report `FundingNoteUnavailable`; `PreferLocked` admits only
    /// the recovered owner (never a foreign flow's lock) before falling back to unlocked notes.
    pub(crate) fn spendable_orchard_notes(&self) -> anyhow::Result<Vec<SpendableNote>> {
        let policy = self.owner.map_or(LockedInputPolicy::Exclude, |owner| {
            LockedInputPolicy::PreferLocked(NonEmptyBTreeSet::singleton(owner))
        });
        self.spendable_orchard_notes_with_policy(&policy)
    }

    /// Orchard value available to an ordinary transaction, excluding every active lock. Progress
    /// reporting uses this rather than the migration-owned override above.
    pub(crate) fn ordinarily_spendable_orchard_note_values(&self) -> anyhow::Result<Vec<Zatoshis>> {
        self.spendable_orchard_notes_with_policy(&LockedInputPolicy::Exclude)?
            .into_iter()
            .enumerate()
            .map(|(i, (_, _, value))| {
                Zatoshis::from_u64(value)
                    .map_err(|_| anyhow!("spendable note {i} has an out-of-range value"))
            })
            .collect()
    }

    /// Re-audits and, when ready, atomically finalizes a chain-observed Complete migration.
    ///
    /// Rust derives every canonical `(txid, Ironwood action 0, transfer value)` tuple from the
    /// stored PCZTs and state. A provisional Complete retains `self.owner`; only strict success
    /// clears that owner and the remaining locks. An already-finalized ownerless Complete is
    /// re-audited without rewriting state, so pending spends and reorgs still fail closed.
    pub(crate) fn finalize_completed_migration(
        &mut self,
        target_height: TargetHeight,
    ) -> anyhow::Result<bool> {
        let policy = self.owner.map_or(LockedInputPolicy::Exclude, |owner| {
            LockedInputPolicy::PreferLocked(NonEmptyBTreeSet::singleton(owner))
        });
        match finalize_completed_migration(
            &mut self.store,
            target_height,
            ConfirmationsPolicy::default(),
            LockFilter::Policy(&policy),
        )
        .map_err(|e| anyhow!("finalizing exact migration outputs failed: {e}"))?
        {
            MigrationCompletion::Pending(_) => Ok(false),
            MigrationCompletion::SpendablePendingFinality(_) => Ok(true),
            MigrationCompletion::Finalized(state) => {
                self.owner = None;
                self.canonical = Some(state);
                Ok(true)
            }
        }
    }

    /// The account's Orchard full viewing key, from its STORED unified full viewing key (not the
    /// spending key), so read/plan/build paths work for accounts whose spending key never exists
    /// on this device (an imported hardware-wallet account).
    pub(crate) fn stored_orchard_fvk(&self) -> anyhow::Result<FullViewingKey> {
        let account = self
            .wallet
            .get_account(self.account)
            .map_err(|e| anyhow!("account lookup failed: {e}"))?
            .ok_or_else(|| anyhow!("unknown account"))?;
        let ufvk = account
            .ufvk()
            .ok_or_else(|| anyhow!("the account has no unified full viewing key"))?;
        ufvk.orchard()
            .cloned()
            .ok_or_else(|| anyhow!("the account's viewing key has no Orchard component"))
    }
}

/// A deliberately non-persistent adapter for deriving a rollover successor with the exact
/// upstream planner/commit implementation.
///
/// `LockedWalletMigration` cannot represent a view-only external signer because it requires a
/// `UnifiedSpendingKey`. This narrow wrapper retains the SDK adapter's stored-UFVK/optional-USK
/// support, while replacing its generic persistence implementation with a one-write in-memory
/// sink. The resulting state can reach SQLite only through
/// `MigrationRuntimeStore::rollover_source_reservations`, which generates the new run, source
/// reservation owner, and canonical lock owner atomically while retaining predecessor evidence.
pub(crate) struct SuccessorCandidateBackend<'a> {
    source: Backend<'a>,
    candidate: Option<MigrationState>,
}

impl<'a> SuccessorCandidateBackend<'a> {
    pub(crate) fn new(
        wallet: &'a MigrationWallet,
        account: AccountUuid,
        usk: Option<UnifiedSpendingKey>,
        store_conn: &'a mut rusqlite::Connection,
        expected_predecessor: &MigrationState,
    ) -> anyhow::Result<Self> {
        Ok(Self {
            source: Backend::for_successor_candidate(
                wallet,
                account,
                usk,
                store_conn,
                expected_predecessor,
            )?,
            candidate: None,
        })
    }
}

impl MigrationBackend for SuccessorCandidateBackend<'_> {
    type Error = anyhow::Error;

    fn spendable_orchard_note_values(&self) -> Result<Vec<Zatoshis>, Self::Error> {
        MigrationBackend::spendable_orchard_note_values(&self.source)
    }

    fn chain_tip_height(&self) -> Result<BlockHeight, Self::Error> {
        MigrationBackend::chain_tip_height(&self.source)
    }
}

impl MigrationCrypto for SuccessorCandidateBackend<'_> {
    type Error = anyhow::Error;

    fn orchard_fvk(&self) -> Result<FullViewingKey, Self::Error> {
        MigrationCrypto::orchard_fvk(&self.source)
    }

    fn resolve_wallet_note(&self, index: usize) -> Result<OrchardNote, Self::Error> {
        MigrationCrypto::resolve_wallet_note(&self.source, index)
    }

    fn sign(&self, pczt: pczt::Pczt) -> Result<pczt::Pczt, Self::Error> {
        MigrationCrypto::sign(&self.source, pczt)
    }
}

impl PoolMigrationRead for SuccessorCandidateBackend<'_> {
    type Error = anyhow::Error;

    fn get_migration(&self) -> Result<Option<MigrationState>, Self::Error> {
        Ok(self.candidate.clone())
    }
}

impl PoolMigrationWrite for SuccessorCandidateBackend<'_> {
    fn replace_migration(&mut self, state: &MigrationState) -> Result<(), Self::Error> {
        if self.candidate.is_some() {
            return Err(anyhow!(
                "successor candidate adapter permits exactly one in-memory canonical write"
            ));
        }
        self.candidate = Some(state.clone());
        Ok(())
    }

    fn update_transaction(
        &mut self,
        _id: MigrationTxId,
        _state: MigrationTxState,
    ) -> Result<(), Self::Error> {
        Err(anyhow!(
            "successor candidate adapter does not grant lifecycle mutation authority"
        ))
    }
}

impl MigrationBackend for Backend<'_> {
    type Error = anyhow::Error;

    fn spendable_orchard_note_values(&self) -> Result<Vec<Zatoshis>, Self::Error> {
        self.spendable_orchard_notes()?
            .into_iter()
            .enumerate()
            .map(|(i, (_, _, value))| {
                Zatoshis::from_u64(value)
                    .map_err(|_| anyhow!("spendable note {i} has an out-of-range value"))
            })
            .collect()
    }

    fn chain_tip_height(&self) -> Result<BlockHeight, Self::Error> {
        self.wallet
            .chain_height()
            .map_err(|e| anyhow!("chain height lookup failed: {e}"))?
            .ok_or_else(|| anyhow!("the wallet has no chain tip yet; sync first"))
    }
}

impl MigrationCrypto for Backend<'_> {
    type Error = anyhow::Error;

    fn orchard_fvk(&self) -> Result<FullViewingKey, Self::Error> {
        self.stored_orchard_fvk()
    }

    fn resolve_wallet_note(&self, index: usize) -> Result<OrchardNote, Self::Error> {
        let notes = self.spendable_orchard_notes()?;
        let &(note, _, _) = notes
            .get(index)
            .ok_or_else(|| anyhow!("no spendable note at index {index}"))?;
        Ok(note)
    }

    fn sign(&self, pczt: pczt::Pczt) -> Result<pczt::Pczt, Self::Error> {
        let usk = self
            .usk
            .as_ref()
            .ok_or_else(|| anyhow!("signing requires the account's spending key"))?;
        let ask = SpendAuthorizingKey::from(usk.orchard());
        sign_pczt(pczt, &ask).map_err(|e| anyhow!("signing the migration failed: {e}"))
    }
}

impl PoolMigrationRead for Backend<'_> {
    type Error = anyhow::Error;

    fn get_migration(&self) -> Result<Option<MigrationState>, Self::Error> {
        Ok(self.canonical.clone())
    }
}

impl PoolMigrationWrite for Backend<'_> {
    fn replace_migration(&mut self, state: &MigrationState) -> Result<(), Self::Error> {
        // Every replacement goes through the lock-aware whole-state CAS boundary. In particular,
        // demoting an already-finalized Complete after a reorg starts ownerless, generates a fresh
        // owner here, and can only persist against the exact Complete state this backend read.
        let owner = self.owner_for_persist();
        let orchard_fvk = self.stored_orchard_fvk()?;
        let persisted = persist_migration_with_locks(
            self.wallet,
            self.account,
            &orchard_fvk,
            &mut self.store,
            owner,
            self.canonical.as_ref(),
            state,
        )
        .map_err(|e| anyhow!("migration store and input-lock write failed: {e}"))?;
        if matches!(persisted.status(), MigrationStatus::Failed) {
            self.owner = None;
        }
        self.canonical = Some(persisted);
        Ok(())
    }

    fn update_transaction(
        &mut self,
        id: MigrationTxId,
        state: MigrationTxState,
    ) -> Result<(), Self::Error> {
        let owner = self.required_lock_owner()?;
        let orchard_fvk = self.stored_orchard_fvk()?;
        let expected = self
            .canonical
            .as_ref()
            .ok_or_else(|| anyhow!("no canonical migration exists to update"))?;
        let persisted = update_migration_transaction_with_locks(
            self.wallet,
            self.account,
            &orchard_fvk,
            &mut self.store,
            owner,
            expected,
            id,
            state,
        )
        .map_err(|e| anyhow!("migration store and input-lock update failed: {e}"))?;
        if matches!(persisted.status(), MigrationStatus::Failed) {
            self.owner = None;
        }
        self.canonical = Some(persisted);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn owner(byte: u8) -> LockOwner {
        LockOwner::new([byte; 32])
    }

    #[test]
    fn provisional_complete_recovers_its_single_owner() {
        let expected = owner(1);
        assert_eq!(
            owner_recovery(Some(MigrationStatus::Complete), &BTreeSet::from([expected]),).unwrap(),
            OwnerRecovery::Existing(expected),
        );
    }

    #[test]
    fn finalized_complete_remains_ownerless_for_reaudit() {
        assert_eq!(
            owner_recovery(Some(MigrationStatus::Complete), &BTreeSet::new()).unwrap(),
            OwnerRecovery::None,
        );
    }

    #[test]
    fn finalized_complete_demoted_by_reorg_bootstraps_a_new_owner() {
        // Reconciliation changes Complete to InProgress before whole-state persistence. With the
        // finalized state's owner already cleared, that exact combination selects CAS bootstrap.
        assert_eq!(
            owner_recovery(Some(MigrationStatus::InProgress), &BTreeSet::new()).unwrap(),
            OwnerRecovery::Bootstrap,
        );
    }

    #[test]
    fn ambiguous_complete_owners_fail_closed() {
        let error = owner_recovery(
            Some(MigrationStatus::Complete),
            &BTreeSet::from([owner(1), owner(2)]),
        )
        .unwrap_err();
        assert!(error.to_string().contains("2 distinct lock owners"));
    }

    #[test]
    fn existing_owner_restart_refreshes_pending_locks_through_cas() {
        // This source-level wiring guard complements the wallet crate's behavioral restart test.
        // It prevents the SDK adapter from regressing to merely recovering the durable owner token
        // without reacquiring exact pending input locks that expired or disappeared across a crash.
        let source = include_str!("migration_engine.rs");
        let branch = source
            .split_once("OwnerRecovery::Existing(owner) => {")
            .expect("existing-owner recovery branch must exist")
            .1
            .split_once("OwnerRecovery::Bootstrap => {")
            .map(|(branch, _)| branch)
            .expect("existing-owner recovery branch must be isolatable");

        assert!(
            branch.contains("persist_migration_with_locks("),
            "restart recovery must reacquire exact pending locks"
        );
        assert!(
            branch.contains("Some(state),") && branch.contains("\n                    state,"),
            "restart lock refresh must compare and persist the same canonical state through CAS"
        );
        assert!(
            branch.find("persist_migration_with_locks(")
                < branch.find("backend.owner = Some(owner)"),
            "the backend must not expose the recovered owner before lock refresh succeeds"
        );
    }
}
