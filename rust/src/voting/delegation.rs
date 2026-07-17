use std::ffi::CString;
use std::panic::AssertUnwindSafe;
use std::sync::Arc;

use anyhow::anyhow;
use ff::PrimeField;
use ffi_helpers::panic::catch_panic;
use incrementalmerkletree::Position;
use pasta_curves::pallas;
use prost::Message;
use zcash_client_backend::proto::service::TreeState;
use zcash_voting::{self as voting, zkp1};

use crate::{unwrap_exc_or, unwrap_exc_or_null};

use super::constants::{
    CANONICAL_FIELD_LEN, PIR_NULLIFIER_BOUNDS_LEN, PIR_NULLIFIER_LEN, PIR_PATH_ELEMENT_COUNT,
    PIR_PATH_LEN, PIR_ROOT_LEN,
};
use super::db::VotingDatabaseHandle;
use super::ffi_types::{FfiBundleSetupResult, FfiVotingHotkey};
use super::helpers::{bytes_from_ptr, json_to_boxed_slice, open_wallet_db, str_from_ptr};
use super::json::{
    JsonDelegationPirPrecomputeResult, JsonDelegationProofResult, JsonDelegationSubmission,
    JsonNoteInfo, JsonWitnessData,
};
use super::progress::ProgressBridge;

/// Wallet-derived delegation inputs assembled for one FFI call.
///
/// zcash_voting 1.0 derives delegation keys and selects snapshot-eligible
/// notes from the wallet database itself (the crate owns note selection and
/// key material shaping), so the delegation lanes take the wallet DB path and
/// account UUID instead of caller-supplied note/key blobs.
unsafe fn gather_ffi_delegation_inputs(
    handle: &VotingDatabaseHandle,
    round_id: &str,
    wallet_db_data: *const u8,
    wallet_db_data_len: usize,
    account_uuid: *const u8,
    account_uuid_len: usize,
    hotkey_secret: *const u8,
    hotkey_secret_len: usize,
    round_name: &str,
) -> anyhow::Result<voting::selection::DelegationWalletInputs> {
    let account_uuid_str = unsafe { str_from_ptr(account_uuid, account_uuid_len) }?;
    let secret = unsafe { bytes_from_ptr(hotkey_secret, hotkey_secret_len) }?;
    let hotkey = voting::types::VotingHotkey::from_stored_secret(secret, handle.network)
        .map_err(|e| anyhow!("invalid voting hotkey material: {}", e))?;

    let state = handle
        .db
        .get_round_state(round_id)
        .map_err(|e| anyhow!("round not found: {}", e))?;
    let anchor_tree_state_bytes = voting::storage::queries::load_tree_state(
        &handle.db.conn(),
        round_id,
        &handle.db.wallet_id(),
    )
    .map_err(|e| {
        anyhow!("no tree state stored for round {round_id} — call store_tree_state first ({e})")
    })?;

    use zcash_client_backend::data_api::WalletRead as _;
    let network_params = crate::parse_network(handle.network_id)?;
    let wallet_db =
        unsafe { crate::wallet_db(wallet_db_data, wallet_db_data_len, network_params) }?;
    let scanned_height = match wallet_db
        .get_wallet_summary(zcash_client_backend::data_api::wallet::ConfirmationsPolicy::default())
        .map_err(|e| anyhow!("wallet summary lookup failed: {}", e))?
    {
        Some(summary) => u32::from(summary.fully_scanned_height()) as u64,
        None => 0,
    };

    voting::selection::gather_delegation_wallet_inputs(
        voting::selection::GatherDelegationWalletParams {
            wallet_db: &wallet_db,
            account_uuid: &account_uuid_str,
            voting_hotkey: &hotkey,
            snapshot_height: state.snapshot_height,
            scanned_height,
            anchor_tree_state_bytes,
            resolved_round_name: round_name.to_string(),
        },
    )
    .map_err(|e| anyhow!("failed to gather delegation wallet inputs: {}", e))
}

/// JSON shape for the delegation PCZT setup result (zcash_voting 1.0).
#[derive(serde::Serialize)]
struct JsonDelegationSetup {
    pczt_bytes: Vec<u8>,
    pczt_sighash: Vec<u8>,
    rk: Vec<u8>,
    action_index: u32,
    action_bytes: Vec<u8>,
}

/// Address-encoding constants for a voting network (regtest reuses testnet
/// HRPs, matching the wallet-side custom-network convention).
fn hotkey_network_params(network: voting::types::Network) -> zcash_protocol::consensus::Network {
    match network {
        voting::types::Network::Mainnet => zcash_protocol::consensus::Network::MainNetwork,
        voting::types::Network::Testnet | voting::types::Network::Regtest => {
            zcash_protocol::consensus::Network::TestNetwork
        }
    }
}

/// Validate that a cached lightwalletd `TreeState` is anchored to the voting
/// round it will be used for.
///
/// Witness generation trusts the cached Orchard frontier as the historical
/// checkpoint input. The generated Merkle path can verify against that
/// frontier's own root, so we must also enforce that the frontier is exactly
/// the round snapshot: same block height and same note commitment tree root.
fn validate_cached_tree_state_for_round(
    tree_state: &TreeState,
    orchard_root: &[u8],
    params: &voting::VotingRoundParams,
) -> anyhow::Result<()> {
    if tree_state.height != params.snapshot_height {
        return Err(anyhow!(
            "cached TreeState height {} does not match round snapshot_height {}",
            tree_state.height,
            params.snapshot_height
        ));
    }

    if orchard_root != params.nc_root.as_slice() {
        return Err(anyhow!(
            "cached TreeState orchard root does not match round nc_root"
        ));
    }

    Ok(())
}

// =============================================================================
// VotingDatabase methods — Delegation proof
// =============================================================================

/// Generate or reconstruct an app-owned voting hotkey.
///
/// zcash_voting 1.0 uses app-owned hotkeys. Pass an empty `stored_secret` to
/// generate a fresh random hotkey, or a previously stored 64-byte secret to
/// deterministically reconstruct the same hotkey; any other length is an
/// error. The caller must persist `secret_key` (the stored secret) — it is
/// the only way to reconstruct the hotkey.
///
/// Returns a pointer to `FfiVotingHotkey` on success, or null on error.
/// Call `zcashlc_voting_free_hotkey` to free the returned pointer.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_generate_hotkey(
    db: *mut VotingDatabaseHandle,
    stored_secret: *const u8,
    stored_secret_len: usize,
) -> *mut FfiVotingHotkey {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let stored_secret = unsafe { bytes_from_ptr(stored_secret, stored_secret_len) }?;

        let hotkey = if stored_secret.is_empty() {
            voting::hotkey::generate_random_voting_hotkey(handle.network)
                .map_err(|e| anyhow!("generate_hotkey failed: {}", e))?
        } else {
            voting::types::VotingHotkey::from_stored_secret(stored_secret, handle.network)
                .map_err(|e| anyhow!("invalid voting hotkey material: {}", e))?
        };

        let orchard_addr = orchard::Address::from_raw_address_bytes(hotkey.raw_orchard_address());
        let orchard_addr = Option::from(orchard_addr)
            .ok_or_else(|| anyhow!("generated hotkey address bytes are invalid"))?;
        let ua =
            zcash_keys::address::UnifiedAddress::from_receivers(Some(orchard_addr), None, None)
                .ok_or_else(|| anyhow!("failed to assemble hotkey unified address"))?;
        let encoded =
            zcash_keys::address::Address::from(ua).encode(&hotkey_network_params(handle.network));

        let (sk_ptr, sk_len) = crate::ptr_from_vec(hotkey.stored_secret().to_vec());
        let (pk_ptr, pk_len) = crate::ptr_from_vec(hotkey.raw_orchard_address().to_vec());
        let address = CString::new(encoded)
            .map_err(|e| anyhow!("invalid hotkey address string: {}", e))?
            .into_raw();
        Ok(Box::into_raw(Box::new(FfiVotingHotkey {
            secret_key: sk_ptr,
            secret_key_len: sk_len,
            public_key: pk_ptr,
            public_key_len: pk_len,
            address,
        })))
    });
    unwrap_exc_or_null(res)
}

/// Set up note bundles for a voting round.
///
/// `notes_json` is a JSON-encoded `Vec<NoteInfo>`. Bundle packing follows the
/// crate-owned policy (denomination-aware thresholds), and re-running with the
/// same notes is idempotent.
///
/// Returns a pointer to `FfiBundleSetupResult` on success, or null on error.
/// Call `zcashlc_voting_free_bundle_setup_result` to free the returned pointer.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_setup_bundles(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    notes_json: *const u8,
    notes_json_len: usize,
) -> *mut FfiBundleSetupResult {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let notes_bytes = unsafe { bytes_from_ptr(notes_json, notes_json_len) }?;
        let json_notes: Vec<JsonNoteInfo> = serde_json::from_slice(notes_bytes)?;
        let core_notes: Vec<voting::NoteInfo> = json_notes.into_iter().map(Into::into).collect();

        let layout = handle
            .db
            .ensure_bundles_with_skipped_suffix_with_policy(
                &round_id_str,
                &core_notes,
                voting::BundlePolicy::default(),
            )
            .map_err(|e| anyhow!("setup_bundles failed: {}", e))?;

        Ok(Box::into_raw(Box::new(FfiBundleSetupResult {
            bundle_count: layout.bundle_count,
            eligible_weight: layout.eligible_weight,
        })))
    });
    unwrap_exc_or_null(res)
}

/// Get the number of bundles for a round.
///
/// Returns the bundle count on success, or -1 on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_bundle_count(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
) -> i64 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;

        let count = handle
            .db
            .get_bundle_count(&round_id_str)
            .map_err(|e| anyhow!("get_bundle_count failed: {}", e))?;
        Ok(count as i64)
    });
    unwrap_exc_or(res, -1)
}

/// Build the governance PCZT for one delegation bundle.
///
/// zcash_voting 1.0 selects snapshot-eligible notes and shapes key material
/// from the wallet database itself, so this takes the wallet DB path and
/// account UUID plus the app-owned hotkey stored secret.
///
/// Returns JSON-encoded `JsonDelegationSetup` as `*mut FfiBoxedSlice`, or null on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - For every `(ptr, len)` byte argument, if `len > 0` then `ptr` must be
///   non-null and valid for reads for `len` bytes; if `len == 0`, `ptr` is ignored.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_build_pczt(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    wallet_db_data: *const u8,
    wallet_db_data_len: usize,
    account_uuid: *const u8,
    account_uuid_len: usize,
    hotkey_secret: *const u8,
    hotkey_secret_len: usize,
    round_name: *const u8,
    round_name_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let round_name_str = unsafe { str_from_ptr(round_name, round_name_len) }?;

        let inputs = unsafe {
            gather_ffi_delegation_inputs(
                handle,
                &round_id_str,
                wallet_db_data,
                wallet_db_data_len,
                account_uuid,
                account_uuid_len,
                hotkey_secret,
                hotkey_secret_len,
                &round_name_str,
            )
        }?;
        let state = handle
            .db
            .get_round_state(&round_id_str)
            .map_err(|e| anyhow!("round not found: {}", e))?;
        let branch_ids = voting::delegate::LightwalletdBranchIdProvider::for_height(
            handle.network,
            state.snapshot_height,
        )
        .map_err(|e| anyhow!("failed to resolve consensus branch id: {}", e))?;

        let setup = voting::delegate::setup(
            &handle.db,
            &round_id_str,
            bundle_index,
            &inputs.round_note_infos,
            &inputs.delegation_keys,
            &branch_ids,
            &voting::NoopProgressReporter,
        )
        .map_err(|e| anyhow!("build_pczt failed: {}", e))?;

        json_to_boxed_slice(&JsonDelegationSetup {
            pczt_bytes: setup.pczt_bytes,
            pczt_sighash: setup.pczt_sighash.to_vec(),
            rk: setup.rk.to_vec(),
            action_index: setup.action_index as u32,
            action_bytes: setup.action_bytes,
        })
    });
    unwrap_exc_or_null(res)
}

/// Store a tree state for witness generation.
///
/// Returns 0 on success, -1 on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_store_tree_state(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    tree_state_bytes: *const u8,
    tree_state_bytes_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let ts_bytes = unsafe { bytes_from_ptr(tree_state_bytes, tree_state_bytes_len) }?;

        handle
            .db
            .store_tree_state(&round_id_str, ts_bytes)
            .map_err(|e| anyhow!("store_tree_state failed: {}", e))?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Generate Merkle inclusion witnesses for the notes in a bundle and cache
/// them in the voting DB.
///
/// `notes_json` is a JSON-encoded `Vec<NoteInfo>`.
///
/// Returns JSON-encoded `Vec<WitnessData>` as `*mut FfiBoxedSlice`, or null on
/// error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - For every `(ptr, len)` byte argument (`round_id`, `wallet_db_path`,
///   `notes_json`): if `len > 0` then `ptr` must be non-null and valid for
///   reads for `len` bytes; if `len == 0`, `ptr` is ignored. An empty
///   `notes_json` is treated as the empty notes list (JSON is not parsed),
///   and produces an empty witness list.
/// - `network_id` must be `0` (testnet) or `1` (mainnet), matching other
///   `zcashlc_*` FFI.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_generate_note_witnesses(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    wallet_db_path: *const u8,
    wallet_db_path_len: usize,
    notes_json: *const u8,
    notes_json_len: usize,
    network_id: u32,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let wallet_path_str = unsafe { str_from_ptr(wallet_db_path, wallet_db_path_len) }?;
        let wallet_db = open_wallet_db(&wallet_path_str, network_id)?;
        let notes_bytes = unsafe { bytes_from_ptr(notes_json, notes_json_len) }?;
        let json_notes: Vec<JsonNoteInfo> = if notes_bytes.is_empty() {
            Vec::new()
        } else {
            serde_json::from_slice(notes_bytes)?
        };
        let core_notes: Vec<voting::NoteInfo> = json_notes.into_iter().map(Into::into).collect();

        let (tree_state_bytes, params) = {
            let wallet_id = handle.db.wallet_id();
            let conn = handle.db.conn();
            let tree_state_bytes =
                voting::storage::queries::load_tree_state(&conn, &round_id_str, &wallet_id)
                    .map_err(|e| anyhow!("load_tree_state failed: {}", e))?;
            let params =
                voting::storage::queries::load_round_params(&conn, &round_id_str, &wallet_id)
                    .map_err(|e| anyhow!("load_round_params failed: {}", e))?;
            (tree_state_bytes, params)
        };

        // Decode the tree state
        let tree_state = TreeState::decode(tree_state_bytes.as_slice())
            .map_err(|e| anyhow!("failed to decode TreeState protobuf: {}", e))?;
        let orchard_ct = tree_state
            .orchard_tree()
            .map_err(|e| anyhow!("failed to parse orchard tree from TreeState: {}", e))?;
        let frontier_root = orchard_ct.root();
        let frontier_root_bytes = frontier_root.to_bytes();
        validate_cached_tree_state_for_round(&tree_state, &frontier_root_bytes[..], &params)?;
        let frontier = orchard_ct.to_frontier();
        let nonempty_frontier = frontier.take().ok_or_else(|| {
            anyhow!("empty orchard frontier — no orchard activity at snapshot height")
        })?;

        // Convert note positions to Merkle positions
        let positions: Vec<Position> = core_notes
            .iter()
            .map(|n| Position::from(n.position))
            .collect();

        // `BlockHeight` is u32-backed; `snapshot_height` is u64. A wallet that
        // somehow synced past u32::MAX blocks is impossible in protocol terms,
        // but reject it explicitly rather than silently truncating.
        let snapshot_height = u32::try_from(params.snapshot_height).map_err(|_| {
            anyhow!(
                "snapshot_height {} does not fit in u32",
                params.snapshot_height
            )
        })?;
        let checkpoint_height = zcash_protocol::consensus::BlockHeight::from_u32(snapshot_height);

        // Generate witnesses from wallet DB shard data + frontier
        let merkle_paths = wallet_db
            .generate_orchard_witnesses_at_historical_height(
                &positions,
                nonempty_frontier,
                checkpoint_height,
            )
            .map_err(|e| {
                anyhow!(
                    "generate_orchard_witnesses_at_historical_height failed: {}",
                    e
                )
            })?;

        if merkle_paths.len() != core_notes.len() {
            return Err(anyhow!(
                "generated {} Merkle paths for {} notes",
                merkle_paths.len(),
                core_notes.len()
            ));
        }

        // Convert MerklePaths to WitnessData
        let root_bytes = frontier_root_bytes.to_vec();
        let witnesses: Vec<voting::WitnessData> = merkle_paths
            .into_iter()
            .zip(core_notes.iter())
            .map(|(path, note)| {
                let auth_path: Vec<Vec<u8>> = path
                    .path_elems()
                    .iter()
                    .map(|h| h.to_bytes().to_vec())
                    .collect();
                voting::WitnessData {
                    note_commitment: note.commitment.clone(),
                    position: note.position,
                    root: root_bytes.clone(),
                    auth_path,
                }
            })
            .collect();

        // Verify and cache in voting DB
        handle
            .db
            .store_witnesses(&round_id_str, bundle_index, &witnesses)
            .map_err(|e| anyhow!("store_witnesses failed: {}", e))?;

        let json_witnesses: Vec<JsonWitnessData> = witnesses.into_iter().map(Into::into).collect();
        json_to_boxed_slice(&json_witnesses)
    });
    unwrap_exc_or_null(res)
}

// Keep PIR client construction at the SDK boundary so zcash_voting can accept
// an injected transport. Today we use direct Hyper/Rustls. In the future this will be the
// single place to add a Tor-backed transport based on SDK configuration.
fn connect_pir_client(pir_url: &str) -> anyhow::Result<voting::PirClientBlocking> {
    voting::PirClientBlocking::with_transport(pir_url, Arc::new(voting::HyperTransport::new()))
        .map_err(|e| anyhow!("connect to PIR server failed: {}", e))
}

/// Precompute PIR-backed nullifier data for one delegation bundle.
///
/// Witnesses must already be stored (generate_note_witnesses). Returns
/// JSON-encoded `JsonDelegationPirPrecomputeResult`, or null on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - For every `(ptr, len)` byte argument, if `len > 0` then `ptr` must be
///   non-null and valid for reads for `len` bytes; if `len == 0`, `ptr` is ignored.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_precompute_delegation_pir(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    notes_json: *const u8,
    notes_json_len: usize,
    pir_server_url: *const u8,
    pir_server_url_len: usize,
    network_id: u32,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let _ = network_id;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let notes_bytes = unsafe { bytes_from_ptr(notes_json, notes_json_len) }?;
        let json_notes: Vec<JsonNoteInfo> = serde_json::from_slice(notes_bytes)?;
        let core_notes: Vec<voting::NoteInfo> = json_notes.into_iter().map(Into::into).collect();
        let pir_url = unsafe { str_from_ptr(pir_server_url, pir_server_url_len) }?;

        let pir_client = voting::PirClientBlocking::with_transport(
            &pir_url,
            std::sync::Arc::new(voting::HyperTransport::new()),
        )
        .map_err(|e| anyhow!("failed to connect to PIR server: {}", e))?;

        handle
            .db
            .ensure_padded_secrets(&round_id_str, bundle_index, &core_notes)
            .map_err(|e| anyhow!("failed to initialize padded-note secrets: {}", e))?;
        let report = voting::precompute::delegation_pir(
            &handle.db,
            &round_id_str,
            bundle_index,
            &core_notes,
            &pir_client,
            handle.network,
        )
        .map_err(|e| anyhow!("precompute_delegation_pir failed: {}", e))?;

        json_to_boxed_slice(&JsonDelegationPirPrecomputeResult {
            cached_count: report.cached,
            fetched_count: report.fetched,
        })
    });
    unwrap_exc_or_null(res)
}

/// Generate and persist the delegation proof for one bundle.
///
/// Witnesses and PIR precompute data must already be present. zcash_voting
/// 1.0 shapes key material from the wallet database, so this takes the wallet
/// DB path, account UUID, and app-owned hotkey stored secret.
///
/// Returns JSON-encoded `JsonDelegationProofResult`, or null on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - For every `(ptr, len)` byte argument, if `len > 0` then `ptr` must be
///   non-null and valid for reads for `len` bytes; if `len == 0`, `ptr` is ignored.
/// - `progress_callback`/`progress_context` follow the same contract as
///   `zcashlc_voting_build_vote_commitment`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_build_and_prove_delegation(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    wallet_db_data: *const u8,
    wallet_db_data_len: usize,
    account_uuid: *const u8,
    account_uuid_len: usize,
    hotkey_secret: *const u8,
    hotkey_secret_len: usize,
    round_name: *const u8,
    round_name_len: usize,
    pir_server_url: *const u8,
    pir_server_url_len: usize,
    progress_callback: Option<unsafe extern "C" fn(f64, *mut std::ffi::c_void)>,
    progress_context: *mut std::ffi::c_void,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let progress_context = AssertUnwindSafe(progress_context);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let round_name_str = unsafe { str_from_ptr(round_name, round_name_len) }?;
        let pir_url = unsafe { str_from_ptr(pir_server_url, pir_server_url_len) }?;

        let inputs = unsafe {
            gather_ffi_delegation_inputs(
                handle,
                &round_id_str,
                wallet_db_data,
                wallet_db_data_len,
                account_uuid,
                account_uuid_len,
                hotkey_secret,
                hotkey_secret_len,
                &round_name_str,
            )
        }?;
        let pir_client = voting::PirClientBlocking::with_transport(
            &pir_url,
            std::sync::Arc::new(voting::HyperTransport::new()),
        )
        .map_err(|e| anyhow!("failed to connect to PIR server: {}", e))?;

        let reporter: Box<dyn voting::types::DelegationProgressReporter> = match progress_callback {
            Some(cb) => Box::new(ProgressBridge {
                callback: cb,
                context: *progress_context,
            }),
            None => Box::new(voting::NoopProgressReporter),
        };

        let proof = handle
            .db
            .build_and_prove_delegation(
                &round_id_str,
                bundle_index,
                &inputs.round_note_infos,
                &inputs.delegation_keys,
                &pir_client,
                reporter.as_ref(),
            )
            .map_err(|e| anyhow!("build_and_prove_delegation failed: {}", e))?;

        let json_proof: JsonDelegationProofResult = proof.into();
        json_to_boxed_slice(&json_proof)
    });
    unwrap_exc_or_null(res)
}

/// Assemble chain-ready delegation submission fields, signing locally.
///
/// The wallet seed never enters zcash_voting: the crate returns a signing
/// request (sighash + alpha + routing fingerprint), the SpendAuth signature is
/// produced here from the seed, and the signed submission is assembled from
/// stored proof state.
///
/// Returns JSON-encoded `JsonDelegationSubmission`, or null on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - For every `(ptr, len)` byte argument, if `len > 0` then `ptr` must be
///   non-null and valid for reads for `len` bytes; if `len == 0`, `ptr` is ignored.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_delegation_submission(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    wallet_db_data: *const u8,
    wallet_db_data_len: usize,
    account_uuid: *const u8,
    account_uuid_len: usize,
    hotkey_secret: *const u8,
    hotkey_secret_len: usize,
    round_name: *const u8,
    round_name_len: usize,
    sender_seed: *const u8,
    sender_seed_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let round_name_str = unsafe { str_from_ptr(round_name, round_name_len) }?;
        let seed = unsafe { bytes_from_ptr(sender_seed, sender_seed_len) }?;
        if seed.len() < 32 {
            return Err(anyhow!("sender_seed must be at least 32 bytes"));
        }

        let inputs = unsafe {
            gather_ffi_delegation_inputs(
                handle,
                &round_id_str,
                wallet_db_data,
                wallet_db_data_len,
                account_uuid,
                account_uuid_len,
                hotkey_secret,
                hotkey_secret_len,
                &round_name_str,
            )
        }?;
        let request = voting::delegate::signing_request(
            &handle.db,
            &round_id_str,
            bundle_index,
            &inputs.delegation_keys,
        )
        .map_err(|e| anyhow!("failed to load delegation signing request: {}", e))?;

        let fingerprint = zip32::fingerprint::SeedFingerprint::from_seed(seed)
            .ok_or_else(|| anyhow!("sender seed length is not valid for ZIP-32"))?;
        if fingerprint.to_bytes() != request.seed_fingerprint {
            return Err(anyhow!(
                "sender seed fingerprint does not match the delegation signing request"
            ));
        }
        let account = zip32::AccountId::try_from(request.account_index)
            .map_err(|_| anyhow!("invalid account_index {}", request.account_index))?;
        let usk = zcash_keys::keys::UnifiedSpendingKey::from_seed(&request.network, seed, account)
            .map_err(|e| anyhow!("failed to derive account spending key: {}", e))?;
        let ask = orchard::keys::SpendAuthorizingKey::from(usk.orchard());
        let alpha = Option::<pasta_curves::pallas::Scalar>::from(
            pasta_curves::pallas::Scalar::from_repr(request.alpha),
        )
        .ok_or_else(|| anyhow!("delegation alpha is not a valid Pallas scalar"))?;
        let rsk = ask.randomize(&alpha);
        let sig: [u8; 64] = (&rsk.sign(&mut rand::rngs::OsRng, &request.sighash)).into();

        let data = handle
            .db
            .get_delegation_submission_with_signature(
                &round_id_str,
                bundle_index,
                &sig,
                &request.sighash,
            )
            .map_err(|e| anyhow!("get_delegation_submission failed: {}", e))?;

        let json_sub: JsonDelegationSubmission = data.into();
        json_to_boxed_slice(&json_sub)
    });
    unwrap_exc_or_null(res)
}

/// Get the delegation submission payload using a Keystone-provided signature.
///
/// Returns JSON-encoded `DelegationSubmission` as `*mut FfiBoxedSlice`, or null on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_delegation_submission_with_keystone_sig(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    sig: *const u8,
    sig_len: usize,
    sighash: *const u8,
    sighash_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let sig_bytes = unsafe { bytes_from_ptr(sig, sig_len) }?;
        let sighash_bytes = unsafe { bytes_from_ptr(sighash, sighash_len) }?;
        let sig_arr: [u8; 64] = sig_bytes
            .try_into()
            .map_err(|_| anyhow!("sig must be exactly 64 bytes"))?;
        let sighash_arr: [u8; 32] = sighash_bytes
            .try_into()
            .map_err(|_| anyhow!("sighash must be exactly 32 bytes"))?;

        let data = handle
            .db
            .get_delegation_submission_with_signature(
                &round_id_str,
                bundle_index,
                &sig_arr,
                &sighash_arr,
            )
            .map_err(|e| anyhow!("get_delegation_submission_with_keystone_sig failed: {}", e))?;

        let json_sub: JsonDelegationSubmission = data.into();
        json_to_boxed_slice(&json_sub)
    });
    unwrap_exc_or_null(res)
}

/// Store the VAN leaf position after delegation transaction confirmation.
///
/// Returns 0 on success, -1 on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_store_van_position(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    position: u32,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;

        handle
            .db
            .store_van_position(&round_id_str, bundle_index, position)
            .map_err(|e| anyhow!("store_van_position failed: {}", e))?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Validate a PIR-fetched IMT non-membership proof bytewise.
///
/// Inputs are the wire format of `zcash_voting::ImtProofData`: 32-byte LE
/// pallas::Base values for the root and the three nf_bounds, a u32 leaf
/// position, and 29 32-byte path siblings.
///
/// Returns 1 if the proof is valid, 0 if it is well-formed but invalid, and -1
/// if inputs are malformed or a panic occurs.
///
/// # Safety
///
/// - `root`, `nullifier`, and `expected_root` must each point to exactly 32 bytes.
/// - `nf_bounds` must point to exactly 96 bytes (3 * 32).
/// - `path` must point to exactly 928 bytes (29 * 32).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_validate_pir_proof(
    root: *const u8,
    nf_bounds: *const u8,
    leaf_pos: u32,
    path: *const u8,
    nullifier: *const u8,
    expected_root: *const u8,
) -> i32 {
    let res = catch_panic(|| {
        let root_bytes: [u8; PIR_ROOT_LEN] =
            unsafe { std::slice::from_raw_parts(root, PIR_ROOT_LEN) }
                .try_into()
                .map_err(|_| anyhow!("root must be exactly {PIR_ROOT_LEN} bytes"))?;
        let nf_bounds_bytes: [u8; PIR_NULLIFIER_BOUNDS_LEN] =
            unsafe { std::slice::from_raw_parts(nf_bounds, PIR_NULLIFIER_BOUNDS_LEN) }
                .try_into()
                .map_err(|_| {
                    anyhow!("nf_bounds must be exactly {PIR_NULLIFIER_BOUNDS_LEN} bytes")
                })?;
        let path_bytes: [u8; PIR_PATH_LEN] =
            unsafe { std::slice::from_raw_parts(path, PIR_PATH_LEN) }
                .try_into()
                .map_err(|_| anyhow!("path must be exactly {PIR_PATH_LEN} bytes"))?;
        let nullifier_bytes: [u8; PIR_NULLIFIER_LEN] =
            unsafe { std::slice::from_raw_parts(nullifier, PIR_NULLIFIER_LEN) }
                .try_into()
                .map_err(|_| anyhow!("nullifier must be exactly {PIR_NULLIFIER_LEN} bytes"))?;
        let expected_root_bytes: [u8; PIR_ROOT_LEN] =
            unsafe { std::slice::from_raw_parts(expected_root, PIR_ROOT_LEN) }
                .try_into()
                .map_err(|_| anyhow!("expected_root must be exactly {PIR_ROOT_LEN} bytes"))?;

        let proof = zcash_voting::ImtProofData {
            root: parse_base(&root_bytes, "root")?,
            nf_bounds: [
                parse_base(&nf_bounds_bytes[0..CANONICAL_FIELD_LEN], "nf_bounds[0]")?,
                parse_base(
                    &nf_bounds_bytes[CANONICAL_FIELD_LEN..CANONICAL_FIELD_LEN * 2],
                    "nf_bounds[1]",
                )?,
                parse_base(
                    &nf_bounds_bytes[CANONICAL_FIELD_LEN * 2..PIR_NULLIFIER_BOUNDS_LEN],
                    "nf_bounds[2]",
                )?,
            ],
            leaf_pos,
            path: parse_path(&path_bytes)?,
        };

        let nullifier = parse_base(&nullifier_bytes, "nullifier")?;
        let expected_root = parse_base(&expected_root_bytes, "expected_root")?;

        match zkp1::validate_and_convert_pir_proof(proof, nullifier, expected_root) {
            Ok(_) => Ok(1),
            Err(_) => Ok(0),
        }
    });
    unwrap_exc_or(res, -1)
}

fn parse_base(bytes: &[u8], label: &str) -> anyhow::Result<pallas::Base> {
    let bytes: [u8; CANONICAL_FIELD_LEN] = bytes
        .try_into()
        .map_err(|_| anyhow!("{label} must be exactly {CANONICAL_FIELD_LEN} bytes"))?;
    Option::from(pallas::Base::from_repr(bytes))
        .ok_or_else(|| anyhow!("{label} is not a canonical pallas::Base encoding"))
}

fn parse_path(bytes: &[u8]) -> anyhow::Result<[pallas::Base; PIR_PATH_ELEMENT_COUNT]> {
    let mut path = [pallas::Base::from(0); PIR_PATH_ELEMENT_COUNT];
    for (i, chunk) in bytes.chunks_exact(CANONICAL_FIELD_LEN).enumerate() {
        path[i] = parse_base(chunk, "path element")?;
    }
    Ok(path)
}
