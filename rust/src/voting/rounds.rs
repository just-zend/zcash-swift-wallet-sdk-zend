use std::ffi::CString;
use std::panic::AssertUnwindSafe;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;

use crate::{unwrap_exc_or, unwrap_exc_or_null};

use super::db::VotingDatabaseHandle;
use super::ffi_types::{FfiRoundState, FfiRoundSummaries, FfiRoundSummary, FfiVoteRecords};
use super::helpers::{round_phase_to_u32, str_from_ptr};

/// Initialize a voting round.
///
/// Returns 0 on success, -1 on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - String/byte parameters must be valid for their stated lengths.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_init_round(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    snapshot_height: u64,
    ea_pk: *const u8,
    ea_pk_len: usize,
    nc_root: *const u8,
    nc_root_len: usize,
    nullifier_imt_root: *const u8,
    nullifier_imt_root_len: usize,
    session_json: *const u8,
    session_json_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| -> anyhow::Result<i32> {
        // [IW-PORT] zcash_voting 1.0 (the ironwood-aligned line this branch
        // rides): round init was re-signatured in 1.0.
        // Honest error until the voting-FFI port (census: voting row).
        let _ = (
            &db,
            round_id,
            round_id_len,
            snapshot_height,
            ea_pk,
            ea_pk_len,
            nc_root,
            nc_root_len,
            nullifier_imt_root,
            nullifier_imt_root_len,
            session_json,
            session_json_len,
        );
        Err(anyhow!(
            "voting: init_round is unavailable on the ironwood-support graph (zcash_voting port pending)"
        ))
    });
    unwrap_exc_or(res, -1)
}

/// Get the state of a voting round.
///
/// Returns a pointer to `FfiRoundState` on success, or null on error.
/// Call `zcashlc_voting_free_round_state` to free the returned pointer.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_round_state(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
) -> *mut FfiRoundState {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;

        let state = handle
            .db
            .get_round_state(&round_id_str)
            .map_err(|e| anyhow!("get_round_state failed: {}", e))?;

        let phase = round_phase_to_u32(state.phase);
        let round_id =
            CString::new(state.round_id).map_err(|e| anyhow!("invalid round_id string: {}", e))?;
        let hotkey_address = state
            .hotkey_address
            .map(|addr| {
                CString::new(addr).map_err(|e| anyhow!("invalid hotkey_address string: {}", e))
            })
            .transpose()?;
        let ffi_state = FfiRoundState {
            round_id: round_id.into_raw(),
            phase,
            snapshot_height: state.snapshot_height,
            hotkey_address: hotkey_address
                .map(CString::into_raw)
                .unwrap_or(std::ptr::null_mut()),
            delegated_weight: state.delegated_weight.map_or(-1, |w| w as i64),
            proof_generated: state.proof_generated,
        };

        Ok(Box::into_raw(Box::new(ffi_state)))
    });
    unwrap_exc_or_null(res)
}

/// List all voting rounds.
///
/// Returns a pointer to `FfiRoundSummaries` on success, or null on error.
/// Call `zcashlc_voting_free_round_summaries` to free the returned pointer.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_list_rounds(
    db: *mut VotingDatabaseHandle,
) -> *mut FfiRoundSummaries {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;

        let rounds = handle
            .db
            .list_rounds()
            .map_err(|e| anyhow!("list_rounds failed: {}", e))?;

        struct OwnedRoundSummary {
            round_id: CString,
            phase: u32,
            snapshot_height: u64,
            created_at: u64,
        }

        let owned_rounds: Vec<OwnedRoundSummary> = rounds
            .into_iter()
            .map(|s| {
                let phase = round_phase_to_u32(s.phase);
                Ok(OwnedRoundSummary {
                    round_id: CString::new(s.round_id)
                        .map_err(|e| anyhow!("invalid round_id string: {}", e))?,
                    phase,
                    snapshot_height: s.snapshot_height,
                    created_at: s.created_at,
                })
            })
            .collect::<anyhow::Result<Vec<_>>>()?;

        let ffi_rounds: Vec<FfiRoundSummary> = owned_rounds
            .into_iter()
            .map(|s| FfiRoundSummary {
                round_id: s.round_id.into_raw(),
                phase: s.phase,
                snapshot_height: s.snapshot_height,
                created_at: s.created_at,
            })
            .collect();

        let (ptr, len) = crate::ptr_from_vec(ffi_rounds);
        Ok(Box::into_raw(Box::new(FfiRoundSummaries { ptr, len })))
    });
    unwrap_exc_or_null(res)
}

/// Get vote records for a round.
///
/// Returns a pointer to `FfiVoteRecords` on success, or null on error.
/// Call `zcashlc_voting_free_vote_records` to free the returned pointer.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_votes(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
) -> *mut FfiVoteRecords {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| -> anyhow::Result<*mut FfiVoteRecords> {
        // [IW-PORT] zcash_voting 1.0 (the ironwood-aligned line this branch
        // rides): the vote-record shape changed in 1.0.
        // Honest error until the voting-FFI port (census: voting row).
        let _ = (&db, round_id, round_id_len);
        Err(anyhow!(
            "voting: get_votes is unavailable on the ironwood-support graph (zcash_voting port pending)"
        ))
    });
    unwrap_exc_or_null(res)
}

/// Clear all data for a voting round.
///
/// Returns 0 on success, -1 on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_clear_round(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;

        handle
            .db
            .clear_round(&round_id_str)
            .map_err(|e| anyhow!("clear_round failed: {}", e))?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Delete bundle rows with index >= `keep_count`, removing skipped bundles.
///
/// Returns the number of deleted rows on success, or -1 on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_delete_skipped_bundles(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    keep_count: u32,
) -> i64 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;

        let deleted = handle
            .db
            .delete_skipped_bundles(&round_id_str, keep_count)
            .map_err(|e| anyhow!("delete_skipped_bundles failed: {}", e))?;
        Ok(deleted as i64)
    });
    unwrap_exc_or(res, -1)
}

// [IW-PORT] 0.11-flow tests parked behind `voting-port-tests` (see voting.rs).
#[cfg(all(test, feature = "voting-port-tests"))]
mod tests {
    use super::*;
    use crate::voting::db::zcashlc_voting_db_free;
    use crate::voting::test_helpers::open_memory_db;

    fn init_round(
        db: *mut VotingDatabaseHandle,
        round_id: &[u8],
        ea_pk: &[u8],
        nc_root: &[u8],
        nullifier_imt_root: &[u8],
    ) -> i32 {
        unsafe {
            zcashlc_voting_init_round(
                db,
                round_id.as_ptr(),
                round_id.len(),
                123,
                ea_pk.as_ptr(),
                ea_pk.len(),
                nc_root.as_ptr(),
                nc_root.len(),
                nullifier_imt_root.as_ptr(),
                nullifier_imt_root.len(),
                std::ptr::null(),
                0,
            )
        }
    }

    fn round_exists(db: *mut VotingDatabaseHandle, round_id: &[u8]) -> bool {
        let state =
            unsafe { zcashlc_voting_get_round_state(db, round_id.as_ptr(), round_id.len()) };
        if state.is_null() {
            false
        } else {
            unsafe { crate::voting::ffi_types::zcashlc_voting_free_round_state(state) };
            true
        }
    }

    #[test]
    fn init_round_rejects_invalid_round_param_lengths_without_persisting() {
        let db = open_memory_db();
        let valid = [7u8; 32];

        let cases = [
            ("bad-ea-pk".as_bytes(), &valid[..31], &valid[..], &valid[..]),
            (
                "bad-nc-root".as_bytes(),
                &valid[..],
                &valid[..31],
                &valid[..],
            ),
            (
                "bad-nullifier-root".as_bytes(),
                &valid[..],
                &valid[..],
                &valid[..31],
            ),
        ];

        for (round_id, ea_pk, nc_root, nullifier_imt_root) in cases {
            let code = init_round(db, round_id, ea_pk, nc_root, nullifier_imt_root);
            assert_eq!(code, -1);
            assert!(!round_exists(db, round_id));
        }

        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn init_round_accepts_valid_round_param_lengths() {
        let db = open_memory_db();
        let round_id = b"round";
        let valid = [7u8; 32];

        let code = init_round(db, round_id, &valid, &valid, &valid);

        assert_eq!(code, 0);
        assert!(round_exists(db, round_id));

        unsafe { zcashlc_voting_db_free(db) };
    }
}
