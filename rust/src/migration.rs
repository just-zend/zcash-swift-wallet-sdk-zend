//! FFI wrapping [`zodl_ironwood_migration::MigrationContext`], the synchronous, network-free
//! Orchard→Ironwood migration engine.
//!
//! Every function marshals whole `serde` types as JSON through [`ffi::BoxedSlice`]: on success it
//! returns a non-null `BoxedSlice` holding the JSON body; on failure it returns null and stores the
//! message for `zcashlc_last_error_message`. Void crate methods encode `()` (`"null"`), which the
//! Swift welding ignores. The crate never broadcasts — `PreparedTx.raw_pczt` is a serialized PCZT;
//! the Swift layer extracts the consensus transaction via `zcashlc_migration_extract_broadcast_tx`,
//! broadcasts that, and reports the outcome back via `record_transfer_result`.

use std::cell::Cell;
use std::ffi::{CStr, OsStr};
use std::os::raw::c_char;
use std::os::unix::ffi::OsStrExt;
use std::slice;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use zcash_client_backend::data_api::{Account, WalletRead};
use zodl_ironwood_migration::{
    ImmediateMigrationPreview, InvalidStateError, KnownUnsentReason, LocalSubmissionFailure,
    MigrationContext, MigrationError, MigrationIntentSchedule, MigrationSchedule,
    NoteSplitProposal, SubmissionPolicy, SubmissionPolicyValidationFailure, TransferPczt,
    TransferResult, migration_engine_schema_metadata,
};

use crate::ffi;
use crate::unwrap_exc_or_null;

/// Stable marker surfaced through `zcashlc_last_error_message` when an ordinary wallet spend is
/// rejected because the Ironwood migration owns/reserves the account's spendable Orchard state.
/// Swift maps this marker to a typed `ZcashError`; keep it free of user or transaction data.
pub(crate) const ORDINARY_SPENDS_BLOCKED_ERROR_MARKER: &str =
    "IRONWOOD_MIGRATION_ORDINARY_SPENDS_BLOCKED";

/// Stable process-local code read by Swift immediately after a protected FFI call fails. The
/// underlying `ffi_helpers` channel exposes prose only; this independent code prevents behavior
/// from depending on that prose and keeps raw Rust errors out of telemetry.
const MIGRATION_FFI_ERROR_NONE: u32 = 0;
const MIGRATION_FFI_ERROR_ORDINARY_SPENDS_BLOCKED: u32 = 1;
/// `bind_submission_policy` rejected a changed immutable policy because transaction artifacts
/// already exist. This is deliberately distinct from stale revision, schema, I/O, and corruption.
const MIGRATION_FFI_ERROR_IMMUTABLE_SUBMISSION_POLICY_CONFLICT: u32 = 2;
const MIGRATION_FFI_ERROR_INITIALIZE_NOT_SYNCED: u32 = 10;
const MIGRATION_FFI_ERROR_INITIALIZE_NOT_INITIALIZED: u32 = 11;
const MIGRATION_FFI_ERROR_INITIALIZE_SCHEMA_INCOMPATIBLE: u32 = 12;
const MIGRATION_FFI_ERROR_INITIALIZE_ENGINE_SCHEMA_NEWER: u32 = 13;
const MIGRATION_FFI_ERROR_INITIALIZE_ENGINE_SCHEMA_CORRUPT: u32 = 14;
const MIGRATION_FFI_ERROR_INITIALIZE_CONSENSUS_MISMATCH: u32 = 15;
const MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_BUSY: u32 = 20;
const MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_LOCKED: u32 = 21;
const MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_FULL: u32 = 22;
const MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_READ_ONLY: u32 = 23;
const MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_CORRUPT: u32 = 24;
const MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_UNAVAILABLE: u32 = 25;
const MIGRATION_FFI_ERROR_INITIALIZE_BACKEND: u32 = 30;
const MIGRATION_FFI_ERROR_INITIALIZE_PIPELINE: u32 = 31;
const MIGRATION_FFI_ERROR_INITIALIZE_OTHER_INVALID: u32 = 32;

thread_local! {
    static LAST_MIGRATION_FFI_ERROR_CODE: Cell<u32> = const { Cell::new(MIGRATION_FFI_ERROR_NONE) };
}

fn set_migration_ffi_error_code(code: u32) {
    LAST_MIGRATION_FFI_ERROR_CODE.with(|value| value.set(code));
}

/// Takes the stable migration-specific error code for the immediately preceding protected FFI
/// operation on this thread, resetting it to zero. `0` means no migration-specific classification.
/// Codes are a behavior boundary, not log text: Swift maps them to public typed failures and never
/// parses or exports the underlying Rust/SQLite message.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_last_migration_error_code() -> u32 {
    LAST_MIGRATION_FFI_ERROR_CODE.with(|value| value.replace(MIGRATION_FFI_ERROR_NONE))
}

fn sqlite_initialization_error_code(error: &rusqlite::Error) -> u32 {
    use rusqlite::ffi::ErrorCode;

    match error {
        rusqlite::Error::SqliteFailure(error, _) => match error.code {
            ErrorCode::DatabaseBusy => MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_BUSY,
            ErrorCode::DatabaseLocked | ErrorCode::FileLockingProtocolFailed => {
                MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_LOCKED
            }
            ErrorCode::DiskFull => MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_FULL,
            ErrorCode::ReadOnly => MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_READ_ONLY,
            ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase => {
                MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_CORRUPT
            }
            ErrorCode::CannotOpen
            | ErrorCode::PermissionDenied
            | ErrorCode::SystemIoFailure
            | ErrorCode::NoLargeFileSupport => MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_UNAVAILABLE,
            _ => MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_UNAVAILABLE,
        },
        _ => MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_UNAVAILABLE,
    }
}

fn initialization_error_code(error: &MigrationError) -> u32 {
    match error {
        MigrationError::NotSynced => MIGRATION_FFI_ERROR_INITIALIZE_NOT_SYNCED,
        MigrationError::NotInitialized => MIGRATION_FFI_ERROR_INITIALIZE_NOT_INITIALIZED,
        MigrationError::InvalidState(InvalidStateError::SchemaIncompatible) => {
            MIGRATION_FFI_ERROR_INITIALIZE_SCHEMA_INCOMPATIBLE
        }
        MigrationError::InvalidState(InvalidStateError::EngineSchemaNewer { .. }) => {
            MIGRATION_FFI_ERROR_INITIALIZE_ENGINE_SCHEMA_NEWER
        }
        MigrationError::InvalidState(InvalidStateError::EngineSchemaCorrupt { .. }) => {
            MIGRATION_FFI_ERROR_INITIALIZE_ENGINE_SCHEMA_CORRUPT
        }
        MigrationError::InvalidState(InvalidStateError::ConsensusConfigurationMismatch) => {
            MIGRATION_FFI_ERROR_INITIALIZE_CONSENSUS_MISMATCH
        }
        MigrationError::InvalidState(_) => MIGRATION_FFI_ERROR_INITIALIZE_OTHER_INVALID,
        MigrationError::Db(error) => sqlite_initialization_error_code(error),
        MigrationError::Backend(zcash_client_sqlite::error::SqliteClientError::DbError(error)) => {
            sqlite_initialization_error_code(error)
        }
        MigrationError::Backend(zcash_client_sqlite::error::SqliteClientError::CorruptedData(
            _,
        )) => MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_CORRUPT,
        MigrationError::Backend(zcash_client_sqlite::error::SqliteClientError::Io(_)) => {
            MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_UNAVAILABLE
        }
        MigrationError::Backend(_) => MIGRATION_FFI_ERROR_INITIALIZE_BACKEND,
        MigrationError::Pipeline(_) => MIGRATION_FFI_ERROR_INITIALIZE_PIPELINE,
    }
}

/// Preserve only the stable category across FFI. The source error may contain a database path,
/// schema object, SQL, or other device-local content and must never become typed app telemetry.
fn sanitized_initialization_error(error: MigrationError) -> anyhow::Error {
    let code = initialization_error_code(&error);
    set_migration_ffi_error_code(code);
    anyhow!("IRONWOOD_MIGRATION_INITIALIZATION_FAILED:{code}")
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

fn ensure_exact_spending_account(
    expected: [u8; 16],
    actual: Option<[u8; 16]>,
) -> anyhow::Result<()> {
    match actual {
        Some(actual) if actual == expected => Ok(()),
        Some(_) => Err(anyhow!(
            "unified spending key belongs to a different wallet account"
        )),
        None => Err(anyhow!(
            "unified spending key does not belong to an account in this wallet"
        )),
    }
}

/// Decode a spend-authority input and prove through the wallet DB that its UFVK resolves to the
/// exact account UUID carried by this migration FFI call. This check runs before every engine
/// mutation that accepts a USK; a merely valid signature from another wallet account is never an
/// acceptable substitute for account identity.
///
/// # Safety
/// All pointers must satisfy their enclosing FFI function's documented read requirements.
unsafe fn ensure_usk_matches_migration_account(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    usk_ptr: *const u8,
    usk_len: usize,
) -> anyhow::Result<()> {
    let network = crate::parse_network(network_id)?;
    let expected = unsafe { account_16(account_uuid_bytes)? };
    let usk = unsafe { crate::decode_usk(usk_ptr, usk_len)? };
    let db = unsafe { crate::wallet_db(db_data, db_data_len, network)? };
    let actual = db
        .get_account_for_ufvk(&usk.to_unified_full_viewing_key())?
        .map(|account| *account.id().expose_uuid().as_bytes());
    ensure_exact_spending_account(expected, actual)
}

/// Fail closed before an ordinary account spend while an authoritative migration snapshot blocks
/// those spends. This is called from the ordinary proposal *and* materialization FFI paths so a
/// proposal created before migration began cannot bypass the reservation.
///
/// # Safety
/// `db_data` must satisfy the safety requirements of [`migration_db_path`].
pub(crate) unsafe fn ensure_account_ordinary_spends_allowed(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid: [u8; 16],
    network: crate::NetworkParams,
) -> anyhow::Result<()> {
    // Fail closed for every guard failure, including inability to reconcile/read authoritative
    // state. Clear only after the guard positively proves this account is spendable.
    set_migration_ffi_error_code(MIGRATION_FFI_ERROR_ORDINARY_SPENDS_BLOCKED);
    let path = unsafe { migration_db_path(db_data, db_data_len)? };
    let chain_id = network.canonical_chain_id().to_string();
    let ctx = MigrationContext::new_with_chain_id(path, network, &chain_id, account_uuid)
        .map_err(|error| anyhow!("open migration context for ordinary-spend guard: {error}"))?;
    // Snapshot reconciliation runs first so a launch that already observed completion can
    // self-heal and unblock sends instead of relying on the app to call a separate getter.
    if ctx
        .migration_snapshot()
        .map_err(|e| anyhow!("reconcile ordinary-spend guard: {e}"))?
        .ordinary_spends_blocked
    {
        return Err(anyhow!(ORDINARY_SPENDS_BLOCKED_ERROR_MARKER));
    }
    set_migration_ffi_error_code(MIGRATION_FFI_ERROR_NONE);
    Ok(())
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
) -> anyhow::Result<MigrationContext<crate::NetworkParams>> {
    let path = unsafe { migration_db_path(db_data, db_data_len)? };
    // Resolve the same consensus parameters (identity + custom activation heights) the rest of the SDK
    // uses for this network id, so migration runs with matching consensus — including a custom network
    // (network_id 2, configured via `zcashlc_set_custom_network`, e.g. base = Main + custom heights).
    let network = crate::parse_network(network_id)?;
    let account = unsafe { account_16(account_uuid_bytes)? };
    let chain_id = network.canonical_chain_id().to_string();
    MigrationContext::new_with_chain_id(path, network, &chain_id, account)
        .map_err(|error| anyhow!("open migration context: {error}"))
}

/// Read migration-engine schema metadata without initialization or DDL (JSON
/// `MigrationEngineSchemaMetadata`). This stable forward-schema probe never parses error prose.
///
/// # Safety
/// `db_data` must satisfy [`migration_db_path`]. Free the returned pointer with
/// `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_engine_schema_metadata(
    db_data: *const u8,
    db_data_len: usize,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let path = unsafe { migration_db_path(db_data, db_data_len)? };
        let metadata = migration_engine_schema_metadata(path)
            .map_err(|error| anyhow!("read migration engine schema metadata: {error}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&metadata)?))
    });
    unwrap_exc_or_null(res)
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

/// Authoritative revisioned migration snapshot (JSON `MigrationSnapshot`). This performs the
/// engine's idempotent reconciliation before returning state, counts, failure/recovery metadata,
/// the next safe action, and the ordinary-spend reservation flag in one coherent read.
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_snapshot(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let value = ctx
            .migration_snapshot()
            .map_err(|e| anyhow!("migration_snapshot: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Atomically persist the private-migration signer choice and SDK-validated submission policy
/// before proving/signing. Exact retries are idempotent and return the fresh authoritative
/// snapshot as JSON.
///
/// # Safety
/// See [`context`]; `policy_ptr` must be valid for reads of `policy_len` bytes. Free the returned
/// pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_begin_private(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    external_signer: bool,
    policy_ptr: *const u8,
    policy_len: usize,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let policy: SubmissionPolicy =
            serde_json::from_slice(unsafe { slice::from_raw_parts(policy_ptr, policy_len) })
                .map_err(|error| anyhow!("decode SubmissionPolicy: {error}"))?;
        let snapshot = ctx
            .begin_private_migration(external_signer, policy)
            .map_err(|error| anyhow!("begin_private_migration: {error}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&snapshot)?))
    });
    unwrap_exc_or_null(res)
}

/// Bind a validated immutable submission policy to the active run at `expected_revision`,
/// returning the fresh authoritative snapshot as JSON.
///
/// # Safety
/// See [`context`]; `policy_ptr` must be valid for reads of `policy_len` bytes. Free the returned
/// pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_bind_submission_policy(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    expected_run_id: *const c_char,
    expected_revision: u64,
    policy_ptr: *const u8,
    policy_len: usize,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        set_migration_ffi_error_code(MIGRATION_FFI_ERROR_NONE);
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let expected_run_id = unsafe { CStr::from_ptr(expected_run_id) }
            .to_str()
            .map_err(|error| anyhow!("expected_run_id: {error}"))?;
        let policy: SubmissionPolicy =
            serde_json::from_slice(unsafe { slice::from_raw_parts(policy_ptr, policy_len) })
                .map_err(|error| anyhow!("decode SubmissionPolicy: {error}"))?;
        let snapshot = match ctx.bind_submission_policy(expected_run_id, expected_revision, policy)
        {
            Ok(snapshot) => snapshot,
            Err(error) => {
                if matches!(
                    error,
                    MigrationError::InvalidState(InvalidStateError::SubmissionPolicyMismatch)
                ) {
                    set_migration_ffi_error_code(
                        MIGRATION_FFI_ERROR_IMMUTABLE_SUBMISSION_POLICY_CONFLICT,
                    );
                }
                return Err(anyhow!("bind_submission_policy: {error}"));
            }
        };
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&snapshot)?))
    });
    unwrap_exc_or_null(res)
}

/// Durably record why the selected endpoint/policy could not be validated before any network
/// submission. `failure` is a stable FFI discriminant: `0` means endpoint consensus mismatch and
/// `1` means the selected policy differs from the run's immutable bound policy. Exact retries at
/// the resulting revision are idempotent in the engine.
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_record_submission_policy_validation_failure(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    expected_run_id: *const c_char,
    expected_revision: u64,
    failure: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let expected_run_id = unsafe { CStr::from_ptr(expected_run_id) }
            .to_str()
            .map_err(|error| anyhow!("expected_run_id: {error}"))?;
        let failure = match failure {
            0 => SubmissionPolicyValidationFailure::EndpointConsensusMismatch,
            1 => SubmissionPolicyValidationFailure::SubmissionPolicyMismatch,
            value => {
                return Err(anyhow!(
                    "invalid submission-policy validation failure: {value}"
                ));
            }
        };
        let snapshot = ctx
            .record_submission_policy_validation_failure(
                expected_run_id,
                expected_revision,
                failure,
            )
            .map_err(|error| anyhow!("record_submission_policy_validation_failure: {error}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&snapshot)?))
    });
    unwrap_exc_or_null(res)
}

/// Pause the active run at an optimistic-concurrency revision and return its fresh snapshot.
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_pause(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    expected_run_id: *const c_char,
    expected_revision: u64,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let expected_run_id = unsafe { CStr::from_ptr(expected_run_id) }
            .to_str()
            .map_err(|error| anyhow!("expected_run_id: {error}"))?;
        let snapshot = ctx
            .pause_migration(expected_run_id, expected_revision)
            .map_err(|error| anyhow!("pause_migration: {error}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&snapshot)?))
    });
    unwrap_exc_or_null(res)
}

/// Clear only an engine-owned `RetryAutomatically` failure at `expected_revision` and derive the
/// next durable continuation phase. User-reapproval, proof rebuild, paused, abandoning, and
/// terminal states are rejected by the engine rather than being generically reset.
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_retry_automatic_recovery(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    expected_run_id: *const c_char,
    expected_revision: u64,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let expected_run_id = unsafe { CStr::from_ptr(expected_run_id) }
            .to_str()
            .map_err(|error| anyhow!("expected_run_id: {error}"))?;
        let snapshot = ctx
            .retry_automatic_recovery(expected_run_id, expected_revision)
            .map_err(|error| anyhow!("retry_automatic_recovery: {error}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&snapshot)?))
    });
    unwrap_exc_or_null(res)
}

/// Resume a paused active run and return its fresh snapshot.
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_resume(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    expected_run_id: *const c_char,
    expected_revision: u64,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let expected_run_id = unsafe { CStr::from_ptr(expected_run_id) }
            .to_str()
            .map_err(|error| anyhow!("expected_run_id: {error}"))?;
        let snapshot = ctx
            .resume_migration(expected_run_id, expected_revision)
            .map_err(|error| anyhow!("resume_migration: {error}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&snapshot)?))
    });
    unwrap_exc_or_null(res)
}

/// Request safe abandonment at an optimistic-concurrency revision and return the fresh snapshot.
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_request_abandonment(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    expected_run_id: *const c_char,
    expected_revision: u64,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let expected_run_id = unsafe { CStr::from_ptr(expected_run_id) }
            .to_str()
            .map_err(|error| anyhow!("expected_run_id: {error}"))?;
        let snapshot = ctx
            .request_abandonment(expected_run_id, expected_revision)
            .map_err(|error| anyhow!("request_abandonment: {error}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&snapshot)?))
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
    expected_run_id: *const c_char,
    expected_revision: u64,
    proposal_ptr: *const u8,
    proposal_len: usize,
    usk_ptr: *const u8,
    usk_len: usize,
    expected_policy_fingerprint: *const c_char,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        unsafe {
            ensure_usk_matches_migration_account(
                db_data,
                db_data_len,
                account_uuid_bytes,
                network_id,
                usk_ptr,
                usk_len,
            )?
        };
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let expected_run_id = unsafe { CStr::from_ptr(expected_run_id) }
            .to_str()
            .map_err(|error| anyhow!("expected_run_id: {error}"))?;
        let proposal: NoteSplitProposal =
            serde_json::from_slice(unsafe { slice::from_raw_parts(proposal_ptr, proposal_len) })
                .map_err(|e| anyhow!("decode NoteSplitProposal: {e}"))?;
        let usk = unsafe { slice::from_raw_parts(usk_ptr, usk_len) };
        let expected_policy_fingerprint = unsafe { CStr::from_ptr(expected_policy_fingerprint) }
            .to_str()
            .map_err(|e| anyhow!("expected_policy_fingerprint: {e}"))?;
        let value = ctx
            .sign_note_split(
                expected_run_id,
                expected_revision,
                &proposal,
                usk,
                expected_policy_fingerprint,
            )
            .map_err(|e| anyhow!("sign_note_split: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Build the note-split transaction as an unsigned PCZT for an external signer (JSON
/// `ClaimedNoteSplitPczt`). The exact approved proposal is revalidated before proving or run
/// mutation; the original remains staged inside the engine under the signer-round token.
///
/// # Safety
/// See [`context`]; `proposal_ptr` must be valid for reads of `proposal_len` bytes. Free the
/// returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_create_unsigned_note_split_pczt(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    expected_run_id: *const c_char,
    expected_revision: u64,
    proposal_ptr: *const u8,
    proposal_len: usize,
    expected_policy_fingerprint: *const c_char,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let expected_run_id = unsafe { CStr::from_ptr(expected_run_id) }
            .to_str()
            .map_err(|error| anyhow!("expected_run_id: {error}"))?;
        let proposal: NoteSplitProposal =
            serde_json::from_slice(unsafe { slice::from_raw_parts(proposal_ptr, proposal_len) })
                .map_err(|e| anyhow!("decode NoteSplitProposal: {e}"))?;
        let expected_policy_fingerprint = unsafe { CStr::from_ptr(expected_policy_fingerprint) }
            .to_str()
            .map_err(|e| anyhow!("expected_policy_fingerprint: {e}"))?;
        let claim = ctx
            .create_unsigned_note_split_pczt(
                expected_run_id,
                expected_revision,
                &proposal,
                expected_policy_fingerprint,
            )
            .map_err(|e| anyhow!("create_unsigned_note_split_pczt: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&claim)?))
    });
    unwrap_exc_or_null(res)
}

/// Accept the externally signed note-split PCZT: merge the device's signatures into the staged
/// original, verify + finalize, and persist the run (JSON `PreparedTx`). Broadcasting the
/// returned `PreparedTx` then flows through the existing extract + submit + record path.
/// `run_id` and `signer_token` must match the staged signer round; `pczt_ptr` is the raw
/// device-signed PCZT bytes.
///
/// # Safety
/// See [`context`]; strings must be valid C strings and `pczt_ptr` valid for reads of
/// `pczt_len` bytes. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_store_signed_note_split_pczt(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    run_id: *const c_char,
    signer_token: *const c_char,
    pczt_ptr: *const u8,
    pczt_len: usize,
    expected_policy_fingerprint: *const c_char,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let run_id = unsafe { CStr::from_ptr(run_id) }
            .to_str()
            .map_err(|e| anyhow!("run_id: {e}"))?;
        let signer_token = unsafe { CStr::from_ptr(signer_token) }
            .to_str()
            .map_err(|e| anyhow!("signer_token: {e}"))?;
        let pczt = unsafe { slice::from_raw_parts(pczt_ptr, pczt_len) };
        let expected_policy_fingerprint = unsafe { CStr::from_ptr(expected_policy_fingerprint) }
            .to_str()
            .map_err(|e| anyhow!("expected_policy_fingerprint: {e}"))?;
        let value = ctx
            .store_signed_note_split_pczt(run_id, signer_token, pczt, expected_policy_fingerprint)
            .map_err(|e| anyhow!("store_signed_note_split_pczt: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Build one unsigned PCZT per transfer of the schedule for an external signer (JSON
/// `Vec<TransferPczt>`, each `{ id, raw_pczt }`). The proven originals are staged inside the
/// crate keyed by transfer id; the platform routes the unsigned PCZTs to the device and hands
/// the signed set back to `zcashlc_migration_store_signed_schedule_pczts`. `schedule` is JSON
/// `MigrationSchedule`.
///
/// # Safety
/// See [`context`]; `schedule_ptr` must be valid for reads of `schedule_len` bytes. Free the
/// returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_create_unsigned_transfer_pczts(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    schedule_ptr: *const u8,
    schedule_len: usize,
    expected_policy_fingerprint: *const c_char,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let schedule: MigrationSchedule =
            serde_json::from_slice(unsafe { slice::from_raw_parts(schedule_ptr, schedule_len) })
                .map_err(|e| anyhow!("decode MigrationSchedule: {e}"))?;
        let expected_policy_fingerprint = unsafe { CStr::from_ptr(expected_policy_fingerprint) }
            .to_str()
            .map_err(|e| anyhow!("expected_policy_fingerprint: {e}"))?;
        let value = ctx
            .create_unsigned_transfer_pczts(&schedule, expected_policy_fingerprint)
            .map_err(|e| anyhow!("create_unsigned_transfer_pczts: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Accept the full set of externally signed transfer PCZTs — all-or-nothing (JSON `null` on
/// success). Every staged transfer must be matched by id; a partial, mismatched, or invalid set
/// stores nothing. `signed` is JSON `Vec<TransferPczt>` (`{ id, raw_pczt }` pairs).
///
/// # Safety
/// See [`context`]; `signed_ptr` must be valid for reads of `signed_len` bytes. Free the
/// returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_store_signed_schedule_pczts(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    signed_ptr: *const u8,
    signed_len: usize,
    expected_policy_fingerprint: *const c_char,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let signed: Vec<TransferPczt> =
            serde_json::from_slice(unsafe { slice::from_raw_parts(signed_ptr, signed_len) })
                .map_err(|e| anyhow!("decode signed transfer PCZTs: {e}"))?;
        let expected_policy_fingerprint = unsafe { CStr::from_ptr(expected_policy_fingerprint) }
            .to_str()
            .map_err(|e| anyhow!("expected_policy_fingerprint: {e}"))?;
        ctx.store_signed_schedule_pczts(&signed, expected_policy_fingerprint)
            .map_err(|e| anyhow!("store_signed_schedule_pczts: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&())?))
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

/// Generate the immediate (single-transaction) migration schedule (JSON `MigrationSchedule`): one
/// transfer sweeping the whole spendable Orchard balance into Ironwood, executable now.
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_propose_immediate(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let value = ctx
            .propose_immediate_migration_transfers()
            .map_err(|e| anyhow!("propose_immediate_migration_transfers: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Preview exact immediate-migration economics (JSON `ImmediateMigrationPreview`) without
/// creating a draft, run, reservation, signature, or transaction. The engine pins the wallet
/// reads and upstream ZIP-317 proposal probe to one SQLite snapshot.
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_preview_immediate(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let path = unsafe { migration_db_path(db_data, db_data_len)? };
        let metadata = migration_engine_schema_metadata(path)
            .map_err(|error| anyhow!("read migration schema before preview: {error}"))?;
        if metadata.found_version != Some(metadata.supported_version) {
            // Context construction initializes/upgrades the engine schema. Refuse that implicit
            // write here so the preview FFI remains read-only even when called out of lifecycle
            // order; `initialize_post_upgrade` owns all schema creation and upgrades.
            return Err(anyhow!(
                "migration preview requires initialize_post_upgrade at the current schema"
            ));
        }
        let network = crate::parse_network(network_id)?;
        let chain_id = network.canonical_chain_id().to_string();
        let account = unsafe { account_16(account_uuid_bytes)? };
        let value: ImmediateMigrationPreview =
            MigrationContext::preview_immediate_migration_read_only(
                path, network, &chain_id, account,
            )
            .map_err(|error| anyhow!("preview_immediate_migration: {error}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Propose the private, anchorless intent schedule (JSON `MigrationIntentSchedule`). No
/// transaction anchor or expiry is selected until an individual intent becomes due.
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_propose_private_intents(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let value = ctx
            .propose_private_migration_intents()
            .map_err(|e| anyhow!("propose_private_migration_intents: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Propose one immediate, anchorless intent (JSON `MigrationIntentSchedule`).
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_propose_immediate_intent(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let value = ctx
            .propose_immediate_migration_intent()
            .map_err(|e| anyhow!("propose_immediate_migration_intent: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Atomically commit one user-approved anchorless intent schedule and SDK-validated submission
/// policy with a revision compare-and-set token (JSON `MigrationSnapshot` on success).
/// `external_signer` permanently selects the signer mode for the run.
///
/// # Safety
/// See [`context`]; `schedule_ptr` and `policy_ptr` must be valid for reads of their respective
/// lengths. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_commit_intents(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    schedule_ptr: *const u8,
    schedule_len: usize,
    external_signer: bool,
    policy_ptr: *const u8,
    policy_len: usize,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let schedule: MigrationIntentSchedule =
            serde_json::from_slice(unsafe { slice::from_raw_parts(schedule_ptr, schedule_len) })
                .map_err(|e| anyhow!("decode MigrationIntentSchedule: {e}"))?;
        let policy: SubmissionPolicy =
            serde_json::from_slice(unsafe { slice::from_raw_parts(policy_ptr, policy_len) })
                .map_err(|error| anyhow!("decode SubmissionPolicy: {error}"))?;
        let snapshot = ctx
            .commit_migration_intents(&schedule, external_signer, policy)
            .map_err(|e| anyhow!("commit_migration_intents: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&snapshot)?))
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
    expected_policy_fingerprint: *const c_char,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        unsafe {
            ensure_usk_matches_migration_account(
                db_data,
                db_data_len,
                account_uuid_bytes,
                network_id,
                usk_ptr,
                usk_len,
            )?
        };
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let schedule: MigrationSchedule =
            serde_json::from_slice(unsafe { slice::from_raw_parts(schedule_ptr, schedule_len) })
                .map_err(|e| anyhow!("decode MigrationSchedule: {e}"))?;
        let usk = unsafe { slice::from_raw_parts(usk_ptr, usk_len) };
        let expected_policy_fingerprint = unsafe { CStr::from_ptr(expected_policy_fingerprint) }
            .to_str()
            .map_err(|e| anyhow!("expected_policy_fingerprint: {e}"))?;
        ctx.sign_and_store_migration_schedule(&schedule, usk, expected_policy_fingerprint)
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

/// Atomically claim the persisted prep transaction or a due legacy transfer (JSON
/// `Option<ClaimedTx>`). The claim token must accompany the submission result.
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_claim_next_due_transfer(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    expected_run_id: *const c_char,
    expected_revision: u64,
    lease_duration_ms: u64,
    expected_policy_fingerprint: *const c_char,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let expected_run_id = unsafe { CStr::from_ptr(expected_run_id) }
            .to_str()
            .map_err(|error| anyhow!("expected_run_id: {error}"))?;
        let expected_policy_fingerprint = unsafe { CStr::from_ptr(expected_policy_fingerprint) }
            .to_str()
            .map_err(|e| anyhow!("expected_policy_fingerprint: {e}"))?;
        let value = ctx
            .claim_next_due_transfer(
                expected_run_id,
                expected_revision,
                lease_duration_ms,
                expected_policy_fingerprint,
            )
            .map_err(|e| anyhow!("claim_next_due_transfer: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Ingest and atomically claim the exact persisted denomination-split transaction (JSON
/// `Option<ClaimedTx>`). Both software and external-signer split flows call this after the signed
/// PCZT has been durably persisted. The claim token must accompany the submission result.
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_claim_note_split_submission(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    expected_run_id: *const c_char,
    expected_revision: u64,
    lease_duration_ms: u64,
    expected_policy_fingerprint: *const c_char,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let expected_run_id = unsafe { CStr::from_ptr(expected_run_id) }
            .to_str()
            .map_err(|error| anyhow!("expected_run_id: {error}"))?;
        let expected_policy_fingerprint = unsafe { CStr::from_ptr(expected_policy_fingerprint) }
            .to_str()
            .map_err(|e| anyhow!("expected_policy_fingerprint: {e}"))?;
        let value = ctx
            .claim_note_split_submission(
                expected_run_id,
                expected_revision,
                lease_duration_ms,
                expected_policy_fingerprint,
            )
            .map_err(|e| anyhow!("claim_note_split_submission: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Retrieve the exact already-staged proven-but-unsigned note-split signer envelope after
/// relaunch. This never proves or stages replacement bytes (JSON `Option<ClaimedNoteSplitPczt>`).
///
/// # Safety
/// See [`context`]; string pointers must be valid C strings. Free the returned pointer with
/// `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_resume_note_split_external_pczt(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    expected_run_id: *const c_char,
    expected_revision: u64,
    expected_policy_fingerprint: *const c_char,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let expected_run_id = unsafe { CStr::from_ptr(expected_run_id) }
            .to_str()
            .map_err(|error| anyhow!("expected_run_id: {error}"))?;
        let expected_policy_fingerprint = unsafe { CStr::from_ptr(expected_policy_fingerprint) }
            .to_str()
            .map_err(|error| anyhow!("expected_policy_fingerprint: {error}"))?;
        let value = ctx
            .resume_staged_note_split_pczt(
                expected_run_id,
                expected_revision,
                expected_policy_fingerprint,
            )
            .map_err(|error| anyhow!("resume_staged_note_split_pczt: {error}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Materialize one due software-signer intent at a fresh natural anchor, durably stage and ingest
/// its exact bytes, then atomically lease it for submission (JSON `Option<ClaimedTx>`).
///
/// # Safety
/// See [`context`]; `usk_ptr` must be valid for reads of `usk_len` bytes. Free the returned pointer
/// with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_materialize_and_claim_next_due(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    expected_run_id: *const c_char,
    expected_revision: u64,
    lease_duration_ms: u64,
    usk_ptr: *const u8,
    usk_len: usize,
    expected_policy_fingerprint: *const c_char,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        unsafe {
            ensure_usk_matches_migration_account(
                db_data,
                db_data_len,
                account_uuid_bytes,
                network_id,
                usk_ptr,
                usk_len,
            )?
        };
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let expected_run_id = unsafe { CStr::from_ptr(expected_run_id) }
            .to_str()
            .map_err(|error| anyhow!("expected_run_id: {error}"))?;
        let usk = unsafe { slice::from_raw_parts(usk_ptr, usk_len) };
        let expected_policy_fingerprint = unsafe { CStr::from_ptr(expected_policy_fingerprint) }
            .to_str()
            .map_err(|e| anyhow!("expected_policy_fingerprint: {e}"))?;
        let value = ctx
            .materialize_and_claim_next_due(
                expected_run_id,
                expected_revision,
                lease_duration_ms,
                usk,
                expected_policy_fingerprint,
            )
            .map_err(|e| anyhow!("materialize_and_claim_next_due: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Build and lease one due proven-but-unsigned PCZT for an external signer (JSON
/// `Option<ClaimedTransferPczt>`). It is never safe for a background worker to sign this value.
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_stage_next_due_external_pczt(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    expected_run_id: *const c_char,
    expected_revision: u64,
    lease_duration_ms: u64,
    expected_policy_fingerprint: *const c_char,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let expected_run_id = unsafe { CStr::from_ptr(expected_run_id) }
            .to_str()
            .map_err(|error| anyhow!("expected_run_id: {error}"))?;
        let expected_policy_fingerprint = unsafe { CStr::from_ptr(expected_policy_fingerprint) }
            .to_str()
            .map_err(|e| anyhow!("expected_policy_fingerprint: {e}"))?;
        let value = ctx
            .stage_next_due_external_pczt(
                expected_run_id,
                expected_revision,
                lease_duration_ms,
                expected_policy_fingerprint,
            )
            .map_err(|e| anyhow!("stage_next_due_external_pczt: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Retrieve an already-staged due external-signer envelope after relaunch, preserving its bytes
/// and signer token while atomically renewing the signing lease (JSON
/// `Option<ClaimedTransferPczt>`). This never materializes a new intent.
///
/// # Safety
/// See [`context`]; string pointers must be valid C strings. Free the returned pointer with
/// `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_resume_due_external_pczt(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    expected_run_id: *const c_char,
    expected_revision: u64,
    lease_duration_ms: u64,
    expected_policy_fingerprint: *const c_char,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let expected_run_id = unsafe { CStr::from_ptr(expected_run_id) }
            .to_str()
            .map_err(|error| anyhow!("expected_run_id: {error}"))?;
        let expected_policy_fingerprint = unsafe { CStr::from_ptr(expected_policy_fingerprint) }
            .to_str()
            .map_err(|error| anyhow!("expected_policy_fingerprint: {error}"))?;
        let value = ctx
            .resume_due_external_pczt(
                expected_run_id,
                expected_revision,
                lease_duration_ms,
                expected_policy_fingerprint,
            )
            .map_err(|error| anyhow!("resume_due_external_pczt: {error}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Resume a durably signed staged or expired-lease submitting intent without signer-session state
/// (JSON `Option<ClaimedTx>`). Unsigned external-signer rows are deliberately excluded.
///
/// # Safety
/// See [`context`]. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_resume_staged_submission(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    expected_run_id: *const c_char,
    expected_revision: u64,
    lease_duration_ms: u64,
    expected_policy_fingerprint: *const c_char,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let expected_run_id = unsafe { CStr::from_ptr(expected_run_id) }
            .to_str()
            .map_err(|error| anyhow!("expected_run_id: {error}"))?;
        let expected_policy_fingerprint = unsafe { CStr::from_ptr(expected_policy_fingerprint) }
            .to_str()
            .map_err(|e| anyhow!("expected_policy_fingerprint: {e}"))?;
        let value = ctx
            .resume_staged_submission(
                expected_run_id,
                expected_revision,
                lease_duration_ms,
                expected_policy_fingerprint,
            )
            .map_err(|e| anyhow!("resume_staged_submission: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Merge the device-signed PCZT into the engine-owned proven original, durably stage and ingest
/// the exact signed transaction, then return its submission claim (JSON `Option<ClaimedTx>`).
///
/// # Safety
/// See [`context`]; `intent_id` and `attempt_token` must be valid C strings and `pczt_ptr` valid for
/// reads of `pczt_len` bytes. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_store_signed_due_intent(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    intent_id: *const c_char,
    attempt_token: *const c_char,
    pczt_ptr: *const u8,
    pczt_len: usize,
    lease_duration_ms: u64,
    expected_policy_fingerprint: *const c_char,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let intent_id = unsafe { CStr::from_ptr(intent_id) }
            .to_str()
            .map_err(|e| anyhow!("intent_id: {e}"))?;
        let attempt_token = unsafe { CStr::from_ptr(attempt_token) }
            .to_str()
            .map_err(|e| anyhow!("attempt_token: {e}"))?;
        let pczt = unsafe { slice::from_raw_parts(pczt_ptr, pczt_len) };
        let expected_policy_fingerprint = unsafe { CStr::from_ptr(expected_policy_fingerprint) }
            .to_str()
            .map_err(|e| anyhow!("expected_policy_fingerprint: {e}"))?;
        let value = ctx
            .store_signed_due_intent(
                intent_id,
                attempt_token,
                pczt,
                lease_duration_ms,
                expected_policy_fingerprint,
            )
            .map_err(|e| anyhow!("store_signed_due_intent: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&value)?))
    });
    unwrap_exc_or_null(res)
}

/// Extract the broadcast-ready consensus transaction from a serialized signed PCZT
/// (`PreparedTx.raw_pczt`). Returns JSON `ExtractedTx { txid, raw_tx }`, with `txid` recomputed by
/// librustzcash from the exact extracted transaction bytes.
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
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&tx)?))
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
    expected_policy_fingerprint: *const c_char,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        unsafe {
            ensure_usk_matches_migration_account(
                db_data,
                db_data_len,
                account_uuid_bytes,
                network_id,
                usk_ptr,
                usk_len,
            )?
        };
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let usk = unsafe { slice::from_raw_parts(usk_ptr, usk_len) };
        let expected_policy_fingerprint = unsafe { CStr::from_ptr(expected_policy_fingerprint) }
            .to_str()
            .map_err(|e| anyhow!("expected_policy_fingerprint: {e}"))?;
        let value = ctx
            .refresh_stale_transfers(usk, expected_policy_fingerprint)
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

/// Compare-and-set the platform's submission outcome for one leased transaction (JSON `null` on
/// success). A wrong or expired token is rejected without mutating state.
///
/// # Safety
/// See [`context`]; `transfer_id` and `attempt_token` must be valid C strings and `result_ptr`
/// valid for `result_len` bytes. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_record_claimed_transfer_result(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    transfer_id: *const c_char,
    attempt_token: *const c_char,
    result_ptr: *const u8,
    result_len: usize,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let transfer_id = unsafe { CStr::from_ptr(transfer_id) }
            .to_str()
            .map_err(|e| anyhow!("transfer_id: {e}"))?;
        let attempt_token = unsafe { CStr::from_ptr(attempt_token) }
            .to_str()
            .map_err(|e| anyhow!("attempt_token: {e}"))?;
        let result: TransferResult =
            serde_json::from_slice(unsafe { slice::from_raw_parts(result_ptr, result_len) })
                .map_err(|e| anyhow!("decode TransferResult: {e}"))?;
        ctx.record_claimed_transfer_result(transfer_id, attempt_token, result)
            .map_err(|e| anyhow!("record_claimed_transfer_result: {e}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&())?))
    });
    unwrap_exc_or_null(res)
}

/// Renew a still-live network submission lease (JSON `Option<ClaimedTx>`). The exact transaction
/// and attempt token are unchanged; a closed consensus window returns `None` after safe release.
///
/// # Safety
/// See [`context`]; string pointers must be valid C strings. Free the returned pointer with
/// `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_renew_claimed_transfer_lease(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    transfer_id: *const c_char,
    attempt_token: *const c_char,
    lease_duration_ms: u64,
    expected_policy_fingerprint: *const c_char,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let transfer_id = unsafe { CStr::from_ptr(transfer_id) }
            .to_str()
            .map_err(|error| anyhow!("transfer_id: {error}"))?;
        let attempt_token = unsafe { CStr::from_ptr(attempt_token) }
            .to_str()
            .map_err(|error| anyhow!("attempt_token: {error}"))?;
        let expected_policy_fingerprint = unsafe { CStr::from_ptr(expected_policy_fingerprint) }
            .to_str()
            .map_err(|error| anyhow!("expected_policy_fingerprint: {error}"))?;
        let claim = ctx
            .renew_claimed_transfer_lease(
                transfer_id,
                attempt_token,
                lease_duration_ms,
                expected_policy_fingerprint,
            )
            .map_err(|error| anyhow!("renew_claimed_transfer_lease: {error}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&claim)?))
    });
    unwrap_exc_or_null(res)
}

/// Release a live claim only after the SDK attests that no transport call began (JSON `null`).
///
/// # Safety
/// See [`context`]; strings must be valid C strings and `reason_ptr` valid for reads of
/// `reason_len` bytes. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_release_claimed_transfer_known_unsent(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    transfer_id: *const c_char,
    attempt_token: *const c_char,
    reason_ptr: *const u8,
    reason_len: usize,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let transfer_id = unsafe { CStr::from_ptr(transfer_id) }
            .to_str()
            .map_err(|error| anyhow!("transfer_id: {error}"))?;
        let attempt_token = unsafe { CStr::from_ptr(attempt_token) }
            .to_str()
            .map_err(|error| anyhow!("attempt_token: {error}"))?;
        let reason: KnownUnsentReason =
            serde_json::from_slice(unsafe { slice::from_raw_parts(reason_ptr, reason_len) })
                .map_err(|error| anyhow!("decode KnownUnsentReason: {error}"))?;
        ctx.release_claimed_transfer_known_unsent(transfer_id, attempt_token, reason)
            .map_err(|error| anyhow!("release_claimed_transfer_known_unsent: {error}"))?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&())?))
    });
    unwrap_exc_or_null(res)
}

/// Quarantine a local pre-transport integrity failure while retaining exact bytes (JSON `null`).
///
/// # Safety
/// See [`context`]; strings must be valid C strings and `failure_ptr` valid for reads of
/// `failure_len` bytes. Free the returned pointer with `zcashlc_free_boxed_slice`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_migration_record_claimed_transfer_local_failure(
    db_data: *const u8,
    db_data_len: usize,
    account_uuid_bytes: *const u8,
    network_id: u32,
    transfer_id: *const c_char,
    attempt_token: *const c_char,
    failure_ptr: *const u8,
    failure_len: usize,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ctx = unsafe { context(db_data, db_data_len, account_uuid_bytes, network_id)? };
        let transfer_id = unsafe { CStr::from_ptr(transfer_id) }
            .to_str()
            .map_err(|error| anyhow!("transfer_id: {error}"))?;
        let attempt_token = unsafe { CStr::from_ptr(attempt_token) }
            .to_str()
            .map_err(|error| anyhow!("attempt_token: {error}"))?;
        let failure: LocalSubmissionFailure =
            serde_json::from_slice(unsafe { slice::from_raw_parts(failure_ptr, failure_len) })
                .map_err(|error| anyhow!("decode LocalSubmissionFailure: {error}"))?;
        ctx.record_claimed_transfer_local_failure(transfer_id, attempt_token, failure)
            .map_err(|error| anyhow!("record_claimed_transfer_local_failure: {error}"))?;
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
    set_migration_ffi_error_code(MIGRATION_FFI_ERROR_NONE);
    let res = catch_panic(|| {
        let path = unsafe { migration_db_path(db_data, db_data_len)? };
        let network = crate::parse_network(network_id)?;
        let account = unsafe { account_16(account_uuid_bytes)? };
        let chain_id = network.canonical_chain_id().to_string();
        // Keep the engine error structured until it has been converted to the stable sanitized
        // code. The generic `context` helper intentionally erases errors into `anyhow` prose and
        // therefore is not suitable for this recovery-critical boundary.
        let ctx = MigrationContext::new_with_chain_id(path, network, &chain_id, account)
            .map_err(sanitized_initialization_error)?;
        ctx.initialize_post_upgrade()
            .map_err(sanitized_initialization_error)?;
        Ok(ffi::BoxedSlice::some(serde_json::to_vec(&())?))
    });
    unwrap_exc_or_null(res)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unique_test_path(label: &str) -> std::path::PathBuf {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "zcashlc_{label}_{}_{}.sqlite",
            std::process::id(),
            nonce
        ))
    }

    #[test]
    fn spend_authority_must_resolve_to_the_exact_ffi_account() {
        let account_a = [7u8; 16];
        let account_b = [8u8; 16];

        ensure_exact_spending_account(account_a, Some(account_a)).unwrap();
        assert!(ensure_exact_spending_account(account_a, Some(account_b)).is_err());
        assert!(ensure_exact_spending_account(account_a, None).is_err());
    }

    #[test]
    fn migration_state_on_fresh_db_is_not_started() {
        let path = unique_test_path("mig");
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

    #[test]
    fn data_database_init_exposes_typed_corruption_code_once() {
        let path = unique_test_path("corrupt_wallet");
        std::fs::write(&path, b"not a sqlite wallet or a private path").unwrap();
        let db = path.to_str().unwrap().as_bytes();

        assert_eq!(
            unsafe {
                crate::zcashlc_init_data_database(db.as_ptr(), db.len(), std::ptr::null(), 0, 0)
            },
            -1
        );
        assert_eq!(
            crate::zcashlc_last_database_init_error_code(),
            crate::DATABASE_INIT_ERROR_CORRUPT
        );
        assert_eq!(
            crate::zcashlc_last_database_init_error_code(),
            crate::DATABASE_INIT_ERROR_NONE
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn store_signed_schedule_pczts_with_nothing_staged_is_an_error() {
        let path = unique_test_path("mig_ext");
        let path_str = path.to_str().unwrap();
        let db = path_str.as_bytes();
        let account = [7u8; 16];
        let signed = br#"[{"id":"run-0","raw_pczt":[1,2,3]}]"#;
        let policy_fingerprint = std::ffi::CString::new("00").unwrap();
        let ptr = unsafe {
            zcashlc_migration_store_signed_schedule_pczts(
                db.as_ptr(),
                db.len(),
                account.as_ptr(),
                1,
                signed.as_ptr(),
                signed.len(),
                policy_fingerprint.as_ptr(),
            )
        };
        // No staged transfer PCZTs exist -> the crate rejects the set -> null + last-error set.
        assert!(ptr.is_null());
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn ordinary_spend_guards_fail_closed_for_a_live_private_run() {
        let path = unique_test_path("mig_spend_guard");
        let path_str = path.to_str().unwrap();
        let db = path_str.as_bytes();
        let account = [9u8; 16];
        let network = crate::parse_network(1).unwrap();

        assert_eq!(
            unsafe {
                crate::zcashlc_init_data_database(db.as_ptr(), db.len(), std::ptr::null(), 0, 1)
            },
            0
        );

        unsafe { ensure_account_ordinary_spends_allowed(db.as_ptr(), db.len(), account, network) }
            .unwrap();
        assert_eq!(
            zcashlc_last_migration_error_code(),
            MIGRATION_FFI_ERROR_NONE
        );

        let conn = rusqlite::Connection::open(&path).unwrap();
        let account_uuid = uuid::Uuid::from_bytes(account).to_string();
        let consensus_fingerprint = zodl_ironwood_migration::consensus_config_fingerprint(
            &network,
            &network.canonical_chain_id().to_string(),
        )
        .unwrap();
        conn.execute(
            "INSERT INTO ext_ironwood_migration_runs
                (run_id, account_uuid, network, db_fingerprint, consensus_fingerprint, mode, phase,
                 created_at_ms, updated_at_ms, target_values_json)
             VALUES ('00000000-0000-4000-8000-000000000001', ?1, 'main', ?2, ?3,
                     'private_scheduled', 'ready_to_prepare', 1, 1, '[]')",
            rusqlite::params![account_uuid, path_str, consensus_fingerprint],
        )
        .unwrap();
        drop(conn);

        let account_error = unsafe {
            ensure_account_ordinary_spends_allowed(db.as_ptr(), db.len(), account, network)
        }
        .unwrap_err();
        assert_eq!(
            account_error.to_string(),
            ORDINARY_SPENDS_BLOCKED_ERROR_MARKER
        );
        assert_eq!(
            zcashlc_last_migration_error_code(),
            MIGRATION_FFI_ERROR_ORDINARY_SPENDS_BLOCKED
        );

        // Account-scoped locking is essential for multi-account wallets: the same DB may continue
        // ordinary spending from account B while account A's Orchard corpus is migration-owned.
        let account_b = [10u8; 16];
        unsafe {
            ensure_account_ordinary_spends_allowed(db.as_ptr(), db.len(), account_b, network)
        }
        .unwrap();
        assert_eq!(
            zcashlc_last_migration_error_code(),
            MIGRATION_FFI_ERROR_NONE
        );

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn initialization_error_codes_are_stable_and_sanitized() {
        use rusqlite::ffi::{Error, ErrorCode};

        assert_eq!(
            initialization_error_code(&MigrationError::NotSynced),
            MIGRATION_FFI_ERROR_INITIALIZE_NOT_SYNCED
        );
        assert_eq!(
            initialization_error_code(&MigrationError::NotInitialized),
            MIGRATION_FFI_ERROR_INITIALIZE_NOT_INITIALIZED
        );
        assert_eq!(
            initialization_error_code(&MigrationError::InvalidState(
                InvalidStateError::SchemaIncompatible,
            )),
            MIGRATION_FFI_ERROR_INITIALIZE_SCHEMA_INCOMPATIBLE
        );
        assert_eq!(
            initialization_error_code(&MigrationError::InvalidState(
                InvalidStateError::EngineSchemaNewer {
                    found: 9,
                    supported: 4,
                },
            )),
            MIGRATION_FFI_ERROR_INITIALIZE_ENGINE_SCHEMA_NEWER
        );
        assert_eq!(
            initialization_error_code(&MigrationError::InvalidState(
                InvalidStateError::EngineSchemaCorrupt {
                    object: "secret-table-name".to_string(),
                },
            )),
            MIGRATION_FFI_ERROR_INITIALIZE_ENGINE_SCHEMA_CORRUPT
        );
        assert_eq!(
            initialization_error_code(&MigrationError::InvalidState(
                InvalidStateError::ConsensusConfigurationMismatch,
            )),
            MIGRATION_FFI_ERROR_INITIALIZE_CONSENSUS_MISMATCH
        );
        assert_eq!(
            initialization_error_code(&MigrationError::InvalidState(
                InvalidStateError::NoActiveRun,
            )),
            MIGRATION_FFI_ERROR_INITIALIZE_OTHER_INVALID
        );

        let cases = [
            (
                ErrorCode::DatabaseBusy,
                MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_BUSY,
            ),
            (
                ErrorCode::DatabaseLocked,
                MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_LOCKED,
            ),
            (
                ErrorCode::DiskFull,
                MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_FULL,
            ),
            (
                ErrorCode::ReadOnly,
                MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_READ_ONLY,
            ),
            (
                ErrorCode::DatabaseCorrupt,
                MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_CORRUPT,
            ),
            (
                ErrorCode::CannotOpen,
                MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_UNAVAILABLE,
            ),
        ];
        for (sqlite_code, expected) in cases {
            let error = MigrationError::Db(rusqlite::Error::SqliteFailure(
                Error {
                    code: sqlite_code,
                    extended_code: 0,
                },
                Some("raw-device-secret".to_string()),
            ));
            assert_eq!(initialization_error_code(&error), expected);
            let sanitized = sanitized_initialization_error(error).to_string();
            assert!(!sanitized.contains("raw-device-secret"));
            assert_eq!(
                sanitized,
                format!("IRONWOOD_MIGRATION_INITIALIZATION_FAILED:{expected}")
            );
            assert_eq!(zcashlc_last_migration_error_code(), expected);
        }

        assert_eq!(
            initialization_error_code(&MigrationError::Backend(
                zcash_client_sqlite::error::SqliteClientError::CorruptedData(
                    "raw-device-secret".to_string(),
                ),
            )),
            MIGRATION_FFI_ERROR_INITIALIZE_DATABASE_CORRUPT
        );
        assert_eq!(
            initialization_error_code(&MigrationError::Pipeline("raw-device-secret".to_string(),)),
            MIGRATION_FFI_ERROR_INITIALIZE_PIPELINE
        );
    }

    #[test]
    fn newer_engine_schema_has_structured_metadata_and_is_not_downgraded() {
        let path = unique_test_path("mig_newer_schema");
        let path_str = path.to_str().unwrap();
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE ext_ironwood_migration_meta (
                 singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                 schema_version INTEGER NOT NULL
             );
             INSERT INTO ext_ironwood_migration_meta (singleton, schema_version) VALUES (1, 5);",
        )
        .unwrap();
        drop(conn);

        let db = path_str.as_bytes();
        let account = [4_u8; 16];
        let ptr = unsafe { zcashlc_migration_snapshot(db.as_ptr(), db.len(), account.as_ptr(), 1) };
        assert!(ptr.is_null());

        let initialization_ptr = unsafe {
            zcashlc_migration_initialize_post_upgrade(db.as_ptr(), db.len(), account.as_ptr(), 1)
        };
        assert!(initialization_ptr.is_null());
        assert_eq!(
            zcashlc_last_migration_error_code(),
            MIGRATION_FFI_ERROR_INITIALIZE_ENGINE_SCHEMA_NEWER
        );

        let metadata_ptr =
            unsafe { zcashlc_migration_engine_schema_metadata(db.as_ptr(), db.len()) };
        assert!(!metadata_ptr.is_null());
        let metadata: zodl_ironwood_migration::MigrationEngineSchemaMetadata =
            serde_json::from_slice(unsafe { (*metadata_ptr).as_slice() }).unwrap();
        assert_eq!(metadata.found_version, Some(5));
        assert_eq!(metadata.supported_version, 4);
        assert!(metadata.is_newer);
        unsafe { crate::ffi::zcashlc_free_boxed_slice(metadata_ptr) }

        let conn = rusqlite::Connection::open(&path).unwrap();
        let version: u32 = conn
            .query_row(
                "SELECT schema_version FROM ext_ironwood_migration_meta WHERE singleton = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(version, 5);

        let _ = std::fs::remove_file(&path);
    }
}
