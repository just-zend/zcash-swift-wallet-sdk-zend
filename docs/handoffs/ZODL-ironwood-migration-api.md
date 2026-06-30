# Handoff — ZODL app: adopt the updated SDK Ironwood migration API

**Audience:** whoever integrates the Orchard → Ironwood migration API in the ZODL app.
**Driver:** the SDK welding tier pivoted to the `zodl_ironwood_migration` crate `main` (PCZT pivot +
canonical `zcash_protocol` types), and the SDK orchestration layer adopted it on branch
`michal/MOB-1455-2-ironwood-migration-sdk-impl` (ticket MOB-1455). This handoff lists the *app-facing*
deltas.

The migration API is **pre-release** (it has never shipped in a tagged SDK version), so the items
below are corrections to the in-flight surface — not breaking changes against a release you already
depend on. They matter only if your integration was written against an earlier draft of this API.

---

## TL;DR — what changes in ZODL

1. **Two field renames on returned models (read sites):**
   - `MigrationProgress.remainingOrchardZatoshi` → **`remainingOrchard`** (`UInt64`, unchanged type)
   - `TransferProposal.amountZatoshi` → **`amount`** (`UInt64`, unchanged type)
2. **One new (optional) recovery method:** `refreshStaleTransfers(spendingKey:for:) async throws -> UInt32`.
3. **No behavioral change you must handle:** broadcasting is now internally *extract-then-submit*, but
   that is entirely inside the SDK. You keep calling `submitNoteSplit` / `executeNextPendingTransfer`
   exactly as before.

If your ZODL code never reads `remainingOrchardZatoshi` / `amountZatoshi` and you do not need the new
recovery method, **no change is required.**

---

## 1. Field renames (the only likely code change)

The crate moved to canonical `zcash_protocol` types. The **wire format is unchanged** (plain `u64`);
only the Swift property names changed.

| Old | New | Type | Where you read it |
|---|---|---|---|
| `MigrationProgress.remainingOrchardZatoshi` | `MigrationProgress.remainingOrchard` | `UInt64` | progress UI; also inside `MigrationState.inProgress(_)` |
| `TransferProposal.amountZatoshi` | `TransferProposal.amount` | `UInt64` | the migration-schedule confirmation UI (`MigrationSchedule.transfers`) |

Grep your app for `remainingOrchardZatoshi` and `amountZatoshi` and rename.

`PreparedTx.rawTx` was also renamed to `PreparedTx.rawPczt`, but **the public `Synchronizer` API never
returns a `PreparedTx`** (broadcasting is internal), so ZODL almost certainly does not reference it.
Listed only for completeness.

Everything else is unchanged: `MigrationState`, `AttentionReason`, `TransferResult`,
`NetworkPrivacyOptions`, `NoteSplitProposal`, `MigrationSchedule`, and all other field names / enum
cases keep their names.

## 2. New method — `refreshStaleTransfers`

```swift
func refreshStaleTransfers(spendingKey: UnifiedSpendingKey, for account: AccountUUID) async throws -> UInt32
```

Re-anchors, re-proves and re-signs the active migration run's scheduled transfers when they have gone
stale (their anchor is too old to broadcast). Returns the number of transfers refreshed. Pair it with
the existing `hasOverdueTransfers(for:)` detector:

```swift
if try await synchronizer.hasOverdueTransfers(for: account) {
    let refreshed = try await synchronizer.refreshStaleTransfers(spendingKey: usk, for: account)
    // …then resume executing due transfers…
}
```

This is a lighter recovery than `restartCurrentMigrationStep(for:)` (which re-proposes a whole new
schedule). Adopting it is optional.

## 3. Broadcasting is now extract-then-submit (internal — no action needed)

`PreparedTx.rawPczt` is a serialized PCZT, not a broadcastable transaction. The SDK now extracts the
consensus transaction from the signed PCZT before submitting it. This is fully encapsulated inside
`submitNoteSplit(...)` and `executeNextPendingTransfer(...)` — your call sites and their
`TransferResult` handling are unchanged.

---

## Full public API reference (async `Synchronizer`, current shape)

All methods take `for account: AccountUUID`. Async-only — the `ClosureSynchronizer` /
`CombineSynchronizer` adapters do **not** expose migration (out of scope for this version).

```swift
// State / progress
func migrationState(for: AccountUUID) async throws -> MigrationState
func migrationProgress(for: AccountUUID) async throws -> MigrationProgress?

// Note split
func isNoteSplitNeeded(for: AccountUUID) async throws -> Bool
func prepareNoteSplit(for: AccountUUID) async throws -> NoteSplitProposal
func submitNoteSplit(proposal: NoteSplitProposal, spendingKey: UnifiedSpendingKey,
                     options: NetworkPrivacyOptions, for: AccountUUID) async throws -> TransferResult

// Schedule
func proposeMigrationTransfers(for: AccountUUID) async throws -> MigrationSchedule
func signAndStoreMigrationSchedule(_ schedule: MigrationSchedule, spendingKey: UnifiedSpendingKey,
                                   for: AccountUUID) async throws

// Execution
func isSyncRequiredBeforeNextTransfer(for: AccountUUID) async throws -> Bool
func executeNextPendingTransfer(options: NetworkPrivacyOptions, for: AccountUUID) async throws -> TransferResult?

// Detection / recovery
func hasOverdueTransfers(for: AccountUUID) async throws -> Bool
func hasInvalidTransfers(for: AccountUUID) async throws -> Bool
func refreshStaleTransfers(spendingKey: UnifiedSpendingKey, for: AccountUUID) async throws -> UInt32   // NEW
func restartCurrentMigrationStep(for: AccountUUID) async throws -> MigrationSchedule

// Lifecycle
func initializePostUpgrade(for: AccountUUID) async throws
```

### Model field names (final)

```swift
MigrationProgress { completedTransfers: UInt32, totalTransfers: UInt32,
                    remainingOrchard: UInt64, nextTransferReadyAtHeight: UInt32? }
TransferProposal  { id: String, amount: UInt64, anchorHeight: UInt32,
                    nextExecutableAfterHeight: UInt32, expiryHeight: UInt32 }
MigrationSchedule { transfers: [TransferProposal], estimatedDurationHours: UInt32 }
NoteSplitProposal { outputNotes: [UInt64], fee: UInt64 }
NetworkPrivacyOptions { useTor: Bool, submissionEndpoint: String? }
MigrationState  = .notStarted | .splitPendingConfirmation | .readyToPropose
                | .inProgress(MigrationProgress) | .requiresAttention(AttentionReason) | .complete
AttentionReason = .invalidTransfer(transferId: String) | .transferExpired | .syncRequiredBeforeNext
TransferResult  = .success(txid: String) | .networkError(retryable: Bool) | .invalidNote | .expired
```

## Caveats to keep in mind

- **`NetworkPrivacyOptions` is accepted but ignored in this version.** Broadcast uses the SDK's
  already-configured lightwalletd. Keep passing it (the parameter is required); Tor / secondary-endpoint
  honoring will come later.
- **On-device proving cost (SDK-side, may affect UX).** The crate's PCZT pipeline builds Orchard +
  Ironwood proving keys and proves on device, which adds time/size to `submitNoteSplit` /
  `signAndStoreMigrationSchedule` / `refreshStaleTransfers`. Budget for it in spinners / background
  task time limits. (The persisted-PCZT model also leaves the door open to moving signing to an
  external signer later; not exposed yet.)
- **End-to-end broadcast is not yet verified on a seeded/synced wallet** — the SDK side is compile- and
  offline-test verified. Coordinate a staging round-trip before relying on it in production.
