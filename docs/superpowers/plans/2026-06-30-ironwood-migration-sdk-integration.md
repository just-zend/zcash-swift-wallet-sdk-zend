# Ironwood Migration SDK Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline; build state is session-local) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the `zodl_ironwood_migration` engine into `libzcashlc` through the Rust FFI and the internal `ZcashRustBackendWelding` Swift layer (welding tier only).

**Architecture:** Switch the SDK's librustzcash graph to the valargroup fork (`nu6.3`), add the crate as a path dep, expose each `MigrationContext` method as one `extern "C"` fn marshalling whole `serde` types as JSON through the existing `BoxedSlice`, and decode them in `@DBActor` welding methods. Also close crate gap #1 (`self_payment_request`) in the crate repo.

**Tech Stack:** Rust (cbindgen FFI, serde_json), Swift (Codable, JSONDecoder, `@DBActor`), Sourcery (error codes + mocks), Cargo `[patch.crates-io]`.

## Global Constraints

- **Commit tag:** `[MOB-1455] <title>` on every commit (SDK repo and crate repo).
- **cfg:** `zcash_unstable="nu6.3"` (NOT `nu7`) — via `.cargo/config.toml`.
- **Dep pins:** all librustzcash crates → valargroup fork rev `0c3ad735f8402295fccb9acf2fe897779500bbf5`; `orchard` by branch `adam/qleak-dummy-ciphertexts-on-pr505`; mirror `../ZODLIronwoodMigrationRust/Cargo.toml` exactly; one `rusqlite 0.37` (bundled).
- **FFI contract:** every migration fn returns `*mut ffi::BoxedSlice`; null ⇒ error (`zcashlc_last_error_message`), non-null ⇒ `serde_json` body. Void methods encode `()` → `"null"`.
- **Swift style:** no `.init()` shorthand (explicit type names), no semicolons, prefer `OSAllocatedUnfairLock`. No `print`/`NSLog`. String interpolation, not `+`.
- **Generated files (never hand-edit):** `ZcashError.swift`, `ZcashErrorCode.swift`, `AutoMockable.generated.swift`, the cbindgen header. Use the Sourcery scripts (mocks need Sourcery **2.3.0**).
- **Models are `public`.**
- **Build:** macOS-only local FFI; `OfflineTests` is the test surface. Macro-trust prompt ⇒ STOP and ask.

---

### Task 1: Close crate gap #1 — `self_payment_request` (crate repo)

**Files:**
- Modify: `../ZODLIronwoodMigrationRust/src/backend.rs` (replace the `self_payment_request` stub; add a pure `build_self_payment` helper)
- Test: same file `#[cfg(test)] mod tests`

**Interfaces:**
- Produces (crate-internal): `fn build_self_payment(address: &ZcashAddress, amount: u64) -> Result<TransactionRequest, MigrationError>` and a real `fn self_payment_request(db: &Db, account: AccountUuid, amount: u64) -> Result<TransactionRequest, MigrationError>` consumed by the existing `sign_split` / `sign_schedule`.

- [ ] **Step 1: Verify the exact APIs** (the crate already compiles against the fork — use its fast loop). In `../librustzcash`, grep the `WalletRead::get_current_address` signature and the `UnifiedAddress`→`ZcashAddress` conversion (`zcash_keys::Address`), and confirm `zip321::Payment::new` arity (cf. SDK `rust/src/lib.rs:2157`: `Payment::new(to, Some(value), memo, None, None, vec![])` returns `Result`) and the `Zatoshis` constructor.

- [ ] **Step 2: Write the failing test** (append to `backend.rs` tests; use a known-valid address literal so the helper is testable without a wallet DB):

```rust
#[test]
fn build_self_payment_creates_single_payment_for_amount() {
    let address: zcash_address::ZcashAddress =
        "ztestsapling1ctuamfer5xjnnrdr3xdazenljx0mu0gutcf9u9e74tr2d3jwjnt0qllzxaplu54hgc2tyjdc2p6"
            .parse()
            .expect("address parses");
    let req = build_self_payment(&address, 100_000_000).expect("request builds");
    assert_eq!(req.payments().len(), 1);
    let payment = req.payments().values().next().expect("one payment");
    assert_eq!(u64::from(payment.amount()), 100_000_000);
}
```

- [ ] **Step 3: Run it, expect failure**

Run: `cd ../ZODLIronwoodMigrationRust && cargo test build_self_payment`
Expected: FAIL — `build_self_payment` not found.

- [ ] **Step 4: Implement the pure helper + real wrapper** (replace the stub at `backend.rs:190`). Adjust to the signatures confirmed in Step 1:

```rust
/// Build a zip321 request paying `amount` to `address` (the migration is a self-send).
fn build_self_payment(
    address: &zcash_address::ZcashAddress,
    amount: u64,
) -> Result<TransactionRequest, MigrationError> {
    let value = zcash_protocol::value::Zatoshis::from_u64(amount)
        .map_err(|e| MigrationError::Backend(format!("invalid amount: {e:?}")))?;
    let payment = zip321::Payment::new(address.clone(), Some(value), None, None, None, vec![])
        .map_err(|e| MigrationError::Backend(format!("construct self payment: {e:?}")))?;
    TransactionRequest::new(vec![payment])
        .map_err(|e| MigrationError::Backend(format!("construct request: {e:?}")))
}

/// Resolve the account's current unified address and build a self-payment for `amount`.
fn self_payment_request(
    db: &Db,
    account: AccountUuid,
    amount: u64,
) -> Result<TransactionRequest, MigrationError> {
    let ua = db
        .get_current_address(account)
        .map_err(|e| MigrationError::Backend(format!("get current address: {e:?}")))?
        .ok_or_else(|| MigrationError::Backend("account has no current address".to_string()))?;
    let address = ua.to_zcash_address(&consensus_network_for(db));
    build_self_payment(&address, amount)
}
```

If `get_current_address` needs a `UnifiedAddressRequest`, or the network for `to_zcash_address` must be threaded from the caller, adjust the wrapper signature and its two call sites (`sign_split`, `sign_schedule`) accordingly. The pure helper stays as above.

- [ ] **Step 5: Run tests, expect pass**

Run: `cargo test` (in the crate)
Expected: PASS (all crate tests, incl. the new one). The wrapper is compile-verified by `cargo build`.

- [ ] **Step 6: Commit (crate repo)**

```bash
cd ../ZODLIronwoodMigrationRust
git add src/backend.rs
git commit -m "[MOB-1455] Close gap #1: build real self-payment request

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
cd -
```

---

### Task 2: SDK Rust dependencies + fork switch

**Files:**
- Modify: `Cargo.toml` (add crate dep; add `[patch.crates-io]`; possibly pin `zcash_voting`)
- Create: `.cargo/config.toml`
- Modify: `Cargo.lock` (cargo-generated)
- Modify (as needed): `rust/src/lib.rs`, `rust/src/*.rs` (fork-fallout fixes)

**Interfaces:**
- Produces: a `libzcashlc` crate that compiles against the valargroup fork under `nu6.3`, with `zodl_ironwood_migration` available as `zodl_ironwood_migration::{MigrationContext, Network, NoteSplitProposal, MigrationSchedule, TransferResult, ...}`.

- [ ] **Step 1: Create `.cargo/config.toml`**

```toml
# Ironwood (NU6.3) tx-building is gated behind this unstable cfg in the valargroup
# librustzcash fork. Remove once Ironwood stabilizes.
[build]
rustflags = ["--cfg", "zcash_unstable=\"nu6.3\""]
```

- [ ] **Step 2: Add the crate dep + `[patch.crates-io]` to `Cargo.toml`** (append after `[dependencies]` add the crate; add the patch table near the end). Mirror `../ZODLIronwoodMigrationRust/Cargo.toml` exactly:

```toml
# Add into [dependencies]:
zodl_ironwood_migration = { path = "../ZODLIronwoodMigrationRust" }
```

```toml
# Add at end of Cargo.toml:
[patch.crates-io]
zcash_client_backend = { git = "https://github.com/valargroup/librustzcash", rev = "0c3ad735f8402295fccb9acf2fe897779500bbf5" }
zcash_client_sqlite  = { git = "https://github.com/valargroup/librustzcash", rev = "0c3ad735f8402295fccb9acf2fe897779500bbf5" }
zcash_primitives     = { git = "https://github.com/valargroup/librustzcash", rev = "0c3ad735f8402295fccb9acf2fe897779500bbf5" }
zcash_keys           = { git = "https://github.com/valargroup/librustzcash", rev = "0c3ad735f8402295fccb9acf2fe897779500bbf5" }
zcash_protocol       = { git = "https://github.com/valargroup/librustzcash", rev = "0c3ad735f8402295fccb9acf2fe897779500bbf5" }
zcash_transparent    = { git = "https://github.com/valargroup/librustzcash", rev = "0c3ad735f8402295fccb9acf2fe897779500bbf5" }
zcash_proofs         = { git = "https://github.com/valargroup/librustzcash", rev = "0c3ad735f8402295fccb9acf2fe897779500bbf5" }
zip321               = { git = "https://github.com/valargroup/librustzcash", rev = "0c3ad735f8402295fccb9acf2fe897779500bbf5" }
pczt                 = { git = "https://github.com/valargroup/librustzcash", rev = "0c3ad735f8402295fccb9acf2fe897779500bbf5" }
orchard = { git = "https://github.com/zcash/orchard", branch = "adam/qleak-dummy-ciphertexts-on-pr505" }
```

- [ ] **Step 3: First build (the big discovery step)**

Run: `cargo build` (host = macOS; needs network for the git fetch; slow first time)
Expected initially: may FAIL. Resolve in this order, surfacing rather than hiding:
  1. **`zcash_voting` resolution:** if it fails against the fork, add to `[patch.crates-io]`: `zcash_voting = { git = "https://github.com/valargroup/librustzcash", branch = "adam/qleak-pr136-orchard-librustzcash" }` (vizor's pin). Keep the `Cargo.toml` `zcash_voting` version line as-is.
  2. **orchard feature unification (highest risk):** the SDK's `orchard` needs `unstable-voting-circuits`; if the qleak orchard branch lacks it, the build fails. **STOP and report** — do not drop voting silently. Candidate fixes to propose: an orchard branch carrying both, or (flagged behavior change) gating voting.
  3. **Existing-code fork fallout:** fix forward, mirroring the class of changes on `origin/harry/ironwood-nu6.3-deps` (e.g. `rewind_to_height`→`truncate_to_height`, `put_utxo` extra `None` args, `pczt.serialize()` now returns `Result`, `OrchardCircuitVersion::FixedPostNu6_2`). Apply the minimal change that compiles.
  4. **Macro trust:** not expected under `cargo` (Rust proc-macros run normally); the Swift macro-trust prompt only appears in Xcode (Task 4).

Iterate until `cargo build` succeeds.

- [ ] **Step 4: Commit**

```bash
git add Cargo.toml Cargo.lock .cargo/config.toml rust/src
git commit -m "[MOB-1455] Switch librustzcash to valargroup fork (nu6.3) + add migration crate

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: FFI layer — `rust/src/migration.rs`

**Files:**
- Create: `rust/src/migration.rs`
- Modify: `rust/src/lib.rs` (add `mod migration;` next to the other `mod` lines ~line 92)
- Test: `#[cfg(test)] mod tests` in `migration.rs`

**Interfaces:**
- Produces (C ABI, all return `*mut ffi::BoxedSlice`): `zcashlc_migration_state`, `zcashlc_migration_progress`, `zcashlc_migration_is_note_split_needed`, `zcashlc_migration_prepare_note_split`, `zcashlc_migration_sign_note_split`, `zcashlc_migration_propose_transfers`, `zcashlc_migration_sign_and_store`, `zcashlc_migration_is_sync_required`, `zcashlc_migration_next_due_transfer`, `zcashlc_migration_record_transfer_result`, `zcashlc_migration_has_overdue_transfers`, `zcashlc_migration_has_invalid_transfers`, `zcashlc_migration_restart_step`, `zcashlc_migration_initialize_post_upgrade`. Common params `db_data: *const u8, db_data_len: usize, account_uuid_bytes: *const u8, network_id: u32`.

- [ ] **Step 1: Add `mod migration;` to `rust/src/lib.rs`** (alongside `mod ffi;`):

```rust
mod ffi;
mod ironwood_migration_ffi_placeholder; // (do not add — illustration only)
mod migration;
mod tor;
```
(Concretely: add the single line `mod migration;` after `mod ffi;`.)

- [ ] **Step 2: Write `rust/src/migration.rs` header + helpers + the Rust marshalling test (failing first)**

```rust
//! FFI wrapping `zodl_ironwood_migration::MigrationContext`. Every fn marshals whole `serde`
//! types as JSON through `ffi::BoxedSlice`: success ⇒ non-null JSON body, failure ⇒ null
//! (message via `zcashlc_last_error_message`). The Swift welding decodes the JSON.

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

/// Map the FFI network id to the migration crate's `Network` (testnet = 0, mainnet = 1; mirrors
/// `parse_network`).
fn migration_network(network_id: u32) -> anyhow::Result<Network> {
    match network_id {
        0 => Ok(Network::Test),
        1 => Ok(Network::Main),
        other => Err(anyhow!("Invalid network id: {other}")),
    }
}

/// Borrow the wallet db path (UTF-8) from the FFI byte buffer.
unsafe fn migration_db_path<'a>(db_data: *const u8, db_data_len: usize) -> anyhow::Result<&'a str> {
    let bytes = unsafe { slice::from_raw_parts(db_data, db_data_len) };
    OsStr::from_bytes(bytes)
        .to_str()
        .ok_or_else(|| anyhow!("wallet db path is not valid UTF-8"))
}

/// Copy the 16-byte account uuid from the FFI buffer.
unsafe fn account_16(account_uuid_bytes: *const u8) -> anyhow::Result<[u8; 16]> {
    let bytes = unsafe { slice::from_raw_parts(account_uuid_bytes, 16) };
    <[u8; 16]>::try_from(bytes).map_err(|_| anyhow!("account uuid must be 16 bytes"))
}

/// Build a `MigrationContext` from the common FFI args.
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
```

- [ ] **Step 3: Run the test, expect failure**

Run: `cargo test migration_state_on_fresh_db`
Expected: FAIL — `zcashlc_migration_state` not found.

- [ ] **Step 4: Implement all 14 FFI functions** (append to `migration.rs`). Read-only / no-arg fns:

```rust
/// Current migration state (JSON `MigrationState`).
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

/// Whether note splitting is required (JSON `bool`).
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

/// Compute the note-split proposal (JSON `NoteSplitProposal`).
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

/// Generate the migration schedule (JSON `MigrationSchedule`).
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

/// Whether a sync is required before the next transfer (JSON `bool`).
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

/// Next height-due transfer (JSON `Option<PreparedTx>`).
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

/// Whether any scheduled transfer is overdue (JSON `bool`).
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

/// Whether the migration is in an invalid state (JSON `bool`).
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

/// Re-evaluate remaining balance and return a fresh schedule (JSON `MigrationSchedule`).
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

/// First-launch post-upgrade init (JSON `null` on success).
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
```

Signing fns (JSON arg + raw USK bytes) and the result-recording fn:

```rust
/// Sign + persist the note split (JSON `PreparedTx`). `proposal` is JSON `NoteSplitProposal`;
/// `usk` is the raw `UnifiedSpendingKey` (Orchard era) bytes.
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

/// Pre-sign + persist every transfer in the schedule (JSON `null` on success).
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

/// Record the platform's broadcast outcome (JSON `null` on success). `transfer_id` is a C string;
/// `result` is JSON `TransferResult`.
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
```

- [ ] **Step 5: Run tests, expect pass**

Run: `cargo test migration_state_on_fresh_db`
Expected: PASS. Also `cargo build` clean (cbindgen regenerates the header with the `zcashlc_migration_*` decls).

- [ ] **Step 6: Commit**

```bash
git add rust/src/migration.rs rust/src/lib.rs Cargo.lock
git commit -m "[MOB-1455] FFI: wrap MigrationContext (JSON via BoxedSlice)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Enter local-FFI macOS mode + baseline Swift build

**Files:** none committed (LocalPackages is generated/untracked); any Swift fork-fallout fixes if they arise.

- [ ] **Step 1: Build the macOS slice + switch to local FFI mode**

Run: `./Scripts/init-local-ffi.sh --macos-only`
Expected: builds the macOS staticlib from `rust/` (incl. `zcashlc_migration_*`) into `LocalPackages/`; `Package.swift` auto-detects it.

- [ ] **Step 2: Build `OfflineTests` (no migration Swift yet) to catch Swift-side fallout**

Run (Xcode MCP preferred): `mcp__xcode__BuildProject` on `ZcashSDK.xcworkspace` / OfflineTests scheme. Fallback: `swift build`.
Expected: PASS. If a **macro-trust** prompt appears, **STOP and ask the user**. If existing Swift fails to compile against the regenerated header, fix forward minimally and note it.

- [ ] **Step 3: Run the existing OfflineTests once as a baseline**

Run: `swift test --filter OfflineTests` (or Xcode MCP `RunAllTests` on OfflineTests)
Expected: PASS (pre-existing suite green against the fork). Commit any Swift fallout fixes:

```bash
git add -A
git commit -m "[MOB-1455] Fix existing Swift/FFI for valargroup fork header

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
(If nothing changed, skip the commit.)

---

### Task 5: Swift Codable models — `Model/Migration.swift`

**Files:**
- Create: `Sources/ZcashLightClientKit/Model/Migration.swift`
- Test: `Tests/OfflineTests/MigrationModelTests.swift`

**Interfaces:**
- Produces (public): `MigrationState`, `AttentionReason`, `TransferResult`, `MigrationProgress`, `PreparedTx`, `NoteSplitProposal`, `TransferProposal`, `MigrationSchedule`, `NetworkPrivacyOptions` — all `Equatable, Codable`, decoding serde's external tagging + snake_case.

- [ ] **Step 1: Write failing round-trip tests** (`Tests/OfflineTests/MigrationModelTests.swift`). The JSON literals match serde's exact output (verify against the crate's serde during impl):

```swift
import XCTest
@testable import ZcashLightClientKit

final class MigrationModelTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testMigrationStateUnitVariants() throws {
        XCTAssertEqual(try decode(MigrationState.self, "\"NotStarted\""), .notStarted)
        XCTAssertEqual(try decode(MigrationState.self, "\"SplitPendingConfirmation\""), .splitPendingConfirmation)
        XCTAssertEqual(try decode(MigrationState.self, "\"ReadyToPropose\""), .readyToPropose)
        XCTAssertEqual(try decode(MigrationState.self, "\"Complete\""), .complete)
    }

    func testMigrationStateInProgress() throws {
        let json = """
        {"InProgress":{"completed_transfers":1,"total_transfers":3,"remaining_orchard_zatoshi":600000000,"next_transfer_ready_at_height":2880864}}
        """
        let expected = MigrationState.inProgress(
            MigrationProgress(
                completedTransfers: 1,
                totalTransfers: 3,
                remainingOrchardZatoshi: 600_000_000,
                nextTransferReadyAtHeight: 2_880_864
            )
        )
        XCTAssertEqual(try decode(MigrationState.self, json), expected)
    }

    func testMigrationStateRequiresAttentionNestedEnum() throws {
        XCTAssertEqual(
            try decode(MigrationState.self, "{\"RequiresAttention\":\"TransferExpired\"}"),
            .requiresAttention(.transferExpired)
        )
        XCTAssertEqual(
            try decode(MigrationState.self, "{\"RequiresAttention\":{\"InvalidTransfer\":{\"transfer_id\":\"x\"}}}"),
            .requiresAttention(.invalidTransfer(transferId: "x"))
        )
    }

    func testTransferResultVariants() throws {
        XCTAssertEqual(try decode(TransferResult.self, "{\"Success\":{\"txid\":\"abc\"}}"), .success(txid: "abc"))
        XCTAssertEqual(try decode(TransferResult.self, "{\"NetworkError\":{\"retryable\":true}}"), .networkError(retryable: true))
        XCTAssertEqual(try decode(TransferResult.self, "\"InvalidNote\""), .invalidNote)
        XCTAssertEqual(try decode(TransferResult.self, "\"Expired\""), .expired)
    }

    func testPreparedTxDecodesRawTxArray() throws {
        let tx = try decode(PreparedTx.self, "{\"id\":\"t1\",\"txid\":\"deadbeef\",\"raw_tx\":[5,0,255]}")
        XCTAssertEqual(tx, PreparedTx(id: "t1", txid: "deadbeef", rawTx: [5, 0, 255]))
    }

    func testScheduleAndProposalRoundTrip() throws {
        let json = """
        {"transfers":[{"id":"t1","amount_zatoshi":1000000000,"anchor_height":2880000,"next_executable_after_height":2880288,"expiry_height":2880576}],"estimated_duration_hours":6}
        """
        let decoded = try decode(MigrationSchedule.self, json)
        let reencoded = try JSONEncoder().encode(decoded)
        XCTAssertEqual(try decode(MigrationSchedule.self, String(data: reencoded, encoding: .utf8)!), decoded)
        XCTAssertEqual(decoded.transfers.first?.amountZatoshi, 1_000_000_000)
    }

    func testNoteSplitProposalAndPrivacyOptions() throws {
        XCTAssertEqual(
            try decode(NoteSplitProposal.self, "{\"output_notes\":[100000000,34500000],\"fee\":10000}"),
            NoteSplitProposal(outputNotes: [100_000_000, 34_500_000], fee: 10_000)
        )
        XCTAssertEqual(
            try decode(NetworkPrivacyOptions.self, "{\"use_tor\":true,\"submission_endpoint\":null}"),
            NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil)
        )
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

Run: Xcode MCP `RunSomeTests` (MigrationModelTests) or `swift test --filter MigrationModelTests`
Expected: FAIL — types not found.

- [ ] **Step 3: Implement `Sources/ZcashLightClientKit/Model/Migration.swift`**

```swift
//
//  Migration.swift
//  ZcashLightClientKit
//
//  Public Codable models for the Orchard -> Ironwood migration engine. Field names and enum
//  tags mirror `zodl_ironwood_migration` serde output: structs use snake_case keys; enums use
//  serde external tagging (unit variant -> bare string, data variant -> single-key object).
//

import Foundation

public struct MigrationProgress: Equatable, Codable {
    public let completedTransfers: UInt32
    public let totalTransfers: UInt32
    public let remainingOrchardZatoshi: UInt64
    public let nextTransferReadyAtHeight: UInt32?

    enum CodingKeys: String, CodingKey {
        case completedTransfers = "completed_transfers"
        case totalTransfers = "total_transfers"
        case remainingOrchardZatoshi = "remaining_orchard_zatoshi"
        case nextTransferReadyAtHeight = "next_transfer_ready_at_height"
    }
}

public struct PreparedTx: Equatable, Codable {
    public let id: String
    public let txid: String
    public let rawTx: [UInt8]

    enum CodingKeys: String, CodingKey {
        case id
        case txid
        case rawTx = "raw_tx"
    }
}

public struct NoteSplitProposal: Equatable, Codable {
    public let outputNotes: [UInt64]
    public let fee: UInt64

    enum CodingKeys: String, CodingKey {
        case outputNotes = "output_notes"
        case fee
    }
}

public struct TransferProposal: Equatable, Codable {
    public let id: String
    public let amountZatoshi: UInt64
    public let anchorHeight: UInt32
    public let nextExecutableAfterHeight: UInt32
    public let expiryHeight: UInt32

    enum CodingKeys: String, CodingKey {
        case id
        case amountZatoshi = "amount_zatoshi"
        case anchorHeight = "anchor_height"
        case nextExecutableAfterHeight = "next_executable_after_height"
        case expiryHeight = "expiry_height"
    }
}

public struct MigrationSchedule: Equatable, Codable {
    public let transfers: [TransferProposal]
    public let estimatedDurationHours: UInt32

    enum CodingKeys: String, CodingKey {
        case transfers
        case estimatedDurationHours = "estimated_duration_hours"
    }
}

public struct NetworkPrivacyOptions: Equatable, Codable {
    public let useTor: Bool
    public let submissionEndpoint: String?

    enum CodingKeys: String, CodingKey {
        case useTor = "use_tor"
        case submissionEndpoint = "submission_endpoint"
    }

    public init(useTor: Bool, submissionEndpoint: String?) {
        self.useTor = useTor
        self.submissionEndpoint = submissionEndpoint
    }
}

public enum AttentionReason: Equatable, Codable {
    case invalidTransfer(transferId: String)
    case transferExpired
    case syncRequiredBeforeNext

    enum CodingKeys: String, CodingKey {
        case invalidTransfer = "InvalidTransfer"
    }

    private struct InvalidTransferPayload: Codable {
        let transferId: String
        enum CodingKeys: String, CodingKey {
            case transferId = "transfer_id"
        }
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let tag = try? single.decode(String.self) {
            switch tag {
            case "TransferExpired":
                self = .transferExpired
                return
            case "SyncRequiredBeforeNext":
                self = .syncRequiredBeforeNext
                return
            default:
                break
            }
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let payload = try container.decode(InvalidTransferPayload.self, forKey: .invalidTransfer)
        self = .invalidTransfer(transferId: payload.transferId)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .transferExpired:
            var container = encoder.singleValueContainer()
            try container.encode("TransferExpired")
        case .syncRequiredBeforeNext:
            var container = encoder.singleValueContainer()
            try container.encode("SyncRequiredBeforeNext")
        case .invalidTransfer(let transferId):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(InvalidTransferPayload(transferId: transferId), forKey: .invalidTransfer)
        }
    }
}

public enum TransferResult: Equatable, Codable {
    case success(txid: String)
    case networkError(retryable: Bool)
    case invalidNote
    case expired

    enum CodingKeys: String, CodingKey {
        case success = "Success"
        case networkError = "NetworkError"
    }

    private struct SuccessPayload: Codable {
        let txid: String
    }

    private struct NetworkErrorPayload: Codable {
        let retryable: Bool
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let tag = try? single.decode(String.self) {
            switch tag {
            case "InvalidNote":
                self = .invalidNote
                return
            case "Expired":
                self = .expired
                return
            default:
                break
            }
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let payload = try? container.decode(SuccessPayload.self, forKey: .success) {
            self = .success(txid: payload.txid)
            return
        }
        let payload = try container.decode(NetworkErrorPayload.self, forKey: .networkError)
        self = .networkError(retryable: payload.retryable)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .invalidNote:
            var container = encoder.singleValueContainer()
            try container.encode("InvalidNote")
        case .expired:
            var container = encoder.singleValueContainer()
            try container.encode("Expired")
        case .success(let txid):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(SuccessPayload(txid: txid), forKey: .success)
        case .networkError(let retryable):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(NetworkErrorPayload(retryable: retryable), forKey: .networkError)
        }
    }
}

public enum MigrationState: Equatable, Codable {
    case notStarted
    case splitPendingConfirmation
    case readyToPropose
    case inProgress(MigrationProgress)
    case requiresAttention(AttentionReason)
    case complete

    enum CodingKeys: String, CodingKey {
        case inProgress = "InProgress"
        case requiresAttention = "RequiresAttention"
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let tag = try? single.decode(String.self) {
            switch tag {
            case "NotStarted":
                self = .notStarted
                return
            case "SplitPendingConfirmation":
                self = .splitPendingConfirmation
                return
            case "ReadyToPropose":
                self = .readyToPropose
                return
            case "Complete":
                self = .complete
                return
            default:
                break
            }
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let progress = try? container.decode(MigrationProgress.self, forKey: .inProgress) {
            self = .inProgress(progress)
            return
        }
        let reason = try container.decode(AttentionReason.self, forKey: .requiresAttention)
        self = .requiresAttention(reason)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .notStarted:
            var container = encoder.singleValueContainer()
            try container.encode("NotStarted")
        case .splitPendingConfirmation:
            var container = encoder.singleValueContainer()
            try container.encode("SplitPendingConfirmation")
        case .readyToPropose:
            var container = encoder.singleValueContainer()
            try container.encode("ReadyToPropose")
        case .complete:
            var container = encoder.singleValueContainer()
            try container.encode("Complete")
        case .inProgress(let progress):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(progress, forKey: .inProgress)
        case .requiresAttention(let reason):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(reason, forKey: .requiresAttention)
        }
    }
}
```

Add explicit memberwise `public init`s to `MigrationProgress`, `PreparedTx`, `NoteSplitProposal`, `TransferProposal`, `MigrationSchedule` (public structs need public inits to be constructed from tests/consumers; follow the `NetworkPrivacyOptions` example).

- [ ] **Step 4: Run tests, expect pass**

Run: `swift test --filter MigrationModelTests` (or Xcode MCP)
Expected: PASS. **If any JSON literal mismatches serde**, emit the real JSON from the crate (`serde_json::to_string` in a scratch crate test) and correct the literal/`CodingKeys`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZcashLightClientKit/Model/Migration.swift Tests/OfflineTests/MigrationModelTests.swift
git commit -m "[MOB-1455] Swift Codable models mirroring migration serde types

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Error codes (Sourcery)

**Files:**
- Modify: `Sources/ZcashLightClientKit/Error/ZcashErrorCodeDefinition.swift` (add 14 cases after `rustEip681Parse`, code `ZRUST0092`)
- Regenerate: `Error/ZcashError.swift`, `Error/ZcashErrorCode.swift` (via script — do not hand-edit)

**Interfaces:**
- Produces: `ZcashError.rustMigrationState(String)` … `rustMigrationInitializePostUpgrade(String)` (14 cases, codes `ZRUST0093`–`ZRUST0106`).

- [ ] **Step 1: Add 14 cases to `ZcashErrorCodeDefinition.swift`** (after the `rustEip681Parse` case):

```swift
    /// Error from rust layer when calling ZcashRustBackend.migrationState
    /// - `rustError` contains error generated by the rust layer.
    // sourcery: code="ZRUST0093"
    case rustMigrationState(_ rustError: String)
    /// Error from rust layer when calling ZcashRustBackend.migrationProgress
    // sourcery: code="ZRUST0094"
    case rustMigrationProgress(_ rustError: String)
    /// Error from rust layer when calling ZcashRustBackend.migrationIsNoteSplitNeeded
    // sourcery: code="ZRUST0095"
    case rustMigrationIsNoteSplitNeeded(_ rustError: String)
    /// Error from rust layer when calling ZcashRustBackend.migrationPrepareNoteSplit
    // sourcery: code="ZRUST0096"
    case rustMigrationPrepareNoteSplit(_ rustError: String)
    /// Error from rust layer when calling ZcashRustBackend.migrationSignNoteSplit
    // sourcery: code="ZRUST0097"
    case rustMigrationSignNoteSplit(_ rustError: String)
    /// Error from rust layer when calling ZcashRustBackend.migrationProposeTransfers
    // sourcery: code="ZRUST0098"
    case rustMigrationProposeTransfers(_ rustError: String)
    /// Error from rust layer when calling ZcashRustBackend.migrationSignAndStore
    // sourcery: code="ZRUST0099"
    case rustMigrationSignAndStore(_ rustError: String)
    /// Error from rust layer when calling ZcashRustBackend.migrationIsSyncRequired
    // sourcery: code="ZRUST0100"
    case rustMigrationIsSyncRequired(_ rustError: String)
    /// Error from rust layer when calling ZcashRustBackend.migrationNextDueTransfer
    // sourcery: code="ZRUST0101"
    case rustMigrationNextDueTransfer(_ rustError: String)
    /// Error from rust layer when calling ZcashRustBackend.migrationRecordTransferResult
    // sourcery: code="ZRUST0102"
    case rustMigrationRecordTransferResult(_ rustError: String)
    /// Error from rust layer when calling ZcashRustBackend.migrationHasOverdueTransfers
    // sourcery: code="ZRUST0103"
    case rustMigrationHasOverdueTransfers(_ rustError: String)
    /// Error from rust layer when calling ZcashRustBackend.migrationHasInvalidTransfers
    // sourcery: code="ZRUST0104"
    case rustMigrationHasInvalidTransfers(_ rustError: String)
    /// Error from rust layer when calling ZcashRustBackend.migrationRestartStep
    // sourcery: code="ZRUST0105"
    case rustMigrationRestartStep(_ rustError: String)
    /// Error from rust layer when calling ZcashRustBackend.migrationInitializePostUpgrade
    // sourcery: code="ZRUST0106"
    case rustMigrationInitializePostUpgrade(_ rustError: String)
```

(Confirm `ZRUST0092` is the current max before assigning `0093`+.)

- [ ] **Step 2: Regenerate**

Run: `./Error/Sourcery/generateErrorCode.sh`
Expected: `ZcashError.swift` + `ZcashErrorCode.swift` updated with the 14 cases.

- [ ] **Step 3: Build to confirm the generated files compile**

Run: `swift build`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/ZcashLightClientKit/Error/
git commit -m "[MOB-1455] Add migration rust error codes (ZRUST0093-0106)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Welding — protocol + actor impl + mocks

**Files:**
- Modify: `Sources/ZcashLightClientKit/Rust/ZcashRustBackendWelding.swift` (14 protocol methods)
- Modify: `Sources/ZcashLightClientKit/Rust/ZcashRustBackend.swift` (14 `@DBActor` impls)
- Regenerate: `Tests/TestUtils/Sourcery/GeneratedMocks/AutoMockable.generated.swift`

**Interfaces:**
- Consumes: the FFI fns (Task 3), models (Task 5), error cases (Task 6).
- Produces (protocol): `migrationState(for:)`, `migrationProgress(for:)`, `migrationIsNoteSplitNeeded(for:)`, `migrationPrepareNoteSplit(for:)`, `migrationSignNoteSplit(proposal:usk:for:)`, `migrationProposeTransfers(for:)`, `migrationSignAndStore(schedule:usk:for:)`, `migrationIsSyncRequired(for:)`, `migrationNextDueTransfer(for:)`, `migrationRecordTransferResult(transferId:result:for:)`, `migrationHasOverdueTransfers(for:)`, `migrationHasInvalidTransfers(for:)`, `migrationRestartStep(for:)`, `migrationInitializePostUpgrade(for:)` — all `async throws`.

- [ ] **Step 1: Add 14 declarations to `ZcashRustBackendWelding.swift`** (after `consensusBranchIdFor`):

```swift
    /// Current Orchard -> Ironwood migration state for `account`.
    func migrationState(for account: AccountUUID) async throws -> MigrationState
    /// Live migration progress, or nil when no migration is in progress.
    func migrationProgress(for account: AccountUUID) async throws -> MigrationProgress?
    /// Whether the Orchard notes must be split before migration.
    func migrationIsNoteSplitNeeded(for account: AccountUUID) async throws -> Bool
    /// The optimal note split for the spendable Orchard balance.
    func migrationPrepareNoteSplit(for account: AccountUUID) async throws -> NoteSplitProposal
    /// Build, sign and persist the note-split tx; returns bytes for the platform to broadcast.
    func migrationSignNoteSplit(proposal: NoteSplitProposal, usk: UnifiedSpendingKey, for account: AccountUUID) async throws -> PreparedTx
    /// The full migration schedule for the spendable Orchard balance.
    func migrationProposeTransfers(for account: AccountUUID) async throws -> MigrationSchedule
    /// Pre-sign and persist every transfer in the schedule.
    func migrationSignAndStore(schedule: MigrationSchedule, usk: UnifiedSpendingKey, for account: AccountUUID) async throws
    /// Whether a sync is required before the next transfer.
    func migrationIsSyncRequired(for account: AccountUUID) async throws -> Bool
    /// The next height-due pre-signed transfer, or nil.
    func migrationNextDueTransfer(for account: AccountUUID) async throws -> PreparedTx?
    /// Record the platform's broadcast outcome, advancing engine state.
    func migrationRecordTransferResult(transferId: String, result: TransferResult, for account: AccountUUID) async throws
    /// Whether any scheduled transfer is overdue.
    func migrationHasOverdueTransfers(for account: AccountUUID) async throws -> Bool
    /// Whether the migration is in an invalid state.
    func migrationHasInvalidTransfers(for account: AccountUUID) async throws -> Bool
    /// Re-evaluate the remaining balance and return a fresh schedule.
    func migrationRestartStep(for account: AccountUUID) async throws -> MigrationSchedule
    /// First-launch post-upgrade initialization.
    func migrationInitializePostUpgrade(for account: AccountUUID) async throws
```

- [ ] **Step 2: Add the 14 `@DBActor` impls to `ZcashRustBackend.swift`** (after `consensusBranchIdFor`). Read/return-value methods follow this template (JSON-decode BoxedSlice; null ⇒ throw):

```swift
    @DBActor func migrationState(for account: AccountUUID) async throws -> MigrationState {
        let ptr = zcashlc_migration_state(dbData.0, dbData.1, account.id, networkType.networkId)
        guard let ptr else {
            throw ZcashError.rustMigrationState(lastErrorMessage(fallback: "`migrationState` failed"))
        }
        defer { zcashlc_free_boxed_slice(ptr) }
        let data = Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len))
        do {
            return try JSONDecoder().decode(MigrationState.self, from: data)
        } catch {
            throw ZcashError.rustMigrationState("Failed to decode MigrationState: \(error)")
        }
    }

    @DBActor func migrationProgress(for account: AccountUUID) async throws -> MigrationProgress? {
        let ptr = zcashlc_migration_progress(dbData.0, dbData.1, account.id, networkType.networkId)
        guard let ptr else {
            throw ZcashError.rustMigrationProgress(lastErrorMessage(fallback: "`migrationProgress` failed"))
        }
        defer { zcashlc_free_boxed_slice(ptr) }
        let data = Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len))
        do {
            return try JSONDecoder().decode(MigrationProgress?.self, from: data)
        } catch {
            throw ZcashError.rustMigrationProgress("Failed to decode MigrationProgress: \(error)")
        }
    }

    @DBActor func migrationIsNoteSplitNeeded(for account: AccountUUID) async throws -> Bool {
        let ptr = zcashlc_migration_is_note_split_needed(dbData.0, dbData.1, account.id, networkType.networkId)
        guard let ptr else {
            throw ZcashError.rustMigrationIsNoteSplitNeeded(lastErrorMessage(fallback: "`migrationIsNoteSplitNeeded` failed"))
        }
        defer { zcashlc_free_boxed_slice(ptr) }
        let data = Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len))
        do {
            return try JSONDecoder().decode(Bool.self, from: data)
        } catch {
            throw ZcashError.rustMigrationIsNoteSplitNeeded("Failed to decode Bool: \(error)")
        }
    }

    @DBActor func migrationPrepareNoteSplit(for account: AccountUUID) async throws -> NoteSplitProposal {
        let ptr = zcashlc_migration_prepare_note_split(dbData.0, dbData.1, account.id, networkType.networkId)
        guard let ptr else {
            throw ZcashError.rustMigrationPrepareNoteSplit(lastErrorMessage(fallback: "`migrationPrepareNoteSplit` failed"))
        }
        defer { zcashlc_free_boxed_slice(ptr) }
        let data = Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len))
        do {
            return try JSONDecoder().decode(NoteSplitProposal.self, from: data)
        } catch {
            throw ZcashError.rustMigrationPrepareNoteSplit("Failed to decode NoteSplitProposal: \(error)")
        }
    }

    @DBActor func migrationProposeTransfers(for account: AccountUUID) async throws -> MigrationSchedule {
        let ptr = zcashlc_migration_propose_transfers(dbData.0, dbData.1, account.id, networkType.networkId)
        guard let ptr else {
            throw ZcashError.rustMigrationProposeTransfers(lastErrorMessage(fallback: "`migrationProposeTransfers` failed"))
        }
        defer { zcashlc_free_boxed_slice(ptr) }
        let data = Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len))
        do {
            return try JSONDecoder().decode(MigrationSchedule.self, from: data)
        } catch {
            throw ZcashError.rustMigrationProposeTransfers("Failed to decode MigrationSchedule: \(error)")
        }
    }

    @DBActor func migrationIsSyncRequired(for account: AccountUUID) async throws -> Bool {
        let ptr = zcashlc_migration_is_sync_required(dbData.0, dbData.1, account.id, networkType.networkId)
        guard let ptr else {
            throw ZcashError.rustMigrationIsSyncRequired(lastErrorMessage(fallback: "`migrationIsSyncRequired` failed"))
        }
        defer { zcashlc_free_boxed_slice(ptr) }
        let data = Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len))
        do {
            return try JSONDecoder().decode(Bool.self, from: data)
        } catch {
            throw ZcashError.rustMigrationIsSyncRequired("Failed to decode Bool: \(error)")
        }
    }

    @DBActor func migrationNextDueTransfer(for account: AccountUUID) async throws -> PreparedTx? {
        let ptr = zcashlc_migration_next_due_transfer(dbData.0, dbData.1, account.id, networkType.networkId)
        guard let ptr else {
            throw ZcashError.rustMigrationNextDueTransfer(lastErrorMessage(fallback: "`migrationNextDueTransfer` failed"))
        }
        defer { zcashlc_free_boxed_slice(ptr) }
        let data = Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len))
        do {
            return try JSONDecoder().decode(PreparedTx?.self, from: data)
        } catch {
            throw ZcashError.rustMigrationNextDueTransfer("Failed to decode PreparedTx: \(error)")
        }
    }

    @DBActor func migrationHasOverdueTransfers(for account: AccountUUID) async throws -> Bool {
        let ptr = zcashlc_migration_has_overdue_transfers(dbData.0, dbData.1, account.id, networkType.networkId)
        guard let ptr else {
            throw ZcashError.rustMigrationHasOverdueTransfers(lastErrorMessage(fallback: "`migrationHasOverdueTransfers` failed"))
        }
        defer { zcashlc_free_boxed_slice(ptr) }
        let data = Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len))
        do {
            return try JSONDecoder().decode(Bool.self, from: data)
        } catch {
            throw ZcashError.rustMigrationHasOverdueTransfers("Failed to decode Bool: \(error)")
        }
    }

    @DBActor func migrationHasInvalidTransfers(for account: AccountUUID) async throws -> Bool {
        let ptr = zcashlc_migration_has_invalid_transfers(dbData.0, dbData.1, account.id, networkType.networkId)
        guard let ptr else {
            throw ZcashError.rustMigrationHasInvalidTransfers(lastErrorMessage(fallback: "`migrationHasInvalidTransfers` failed"))
        }
        defer { zcashlc_free_boxed_slice(ptr) }
        let data = Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len))
        do {
            return try JSONDecoder().decode(Bool.self, from: data)
        } catch {
            throw ZcashError.rustMigrationHasInvalidTransfers("Failed to decode Bool: \(error)")
        }
    }

    @DBActor func migrationRestartStep(for account: AccountUUID) async throws -> MigrationSchedule {
        let ptr = zcashlc_migration_restart_step(dbData.0, dbData.1, account.id, networkType.networkId)
        guard let ptr else {
            throw ZcashError.rustMigrationRestartStep(lastErrorMessage(fallback: "`migrationRestartStep` failed"))
        }
        defer { zcashlc_free_boxed_slice(ptr) }
        let data = Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len))
        do {
            return try JSONDecoder().decode(MigrationSchedule.self, from: data)
        } catch {
            throw ZcashError.rustMigrationRestartStep("Failed to decode MigrationSchedule: \(error)")
        }
    }
```

Void methods (success ⇒ non-null body, ignored) and arg-carrying methods:

```swift
    @DBActor func migrationInitializePostUpgrade(for account: AccountUUID) async throws {
        let ptr = zcashlc_migration_initialize_post_upgrade(dbData.0, dbData.1, account.id, networkType.networkId)
        guard let ptr else {
            throw ZcashError.rustMigrationInitializePostUpgrade(lastErrorMessage(fallback: "`migrationInitializePostUpgrade` failed"))
        }
        zcashlc_free_boxed_slice(ptr)
    }

    @DBActor func migrationSignNoteSplit(proposal: NoteSplitProposal, usk: UnifiedSpendingKey, for account: AccountUUID) async throws -> PreparedTx {
        let proposalBytes = [UInt8](try JSONEncoder().encode(proposal))
        let ptr = proposalBytes.withUnsafeBufferPointer { proposalPtr in
            usk.bytes.withUnsafeBufferPointer { uskPtr in
                zcashlc_migration_sign_note_split(
                    dbData.0,
                    dbData.1,
                    account.id,
                    networkType.networkId,
                    proposalPtr.baseAddress,
                    UInt(proposalBytes.count),
                    uskPtr.baseAddress,
                    UInt(usk.bytes.count)
                )
            }
        }
        guard let ptr else {
            throw ZcashError.rustMigrationSignNoteSplit(lastErrorMessage(fallback: "`migrationSignNoteSplit` failed"))
        }
        defer { zcashlc_free_boxed_slice(ptr) }
        let data = Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len))
        do {
            return try JSONDecoder().decode(PreparedTx.self, from: data)
        } catch {
            throw ZcashError.rustMigrationSignNoteSplit("Failed to decode PreparedTx: \(error)")
        }
    }

    @DBActor func migrationSignAndStore(schedule: MigrationSchedule, usk: UnifiedSpendingKey, for account: AccountUUID) async throws {
        let scheduleBytes = [UInt8](try JSONEncoder().encode(schedule))
        let ptr = scheduleBytes.withUnsafeBufferPointer { schedulePtr in
            usk.bytes.withUnsafeBufferPointer { uskPtr in
                zcashlc_migration_sign_and_store(
                    dbData.0,
                    dbData.1,
                    account.id,
                    networkType.networkId,
                    schedulePtr.baseAddress,
                    UInt(scheduleBytes.count),
                    uskPtr.baseAddress,
                    UInt(usk.bytes.count)
                )
            }
        }
        guard let ptr else {
            throw ZcashError.rustMigrationSignAndStore(lastErrorMessage(fallback: "`migrationSignAndStore` failed"))
        }
        zcashlc_free_boxed_slice(ptr)
    }

    @DBActor func migrationRecordTransferResult(transferId: String, result: TransferResult, for account: AccountUUID) async throws {
        let resultBytes = [UInt8](try JSONEncoder().encode(result))
        let ptr = resultBytes.withUnsafeBufferPointer { resultPtr in
            zcashlc_migration_record_transfer_result(
                dbData.0,
                dbData.1,
                account.id,
                networkType.networkId,
                [CChar](transferId.utf8CString),
                resultPtr.baseAddress,
                UInt(resultBytes.count)
            )
        }
        guard let ptr else {
            throw ZcashError.rustMigrationRecordTransferResult(lastErrorMessage(fallback: "`migrationRecordTransferResult` failed"))
        }
        zcashlc_free_boxed_slice(ptr)
    }
```

(`account.id` is `[UInt8]` of 16 bytes → bridges to `const uint8_t *`; `networkType.networkId` is the `u32`. Match the exact pointer-bridging the cbindgen header expects — if it imports `db_data` as non-optional `UnsafePointer<UInt8>`, the `dbData.0` String bridges as in `listAccounts`.)

- [ ] **Step 3: Regenerate mocks**

Run: `./Tests/TestUtils/Sourcery/generateMocks.sh` (needs Sourcery **2.3.0**)
Expected: `AutoMockable.generated.swift` gains the 14 mocked methods.

- [ ] **Step 4: Build (rebuild the macOS slice first if FFI signatures changed)**

Run: `./Scripts/rebuild-local-ffi.sh macos` (only if `migration.rs` changed since Task 4) then `swift build`
Expected: PASS — welding + mocks compile.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZcashLightClientKit/Rust/ZcashRustBackendWelding.swift Sources/ZcashLightClientKit/Rust/ZcashRustBackend.swift Tests/TestUtils/Sourcery/GeneratedMocks/AutoMockable.generated.swift
git commit -m "[MOB-1455] Welding: 14 migration methods on ZcashRustBackend + mocks

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: FFI integration offline tests

**Files:**
- Create: `Tests/OfflineTests/MigrationFFITests.swift`

**Interfaces:**
- Consumes: `ZcashRustBackend.makeForTests(dbData:fsBlockDbRoot:networkType:)`, the welding methods.

- [ ] **Step 1: Write the tests** (use a fresh data db so the migration state is `NotStarted`; the prepopulated builder is fine too — no run exists either way):

```swift
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class MigrationFFITests: XCTestCase {
    var dbData: URL!
    var rustBackend: ZcashRustBackendWelding!
    let account = AccountUUID(id: [UInt8](repeating: 7, count: 16))

    override func setUp() {
        super.setUp()
        dbData = try! __dataDbURL()
        rustBackend = ZcashRustBackend.makeForTests(
            dbData: dbData,
            fsBlockDbRoot: Environment.uniqueTestTempDirectory,
            networkType: .testnet
        )
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: dbData!)
        rustBackend = nil
    }

    func testMigrationStateOnFreshWalletIsNotStarted() async throws {
        let state = try await rustBackend.migrationState(for: account)
        XCTAssertEqual(state, .notStarted)
    }

    func testMigrationProgressIsNilWhenNotStarted() async throws {
        let progress = try await rustBackend.migrationProgress(for: account)
        XCTAssertNil(progress)
    }

    func testInitializePostUpgradeSucceeds() async throws {
        try await rustBackend.migrationInitializePostUpgrade(for: account)
    }

    func testRecordTransferResultWithNoActiveRunThrows() async throws {
        do {
            try await rustBackend.migrationRecordTransferResult(
                transferId: "does-not-exist",
                result: .success(txid: "abc"),
                for: account
            )
            XCTFail("expected record without an active run to throw")
        } catch {
            // MigrationError::InvalidState -> null ptr -> rustMigrationRecordTransferResult
        }
    }
}
```

- [ ] **Step 2: Run, expect pass**

Run: `swift test --filter MigrationFFITests` (or Xcode MCP `RunSomeTests`)
Expected: PASS. (If `__dataDbURL()`/`Environment.uniqueTestTempDirectory` differ, mirror `ZcashRustBackendTests.swift`'s setup exactly.)

- [ ] **Step 3: Run the full OfflineTests suite (no regressions)**

Run: `swift test --filter OfflineTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Tests/OfflineTests/MigrationFFITests.swift
git commit -m "[MOB-1455] Offline tests: migration FFI marshalling + state machine

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add an entry** under the top/unreleased section:

```markdown
### Added
- Internal `ZcashRustBackendWelding` surface for the Orchard → Ironwood migration engine
  (`zodl_ironwood_migration`): migration state/progress, note-split planning + signing, transfer
  scheduling + signing, due-transfer execution bookkeeping, and lifecycle/recovery. The public
  `Synchronizer` API and network broadcast composition follow in a later change.

### Changed
- The Rust core now builds against the valargroup `librustzcash` fork under
  `zcash_unstable="nu6.3"` to enable Ironwood (NU6.3) transaction building.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "[MOB-1455] CHANGELOG: migration welding + valargroup/nu6.3 deps

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:** Deps/build mode → Task 2,4. FFI (14 fns) → Task 3. Models → Task 5. Welding + protocol → Task 7. Error codes → Task 6. Mocks → Task 7. Offline tests → Task 5,8. Crate gap #1 → Task 1. CHANGELOG → Task 9. Out-of-scope items (public API, broadcast, iOS slices, MIGRATING) correctly absent. ✓

**Placeholder scan:** No TBD/TODO; all code blocks concrete. The one illustrative `mod ironwood_migration_ffi_placeholder` line is explicitly labelled "do not add". ✓

**Type consistency:** Welding method names match between protocol (Task 7 step 1), impls (step 2), error cases (Task 6), and tests (Task 8). FFI fn names match between Task 3 and the welding call sites. Model property names match between `Migration.swift` (Task 5) and the test literals. ✓

**Known build-discovered gaps (acceptable, flagged in-task):** exact `Payment::new`/`get_current_address`/`Zatoshis` APIs (Task 1 verifies in the crate loop); fork fallout extent (Task 2); orchard/voting feature unification (Task 2, STOP-and-report); exact serde JSON literals (Task 5 step 4 verifies against the crate).
