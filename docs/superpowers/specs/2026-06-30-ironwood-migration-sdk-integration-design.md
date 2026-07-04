# Design — Integrate `zodl_ironwood_migration` into the iOS SDK (welding tier)

**Date:** 2026-06-30
**Branch:** `michal/MOB-1455-ironwood-migration-prototype-ffi`
**Commit tag:** `[MOB-1455]`
**Source handoff:** `../IOS-SDK-INTEGRATION-HANDOFF.md`
**Crate under integration:** `../ZODLIronwoodMigrationRust` (local path dep; git repo on `main`)

## 1. Goal

Wire the synchronous, network-free `zodl_ironwood_migration` engine into `libzcashlc` so the
Swift SDK can drive an Orchard→Ironwood migration through the Rust FFI. Three layers:

1. **Dependencies / build mode** — switch the SDK's librustzcash graph to the valargroup fork
   (rev `0c3ad735`), add the crate, set the `nu6.3` unstable cfg.
2. **FFI** (`rust/src/migration.rs`) — one `extern "C"` function per `MigrationContext` method,
   marshalling whole `serde` types as JSON through the existing `BoxedSlice` mechanism.
3. **Swift welding** — `Codable` models, `ZcashRustBackendWelding` protocol methods +
   `ZcashRustBackend` actor implementations, generated error codes, regenerated mocks, offline
   tests.

Plus, per the approved scope, **close crate gap #1** (`backend::self_payment_request`) in
`../ZODLIronwoodMigrationRust` so the signing path is real rather than stubbed.

## 2. Approved scope decisions

| Decision | Choice | Consequence |
|---|---|---|
| Stack depth | **Welding only** | Add to the *internal* `ZcashRustBackendWelding` protocol + `ZcashRustBackend` actor. **Do NOT** touch the public `Synchronizer`/`SDKSynchronizer` protocol, Closure/Combine adapters, or the §6 broadcast composition. Public API + broadcast = follow-up. |
| Crate gap #1 (live signing) | **Close it now in the crate** | Implement `self_payment_request` in `../ZODLIronwoodMigrationRust/src/backend.rs`. Stays compile-verified (end-to-end run needs a synced wallet DB, which we are not building). |
| Commit tag | `[MOB-1455]` | Every commit on this branch (SDK repo) and the crate repo. |
| Marshalling | **JSON via `BoxedSlice`** | No hand-written `repr(C)` structs (unlike Harry's branch). Uniform: every migration FFI fn returns `*mut ffi::BoxedSlice`; null ⇒ error, non-null ⇒ `serde_json` body. |
| Model visibility | **`public`** | Model types mirror the crate's public vocabulary and the follow-up public API will reuse them verbatim; making them public now avoids a later breaking change. (Reversible — say the word to keep them `internal`.) |
| `zcash_voting` conflict | **Pin to valargroup branch** | The Swift SDK depends on `voting` (`Sources/.../Rust/Voting/*` + `Synchronizer`), so gating `mod voting` out (Harry's approach) would break the Swift layer. Pin `zcash_voting` to the valargroup branch so it resolves against the fork and voting keeps working. |
| Build target | **macOS-only local FFI** | `init-local-ffi.sh --macos-only`, then build/run `OfflineTests`. iOS sim/device slices are out of scope. |

## 3. Architecture & data flow

```
 Swift OfflineTests
        │  (TDD driver)
        ▼
 ZcashRustBackend (actor, @DBActor)        Sources/.../Rust/ZcashRustBackend.swift
   migrationState(for:) / prepareNoteSplit(for:) / signNoteSplit(...) / ...
        │  passes self.dbData bytes + account UUID bytes + network id (+ JSON args, usk bytes)
        │  guard ptr / defer free / JSONDecoder().decode(...)
        ▼
 zcashlc_migration_*  (extern "C")          rust/src/migration.rs   (NEW)
        │  catch_panic → MigrationContext::new(path, net, acct).method(...) → serde_json::to_vec
        ▼
 MigrationContext facade                    zodl_ironwood_migration (crate, local path)
        │  core (denominations/scheduling/state/store) + backend (valargroup librustzcash)
        ▼
 wallet dataDb (sqlite)  +  ironwood_migration_* tables (engine-owned)
```

**Key invariant (network-free):** the crate prepares/signs/persists/schedules and returns bytes;
it never opens a socket. Broadcasting `PreparedTx.rawTx` over LightWalletService/Tor is the
Swift layer's job — **out of scope here** (follow-up §6 composition).

**Concurrency:** every migration welding method touches the wallet DB file, so all are
`@DBActor` (matching `transactionDataRequests`), serialising with the SDK's other DB access.
The crate opens short-lived `rusqlite` connections per call to the same file.

## 4. Detailed design

### 4.1 Crate gap #1 — `self_payment_request` (`../ZODLIronwoodMigrationRust`)

Replace the stub (currently `Err("...integration gap")`) with a real ZIP-321 self-payment build,
split into a TDD-able pure seam + a thin DB-touching wrapper:

- **Pure helper** `build_self_payment(address: &ZcashAddress, amount: u64) -> Result<TransactionRequest, MigrationError>`
  — builds one `zip321::Payment` of `amount` to `address`, wraps in `TransactionRequest::new`.
  **Unit-tested** (no DB).
- **Wrapper** `self_payment_request(db, account, amount)` — resolves the account's current unified
  address via `WalletRead::get_current_address`, converts to `ZcashAddress`, calls the pure helper.
  **Compile-verified** (resolving a real address needs a seeded wallet DB — documented gap #2).

Verify exact valargroup APIs (`get_current_address` signature/return; `zip321::Payment`
constructor arity) against `../librustzcash` before writing. Commit in the crate repo on `main`.

### 4.2 Dependencies (`Cargo.toml`, `.cargo/config.toml`, `Cargo.lock`)

- Add dep: `zodl_ironwood_migration = { path = "../ZODLIronwoodMigrationRust" }`.
- Add `[patch.crates-io]` pointing **all** librustzcash crates at the valargroup fork, **mirroring
  `../ZODLIronwoodMigrationRust/Cargo.toml` exactly** (rev `0c3ad735f8402295fccb9acf2fe897779500bbf5`):
  `zcash_client_backend`, `zcash_client_sqlite`, `zcash_primitives`, `zcash_keys`,
  `zcash_protocol`, `zcash_transparent`, `zcash_proofs`, `zip321`, `pczt`.
- `orchard` pinned **by branch** `adam/qleak-dummy-ciphertexts-on-pr505` (a rev won't unify with
  the workspace's branch spec).
- `zcash_voting`: keep, but if it fails to resolve against the fork, pin to the valargroup branch
  `adam/qleak-pr136-orchard-librustzcash` (as vizor does).
- New `.cargo/config.toml`:
  ```toml
  [build]
  rustflags = ["--cfg", "zcash_unstable=\"nu6.3\""]
  ```
  Without it every Ironwood API compiles out.
- **rusqlite single-versioning:** keep one `rusqlite 0.37` (bundled) across SDK + crate.

### 4.3 FFI layer (`rust/src/migration.rs` + `mod migration;` in `lib.rs`)

cbindgen (`rust/build.rs`) auto-emits the header — no manual header edits. Mirror the
`zcashlc_propose_transfer` idiom: `catch_panic(|| { ... }) ; unwrap_exc_or_null(res)`.

**Uniform contract:** every fn returns `*mut ffi::BoxedSlice`. Success ⇒ `BoxedSlice::some(serde_json::to_vec(&value)?)`;
failure ⇒ closure returns `Err(anyhow!(...))` ⇒ `unwrap_exc_or_null` returns null and stores the
message for `zcashlc_last_error_message`. Void crate methods encode `serde_json::to_vec(&())`
(`"null"`); Swift ignores the body. `MigrationError` (Display + std::error::Error) maps via
`.map_err(|e| anyhow!("...: {e}"))`.

Shared helpers in `migration.rs`:
- `migration_network(network_id: u32) -> anyhow::Result<zodl_ironwood_migration::Network>`
  (reuse the `parse_network` id constants: testnet-id→`Test`, mainnet-id→`Main`).
- `migration_db_path(db_data, len) -> anyhow::Result<&str>` (`OsStr::from_bytes(...).to_str()`).
- `account_16(account_uuid_bytes) -> [u8; 16]`.
- USK signing methods pass raw `slice::from_raw_parts(usk_ptr, usk_len)` straight to the crate
  (the crate's `backend::parse_usk` expects `UnifiedSpendingKey` bytes, `Era::Orchard` — same
  encoding `decode_usk` uses, confirmed).

Functions (all take `db_data,len, account_uuid_bytes, network_id`; extras noted):

| # | FFI fn | extra args | JSON body |
|---|---|---|---|
| 1 | `zcashlc_migration_state` | — | `MigrationState` |
| 2 | `zcashlc_migration_progress` | — | `Option<MigrationProgress>` |
| 3 | `zcashlc_migration_is_note_split_needed` | — | `bool` |
| 4 | `zcashlc_migration_prepare_note_split` | — | `NoteSplitProposal` |
| 5 | `zcashlc_migration_sign_note_split` | `proposal_ptr,len`, `usk_ptr,len` | `PreparedTx` |
| 6 | `zcashlc_migration_propose_transfers` | — | `MigrationSchedule` |
| 7 | `zcashlc_migration_sign_and_store` | `schedule_ptr,len`, `usk_ptr,len` | `null` |
| 8 | `zcashlc_migration_is_sync_required` | — | `bool` |
| 9 | `zcashlc_migration_next_due_transfer` | — | `Option<PreparedTx>` |
| 10 | `zcashlc_migration_record_transfer_result` | `transfer_id` (c_char), `result_ptr,len` | `null` |
| 11 | `zcashlc_migration_has_overdue_transfers` | — | `bool` |
| 12 | `zcashlc_migration_has_invalid_transfers` | — | `bool` |
| 13 | `zcashlc_migration_restart_step` | — | `MigrationSchedule` |
| 14 | `zcashlc_migration_initialize_post_upgrade` | — | `null` |

Struct args (proposal/schedule/result) arrive as JSON bytes → `serde_json::from_slice`. Returned
`BoxedSlice` freed by the existing `zcashlc_free_boxed_slice`. **No broadcast fn** (by design).

### 4.4 Swift models (`Sources/ZcashLightClientKit/Model/Migration.swift`, NEW)

`public` `Codable`/`Equatable` types mirroring `src/types.rs`. **serde JSON shapes to match:**
- Struct fields are **snake_case verbatim** (`output_notes`, `amount_zatoshi`, `anchor_height`,
  `next_executable_after_height`, `expiry_height`, `estimated_duration_hours`,
  `completed_transfers`, `total_transfers`, `remaining_orchard_zatoshi`,
  `next_transfer_ready_at_height`, `raw_tx`, `use_tor`, `submission_endpoint`, `transfer_id`,
  `retryable`, `txid`) → explicit `CodingKeys` per struct.
- Enums use serde **external tagging**: unit variant ⇒ bare string (`"NotStarted"`,
  `"InvalidNote"`); data variant ⇒ single-key object (`{"InProgress":{…}}`,
  `{"Success":{"txid":"…"}}`, `{"RequiresAttention":"TransferExpired"}`,
  `{"RequiresAttention":{"InvalidTransfer":{"transfer_id":"…"}}}`). Custom `init(from:)` +
  `encode(to:)` handling string-or-object; nested (`MigrationState.requiresAttention` decodes an
  `AttentionReason`, itself string-or-object).
- `raw_tx: Vec<u8>` ⇒ serde JSON **array of numbers** ⇒ `[UInt8]`.
- zatoshi `u64` ⇒ `UInt64`; heights `u32` ⇒ `UInt32`; `Option` ⇒ Swift optional.

Types: `MigrationNetwork` (or reuse existing network mapping at the welding boundary),
`NetworkPrivacyOptions`, `NoteSplitProposal`, `TransferProposal`, `MigrationSchedule`,
`MigrationProgress`, `PreparedTx`, `MigrationState`, `AttentionReason`, `TransferResult`.
Exact JSON is **cross-checked by emitting `serde_json::to_string` from the crate** during impl;
Swift `CodingKeys`/decoders adjusted to match byte-for-byte.

### 4.5 Welding (`Rust/ZcashRustBackendWelding.swift` + `Rust/ZcashRustBackend.swift`)

14 protocol methods + 14 `@DBActor` impls. Idiom (from Harry's `planOrchardDenominationSplit`,
adapted to BoxedSlice+JSON):

```swift
@DBActor func migrationState(for account: AccountUUID) throws -> MigrationState {
    let ptr = zcashlc_migration_state(dbData.0, dbData.1, account.id.uuid_bytes, networkType.networkId)
    guard let ptr else {
        throw ZcashError.rustMigrationState(lastErrorMessage(fallback: "`migrationState` failed"))
    }
    defer { zcashlc_free_boxed_slice(ptr) }
    let data = Data(/* ptr.pointee.ptr, ptr.pointee.len — existing BoxedSlice→Data helper */)
    do { return try JSONDecoder().decode(MigrationState.self, from: data) }
    catch { throw ZcashError.rustMigrationState("decode failed: \(error)") }
}
```

Signing methods (`signNoteSplit`, `signAndStoreMigrationSchedule`) `JSONEncoder().encode` the
proposal/schedule arg and pass the USK bytes (as `createProposedTransactions` already does).
`recordTransferResult` takes `transferId: String` + `TransferResult`. Exact `dbData` byte access +
account-UUID-bytes + `networkId` follow whatever the existing methods use (verified in impl).

### 4.6 Errors (Sourcery — never hand-edit generated files)

Add 14 cases to `Error/ZcashErrorCodeDefinition.swift`, codes **ZRUST0093–ZRUST0106**
(`rustMigrationState` … `rustMigrationInitializePostUpgrade`), each `case rustMigrationX(_ rustError: String)`.
Run `Error/Sourcery/generateErrorCode.sh` → regenerates `ZcashError.swift` + `ZcashErrorCode.swift`.
Each welding method throws its own case for both null-ptr and JSON-decode failure.

### 4.7 Mocks (Sourcery 2.3.0 exactly)

New protocol methods ⇒ run `Tests/TestUtils/Sourcery/generateMocks.sh` to regenerate
`Tests/TestUtils/Sourcery/GeneratedMocks/AutoMockable.generated.swift`, or `OfflineTests` won't
compile.

## 5. TDD plan

Red → green, smallest first. Offline-testable surface only (gap #2: balance/sign need a synced DB).

**Crate (gap #1):**
- `build_self_payment` builds a `TransactionRequest` with one `amount`-valued payment to the given
  address (pure unit test). The DB-touching wrapper stays compile-verified.

**SDK Rust (`migration.rs`):**
- `zcashlc_migration_state` on a fresh temp sqlite path returns non-null `BoxedSlice` whose JSON is
  `"NotStarted"` (validates helpers + marshalling end-to-end in Rust).

**Swift `Tests/OfflineTests` (primary driver):**
- Model decode/encode round-trips for every type, against JSON literals matching serde's exact
  output (cross-checked from the crate): each `MigrationState`/`TransferResult` variant,
  `NoteSplitProposal`, `TransferProposal`, `MigrationSchedule`, `MigrationProgress`, `PreparedTx`
  (incl. `raw_tx` array), `NetworkPrivacyOptions`, `AttentionReason`.
- FFI integration via `ZcashRustBackend.makeForTests` on the pre-populated data DB:
  - `migrationState(for:)` on a fresh wallet ⇒ `.notStarted`.
  - `migrationProgress(for:)` ⇒ `nil`.
  - `initializePostUpgrade(for:)` ⇒ no throw.
  - `recordTransferResult(...)` with no active run ⇒ throws `rustMigrationRecordTransferResult`.

## 6. Build & verify loop

1. `./Scripts/init-local-ffi.sh --macos-only` — enter local-FFI mode, build the macOS slice
   (first build recompiles the whole valargroup graph — slow; needs network for the git fetch).
2. Iterate Rust: `./Scripts/rebuild-local-ffi.sh macos`. Iterate Swift: rebuild in Xcode.
3. Build/test `OfflineTests` via **Xcode MCP** (`BuildProject` / `RunSomeTests` on the OfflineTests
   scheme/test plan; open `ZcashSDK.xcworkspace`), falling back to `swift build` /
   `swift test --filter OfflineTests` (CI parity) if the MCP is unavailable.
4. **Macro trust:** if the fork's Swift macros aren't trusted, **STOP and ask** — do not bypass.

## 7. Risks (build-discovered; surface, don't silently work around)

1. **orchard feature unification vs voting (highest).** The SDK's `orchard` needs
   `unstable-voting-circuits`; the `qleak-dummy-ciphertexts-on-pr505` branch may not define it.
   Cargo unions features onto the patched orchard. If it fails to build, that's a real conflict —
   surface it (candidate fixes: a different orchard branch that has both, or, last resort and a
   flagged behavior change, gating voting). **Will not silently drop voting.**
2. **Fork-switch fallout in existing `rust/src/lib.rs`.** Switching the patch to the Ironwood-era
   fork can change existing APIs (Harry's branch shows `rewind_to_height`→`truncate_to_height`,
   `put_utxo` arity, `pczt.serialize()` now `Result`, `OrchardCircuitVersion`). Fix forward to
   compile; scope is unbounded until the first build.
3. **`zcash_voting` resolution** against the all-valargroup stack (mitigation: branch pin §4.2).
4. **Gap #1 stays compile-verified** — `self_payment_request` and all balance/sign paths need a
   seeded, synced wallet DB to run; offline tests cannot cover them (gap #2).

## 8. Out of scope (follow-up)

Public `Synchronizer`/`SDKSynchronizer` API; Closure/Combine adapters; the §6 broadcast
composition (`submitNoteSplit`, `executeNextPendingTransfer`) over LightWalletService/Tor; iOS
sim/device FFI slices; a synced-wallet (Darkside) fixture for end-to-end signing; `MIGRATING.md`
public-API entry (none yet — welding is internal).

## 9. Touchpoints

**Crate repo (`../ZODLIronwoodMigrationRust`):** `src/backend.rs` (close gap #1) + test; commit on `main`.

**SDK repo:** `Cargo.toml` · `.cargo/config.toml` (new) · `Cargo.lock` · `rust/src/migration.rs`
(new) · `rust/src/lib.rs` (`mod migration;` + any fork-fallout fixes) · `Sources/.../Model/Migration.swift`
(new) · `Sources/.../Rust/ZcashRustBackendWelding.swift` · `Sources/.../Rust/ZcashRustBackend.swift`
· `Sources/.../Error/ZcashErrorCodeDefinition.swift` (+ Sourcery → `ZcashError.swift`,
`ZcashErrorCode.swift`) · `Tests/.../AutoMockable.generated.swift` (regen) ·
`Tests/OfflineTests/MigrationFFITests.swift` (+ model tests) · `CHANGELOG.md`.
