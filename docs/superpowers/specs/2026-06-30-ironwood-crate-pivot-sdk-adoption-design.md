# Design — Adopt the crate PCZT pivot in the SDK orchestration layer

**Date:** 2026-06-30
**Branch:** `michal/MOB-1455-2-ironwood-migration-sdk-impl` (current).
**Ticket:** MOB-1455.
**Source handoff:** "SDK-impl/orchestration changes after the crate PCZT pivot" (inline, from the
FFI/welding branch `michal/MOB-1455-ironwood-migration-prototype-ffi`).
**Supersedes:** the broadcast/rename portions of
`2026-06-30-ironwood-migration-public-api-design.md` (written against the pre-pivot model — it shows
direct `rawTx` submission and old field names). That doc is kept as historical context.

## Problem — the branch does not compile

The welding tier was updated to the crate's `main` (PCZT pivot) in commit `86450d54`, renaming the
public model **properties** and **CodingKeys** (`rawTx → rawPczt`, `amountZatoshi → amount`,
`remainingOrchardZatoshi → remainingOrchard`) and adding two welding methods
(`migrationExtractBroadcastTx`, `migrationRefreshStaleTransfers`, error codes ZRUST0107/0108). That
tier is complete and offline-tested.

But the public-API layer added afterward (commits `6d12b2ec`, `2ac31c14`) was written against the
**pre-pivot** model. The result is an inconsistent tree that cannot build:

1. **`Model/Migration.swift`** — the public memberwise inits use the **old** parameter labels and
   assign to **non-existent** properties: `MigrationProgress.init(… remainingOrchardZatoshi:)` does
   `self.remainingOrchardZatoshi = …` (property is `remainingOrchard`); `PreparedTx.init(… rawTx:)`
   does `self.rawTx = …` (property is `rawPczt`); `TransferProposal.init(… amountZatoshi:)` does
   `self.amountZatoshi = …` (property is `amount`). Three compile errors.
2. **`SDKSynchronizer.broadcastMigrationTx`** — reads `prepared.rawTx` (non-existent) and submits it
   directly. Both a compile error and the wrong behavior: per the handoff §1, `rawPczt` is a
   **serialized PCZT**, not a broadcastable tx; it must be run through `migrationExtractBroadcastTx`
   first.
3. **Test files disagree.** `MigrationModelTests.swift` already uses the new init labels
   (`PreparedTx(… rawPczt:)`, `MigrationProgress(… remainingOrchard:)`), while
   `MigrationSynchronizerTests.swift` uses the old labels (`rawTx:`, `remainingOrchardZatoshi:`) and
   asserts the submitted bytes equal `prepared.rawTx`. Both cannot hold.

The handoff §3 dictates the resolution: the **new** names win.

## Goal

Make the orchestration layer consistent with the pivoted welding tier: finish the field renames,
adopt the extract-then-submit broadcast flow, surface the one orphan welding method, get the package
+ OfflineTests green, and hand the public-API delta to the ZODL app.

## Decisions

1. **New names win** (handoff §3) — fix the three inits in `Migration.swift` to the new parameter
   labels (`rawPczt:`, `amount:`, `remainingOrchard:`) and correct the body assignments. This makes
   the already-correct `MigrationModelTests.swift` compile.
2. **Extract-then-submit** (handoff §1) — `broadcastMigrationTx` gains a `for account:` parameter and,
   before submitting, calls
   `initializer.rustBackend.migrationExtractBroadcastTx(pczt: prepared.rawPczt, for: account)` to get
   the consensus tx bytes; those bytes (not the PCZT) are what gets submitted. An extract failure
   **propagates** (it is a local/crate error — `ZcashError.rustMigrationExtractBroadcastTx` — not a
   network outcome, so it is not mapped to `.networkError`). Both composites already have `account`
   in scope and pass it through.
3. **Surface `refreshStaleTransfers` publicly** (user-confirmed) — add
   `refreshStaleTransfers(spendingKey:for:) async throws -> UInt32` to the `Synchronizer` protocol +
   `SDKSynchronizer` as a thin delegation to `migrationRefreshStaleTransfers`. It is the only welding
   method with no consumer; it is a standalone recovery op (re-anchor + re-prove + re-sign the active
   run's stale transfers) that pairs with the existing `hasOverdueTransfers(for:)` detector. Naming
   drops the `migration` prefix to match the sibling delegations (`hasOverdueTransfers`,
   `restartCurrentMigrationStep`). Uses `spendingKey:` per the SDK convention (locked decision #5 of
   the public-API design).
4. **No new behavior beyond the above** (handoff §5) — error marshaling, numeric wire format, and the
   14 pre-existing welding methods are unchanged. `NetworkPrivacyOptions` stays accepted-but-ignored
   in v1. Closure/Combine adapters and voting remain out of scope.

## Changes (file by file)

### `Sources/ZcashLightClientKit/Model/Migration.swift`
Fix the three public inits (labels + body assignments):
- `MigrationProgress.init(completedTransfers:totalTransfers:remainingOrchard:nextTransferReadyAtHeight:)`
- `PreparedTx.init(id:txid:rawPczt:)`
- `TransferProposal.init(id:amount:anchorHeight:nextExecutableAfterHeight:expiryHeight:)`

### `Sources/ZcashLightClientKit/Synchronizer.swift`
- Add to the `// MARK: - Ironwood migration` section:
  ```swift
  /// Re-anchors, re-proves and re-signs the active migration run's scheduled transfers when they
  /// have gone stale (their anchor is too old to broadcast). Returns the number of transfers
  /// refreshed. Detect the need with ``hasOverdueTransfers(for:)``.
  func refreshStaleTransfers(spendingKey: UnifiedSpendingKey, for account: AccountUUID) async throws -> UInt32
  ```
  Placed in the recovery cluster (next to `hasOverdueTransfers` / `restartCurrentMigrationStep`).

### `Sources/ZcashLightClientKit/Synchronizer/SDKSynchronizer.swift`
- `broadcastMigrationTx(_ prepared: PreparedTx, for account: AccountUUID)`: extract first, then submit
  the extracted bytes. Update both call sites (`submitNoteSplit`, `executeNextPendingTransfer`) to
  `broadcastMigrationTx(prepared, for: account)`.
- Add the `refreshStaleTransfers` delegation:
  ```swift
  public func refreshStaleTransfers(spendingKey: UnifiedSpendingKey, for account: AccountUUID) async throws -> UInt32 {
      try await initializer.rustBackend.migrationRefreshStaleTransfers(usk: spendingKey, for: account)
  }
  ```

### `Tests/TestUtils/Sourcery/GeneratedMocks/AutoMockable.generated.swift`
Regenerated (Sourcery 2.3.0) so `SynchronizerMock` gains `refreshStaleTransfers`. Not hand-edited.

### `Tests/OfflineTests/MigrationSynchronizerTests.swift`
- `makePreparedTx(… rawTx:)` → `rawPczt:`; `MigrationProgress(… remainingOrchardZatoshi:)` →
  `remainingOrchard:`.
- Every composite test that reaches broadcast sets a **distinct** extract return value
  (`rustBackend.migrationExtractBroadcastTxPcztForReturnValue = extracted`) and asserts the submitted
  raw equals `Data(extracted)` (not `Data(prepared.rawPczt)`), plus that extract received
  `(prepared.rawPczt, account)`. This is what verifies the pivot.
- New test: extract throws → neither `submit` nor `migrationRecordTransferResult` is called, error
  propagates.
- New delegation test: `refreshStaleTransfers` delegates to `migrationRefreshStaleTransfers` and
  passes `(spendingKey, account)`, returning the count.

### `CHANGELOG.md`
Add `refreshStaleTransfers` to the public-API "Added" bullet; tweak the broadcast sentence to mention
the extract step. (The welding bullet already lists rawPczt + extract + stale-transfer refresh.)

### `MIGRATING.md`
Add `refreshStaleTransfers` to the migration-API method list under the existing "Orchard → Ironwood
migration API on `Synchronizer`" section.

### `docs/handoffs/ZODL-ironwood-migration-api.md` (new)
The ZODL-facing public-API delta (see below).

## Public-API delta for ZODL

The migration API is **pre-release** (unreleased), so these are not breaking changes against any
shipped tag — they are corrections to the in-flight surface ZODL is integrating against.

- **Renamed reads:** `MigrationProgress.remainingOrchardZatoshi → remainingOrchard`,
  `TransferProposal.amountZatoshi → amount`. ZODL reads both (progress UI, schedule confirmation).
- **`PreparedTx.rawTx → rawPczt`** — almost certainly invisible to ZODL: the public `Synchronizer`
  API never returns a `PreparedTx` (the composites return `TransferResult`); broadcasting is fully
  internal to the SDK. Listed for completeness.
- **New additive method:** `refreshStaleTransfers(spendingKey:for:) -> UInt32`. Optional to adopt;
  pair with `hasOverdueTransfers(for:)`.
- **Behavioral (transparent to ZODL):** broadcasting is now internally extract-then-submit. ZODL keeps
  calling `submitNoteSplit` / `executeNextPendingTransfer` unchanged.

## Testing & verification (TDD where it pays)

The model/synchronizer tests already encode the contract; TDD here = fix the tests to the new shape
first (they fail to compile / fail assertions against the current tree), then make them green.

- Build the package and run **OfflineTests** via the Xcode MCP (per global tooling rule). If Swift
  macros aren't trusted, **stop and ask** — do not bypass.
- Targeted suites: `MigrationSynchronizerTests`, `MigrationModelTests`, `MigrationFFITests`.
- Swift style: explicit type names (no `.init()`), no semicolons, injected `Logger`, string
  interpolation. Commit messages `[MOB-1455] …` on the current branch.

## Out of scope / deferred (→ final report)

- End-to-end broadcast against a seeded/synced DB (handoff §4 runtime caveats: on-device proving cost,
  circuit-version pairing, `extract_broadcast_tx` round-trip, pre-issue-#1 DB rename). Compile +
  mock-level offline only here.
- `NetworkPrivacyOptions` (Tor / secondary endpoint) honoring.
- txid byte-order assumption in `broadcastMigrationTx` (unchanged from the prior design).
- Closure/Combine adapters; voting re-enable.
