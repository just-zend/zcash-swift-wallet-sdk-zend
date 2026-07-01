//! FFI wrapping [`zodl_ironwood_migration::MigrationContext`], the synchronous, network-free
//! Orchard→Ironwood migration engine.
//!
//! Every function marshals whole `serde` types as JSON through [`ffi::BoxedSlice`]: on success it
//! returns a non-null `BoxedSlice` holding the JSON body; on failure it returns null and stores the
//! message for `zcashlc_last_error_message`. Void crate methods encode `()` (`"null"`), which the
//! Swift welding ignores. The crate never broadcasts — `PreparedTx.raw_pczt` is a serialized PCZT;
//! the Swift layer extracts the consensus transaction via `zcashlc_migration_extract_broadcast_tx`,
//! broadcasts that, and reports the outcome back via `record_transfer_result`.

use std::ffi::{CStr, OsStr};
use std::os::raw::c_char;
use std::os::unix::ffi::OsStrExt;
use std::slice;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use zodl_ironwood_migration::{
    MigrationContext, MigrationSchedule, Network, NoteSplitProposal, TransferResult,
};

use crate::ffi;
use crate::unwrap_exc_or_null;

/// Map the FFI network id to the migration crate's [`Network`] (testnet = 0, mainnet = 1, mirroring
/// `parse_network`).
fn migration_network(network_id: u32) -> anyhow::Result<Network> {
    match network_id {
        0 => Ok(Network::TestNetwork),
        1 => Ok(Network::MainNetwork),
        // The migration engine's `Network` has no regtest/LocalNetwork variant, so the Orchard→Ironwood
        // migration cannot run against a custom-parameter network yet. Connecting + syncing regtest is
        // supported; enabling migration there is a follow-up in the migration crate (MOB-1455).
        2 => Err(anyhow!(
            "regtest (network id 2) is not supported by the Ironwood migration engine yet (MOB-1455)"
        )),
        other => Err(anyhow!("Invalid network id: {other}")),
    }
}

/// Borrow the wallet db path (UTF-8) from the FFI byte buffer.
///
/// # Safety
/// `db_data` must be valid for reads of `db_data_len` bytes.
unsafe fn migration_db_path<'a>(db_data: *const u8, db_data_len: usize) -> anyhow::Result<&'a str> {
    let bytes = unsafe { slice::from_raw_parts(db_data, db_data_len) };
    OsStr::from_bytes(bytes)
        .to_str()
        .ok_or_else(|| anyhow!("wallet db path is not valid UTF-8"))
}

/// Copy the 16-byte account uuid from the FFI buffer.
///
/// # Safety
/// `account_uuid_bytes` must be valid for reads of 16 bytes.
unsafe fn account_16(account_uuid_bytes: *const u8) -> anyhow::Result<[u8; 16]> {
    let bytes = unsafe { slice::from_raw_parts(account_uuid_bytes, 16) };
    <[u8; 16]>::try_from(bytes).map_err(|_| anyhow!("account uuid must be 16 bytes"))
}

/// Build a [`MigrationContext`] from the common FFI args.
///
/// # Safety
/// `db_data`/`account_uuid_bytes` must satisfy the safety requirements of [`migration_db_path`] and
/// [`account_16`].
unsafe fn context(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> anyhow::Result<MigrationContext> {
    let path = unsafe { migration_db_path(db_data, db_data_len)? };
    let network = migration_network(network_id)?;
    let account = unsafe { account_16(account_uuid_bytes)? };
    MigrationContext::new(path, network, account)
        .map_err(|e| anyhow!("open migration context: {e}"))
}

/// Current migration state (JSON `MigrationState`).
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_state(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let value = ctx
            .migration_state()
            .map_err(|e| anyhow!("migration_state: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Migration progress (JSON `Option<MigrationProgress>`).
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_progress(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let value = ctx
            .migration_progress()
            .map_err(|e| anyhow!("migration_progress: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Whether note splitting is required before migration (JSON `bool`).
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_is_note_split_needed(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let value = ctx
            .is_note_split_needed()
            .map_err(|e| anyhow!("is_note_split_needed: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Compute the note-split proposal for the spendable Orchard balance (JSON `NoteSplitProposal`).
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_prepare_note_split(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let value = ctx
            .prepare_note_split()
            .map_err(|e| anyhow!("prepare_note_split: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Build, sign and persist the note-split transaction (JSON `PreparedTx`). `proposal` is JSON
/// `NoteSplitProposal`; `usk` is the raw `UnifiedSpendingKey` (Orchard era) bytes.
///
/// # Safety
/// See [`context`]; `proposal_ptr`/`usk_ptr` must be valid for reads of their lengths. Free the
/// returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_sign_note_split(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    proposal_ptr: *const u8,
    proposal_len: usize,
    usk_ptr: *const u8,
    usk_len: usize,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let proposal: NoteSplitProposal =
            serde_json::from_slice(unsafe { slice::from_raw_parts(proposal_ptr, proposal_len) })
                .map_err(|e| anyhow!("decode NoteSplitProposal: {e}"))?;
        let usk = unsafe { slice::from_raw_parts(usk_ptr, usk_len) };
        let value = ctx
            .sign_note_split(&proposal, usk)
            .map_err(|e| anyhow!("sign_note_split: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Generate the full migration schedule (JSON `MigrationSchedule`).
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_propose_transfers(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let value = ctx
            .propose_migration_transfers()
            .map_err(|e| anyhow!("propose_migration_transfers: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Pre-sign and persist every transfer in the schedule (JSON `null` on success). `schedule` is JSON
/// `MigrationSchedule`; `usk` is the raw `UnifiedSpendingKey` (Orchard era) bytes.
///
/// # Safety
/// See [`context`]; `schedule_ptr`/`usk_ptr` must be valid for reads of their lengths. Free the
/// returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_sign_and_store(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    schedule_ptr: *const u8,
    schedule_len: usize,
    usk_ptr: *const u8,
    usk_len: usize,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let schedule: MigrationSchedule =
            serde_json::from_slice(unsafe { slice::from_raw_parts(schedule_ptr, schedule_len) })
                .map_err(|e| anyhow!("decode MigrationSchedule: {e}"))?;
        let usk = unsafe { slice::from_raw_parts(usk_ptr, usk_len) };
        ctx.sign_and_store_migration_schedule(&schedule, usk)
            .map_err(|e| anyhow!("sign_and_store_migration_schedule: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&())?))
    });
    unwrap_exc_or_null(res)
}

/// Whether a sync is required before the next transfer (JSON `bool`).
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_is_sync_required(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let value = ctx
            .is_sync_required_before_next_transfer()
            .map_err(|e| anyhow!("is_sync_required_before_next_transfer: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// The next height-due pre-signed transfer, or `None` (JSON `Option<PreparedTx>`).
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_next_due_transfer(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let value = ctx
            .next_due_transfer()
            .map_err(|e| anyhow!("next_due_transfer: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Extract the broadcast-ready consensus transaction from a serialized signed PCZT
/// (`PreparedTx.raw_pczt`). Returns the raw transaction bytes (NOT JSON).
///
/// # Safety
/// See [`context`]; `pczt_ptr` must be valid for reads of `pczt_len` bytes. Free the returned
/// pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_extract_broadcast_tx(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    pczt_ptr: *const u8,
    pczt_len: usize,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let pczt = unsafe { slice::from_raw_parts(pczt_ptr, pczt_len) };
        let tx = ctx
            .extract_broadcast_tx(pczt)
            .map_err(|e| anyhow!("extract_broadcast_tx: {e}"))?;
        Ok(ffi::BoxedSlice::some(tx))
    });
    unwrap_exc_or_null(res)
}

/// Re-anchor, re-prove and re-sign the active run's scheduled transfers, returning the number
/// refreshed (JSON `u32`). `usk` is the raw `UnifiedSpendingKey` (Orchard era) bytes.
///
/// # Safety
/// See [`context`]; `usk_ptr` must be valid for reads of `usk_len` bytes. Free the returned
/// pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_refresh_stale_transfers(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    usk_ptr: *const u8,
    usk_len: usize,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let usk = unsafe { slice::from_raw_parts(usk_ptr, usk_len) };
        let value = ctx
            .refresh_stale_transfers(usk)
            .map_err(|e| anyhow!("refresh_stale_transfers: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Record the platform's broadcast outcome (JSON `null` on success). `transfer_id` is a C string;
/// `result` is JSON `TransferResult`.
///
/// # Safety
/// See [`context`]; `transfer_id` must be a valid C string and `result_ptr` valid for `result_len`
/// bytes. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_record_transfer_result(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    transfer_id: *const c_char,
    result_ptr: *const u8,
    result_len: usize,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let transfer_id = unsafe { CStr::from_ptr(transfer_id) }
            .to_str()
            .map_err(|e| anyhow!("transfer_id: {e}"))?;
        let result: TransferResult =
            serde_json::from_slice(unsafe { slice::from_raw_parts(result_ptr, result_len) })
                .map_err(|e| anyhow!("decode TransferResult: {e}"))?;
        ctx.record_transfer_result(transfer_id, result)
            .map_err(|e| anyhow!("record_transfer_result: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&())?))
    });
    unwrap_exc_or_null(res)
}

/// Whether any scheduled transfer is past its send height but not yet broadcast (JSON `bool`).
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_has_overdue_transfers(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let value = ctx
            .has_overdue_transfers()
            .map_err(|e| anyhow!("has_overdue_transfers: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Whether the migration is in an invalid state (spendable Orchard remains but nothing covers it)
/// (JSON `bool`).
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_has_invalid_transfers(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let value = ctx
            .has_invalid_transfers()
            .map_err(|e| anyhow!("has_invalid_transfers: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Re-evaluate the remaining spendable Orchard balance and return a fresh schedule (JSON
/// `MigrationSchedule`).
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_restart_step(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let value = ctx
            .restart_current_migration_step()
            .map_err(|e| anyhow!("restart_current_migration_step: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// First-launch post-upgrade initialization (JSON `null` on success).
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_initialize_post_upgrade(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        ctx.initialize_post_upgrade()
            .map_err(|e| anyhow!("initialize_post_upgrade: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&())?))
    });
    unwrap_exc_or_null(res)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migration_state_on_fresh_db_is_not_started() {
        let path = std::env::temp_dir().join(format!("zcashlc_mig_{}.sqlite", std::process::id()));
        let path_str = path.to_str().unwrap();
        let db = path_str.as_bytes();
        let account = [7u8; 16];
        let ptr = unsafe { zcashlc_migration_state(db.as_ptr(), db.len(), account.as_ptr(), 1) };
        assert!(!ptr.is_null());
        let body = unsafe { (*ptr).as_slice() };
        assert_eq!(body, b"\"NotStarted\"");
        unsafe { crate::ffi::zcashlc_free_boxed_slice(ptr) }
        let _ = std::fs::remove_file(&path);
    }
}
