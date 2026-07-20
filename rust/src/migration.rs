//! FFI wrapping [`zcash_pool_migration::MigrationContext`], the synchronous, network-free
//! Orchard→Ironwood pool-migration engine.
//!
//! Unlike the `zodl_ironwood_migration` prototype this ports from, the `zcash_pool_migration`
//! crate derives no `serde`: its public types expose `from_parts` constructors and accessor
//! methods, and this layer defines its own `#[repr(C)]` DTOs over those accessors (there is no
//! JSON on this boundary). Every entry point constructs a fresh [`MigrationContext`] per call
//! (cheap by the crate's design — it only ensures the engine's own tables exist), runs inside
//! [`catch_panic`], and reports failures through the thread-local last-error channel
//! (`zcashlc_last_error_message`): pointer-returning functions yield NULL, `bool`-returning
//! functions yield `false`, and the `i64` sentinels are documented per function.
//!
//! Heap ownership: every function that returns a `*mut Ffi*` (or a [`ffi::BoxedSlice`]) transfers
//! ownership to the caller, who must free it with the matching `zcashlc_free_migration_*` (or
//! `zcashlc_free_boxed_slice`) function. C strings embedded in these structs are owned by the
//! struct and freed by its free function; do not free them separately.
//!
//! The crate never broadcasts: a [`PreparedTransfer`]'s `pczt` field is a serialized signed PCZT.
//! The platform turns it into consensus bytes via `zcashlc_migration_extract_broadcast_tx`,
//! broadcasts those, and reports the outcome back via `zcashlc_migration_record_transfer_result`.

use std::ffi::{CStr, CString, OsStr};
use std::os::raw::c_char;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::ptr;
use std::slice;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use zcash_protocol::TxId;
use zcash_protocol::consensus::{BlockHeight, Network, NetworkUpgrade, Parameters};
use zcash_protocol::value::Zatoshis;
use zcash_pool_migration::{
    AttentionReason, MigrationContext, MigrationError, MigrationProgress, MigrationSchedule,
    MigrationState, NoteSplitProposal, PreparedTransfer, SignedTransferPczt, TransferId,
    TransferProposal, TransferResult, UnsignedTransferPczt,
};

use crate::{
    NETWORK_ID_MAINNET, NETWORK_ID_TESTNET, NetworkParams, account_uuid_from_bytes, ffi,
    free_ptr_from_vec, free_ptr_from_vec_with, parse_network, ptr_from_vec, unwrap_exc_or,
    unwrap_exc_or_null, zcashlc_string_free,
};

/// The migration context, bound to the SDK's network-parameter type so it threads the same
/// mainnet/testnet/custom parameters as the rest of the FFI (via [`parse_network`]).
type Ctx = MigrationContext<NetworkParams>;

// ----- error / value marshaling -----

/// Map a [`MigrationError`] into the FFI's `anyhow` error, embedding the stable
/// [`MigrationError::error_code`] value alongside the `Display` message so callers may branch on
/// the code carried in `zcashlc_last_error_message`.
fn map_mig_err(e: MigrationError) -> anyhow::Error {
    anyhow!("migration error {}: {e}", e.error_code())
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

/// Rebuild a [`Zatoshis`] from an FFI `i64` amount (must be non-negative and a valid money value).
fn zat_from_i64(amount: i64, what: &str) -> anyhow::Result<Zatoshis> {
    let raw = u64::try_from(amount).map_err(|_| anyhow!("{what} amount is negative: {amount}"))?;
    Zatoshis::from_u64(raw).map_err(|e| anyhow!("{what} amount is not a valid zatoshi value: {e:?}"))
}

/// Rebuild a [`BlockHeight`] from an FFI `i64` height (must fit in `u32`).
fn height_from_i64(height: i64, what: &str) -> anyhow::Result<BlockHeight> {
    u32::try_from(height)
        .map(BlockHeight::from_u32)
        .map_err(|_| anyhow!("{what} height out of range: {height}"))
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

/// Build a [`MigrationContext`] from the common FFI arguments.
///
/// # Safety
/// - `db_data` must be valid for reads of `db_data_len` bytes and encode a filesystem path.
/// - `account_uuid_bytes` must be valid for reads of 16 bytes.
unsafe fn build_context(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> anyhow::Result<Ctx> {
    let db_path = Path::new(OsStr::from_bytes(unsafe {
        slice::from_raw_parts(db_data, db_data_len)
    }));
    let network = parse_network(network_id)?;
    let account = account_uuid_from_bytes(account_uuid_bytes)
        .map_err(|e| anyhow!("account uuid must be 16 bytes: {e}"))?;
    MigrationContext::new(db_path, network, account).map_err(map_mig_err)
}

/// Rebuild a [`MigrationSchedule`] from the JNI-style parallel arrays the platform round-trips
/// (the schedule the engine handed out, deconstructed field-by-field). All arrays have length
/// `ids_len`.
///
/// # Safety
/// Each array pointer must be valid for reads of `ids_len` elements (or may be null when
/// `ids_len == 0`), and every `ids[i]` must be a valid, NUL-terminated C string.
#[allow(clippy::too_many_arguments)]
unsafe fn rebuild_schedule(
    ids: *const *const c_char,
    ids_len: usize,
    amounts: *const i64,
    anchor_heights: *const i64,
    next_executable_after_heights: *const i64,
    expiry_heights: *const i64,
    estimated_duration_hours: u32,
) -> anyhow::Result<MigrationSchedule> {
    let ids = unsafe { slice_or_empty(ids, ids_len) };
    let amounts = unsafe { slice_or_empty(amounts, ids_len) };
    let anchors = unsafe { slice_or_empty(anchor_heights, ids_len) };
    let next_execs = unsafe { slice_or_empty(next_executable_after_heights, ids_len) };
    let expiries = unsafe { slice_or_empty(expiry_heights, ids_len) };

    let mut transfers = Vec::with_capacity(ids_len);
    for i in 0..ids_len {
        let id_ptr = ids[i];
        if id_ptr.is_null() {
            return Err(anyhow!("transfer id at index {i} is null"));
        }
        let id = unsafe { CStr::from_ptr(id_ptr) }
            .to_str()
            .map_err(|e| anyhow!("transfer id at index {i} is not valid UTF-8: {e}"))?
            .to_owned();
        transfers.push(TransferProposal::from_parts(
            TransferId::from_raw(id),
            zat_from_i64(amounts[i], "transfer")?,
            height_from_i64(anchors[i], "anchor")?,
            height_from_i64(next_execs[i], "next-executable-after")?,
            height_from_i64(expiries[i], "expiry")?,
        ));
    }
    Ok(MigrationSchedule::from_parts(
        transfers,
        estimated_duration_hours,
    ))
}

// ============================================================================================
// #[repr(C)] return DTOs
//
// These are named `Ffi*` in Rust because the base names (`MigrationState`, `MigrationProgress`,
// `MigrationSchedule`, `NoteSplitProposal`, `TransferProposal`, ...) are already taken by the
// imported `zcash_pool_migration` types this module marshals from; the prefix avoids the
// collision and, since cbindgen keeps the Rust name, also lands the `Ffi*` C names the header
// convention wants without any `build.rs` `rename_item` entry.
// ============================================================================================

/// Live migration progress. When returned standalone (`zcashlc_migration_progress`), `is_present`
/// is `false` for the crate's `None` (no migration in progress); as the payload of
/// [`FfiMigrationState::InProgress`] it is always `true`.
#[repr(C)]
pub struct FfiMigrationProgress {
    /// Whether the remaining fields carry a real progress snapshot.
    pub is_present: bool,
    /// The number of scheduled transfers confirmed on-chain so far.
    pub completed_transfers: u32,
    /// The total number of transfers in the current schedule.
    pub total_transfers: u32,
    /// The Orchard-pool value (zatoshi) not yet migrated to Ironwood.
    pub remaining_orchard_value: i64,
    /// The height at which the next transfer becomes broadcastable, or `-1` if none is scheduled.
    pub next_transfer_ready_at_height: i64,
}

impl FfiMigrationProgress {
    fn present(p: &MigrationProgress) -> Self {
        FfiMigrationProgress {
            is_present: true,
            completed_transfers: p.completed_transfers(),
            total_transfers: p.total_transfers(),
            remaining_orchard_value: zat_to_i64(p.remaining_orchard_value()),
            next_transfer_ready_at_height: height_opt_to_i64(p.next_transfer_ready_at_height()),
        }
    }

    fn absent() -> Self {
        FfiMigrationProgress {
            is_present: false,
            completed_transfers: 0,
            total_transfers: 0,
            remaining_orchard_value: 0,
            next_transfer_ready_at_height: -1,
        }
    }
}

/// Why a migration requires user attention (payload of [`FfiMigrationState::RequiresAttention`]).
#[repr(C, u8)]
pub enum FfiAttentionReason {
    /// The input note funding `transfer_id` was spent externally before its transfer broadcast.
    /// `transfer_id` is an owned C string, freed by [`zcashlc_free_migration_state`].
    InvalidTransfer { transfer_id: *mut c_char },
    /// A transaction's anchor/expiry elapsed before it could be broadcast.
    TransferExpired,
    /// A transfer produced Orchard change that must be synced before the next spend.
    SyncRequiredBeforeNext,
}

/// The top-level migration state machine surfaced to the app (see
/// [`zcash_pool_migration::MigrationState`]).
///
/// `#[allow(dead_code)]`: the data-carrying variants' payloads are read by the C consumer across
/// the FFI (cbindgen emits them into the header), which rustc cannot observe — the
/// `InProgress` progress snapshot in particular is never matched back out in Rust.
#[allow(dead_code)]
#[repr(C, u8)]
pub enum FfiMigrationState {
    /// No migration has been initiated (or a run was abandoned).
    NotStarted,
    /// The note-split transaction has been submitted and awaits confirmation.
    SplitPendingConfirmation,
    /// The split is confirmed (or was not needed); ready to propose transfers.
    ReadyToPropose,
    /// The schedule has been committed and transfers are executing.
    InProgress(FfiMigrationProgress),
    /// A transfer cannot proceed automatically; the app must act.
    RequiresAttention(FfiAttentionReason),
    /// All transfers are confirmed; the Orchard balance is fully migrated.
    Complete,
}

impl FfiMigrationState {
    fn from_state(state: MigrationState) -> anyhow::Result<*mut Self> {
        let value = match state {
            MigrationState::NotStarted => FfiMigrationState::NotStarted,
            MigrationState::SplitPendingConfirmation => FfiMigrationState::SplitPendingConfirmation,
            MigrationState::ReadyToPropose => FfiMigrationState::ReadyToPropose,
            MigrationState::InProgress(p) => {
                FfiMigrationState::InProgress(FfiMigrationProgress::present(&p))
            }
            MigrationState::RequiresAttention(reason) => {
                let reason = match reason {
                    AttentionReason::InvalidTransfer(id) => FfiAttentionReason::InvalidTransfer {
                        transfer_id: cstring_raw(id.as_str(), "attention transfer id")?,
                    },
                    AttentionReason::TransferExpired => FfiAttentionReason::TransferExpired,
                    AttentionReason::SyncRequiredBeforeNext => {
                        FfiAttentionReason::SyncRequiredBeforeNext
                    }
                };
                FfiMigrationState::RequiresAttention(reason)
            }
            MigrationState::Complete => FfiMigrationState::Complete,
        };
        Ok(Box::into_raw(Box::new(value)))
    }
}

/// A planned note split: the per-note output values (zatoshi) and the split-transaction fee.
#[repr(C)]
pub struct FfiNoteSplitProposal {
    /// Heap array of `output_values_len` output-note values (zatoshi).
    pub output_values: *mut i64,
    pub output_values_len: usize,
    /// The fee (zatoshi) paid by the note-split transaction itself.
    pub fee: i64,
}

/// A fully proven, signed transaction persisted as a PCZT, ready for the platform to broadcast.
/// When returned by `zcashlc_migration_next_due_transfer`, an all-null/zeroed value (`id` and
/// `pczt` null) means "nothing is due" (as opposed to a NULL return, which signals an error).
#[repr(C)]
pub struct FfiPreparedTransfer {
    /// The transfer's opaque id, as an owned C string (null only in the "nothing due" sentinel).
    pub id: *mut c_char,
    /// The finalized transaction's id, as raw (internal-order) 32-byte value.
    pub txid: [u8; 32],
    /// Heap `pczt_len`-byte serialized signed PCZT (null only in the "nothing due" sentinel).
    pub pczt: *mut u8,
    pub pczt_len: usize,
}

impl FfiPreparedTransfer {
    fn some(pt: PreparedTransfer) -> anyhow::Result<*mut Self> {
        let id = cstring_raw(pt.id().as_str(), "prepared transfer id")?;
        let txid = *pt.txid().as_ref();
        let (pczt, pczt_len) = ptr_from_vec(pt.into_pczt_bytes());
        Ok(Box::into_raw(Box::new(FfiPreparedTransfer {
            id,
            txid,
            pczt,
            pczt_len,
        })))
    }

    fn none() -> *mut Self {
        Box::into_raw(Box::new(FfiPreparedTransfer {
            id: ptr::null_mut(),
            txid: [0u8; 32],
            pczt: ptr::null_mut(),
            pczt_len: 0,
        }))
    }
}

/// A single scheduled Orchard→Ironwood transfer (element of [`FfiMigrationSchedule`]).
#[repr(C)]
pub struct FfiTransferProposal {
    /// The transfer's opaque id, as an owned C string.
    pub id: *mut c_char,
    /// The value (zatoshi) that crosses the turnstile.
    pub amount: i64,
    /// The anchor height the PCZT is built against.
    pub anchor_height: i64,
    /// The height after which the platform may broadcast this transfer.
    pub next_executable_after_height: i64,
    /// The height after which this transfer is no longer valid.
    pub expiry_height: i64,
}

impl FfiTransferProposal {
    /// Marshal a single [`TransferProposal`] into its `#[repr(C)]` form, minting a fresh owned id
    /// C string. Shared by [`FfiMigrationSchedule::from_schedule`] (as an array element) and
    /// [`FfiTransferProposal::some`] (as a standalone boxed return).
    fn from_proposal(t: &TransferProposal) -> anyhow::Result<FfiTransferProposal> {
        Ok(FfiTransferProposal {
            id: cstring_raw(t.id().as_str(), "transfer proposal id")?,
            amount: zat_to_i64(t.amount()),
            anchor_height: i64::from(u32::from(t.anchor_height())),
            next_executable_after_height: i64::from(u32::from(t.next_executable_after_height())),
            expiry_height: i64::from(u32::from(t.expiry_height())),
        })
    }

    /// Heap-box a single proposal for a standalone `*mut FfiTransferProposal` return.
    fn some(t: &TransferProposal) -> anyhow::Result<*mut Self> {
        Ok(Box::into_raw(Box::new(Self::from_proposal(t)?)))
    }
}

/// A full migration schedule presented to the user for one-time confirmation.
#[repr(C)]
pub struct FfiMigrationSchedule {
    /// Heap array of `transfers_len` scheduled transfers, in execution order.
    pub transfers: *mut FfiTransferProposal,
    pub transfers_len: usize,
    /// A rough estimate of how long the schedule takes to fully execute, in hours.
    pub estimated_duration_hours: u32,
}

impl FfiMigrationSchedule {
    fn from_schedule(schedule: MigrationSchedule) -> anyhow::Result<*mut Self> {
        let estimated_duration_hours = schedule.estimated_duration_hours();
        let transfers = schedule
            .transfers()
            .iter()
            .map(FfiTransferProposal::from_proposal)
            .collect::<anyhow::Result<Vec<_>>>()?;
        let (transfers, transfers_len) = ptr_from_vec(transfers);
        Ok(Box::into_raw(Box::new(FfiMigrationSchedule {
            transfers,
            transfers_len,
            estimated_duration_hours,
        })))
    }
}

/// An unsigned-but-proven PCZT awaiting an external signer (element of
/// [`FfiUnsignedTransferPczts`]).
#[repr(C)]
pub struct FfiUnsignedTransferPczt {
    /// The transfer's opaque id, as an owned C string.
    pub id: *mut c_char,
    /// Heap `pczt_len`-byte serialized proven-but-unsigned PCZT.
    pub pczt: *mut u8,
    pub pczt_len: usize,
}

/// The set of unsigned transfer PCZTs to route to an external signer, one per scheduled transfer.
#[repr(C)]
pub struct FfiUnsignedTransferPczts {
    pub ptr: *mut FfiUnsignedTransferPczt,
    pub len: usize,
}

impl FfiUnsignedTransferPczts {
    fn from_vec(pczts: Vec<UnsignedTransferPczt>) -> anyhow::Result<*mut Self> {
        let items = pczts
            .into_iter()
            .map(|u| {
                let id = cstring_raw(u.id().as_str(), "unsigned transfer pczt id")?;
                let (pczt, pczt_len) = ptr_from_vec(u.pczt_bytes().to_vec());
                Ok(FfiUnsignedTransferPczt { id, pczt, pczt_len })
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        let (ptr, len) = ptr_from_vec(items);
        Ok(Box::into_raw(Box::new(FfiUnsignedTransferPczts { ptr, len })))
    }
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
pub unsafe extern "C" fn zcashlc_free_migration_note_split_proposal(ptr: *mut FfiNoteSplitProposal) {
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

// ============================================================================================
// State
// ============================================================================================

/// The current migration state. The app calls this on launch and after every operation; it is
/// also the reconciliation hub (advancing split/transfer/completion phases as the wallet scans).
///
/// # Safety
/// See [`build_context`]. Free the returned pointer with [`zcashlc_free_migration_state`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_state(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut FfiMigrationState {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let state = ctx.migration_state().map_err(map_mig_err)?;
        FfiMigrationState::from_state(state)
    });
    unwrap_exc_or_null(res)
}

/// Migration progress, present only while a migration is in progress. On success the returned
/// pointer is non-null; its `is_present` flag is `false` when there is no progress to report. A
/// NULL return signals an error.
///
/// # Safety
/// See [`build_context`]. Free the returned pointer with [`zcashlc_free_migration_progress`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_progress(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut FfiMigrationProgress {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let progress = ctx.migration_progress().map_err(map_mig_err)?;
        let value = progress
            .as_ref()
            .map_or_else(FfiMigrationProgress::absent, FfiMigrationProgress::present);
        Ok(Box::into_raw(Box::new(value)))
    });
    unwrap_exc_or_null(res)
}

/// Whether the Orchard notes must be split before migration. Returns `false` on error (see
/// `zcashlc_last_error_message`).
///
/// # Safety
/// See [`build_context`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_is_note_split_needed(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> bool {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        ctx.is_note_split_needed().map_err(map_mig_err)
    });
    unwrap_exc_or(res, false)
}

/// Whether any scheduled transfer is past its send height but not yet broadcast. Returns `false`
/// on error (see `zcashlc_last_error_message`).
///
/// # Safety
/// See [`build_context`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_has_overdue_transfers(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> bool {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        ctx.has_overdue_transfers().map_err(map_mig_err)
    });
    unwrap_exc_or(res, false)
}

/// Whether the migration is in an invalid state (spendable Orchard remains but no scheduled
/// transfer covers it). Returns `false` on error (see `zcashlc_last_error_message`).
///
/// # Safety
/// See [`build_context`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_has_invalid_transfers(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> bool {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        ctx.has_invalid_transfers().map_err(map_mig_err)
    });
    unwrap_exc_or(res, false)
}

// ============================================================================================
// Note splitting
// ============================================================================================

/// Compute the optimal note-split proposal for the spendable Orchard balance.
///
/// # Safety
/// See [`build_context`]. Free the returned pointer with
/// [`zcashlc_free_migration_note_split_proposal`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_prepare_note_split(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut FfiNoteSplitProposal {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let proposal = ctx.prepare_note_split().map_err(map_mig_err)?;
        let fee = zat_to_i64(proposal.fee());
        let values: Vec<i64> = proposal
            .output_values()
            .iter()
            .map(|&z| zat_to_i64(z))
            .collect();
        let (output_values, output_values_len) = ptr_from_vec(values);
        Ok(Box::into_raw(Box::new(FfiNoteSplitProposal {
            output_values,
            output_values_len,
            fee,
        })))
    });
    unwrap_exc_or_null(res)
}

/// Build, sign, and persist the note-split transaction, returning the broadcastable prepared
/// transfer. The proposal is passed back as its `(output_values, fee)` parts (from
/// `zcashlc_migration_prepare_note_split`); `usk` is the raw Orchard-era `UnifiedSpendingKey`
/// bytes.
///
/// # Safety
/// See [`build_context`]; `output_values`/`usk_ptr` must be valid for reads of their lengths.
/// Free the returned pointer with [`zcashlc_free_migration_prepared_transfer`].
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
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let values = unsafe { slice_or_empty(output_values, output_values_len) };
        let output_values = values
            .iter()
            .map(|&v| zat_from_i64(v, "note-split output"))
            .collect::<anyhow::Result<Vec<_>>>()?;
        let proposal = NoteSplitProposal::from_parts(output_values, zat_from_i64(fee, "note-split fee")?);
        let usk = unsafe { crate::decode_usk(usk_ptr, usk_len)? };
        let prepared = ctx
            .sign_note_split(&proposal, &usk)
            .map_err(map_mig_err)?;
        FfiPreparedTransfer::some(prepared)
    });
    unwrap_exc_or_null(res)
}

// ============================================================================================
// Proposal / commit
// ============================================================================================

/// The leftover Orchard balance a migration would not cross, when it is large enough to be worth
/// offering the user a choice about (zatoshi). Returns `-1` when there is no such residual (and
/// also `-1` on error, with `zcashlc_last_error_message` set).
///
/// # Safety
/// See [`build_context`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_residual_after_migration(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> i64 {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let residual = ctx.residual_after_migration().map_err(map_mig_err)?;
        Ok(residual.map_or(-1, zat_to_i64))
    });
    unwrap_exc_or(res, -1)
}

/// Generate the full migration schedule for the spendable Orchard balance. When `include_residual`
/// is `true` and a worthwhile residual exists, one extra transfer for it is appended.
///
/// # Safety
/// See [`build_context`]. Free the returned pointer with [`zcashlc_free_migration_schedule`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_propose_transfers(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    include_residual: bool,
) -> *mut FfiMigrationSchedule {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let schedule = ctx
            .propose_migration_transfers(include_residual)
            .map_err(map_mig_err)?;
        FfiMigrationSchedule::from_schedule(schedule)
    });
    unwrap_exc_or_null(res)
}

/// Propose the immediate (single-transaction) migration: sweep the whole spendable Orchard
/// balance into one Ironwood output, executable now.
///
/// # Safety
/// See [`build_context`]. Free the returned pointer with [`zcashlc_free_migration_schedule`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_propose_immediate_transfers(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut FfiMigrationSchedule {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let schedule = ctx
            .propose_immediate_migration_transfers()
            .map_err(map_mig_err)?;
        FfiMigrationSchedule::from_schedule(schedule)
    });
    unwrap_exc_or_null(res)
}

/// Pre-sign and persist every transfer in the schedule. The schedule is passed back as JNI-style
/// parallel arrays (all of length `ids_len`); `usk` is the raw Orchard-era `UnifiedSpendingKey`
/// bytes. Returns `true` on success, `false` on error (see `zcashlc_last_error_message`).
///
/// # Safety
/// See [`build_context`] and [`rebuild_schedule`]; `usk_ptr` must be valid for `usk_len` bytes.
#[allow(clippy::too_many_arguments)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_sign_and_store_schedule(
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
    usk_ptr: *const u8,
    usk_len: usize,
) -> bool {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let schedule = unsafe {
            rebuild_schedule(
                ids,
                ids_len,
                amounts,
                anchor_heights,
                next_executable_after_heights,
                expiry_heights,
                estimated_duration_hours,
            )?
        };
        let usk = unsafe { crate::decode_usk(usk_ptr, usk_len)? };
        ctx.sign_and_store_migration_schedule(&schedule, &usk)
            .map_err(map_mig_err)?;
        Ok(true)
    });
    unwrap_exc_or(res, false)
}

// ============================================================================================
// Delivery
// ============================================================================================

/// The next height-due pre-signed transfer. On success the returned pointer is non-null; its `id`
/// and `pczt` are null when nothing is due. A NULL return signals an error.
///
/// # Safety
/// See [`build_context`]. Free the returned pointer with
/// [`zcashlc_free_migration_prepared_transfer`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_next_due_transfer(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut FfiPreparedTransfer {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        match ctx.next_due_transfer().map_err(map_mig_err)? {
            Some(pt) => FfiPreparedTransfer::some(pt),
            None => Ok(FfiPreparedTransfer::none()),
        }
    });
    unwrap_exc_or_null(res)
}

/// The next height-due scheduled transfer's full proposal (amount, anchor, timing) for an active
/// run, or nothing when no transfer is currently due (no active run, or only the note-split prep is
/// pending). Unlike `zcashlc_migration_next_due_transfer` (an opaque, already-signed PCZT), this
/// exposes the same fields `zcashlc_migration_propose_transfers` originally returned, so a platform
/// can re-arm its background window from `next_executable_after_height` without parsing the PCZT.
///
/// A `NULL` return with no recorded last-error means "nothing pending" (an in-band `None`, like the
/// `-1` sentinel of `zcashlc_migration_residual_after_migration`); a `NULL` return with a recorded
/// last-error signals a failure (see `zcashlc_last_error_message`).
///
/// # Safety
/// See [`build_context`]. Free the returned pointer with
/// [`zcashlc_free_migration_transfer_proposal`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_pending_transfer_proposal(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut FfiTransferProposal {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        match ctx.pending_transfer_proposal().map_err(map_mig_err)? {
            Some(proposal) => FfiTransferProposal::some(&proposal),
            None => Ok(ptr::null_mut()),
        }
    });
    unwrap_exc_or_null(res)
}

/// Extract the broadcast-ready consensus transaction bytes from a serialized signed PCZT (a
/// prepared transfer's `pczt`). Returns the raw transaction bytes as a [`ffi::BoxedSlice`].
///
/// # Safety
/// See [`build_context`]; `pczt_ptr` must be valid for reads of `pczt_len` bytes. Free the
/// returned pointer with `zcashlc_free_boxed_slice`.
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
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let pczt = unsafe { slice_or_empty(pczt_ptr, pczt_len) };
        let tx = ctx.extract_broadcast_tx(pczt).map_err(map_mig_err)?;
        Ok(ffi::BoxedSlice::some(tx))
    });
    unwrap_exc_or_null(res)
}

/// Record the platform's broadcast outcome for a transfer, advancing the engine's state.
///
/// `transfer_id` is the opaque id string the engine handed out. `result_tag` selects the
/// [`TransferResult`] variant: `0` = Success (requires `txid_bytes`, 32 raw internal-order bytes),
/// `1` = NetworkError (uses `retryable`), `2` = InvalidNote, `3` = Expired. `txid_bytes` may be
/// null for every non-Success tag. Returns `true` on success, `false` on error (see
/// `zcashlc_last_error_message`).
///
/// # Safety
/// See [`build_context`]; `transfer_id` must be a valid C string and, when `result_tag == 0`,
/// `txid_bytes` must be valid for reads of 32 bytes.
#[allow(clippy::too_many_arguments)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_record_transfer_result(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    transfer_id: *const c_char,
    result_tag: i32,
    retryable: bool,
    txid_bytes: *const u8,
) -> bool {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        if transfer_id.is_null() {
            return Err(anyhow!("transfer_id is null"));
        }
        let id = unsafe { CStr::from_ptr(transfer_id) }
            .to_str()
            .map_err(|e| anyhow!("transfer_id is not valid UTF-8: {e}"))?
            .to_owned();
        let result = match result_tag {
            0 => {
                if txid_bytes.is_null() {
                    return Err(anyhow!("a success result requires a 32-byte txid"));
                }
                let bytes = unsafe { slice::from_raw_parts(txid_bytes, 32) };
                let arr = <[u8; 32]>::try_from(bytes)
                    .map_err(|_| anyhow!("txid must be exactly 32 bytes"))?;
                TransferResult::Success(TxId::from_bytes(arr))
            }
            1 => TransferResult::NetworkError { retryable },
            2 => TransferResult::InvalidNote,
            3 => TransferResult::Expired,
            other => return Err(anyhow!("invalid transfer result tag: {other}")),
        };
        ctx.record_transfer_result(&TransferId::from_raw(id), result)
            .map_err(map_mig_err)?;
        Ok(true)
    });
    unwrap_exc_or(res, false)
}

/// Whether a sync is required before the next transfer. Returns `false` on error (see
/// `zcashlc_last_error_message`).
///
/// # Safety
/// See [`build_context`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_is_sync_required(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> bool {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        ctx.is_sync_required_before_next_transfer()
            .map_err(map_mig_err)
    });
    unwrap_exc_or(res, false)
}

// ============================================================================================
// Recovery
// ============================================================================================

/// Re-evaluate the remaining spendable Orchard balance and return a fresh schedule (which then
/// flows through the normal confirm → sign path). `include_residual` should match the choice made
/// when the schedule being restarted was first proposed.
///
/// # Safety
/// See [`build_context`]. Free the returned pointer with [`zcashlc_free_migration_schedule`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_restart_step(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    include_residual: bool,
) -> *mut FfiMigrationSchedule {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let schedule = ctx
            .restart_current_migration_step(include_residual)
            .map_err(map_mig_err)?;
        FfiMigrationSchedule::from_schedule(schedule)
    });
    unwrap_exc_or_null(res)
}

/// Re-propose at a fresh anchor and re-sign the active run's scheduled transfers, returning the
/// number refreshed. Returns `-1` on error (see `zcashlc_last_error_message`). `usk` is the raw
/// Orchard-era `UnifiedSpendingKey` bytes; `include_residual` should match the schedule's original
/// choice.
///
/// # Safety
/// See [`build_context`]; `usk_ptr` must be valid for reads of `usk_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_refresh_stale_transfers(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    usk_ptr: *const u8,
    usk_len: usize,
    include_residual: bool,
) -> i64 {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let usk = unsafe { crate::decode_usk(usk_ptr, usk_len)? };
        let count = ctx
            .refresh_stale_transfers(&usk, include_residual)
            .map_err(map_mig_err)?;
        Ok(i64::from(count))
    });
    unwrap_exc_or(res, -1)
}

// ============================================================================================
// External signer (hardware wallet)
// ============================================================================================

/// Build the note-split transaction as an unsigned, proven PCZT for an external signer, staging
/// the proven original in the wallet database. Returns the raw unsigned PCZT bytes as a
/// [`ffi::BoxedSlice`].
///
/// # Safety
/// See [`build_context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_create_unsigned_note_split_pczt(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let pczt = ctx.create_unsigned_note_split_pczt().map_err(map_mig_err)?;
        Ok(ffi::BoxedSlice::some(pczt))
    });
    unwrap_exc_or_null(res)
}

/// Accept the externally signed note-split PCZT: combine it with the staged proven original,
/// verify and finalize it, persist the run, and return the broadcastable prepared transfer.
///
/// # Safety
/// See [`build_context`]; `signed_ptr` must be valid for reads of `signed_len` bytes. Free the
/// returned pointer with [`zcashlc_free_migration_prepared_transfer`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_store_signed_note_split_pczt(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    signed_ptr: *const u8,
    signed_len: usize,
) -> *mut FfiPreparedTransfer {
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let signed = unsafe { slice_or_empty(signed_ptr, signed_len) };
        let prepared = ctx
            .store_signed_note_split_pczt(signed)
            .map_err(map_mig_err)?;
        FfiPreparedTransfer::some(prepared)
    });
    unwrap_exc_or_null(res)
}

/// Build one unsigned, proven PCZT per transfer of the schedule for an external signer, staging
/// each. The schedule is passed as JNI-style parallel arrays (all of length `ids_len`). Returns
/// the `(id, unsigned PCZT)` pairs to route to the signing device.
///
/// # Safety
/// See [`build_context`] and [`rebuild_schedule`]. Free the returned pointer with
/// [`zcashlc_free_migration_unsigned_transfer_pczts`].
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
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let schedule = unsafe {
            rebuild_schedule(
                ids,
                ids_len,
                amounts,
                anchor_heights,
                next_executable_after_heights,
                expiry_heights,
                estimated_duration_hours,
            )?
        };
        let pczts = ctx
            .create_unsigned_transfer_pczts(&schedule)
            .map_err(map_mig_err)?;
        FfiUnsignedTransferPczts::from_vec(pczts)
    });
    unwrap_exc_or_null(res)
}

/// Accept the full set of externally signed transfer PCZTs (all-or-nothing) and, if every staged
/// transfer is matched exactly, persist the committed schedule. The signed set is passed as
/// parallel `ids` / `(pczts, pczt_lens)` arrays (all of length `ids_len`). Returns `true` on
/// success, `false` on error (see `zcashlc_last_error_message`).
///
/// # Safety
/// See [`build_context`]. `ids`, `pczts`, and `pczt_lens` must each be valid for reads of
/// `ids_len` elements (or null when `ids_len == 0`); each `ids[i]` must be a valid C string and
/// each `pczts[i]` valid for `pczt_lens[i]` bytes.
#[allow(clippy::too_many_arguments)]
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
    let res = catch_panic(|| {
        let ctx = unsafe { build_context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let id_ptrs = unsafe { slice_or_empty(ids, ids_len) };
        let pczt_ptrs = unsafe { slice_or_empty(pczts, ids_len) };
        let lens = unsafe { slice_or_empty(pczt_lens, ids_len) };
        let mut signed = Vec::with_capacity(ids_len);
        for i in 0..ids_len {
            if id_ptrs[i].is_null() {
                return Err(anyhow!("signed transfer id at index {i} is null"));
            }
            let id = unsafe { CStr::from_ptr(id_ptrs[i]) }
                .to_str()
                .map_err(|e| anyhow!("signed transfer id at index {i} is not valid UTF-8: {e}"))?
                .to_owned();
            let bytes = unsafe { slice_or_empty(pczt_ptrs[i], lens[i]) }.to_vec();
            signed.push(SignedTransferPczt::from_parts(
                TransferId::from_raw(id),
                bytes,
            ));
        }
        ctx.store_signed_schedule_pczts(&signed)
            .map_err(map_mig_err)?;
        Ok(true)
    });
    unwrap_exc_or(res, false)
}

// ============================================================================================
// Helper
// ============================================================================================

/// The NU6.3 (Ironwood) activation height for the given network id (`0` = testnet, `1` =
/// mainnet), or `-1` when NU6.3 is unset for that network. Returns `-1` on error for any other
/// network id (see `zcashlc_last_error_message`). Regtest/custom networks are out of scope here.
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

    /// A fresh wallet database has no active run, so its state marshals as `NotStarted`. This also
    /// exercises `build_context` (path decode, `parse_network`, `MigrationContext::new` creating
    /// the engine's own tables) end to end over the FFI.
    #[test]
    fn migration_state_on_fresh_db_is_not_started() {
        let path = std::env::temp_dir().join(format!(
            "zcashlc_migration_state_{}.sqlite",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        let path_bytes = path.to_str().unwrap().as_bytes();
        let account = [7u8; 16];
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
}
