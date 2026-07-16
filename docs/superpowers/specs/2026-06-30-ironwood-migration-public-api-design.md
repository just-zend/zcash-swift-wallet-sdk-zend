# Design — Public Ironwood migration API on `Synchronizer`

**Date:** 2026-06-30
**Branch:** `michal/MOB-1455-2-ironwood-migration-sdk-impl` (current — note: differs from the handoff's
named branch `michal/MOB-1455-ironwood-migration-prototype-ffi`; we implement on the current branch per
instruction).
**Ticket:** MOB-1455.
**Source handoff:** `../IOS-SDK-PUBLIC-API-HANDOFF.md`.

## Goal

Expose the app-facing Orchard→Ironwood migration API on the **async** `Synchronizer` protocol and its
concrete `SDKSynchronizer`, built on the already-complete welding tier. The surface is a close port of the
Kotlin `OrchardMigrationSdk`: **11 thin delegations** to `initializer.rustBackend` plus **2 broadcast
composites** that submit the crate's pre-signed transactions through the SDK's **old direct send path**
(`transactionEncoder.submit(transaction:)`).

This session adds **only** the public `Synchronizer`-level API and the two composites. The welding tier
(FFI, `ZcashRustBackendWelding` migration methods, `Model/Migration.swift`, error codes ZRUST0093-0106) is
done and is not modified.

## Locked decisions (from handoff, confirmed with user)

1. **Flat on `Synchronizer`** — methods go directly on the protocol, not a dedicated sub-object.
2. **async-only for v1** — add to the async `Synchronizer` protocol + `SDKSynchronizer` only. Do **not**
   touch the `ClosureSynchronizer` / `CombineSynchronizer` protocols or their adapters
   (`ClosureSDKSynchronizer` / `CombineSDKSynchronizer`). They are independent protocols, so leaving them
   alone is sufficient and they keep compiling.
3. **Broadcast via the OLD direct path** — submit `PreparedTx.rawTx` straight through
   `transactionEncoder.submit(transaction:)`. Leave `SDKBroadcaster`, `Broadcaster`, `SubmitPlanStore`,
   `TxResubmissionAction` untouched.
4. **`NetworkPrivacyOptions`: accept but defer** — keep `options: NetworkPrivacyOptions` in the broadcasting
   signatures, but ignore it in v1 (no per-call Tor / secondary endpoint). Marker at the call site:
   `// TODO: [MOB-1455] honor NetworkPrivacyOptions (Tor / secondary endpoint)`.
5. **Signing methods take `spendingKey: UnifiedSpendingKey`** — matches the SDK convention
   (`createProposedTransactions(proposal:spendingKey:)`), unlike the Kotlin draft which hides keys.
6. **No FFI, model, or error-code changes** — the welding already provides everything.

## Public API — 13 methods

Added to the `Synchronizer` protocol under a new `// MARK: - Ironwood migration` section and implemented in
`SDKSynchronizer`. All take `for account: AccountUUID` because the welding methods do.

```swift
// MARK: - Ironwood migration

func migrationState(for account: AccountUUID) async throws -> MigrationState
func migrationProgress(for account: AccountUUID) async throws -> MigrationProgress?
func isNoteSplitNeeded(for account: AccountUUID) async throws -> Bool
func prepareNoteSplit(for account: AccountUUID) async throws -> NoteSplitProposal
func submitNoteSplit(
    proposal: NoteSplitProposal,
    spendingKey: UnifiedSpendingKey,
    options: NetworkPrivacyOptions,
    for account: AccountUUID
) async throws -> TransferResult                                                   // COMPOSITE (4a)
func proposeMigrationTransfers(for account: AccountUUID) async throws -> MigrationSchedule
func signAndStoreMigrationSchedule(
    _ schedule: MigrationSchedule,
    spendingKey: UnifiedSpendingKey,
    for account: AccountUUID
) async throws
func isSyncRequiredBeforeNextTransfer(for account: AccountUUID) async throws -> Bool
func executeNextPendingTransfer(
    options: NetworkPrivacyOptions,
    for account: AccountUUID
) async throws -> TransferResult?                                                  // COMPOSITE (4b)
func hasOverdueTransfers(for account: AccountUUID) async throws -> Bool
func hasInvalidTransfers(for account: AccountUUID) async throws -> Bool
func restartCurrentMigrationStep(for account: AccountUUID) async throws -> MigrationSchedule
func initializePostUpgrade(for account: AccountUUID) async throws
```

### Delegation mapping (11 methods)

Each delegate calls `initializer.rustBackend.*` directly and returns its result:

| Public method | rustBackend welding method |
|---|---|
| `migrationState(for:)` | `migrationState(for:)` |
| `migrationProgress(for:)` | `migrationProgress(for:)` |
| `isNoteSplitNeeded(for:)` | `migrationIsNoteSplitNeeded(for:)` |
| `prepareNoteSplit(for:)` | `migrationPrepareNoteSplit(for:)` |
| `proposeMigrationTransfers(for:)` | `migrationProposeTransfers(for:)` |
| `signAndStoreMigrationSchedule(_:spendingKey:for:)` | `migrationSignAndStore(schedule:usk:for:)` |
| `isSyncRequiredBeforeNextTransfer(for:)` | `migrationIsSyncRequired(for:)` |
| `hasOverdueTransfers(for:)` | `migrationHasOverdueTransfers(for:)` |
| `hasInvalidTransfers(for:)` | `migrationHasInvalidTransfers(for:)` |
| `restartCurrentMigrationStep(for:)` | `migrationRestartStep(for:)` |
| `initializePostUpgrade(for:)` | `migrationInitializePostUpgrade(for:)` |

**No `throwIfUnprepared()` guard** on the delegations. This matches the nearest analog — the rustBackend
delegations `createPCZTFromProposal` / `redactPCZTForSigner` / `addProofsToPCZT` delegate straight to
`initializer.rustBackend` without guarding. (`proposeTransfer` / `proposeShielding` guard because they are
`transactionEncoder` operations that require `prepare()`.) The migration methods are DB-bound rustBackend
operations and will fail naturally if the data DB is uninitialized.

The welding methods `migrationSignNoteSplit`, `migrationNextDueTransfer`, `migrationRecordTransferResult`
stay internal — they are the building blocks the two composites use (the Kotlin SDK does not surface them).

## The two composites + shared submit helper

Both composites live in `SDKSynchronizer`, where `transactionEncoder` (a `private var`) is reachable. The
crate already built and signed the transaction; the Swift side only **broadcasts the raw bytes** and maps
the outcome to a `TransferResult`.

### Private submit helper

Mirrors the existing `submitTransactions` error handling (`SDKSynchronizer.swift:485-513`):

```swift
private func broadcastMigrationTx(_ prepared: PreparedTx) async throws -> TransferResult {
    // PreparedTx.txid is the crate's hex txid string (display byte order); EncodedTransaction and
    // isTransactionKnownToServer need internal-order Data, so decode + reverse. See "txid handling".
    let txIdData = Data(hexEncoded: prepared.txid).map { Data($0.reversed()) } ?? Data()
    let encoded = EncodedTransaction(transactionId: txIdData, raw: Data(prepared.rawTx))

    // TODO: [MOB-1455] honor NetworkPrivacyOptions (Tor / secondary endpoint). v1 broadcasts over the
    // SDK's already-configured service via the old direct path.
    do {
        try await transactionEncoder.submit(transaction: encoded)
        return .success(txid: prepared.txid)
    } catch ZcashError.serviceSubmitFailed {
        return .networkError(retryable: true)
    } catch TransactionEncoderError.submitError {
        // Trust the network over the submit-side error: if the server already has this tx, the
        // broadcast landed. Mirror submitTransactions' isTransactionKnownToServer upgrade.
        if await transactionEncoder.isTransactionKnownToServer(txId: txIdData) {
            return .success(txid: prepared.txid)
        }
        // Conservative for v1. We do NOT infer invalidNote / expired from submit errors — the engine
        // owns deep invalidity: after broadcast, migrationHasInvalidTransfers / re-querying
        // migrationState surfaces RequiresAttention, and restartCurrentMigrationStep recovers.
        return .networkError(retryable: false)
    }
    // Any other error propagates (mirrors submitTransactions, which only special-cases the two cases
    // above and lets everything else throw).
}
```

### 4a. `submitNoteSplit`

```swift
let prepared = try await initializer.rustBackend.migrationSignNoteSplit(
    proposal: proposal, usk: spendingKey, for: account
)
return try await broadcastMigrationTx(prepared)
// State advances to SplitPendingConfirmation; the app polls migrationState. No record step.
```

### 4b. `executeNextPendingTransfer`

```swift
guard let prepared = try await initializer.rustBackend.migrationNextDueTransfer(for: account) else {
    return nil
}
let result = try await broadcastMigrationTx(prepared)
try await initializer.rustBackend.migrationRecordTransferResult(
    transferId: prepared.id, result: result, for: account
)
return result
```

No `spendingKey` — the transfer is pre-signed. Called from the app's BGTaskScheduler task; the app must not
sync in the same background session as this call (an app-side contract, not enforced here).

## txid handling (resolves a handoff gap)

The handoff sketched `EncodedTransaction(transactionId: preparedTx.txId, ...)`, but the actual model is
`PreparedTx { id: String, txid: String, rawTx: [UInt8] }` — `txid` is a hex **String**, while
`EncodedTransaction.transactionId` and `isTransactionKnownToServer(txId:)` need `Data`. The repo has only
`Data → hex` (`hexEncodedString()`), no `hex → Data`. Resolution:

- Add an internal `init?(hexEncoded:)` to `Data` in `Extensions/HexEncode.swift` (decodes a hex string to
  bytes; returns `nil` for odd length / non-hex).
- In the helper, decode `prepared.txid` then **reverse** to internal byte order. Rationale: the SDK's
  `Data.toHexStringTxId()` is `hexEncodedString().toTxIdString()` where `toTxIdString()` reverses
  internal→display; Zcash `TxId` displays in reversed byte order, so a crate-emitted display txid maps to
  internal-order `Data` by decode-then-reverse.
- `TransferResult.success(txid:)` passes `prepared.txid` **verbatim** — the engine records and matches that
  exact string, so it must not be transformed.

**Risk / scope:** the reversed-order assumption is unverified against the `zodl_ironwood_migration` crate
(end-to-end broadcast is deferred — see Deferred). It affects only the `isTransactionKnownToServer`
optimization and the Tor circuit grouping key; a wrong guess degrades the "already landed" upgrade to the
conservative `.networkError(retryable: false)`, never a correctness bug. Flagged with a code comment.

## Error mapping summary

| Submit outcome | `TransferResult` |
|---|---|
| success | `.success(txid: prepared.txid)` |
| `ZcashError.serviceSubmitFailed` (gRPC/network) | `.networkError(retryable: true)` |
| `TransactionEncoderError.submitError` + server knows txid | `.success(txid: prepared.txid)` |
| `TransactionEncoderError.submitError` + server doesn't know | `.networkError(retryable: false)` |
| any other error | propagates (thrown) |

`invalidNote` / `expired` are intentionally never produced from submit errors — the migration engine's
reconciliation owns deep invalidity.

## Testing (TDD, OfflineTests)

New file `Tests/OfflineTests/MigrationSynchronizerTests.swift`, subclassing `ZcashTestCase`, with a local
`makeSynchronizer(transactionEncoder:rustBackend:)` helper mirroring `BroadcasterTests` (registers mocks in
`mockContainer`, builds an `Initializer(isTorEnabled: false)`, returns an `SDKSynchronizer`). The composites
are driven against `ZcashRustBackendWeldingMock` (for the three building-block methods) and an enhanced
`StubTransactionEncoder` (for submit outcomes).

**`submitNoteSplit`:**
- success — `migrationSignNoteSplit` returns a `PreparedTx`, `submit` succeeds → `.success(txid:)`; assert
  the backend received `(proposal, usk, account)` and the encoder received
  `EncodedTransaction(raw: Data(prepared.rawTx))`.
- gRPC failure — `submit` throws `ZcashError.serviceSubmitFailed` → `.networkError(retryable: true)`.
- submitError + known-to-server — `submit` throws `TransactionEncoderError.submitError`, txid in the stub's
  known set → `.success(txid:)`.
- submitError + unknown — → `.networkError(retryable: false)`.
- sign throws — `migrationSignNoteSplit` throws → `submitNoteSplit` propagates; `submit` not called.

**`executeNextPendingTransfer`:**
- no due transfer — `migrationNextDueTransfer` returns `nil` → returns `nil`; `submit` and
  `migrationRecordTransferResult` not called.
- success — returns `.success(txid:)`; assert `migrationRecordTransferResult` received
  `(prepared.id, .success(txid:), account)`.
- gRPC failure — returns `.networkError(retryable: true)`; assert that exact result was recorded.
- nextDue throws — propagates; `migrationRecordTransferResult` not called.

`StubTransactionEncoder` (in `Tests/TestUtils/SubmissionTestDoubles.swift`) gains two behavior-preserving
knobs: `var submitError: Error?` (thrown by `submit` after it records the transaction) and
`var knownToServerTxIds: Set<Data>` (returned by `isTransactionKnownToServer`). Defaults (`nil`, empty)
preserve current behavior, so `BroadcasterTests` — which uses its own private stub anyway — is unaffected.

Note: `ZcashRustBackendWeldingMock.migrationRecordTransferResult` force-unwraps its closure, so tests that
reach the record step set `migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }` and
read `...ReceivedArguments` for assertions.

## Mock regeneration

Adding methods to the `Synchronizer` protocol breaks `SynchronizerMock` (it conforms to `Synchronizer`)
until regenerated. Run `Tests/TestUtils/Sourcery/generateMocks.sh` (Sourcery **2.3.0** — installed and
verified). Do not hand-edit generated code. Confirm `SynchronizerMock` gains the 13 methods and the target
compiles.

## Files touched

- `Sources/ZcashLightClientKit/Synchronizer.swift` — +13 protocol declarations (new MARK section).
- `Sources/ZcashLightClientKit/Synchronizer/SDKSynchronizer.swift` — +13 implementations (11 delegations,
  2 composites, 1 private `broadcastMigrationTx` helper).
- `Sources/ZcashLightClientKit/Extensions/HexEncode.swift` — internal `Data(hexEncoded:)` initializer.
- `Tests/TestUtils/SubmissionTestDoubles.swift` — extend `StubTransactionEncoder` (2 knobs).
- `Tests/TestUtils/Sourcery/GeneratedMocks/AutoMockable.generated.swift` — regenerated.
- `Tests/OfflineTests/MigrationSynchronizerTests.swift` — new test file.
- `CHANGELOG.md` — new public API entry.
- `MIGRATING.md` — document the new migration surface.

## Do NOT touch

`SDKBroadcaster.swift`, `Broadcaster.swift`, `SubmitPlanStore.swift`, `TxResubmissionAction.swift`; the
welding (`rust/src/migration.rs`, the `migration*` methods, `Model/Migration.swift`, error codes); voting;
`ClosureSynchronizer` / `CombineSynchronizer` protocols + adapters.

## Build / verify / conventions

- Build and run **OfflineTests** via the Xcode MCP (OfflineTests scheme). `LocalPackages/` is present
  (local FFI mode). If Swift macros aren't trusted, **stop and ask the user** (do not bypass).
- Swift style: explicit type names (no `.init()` shorthand), no semicolons, prefer `OSAllocatedUnfairLock`,
  injected `Logger` only, string interpolation not `+`.
- Commit messages: `[MOB-1455] <title>`. Commit to the current branch.

## Deferred — carried to the final report

- **End-to-end broadcast is untested** offline (the welding tier is compile-verified). OfflineTests cover
  the glue with mocks; real propose/sign/submit needs a seeded/synced DB or Darkside-style fixture.
- **`NetworkPrivacyOptions`** (Tor / secondary endpoint) accepted but ignored.
- **txid byte order** unverified against the crate (see txid handling).
- **Closure/Combine adapters** and **voting** re-enable remain out of scope.
