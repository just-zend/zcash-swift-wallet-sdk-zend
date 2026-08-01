# Migrating from previous versions to _Unreleased_

## The SDK-side migration state machine is removed — `migrationAdvanceStep` replaces it

The public 5-state `MigrationState` enum, `MigrationAttentionReason`, and
`migrationState(accountUUID:)` are removed (this was never in a released SDK, so there is no
deprecation period). The SDK no longer derives a state machine of its own on top of the engine at
all: `migrationAdvanceStep(accountUUID:) async throws -> MigrationAdvanceStep?` drives the
upstream engine's public `advance_migration` API. The broadcast-first ordering and prove step's
kind are native to the pinned librustzcash revision (upstream PR #2871); its `Reevaluate` and
`Replan` results project onto the existing `.requiresAttention(id:)` case.
`nil` means no run is stored at all (nothing was ever committed for the account); a stored run
answers `.requiresAttention(id:)`, `.prove(id:kind:)`, `.broadcast(id:)`, `.rebuild(id:)`,
`.waiting`, or the terminal `.complete` — priority order attend > broadcast > prove > rebuild, and
a cancelled run also reports `.complete` rather than ever being driven further.

Every `MigrationState` case a host rendered UI off has a direct replacement — table below — but note
the shape is different: `migrationAdvanceStep` answers "what does the run need next", not "what is
the run's overall status", so a host that switched over the old 5 cases now reads several signals
together instead of one:

| Old `MigrationState` case | Replacement |
| --- | --- |
| `.notStarted` | `migrationAdvanceStep(accountUUID:) == nil && migrationProgress(accountUUID:) == nil` |
| `.splitPendingConfirmation` | `!migrationTransactionStatuses(accountUUID:).isPreparationPhaseComplete` |
| `.inProgress(progress)` | `migrationAdvanceStep` is `.prove`/`.broadcast`/`.waiting` + `migrationProgress(accountUUID:)` for the progress payload |
| `.requiresAttention(.invalidTransfer)` | `migrationAdvanceStep` is `.requiresAttention(id:)` (the engine surfaces it FIRST, ahead of any actionable step); the per-row detail is the new `.invalid(reason:)` case of `MigrationTransactionStatus.State` (`fundingSpent` / `rejectedInvalid` / `rejectedExpired`, with `blockedOn == .invalid`), and `hasInvalidMigrationTransfers(accountUUID:)` remains the boolean check |
| `.requiresAttention(.transferExpired)` | `migrationAdvanceStep` is `.rebuild(id:)` (an already-expired PREPARATION instead reports the new `.expired` case of `MigrationTransactionStatus.Blocker` in `migrationTransactionStatuses(accountUUID:)` — its remedy is `restartCurrentMigrationStep(accountUUID:)`, not a rebuild) |
| `.complete` | `migrationAdvanceStep == .complete` (per-run, including a cancelled run — see below) |

`.complete` is **per-run, never "nothing left to migrate"**: whether a migratable balance remains
(several successive runs, or funds received later) is answered by
`proposeMigrationTransfers(accountUUID:)` alone — an empty schedule means no. This was already true
of the removed `MigrationState.complete` and carries over unchanged to `migrationAdvanceStep ==
.complete`.

Discharging each step:

- `.requiresAttention(id:)` → a transaction of the run is `.invalid(reason:)` (its funding note was
  spent outside the migration, or the network rejected its broadcast) and no automatic step can
  advance the run right now: SYNC and call `migrationAdvanceStep(accountUUID:)` again, which
  adjudicates against the newly scanned data and re-offers the work where the obstruction was
  transient. Only if attention persists, surface the attention UX over the invalid
  `migrationTransactionStatuses(accountUUID:)` row(s) and then `restartCurrentMigrationStep(accountUUID:)`
  (cancel and re-plan). `reconcileMigrationInvalidations(accountUUID:)` is NOT part of this
  discharge — it records no marks; see its own entry below. Invalid rows are excluded from
  delivery and from the sync gate — a dead transfer is never served and gates nothing.
- `.broadcast(id:)` → `executeNextPendingMigrationTransfer(accountUUID:options:useEstimatedTip:)` —
  submit and end the session (a broadcast session must not sync).
- `.prove(id:kind:)` with a `.transfer(crossing:)` kind → `finalizeReadyMigrationTransfers(accountUUID:)`
  at a sync wake-up (see `migrationSyncWakeups(accountUUID:)`); the broadcast then follows in its own
  LATER session. Proving has no deadline of its own — a missed wake-up defers the proof, never
  invalidates it.
- `.prove(id:kind:)` with a `.preparation(layer:index:)` kind → the preparation is due by
  construction and may be proved (`finalizeReadyMigrationTransfers`) and broadcast at the SAME
  wake-up.
- `.rebuild(id:)` → `refreshStaleMigrationTransfers(accountUUID:usk:)` (needs spend authority — a
  spending key in-process, or the external-signer re-serve ceremony for `usk: nil`).
- `.waiting` → nothing is actionable now: register OS wake-ups at the heights
  `migrationSyncWakeups(accountUUID:)` returns, plus each `migrationTransactionStatuses(accountUUID:)`
  row's `scheduledHeight` for the broadcast windows.

### `executeNextPendingMigrationTransfer` is broadcast-only and returns `MigrationTransferAttempt`

`executeNextPendingMigrationTransfer(accountUUID:options:useEstimatedTip:)` now returns
`MigrationTransferAttempt` instead of an optional `MigrationTransferResult`:

- `.nothingDue` — nothing scheduled yet, dependencies unmined, rows awaiting an external signature,
  or everything already broadcast.
- `.awaitingProof(id:)` — the next-due transaction has not been proved yet; run
  `finalizeReadyMigrationTransfers(accountUUID:)` at a sync wake-up, then retry in a later broadcast
  session.
- `.executed(MigrationTransferResult)` — a broadcast was attempted and its outcome recorded.

The call is now strictly BROADCAST-ONLY: it never proves. Proving moved to the new
`finalizeReadyMigrationTransfers(accountUUID:) async throws -> Int` sweep member, which proves every
migration transaction whose anchor the wallet can resolve right now and returns how many were
proved (`0` is the ordinary "nothing left to prove" answer). Run it at sync wake-ups
(`migrationSyncWakeups(accountUUID:)`) — never in a broadcast session, since proving needs the
wallet's commitment tree and takes real time, while a broadcast session must stay a pure delivery
step.

### Renamed: `rescheduleOverdueMigrationTransfer` → `pendingMigrationTransferProposal`

Purely a rename (same signature, same behavior — a straight delegation to the engine-backed
pending-proposal accessor). Update call sites mechanically.

### Signing-session counts are precomputed by the engine, not derived in Swift

`MigrationRunEstimate.Run.signingSessions(maxTransactionsPerSession:)` and
`MigrationRunEstimate.totalSigningSessions(maxTransactionsPerSession:)` are removed. They computed
`ceil(transactions / maxTransactionsPerSession)`, which UNDERCOUNTS the real signing workload:
external-signer effort is actions, not a transaction count (a preparation transaction weighs 16
Orchard-family actions, a transfer 3), so — for example — 6 preparations plus 1 transfer is 99
actions, one Keystone round over the 96-action budget, needing 2 rounds, while any count-based
ceiling admitting ≥ 7 transactions per session claimed 1.

Replacement: `MigrationRunEstimate.Run` gains `actions: Int` (the signing workload) and
`keystoneSigningSessions: Int` (the number of Keystone signing ROUNDS the upstream engine's own
optimal `MinRounds` packing computes for the run, under the new `MigrationSigningBudget.keystone`
== 96 budget), and `MigrationRunEstimate` gains the cross-run sums `totalActions`/
`totalKeystoneSigningSessions`. Both are read-only, verbatim engine passthrough — there is no
Swift-side computation to call with a different budget; for an actual PCZT batch (any budget, order
preserved) use the new `Synchronizer.batchMigrationPcztsForSigning(_:maxActionsPerSession:)`
instead.

### Model initializer changes

- `MigrationTransactionStatus.init(...)` gains two required parameters: `dependsOn: [UInt32]` (the
  ids of the same run's transactions that must mine before this one can be built or broadcast; empty
  when it depends on nothing) and `anchorBoundaryHeight: BlockHeight?` (the bucketed boundary a
  TRANSFER's anchor was drawn against; always `nil` for a preparation, which anchors near-tip at
  proving time instead of a drawn boundary). A new `Array<MigrationTransactionStatus>.isPreparationPhaseComplete`
  computed property answers `.splitPendingConfirmation`'s replacement above.
- `MigrationUnsignedTransferPczt.init(...)` gains a required `actions: Int` (the signer action
  weight for budget batching — 16 for a preparation, 3 for a transfer; `0` on the signed
  counterparts `applyKeystoneBatchSignatures(pczts:batchSignResponse:)` reconstructs, which carry no
  stored kind to weigh).
- `MigrationSchedule.init(...)` gains a required `preparations: [MigrationPreparationStep]` (the
  note-preparation transactions of the same plan — the transfer rows alone do not surface the
  preparations that mint their funding notes). `Codable` decode is back-compatible: a copy persisted
  before this field existed decodes it as an empty array.
- `MigrationSchedule`'s `encode(to:)` deliberately OMITS `proposalHandle`: the handle identifies a
  process-lifetime native plan cache entry, so no persisted copy could ever identify a live plan —
  every decoded copy (round-tripped or legacy) therefore carries handle `0`, the documented
  "re-propose instead of committing a persisted schedule" contract, by construction.
- `MigrationTransactionStatus.State` gains `.invalid(reason: MigrationInvalidReason)` (with
  `MigrationInvalidReason.fundingSpent` / `.rejectedInvalid` / `.rejectedExpired`) and
  `MigrationTransactionStatus.Blocker` gains `.invalid`: the engine's event-recorded death states
  (a foreign spend of a funding note, or a terminal network rejection). Chain inclusion outranks
  the mark — a row the wallet's scan has observed mined reports `.mined`, never `.invalid`. An
  exhaustive `switch` over either enum stops compiling until the new case is handled.

### New members

`finalizeReadyMigrationTransfers(accountUUID:)`, `reconcileMigrationInvalidations(accountUUID:)`,
`migrationSyncWakeups(accountUUID:)`, `estimatedMigrationChainTip()`,
`estimatedMigrationSecondsPerBlock()`,
`batchMigrationPcztsForSigning(_:maxActionsPerSession:)`, and `hasOverdueMigrationTransfers(accountUUID:useEstimatedTip:)`
(the pre-existing `hasOverdueMigrationTransfers(accountUUID:)` becomes a convenience overload
defaulting `useEstimatedTip` to `false`). The two `estimated*` members take NO account: the
projection reads the wallet-shared blocks table, so — like the batching group — one answer serves
every account (an earlier unreleased iteration carried an unused `accountUUID:`; drop the argument).
See each member's doc comment for its full contract; the estimated-tip and privacy-buffer notes
below cover the cross-cutting parts.

`reconcileMigrationInvalidations(accountUUID:)` needs one note of its own, because its name no
longer describes it. It repairs exactly one thing: a transaction this process submitted to a node,
which mined, but whose broadcast was never recorded (a crash, or a failed persist, between
submitting and recording). It returns whether it repaired a row, records no invalid marks, and is
not part of the `.requiresAttention(id:)` discharge. Everything else it used to do belongs to the
engine now — a funding note spent outside the migration is discovered by the satisfiability oracle
from scanned wallet data, and a recorded broadcast is promoted to mined on every
`migrationAdvanceStep`. Expect the name to change before release.

### `useEstimatedTip` parameters

`executeNextPendingMigrationTransfer(accountUUID:options:useEstimatedTip:)` and
`hasOverdueMigrationTransfers(accountUUID:useEstimatedTip:)` gain a `useEstimatedTip: Bool`
parameter (protocol-extension overloads without it default to `false`, so existing two/one-argument
call sites keep compiling unchanged). `true` opts the due-ness check into the wall-clock chain-tip
estimate `estimatedMigrationChainTip()` projects from the most recently scanned blocks'
header times: the estimate may only ACCELERATE scheduled-height due-ness (the effective tip is
`max(scanned, estimated)`) and expiry is always evaluated against the SCANNED tip, never the
estimate — so a wallet that wakes between syncs can deliver an already-due transfer without first
paying for a sync, and an estimator failure silently degrades to the scanned-tip behavior rather
than blocking or crashing the call.

### The sync gate's predicate: privacy buffer, in-flight marker, READY broadcast

`isMigrationSyncBlocked()`/`migrationSyncBlockedStream` block sync, per account, for exactly three
reasons:

1. **Privacy buffer** — network-scaled after every migration broadcast: 600 s on mainnet
   (unchanged from the previous fixed value), 180 s on testnet/regtest — the full 10 minutes only
   slowed QA cycles down there, where traffic-correlation privacy is moot.
   `Synchronizer.migrationPrivacySyncBufferDuration` still reports the value a real synchronizer
   resolves for its own network; the network-less protocol-extension default keeps forwarding the
   mainnet constant.
2. **In-flight broadcast marker** — a 120 s self-expiring marker blocks sync from just before a
   migration submit hits the network until its outcome is recorded, so the
   unrecorded-broadcast repair (`reconcileMigrationInvalidations`) never treats a just-broadcast
   transfer as a submit crash. The marker is (re-)armed at the last pre-submit
   instant — after the Tor bootstrap — so a slow bootstrap does not burn its window, and a marker
   observed implausibly far in the future (a backwards clock step) is clamped/ignored rather than
   wedging sync.
3. **A READY broadcast is waiting** — a PROVED, schedule-due, unexpired, valid transfer the wallet
   should serve (`executeNextPendingMigrationTransfer`) instead of syncing (ZIP 318's
   broadcast-or-sync session split). This clause is estimate-ACCELERATED: the wall-clock chain-tip
   estimate may only bring due-ness forward (the scanned tip is asked first), never decide expiry.
   It deliberately does NOT gate on `hasOverdueMigrationTransfers(accountUUID:useEstimatedTip:)`:
   that broader query also counts due-but-unproved `Signed` rows, whose proofs are produced AT
   sync wake-ups — gating sync on them would starve the very work that clears them, so a `Signed`
   or awaiting-proof row never blocks sync. `hasOverdueMigrationTransfers` remains available as an
   informational query (re-arm background execution, launch reconciliation); it is no longer
   consulted by any gate path.

## The pool-migration surface rides the final engine

The Orchard→Ironwood migration group (never in a released SDK) is rewired onto the final engine
crates (`zcash_pool_migration_backend` + `zcash_pool_migration_sqlite`). For integrators tracking
the unreleased surface:

- **The external-signer note-split pair went plural.** The engine builds N preparation
  transactions, not one split transaction, so
  `createUnsignedNoteSplitPCZT(accountUUID:) -> Data` is now
  `createUnsignedNoteSplitPCZTs(accountUUID:for:) -> [MigrationUnsignedTransferPczt]` (it also
  creates the run, persisted unsigned -- `schedule`, from `proposeMigrationTransfers`, identifies
  the cached plan to build from by its opaque `proposalHandle` when this call is the one creating
  the run; a stored non-terminal run resumes handle-free), and
  `storeSignedNoteSplitPCZT(accountUUID:_: Data)` is now
  `storeSignedNoteSplitPCZTs(accountUUID:_: [MigrationSignedTransferPczt])` (all-or-nothing; the
  returned `PreparedMigrationTransfer` is a storage receipt with a zeroed `txid` — the
  broadcastable value is served by the delivery lane). One signing ceremony still covers the whole
  migration together with `createUnsignedMigrationTransferPCZTs`.
- **`MigrationState.complete` is PER-RUN.** It means "the stored run is fully mined", never
  "nothing left to migrate": ask `proposeMigrationTransfers` whether anything remains (an empty
  schedule means no), and only then treat the account as done. Sequential runs are first-class — a
  new commit over a completed run starts the next one.
- **`MigrationState.readyToPropose` and `MigrationAttentionReason.syncRequiredBeforeNext` are
  removed** (not merely unreachable): the note split and the schedule commit atomically, so
  neither case ever had a real value to carry. This is source-breaking for an exhaustive `switch`
  over either enum — drop the corresponding `case`.
- **`includeResidual` is removed** from `proposeMigrationTransfers`, `restartCurrentMigrationStep`,
  and `refreshStaleMigrationTransfers`: the engine plans canonically and ZIP 318 keeps the residual
  in Orchard, so the parameter never had a real choice behind it. **`isSyncRequiredBeforeNextMigrationTransfer`
  is removed entirely** for the same reason: the note split and the schedule commit atomically, so
  a sync-required gate before the next transfer never had a use.
- **`refreshStaleMigrationTransfers(accountUUID:usk:)` really rebuilds expired transfers.** It
  rebuilds every EXPIRED transfer of the stored run in place: each rebuilt transfer re-spends the
  SAME funding note (recovered by nullifier identity, never an equal-value substitute) on a fresh
  schedule — a fresh memoryless delay from the current tip, a fresh canonical expiry, and a
  freshly drawn boundary anchor — and returns the run's full `MigrationSchedule` as stored AFTER
  the refresh (the current stored schedule when nothing had expired; empty when no run is stored
  or the run is terminal), persisted ALL-OR-NOTHING: a mid-refresh failure persists NONE of the
  batch's rebuilds, so a successful return's schedule is exactly what was atomically committed,
  never a partial batch. The rebuilt rows' fresh scheduled/expiry heights exist nowhere but in
  that returned schedule — re-display it and use it for every later consent echo; a pre-refresh
  copy fails the verified echo with `migrationPlanStale` from then on. `usk` is now
  `UnifiedSpendingKey?`: pass a spending key to sign each rebuilt transfer anew in-process, or
  `nil` for the external-signer (Keystone) lane, which leaves the rebuilt transfers awaiting their
  signature so the existing `createUnsignedMigrationTransferPCZTs` / `storeSignedMigrationSchedulePCZTs`
  ceremony re-serves and completes them. A `FundingNoteUnavailable`-class failure (the expired
  transfer's exact funding note was spent outside the migration) throws naming
  `restartCurrentMigrationStep` (cancel and re-plan the remaining balance) as the remedy.
- **Two new errors:** `migrationPlanStale` (ZRUST0128 — the schedule/note-split consent echo no
  longer matches what is about to be signed; the echo is VERIFIED, never inert display data.
  Recovery depends on when it fires: BEFORE a run is committed, the mismatch is against the
  previewed plan — propose again and re-display. AFTER a run is committed, the mismatch is
  against the stored run itself, and re-proposing cannot converge (proposals re-randomize and
  never touch the committed run) — instead re-read the current stored schedule, which
  `refreshStaleMigrationTransfers(accountUUID:usk:)` returns and the unsigned-transfer PCZT
  serve path works from, and re-display that) and `migrationProvingUnavailable` (ZRUST0127 —
  proving failed hard).
- **`MigrationTransferProposal.anchorHeight` is a reference height** (the proposal-time tip), not
  a commitment-tree anchor: ZIP 374 defers real anchors to proving time.

## The immediate migration lane leaves the engine

The immediate (single-transaction) Orchard→Ironwood migration is no longer proposed or tracked by
the migration engine's own schedule/commit machinery. It is now an ordinary send-max transfer that
the app executes through the normal transaction pipeline, with one new call to record the outcome:

- **`proposeImmediateMigration(accountUUID:) async throws -> MigrationSchedule` is now
  `proposeImmediateMigration(accountUUID:) async throws -> ImmediateMigrationProposal`.**
  `ImmediateMigrationProposal` carries an ordinary `Proposal` — feed it to
  `createProposedTransactions(proposal:spendingKey:)` (software accounts) or
  `createPCZTFromProposal(accountUUID:proposal:)` (Keystone accounts) exactly like any other
  transfer — plus the decoded `amount` (the net value crossing into Ironwood) and `fee`. There is
  no engine plan cache behind it: nothing about the returned proposal can go stale the way a
  `MigrationSchedule` preview can, and `signAndStoreMigrationSchedule` is not part of this lane (it
  remains for `proposeMigrationTransfers`'s gradual path).
- **New: `recordImmediateMigration(accountUUID:txid:) async throws`.** Call it after a successful
  broadcast (software or Keystone lane) so the platform migration state machine reports the sweep:
  `InProgress(0 of 1)` while unmined, then a quiet `NotStarted` once it mines. A MINED immediate
  sweep is CONSUMED — it is NOT surfaced as `Complete`, so there is nothing for the user to
  acknowledge and no per-run completion screen (the sweep zeroes the spendable Orchard balance, so
  the balance-gated "Migration Required" prompt does not re-offer unless new Orchard funds arrive
  later; an unmined sweep that expires likewise falls back to `NotStarted` so the prompt re-offers
  while funds remain). One row per account — a new record supersedes any previous one. Not
  broadcast-sensitive itself (no `migrationBroadcastDuringSync` guard): the actual broadcast already
  rides the guarded `createProposedTransactions`/`createTransactionFromPCZT` path.
- **`MigrationProgress` gains `isImmediate: Bool`** (additive — the public memberwise initializer
  defaults it to `false`, so existing `MigrationProgress(...)` construction sites keep compiling
  unchanged). It is `true` only while the immediate (send-max) lane's sweep is in progress and
  `false` for engine-tracked schedule runs, letting the app keep the immediate aftermath quiet (no
  per-transfer progress UI).
- **Removed** (internal welding surface, never reachable from outside the SDK):
  `ZcashRustBackendWelding.migrationProposeImmediateTransfers` and its FFI,
  `zcashlc_migration_propose_immediate_transfers`. Replaced by the general-purpose
  `proposeSendMaxTransfer(accountUUID:recipient:memo:orchardOnly:)` (called with `orchardOnly: true`
  and `recipient` set to the account's own address, `memo: nil`) — a plain "spend everything to one
  recipient" primitive the migration engine itself never touches.
- **`MigrationSchedule` itself is unaffected** and still backs `proposeMigrationTransfers` /
  `signAndStoreMigrationSchedule` (the gradual, privacy-path schedule).

## Residual locking and the run-count estimate join the migration group

The `Synchronizer` migration group gains three account-scoped requirements. Like the rest of the
group they come with protocol-extension defaults that throw an "unimplemented" `LocalizedError`, so
a custom `Synchronizer` conformer keeps compiling — but it must override them to offer the real
behavior (`SDKSynchronizer` does):

- **New: `lockMigrationResidual(accountUUID:) async throws -> Zatoshi`.** The "Lock balance" choice
  at migration `Complete`: locks every currently-spendable, not-already-locked legacy-Orchard note
  until explicit unlock and returns the total locked (`Zatoshi(0)` is legitimate — nothing was
  spendable). The lock never expires on its own; locked value leaves `PoolBalance.spendableValue`
  but stays in `PoolBalance.lockedValue` (and therefore in `total()`). Idempotent-additive:
  repeating the call locks (and reports) only notes that became spendable since. A concurrent-lock
  race throws (`rustMigrationLockResidual`, ZRUST0132) and may be retried.
- **New: `unlockMigrationResidual(accountUUID:) async throws -> Int`.** The release half: clears
  ALL of the account's output locks and returns the cleared count (safe — the SDK never creates
  proposal-scoped output locks). "Migrate anyway" over a locked residual composes as this call
  followed by `proposeImmediateMigration(accountUUID:)`; locked notes are excluded from note
  selection, so the unlock must come first.
- **New: `estimateMigrationRuns(accountUUID:) async throws -> MigrationRunEstimate`.** The rounds
  preview for the multi-round migration UI: how many migration RUNS ("rounds") migrating the whole
  spendable Orchard balance takes, per run both what it migrates and what preparing it costs, and
  the final residual that never migrates. External-signer session counts are a query on the result
  (`totalSigningSessions(maxTransactionsPerSession:)`), not a parameter. The zero-run estimate is a
  legitimate answer, not an error.
## `WalletInitMode` removed — `prepare()` derives the init flow

The `WalletInitMode` enum is gone. `prepare(with:walletBirthday:...)` no longer takes a
`for walletMode:` parameter — the SDK derives the flow itself:

- an account already exists in `data.db` → open the existing wallet;
- no account + a (past) birthday → **restore**: `recover_until` is set to the current chain tip, so
  the `[birthday … tip]` backfill is tracked as recovery (`SynchronizerState.isRecovering`);
- no account + `nil` birthday → **new wallet**: starts at a reorg-safe recent height, no recovery phase.

A deliberate re-scan is an explicit action — `rewind(_:)` — not an init mode. Update call sites:

```swift
// OLD:
try await synchronizer.prepare(with: seed, walletBirthday: birthday, for: .restoreWallet, ...)
// NEW:
try await synchronizer.prepare(with: seed, walletBirthday: birthday, ...)
```

## The live per-transaction migration status read joins the migration group

The `Synchronizer` migration group gains one account-scoped requirement. Like the rest of the
group it comes with a protocol-extension default that throws an "unimplemented" `LocalizedError`,
so a custom `Synchronizer` conformer keeps compiling — but it must override it to offer the real
behavior (`SDKSynchronizer` does):

- **New: `migrationTransactionStatuses(accountUUID:) async throws -> [MigrationTransactionStatus]`.**
  The live per-transaction detail view behind `migrationProgress(accountUUID:)`'s aggregate
  summary: every committed migration transaction's kind (preparation layer/index or transfer
  crossing), lifecycle state (`broadcast`/`mined` fold the engine's txid/mined-height payload into
  the matching case, so illegal combinations are unrepresentable — a MINED row's txid is NOT
  carried by the engine's own state model), scheduled/expiry heights, readiness, and next
  action/blocker, keyed by a stable id. A verbatim marshal of the engine's own
  `MigrationState::transaction_statuses`, mined-reconciled at read like every sibling; an empty
  array means no stored run or no transactions, not an error. New error code
  `rustMigrationTransactionStatuses` (ZRUST0135).

## The Keystone batch-signing bridge joins the migration group

The `Synchronizer` migration group gains four DB-free, account-free requirements — no
`accountUUID` parameter, since all four operate purely on caller-held PCZT bytes and a scanned
device response, never the wallet database or the migration engine. Like the rest of the group,
the three throwing members come with a protocol-extension default that throws an "unimplemented"
`LocalizedError`, so a custom `Synchronizer` conformer keeps compiling; the fourth
(`resetKeystoneSignBatchDecoder()`) is non-throwing and gets an inert no-op default instead
(mirroring `isMigrationSyncBlocked()`'s treatment). `SDKSynchronizer` overrides all four with real
behavior, forwarding straight to the rust backend rather than through the per-account migration
actor:

- **New: `buildKeystoneSignBatchQRParts(requestId:pczts:maxFragmentLen:) async throws -> [String]`.**
  Builds the animated multi-part QR frames for a Keystone batch-signing request covering `pczts`
  (preparation PCZTs first, then transfer PCZTs, in schedule order). Every PCZT is redacted for
  the batch-Signer role INSIDE this call before it reaches the wire — callers must NOT pre-redact,
  and must retain their own unredacted `pczts`: those bytes, in the SAME order, are what
  `applyKeystoneBatchSignatures(pczts:batchSignResponse:)` applies the device's signatures onto.
- **New: `resetKeystoneSignBatchDecoder() async`.** Discards any in-flight multi-part scan
  session. Only one decode session exists at a time; call this on scan-screen entry, retry, and
  exit. Non-throwing and infallible.
- **New: `decodeKeystoneSignBatchPart(_:expectedRequestId:) async throws -> KeystoneBatchDecodeResult`.**
  Feeds one scanned QR frame to the active (or freshly started) decode session. Returns the new
  public `KeystoneBatchDecodeResult` model: `complete`/`progress` while more frames are needed;
  once complete, the signatures-only response bytes (no PCZT is echoed by the device) and, when
  the response envelope carried it, the new public `KeystoneFirmwareVersion` — the ONLY way to
  learn the signing device's firmware version in this batch flow, since the "signed" PCZTs are
  reconstructed from caller-held bytes plus signatures, never from device-returned PCZT bytes. A
  request-id mismatch at completion throws (a stale/unrelated scan).
- **New: `applyKeystoneBatchSignatures(pczts:batchSignResponse:) async throws -> [MigrationSignedTransferPczt]`.**
  Applies the ceremony's Keystone batch signatures to `pczts`, positionally — `pczts` MUST be the
  SAME array, in the SAME order (including the SAME unredacted bytes), passed to
  `buildKeystoneSignBatchQRParts(requestId:pczts:maxFragmentLen:)`. Returns one signed PCZT per
  element, ready for the existing `storeSignedNoteSplitPCZTs(accountUUID:_:)` /
  `storeSignedMigrationSchedulePCZTs(accountUUID:_:)` calls.

New error codes `rustMigrationKeystoneBuildSignBatchQrParts` (ZRUST0136),
`rustMigrationKeystoneDecodeSignBatchPart` (ZRUST0137), and
`rustMigrationKeystoneApplyBatchSignatures` (ZRUST0138). Like the rest of the migration group, the
Closure/Combine wrapper synchronizers do not mirror these four members.

## The debug fast-reschedule joins the migration group

The `Synchronizer` migration group gains one account-scoped, DEBUG/QA-only requirement. Like the
rest of the group it comes with a protocol-extension default that throws an "unimplemented"
`LocalizedError`, so a custom `Synchronizer` conformer keeps compiling — but it must override it to
offer the real behavior (`SDKSynchronizer` does):

- **New: `debugRescheduleMigrationTransfers(accountUUID:) async throws -> Int`.** DEBUG/QA ONLY:
  rewrites the committed migration schedule's transfer heights (first due in ~2 blocks, then
  4-block strides) and the earliest transfer's anchor boundary so real broadcast delivery can be
  exercised without waiting out ZIP 318's privacy delay — not for production flows. Returns the
  number of transfers rescheduled (`0` when the account has no stored migration);
  already-broadcast/mined transfers and preparations are left untouched. New error code
  `rustMigrationDebugRescheduleTransfers` (ZRUST0139).
## Custom (regtest-style) networks and `NetworkType.regtest`

`NetworkType` gained a third case, `regtest`. **This is a source-breaking change for exhaustive
`switch` statements over `NetworkType`** — add a `.regtest` arm (or a `default`) when updating.

Custom networks let the SDK talk to a custom-parameter chain (for example a modified-mainnet
Ironwood testing backend) whose network upgrades activate at arbitrary heights:

- `ZcashNetworkBuilder.regtest(activationHeights:)` builds a regtest-identity network with the given
  `NetworkActivationHeights` (a `nil` height means "not activated"; the heights are not validated —
  mirror the `nuparams` of the node/`lightwalletd` you connect to).
- `ZcashNetworkBuilder.custom(base:activationHeights:)` combines a chosen base identity (address
  encoding + expected `chainName`, e.g. `.mainnet` for a modified-mainnet backend) with custom
  heights. On-disk databases still use the `regtest`-slot name prefix, so a custom network never
  collides with a real mainnet/testnet wallet in the same container.
- Server validation relaxes for custom networks: `ValidateServerAction` and
  `evaluateBestOf(endpoints:...)` skip the chain-name and consensus-branch-ID checks (the server of a
  modified chain may identify with its base chain's name and a nonstandard branch id). The
  Sapling-activation-height check still applies.

**Process-global registration and ordering.** The custom network's parameters are registered with
the Rust core **once per process** (the first `Initializer` created with a custom network does this).
Anything that resolves the custom network id before that registration — e.g. a
`DerivationTool(networkType: .regtest)` created before any `Initializer` — fails with
"custom network (id 2) used before it was configured", and key validators return `false`. Create the
`Initializer` first, or call `ZcashRustBackend.setCustomNetwork` yourself at startup. Registering a
**different** custom network later in the same process is a configuration bug: the newest values win
process-globally while earlier instances keep their own per-instance state (checkpoint sources,
constants), so the two desynchronize — the registration call reports this (and asserts in debug).

# Migrating from previous versions to v2.8.0-rc.1

## `prepare` now validates the seed against the existing wallet

If the wallet database already contains seed-derived account(s) and the seed passed to `prepare`
does not match them, `prepare` throws `ZcashError.initializerSeedMismatch` (`ZINIT0006`) instead of
silently opening the old wallet (which desynced the app's stored seed from the on-disk account).
Restoring a different wallet requires `wipe()` first. Wallets whose only accounts are imported
(hardware-wallet UFVKs) are exempt — there is no seed-derived account to compare.

## PendingDb is no longer used

PendingDb is no longer used. Wallet developers should take care about deleting
the database file since the SDK will no longer require it or any of the
information stored.

Failed transactions will be treated as "Expired-Unmined" instead. The SDK won't
track failures on its own. Wallet developers would have to account for those.

## The shielded voting API is removed

The shielded voting API is removed: `VotingRustBackend`, the `Voting*` types,
`PirSnapshotResolver`/`PirSnapshotProbing`/`HTTPPirSnapshotProbe`, and the
`zcashlc_voting_*` FFI symbols are gone. `zcash_voting` cannot resolve against the
Ironwood `orchard` release, so voting is not shipped on this line (matching the
Android SDK). Wallet developers using any of these types must remove those calls.

## `AccountBalance` gained an Ironwood pool

`AccountBalance` gains a public `ironwoodBalance` pool for the Ironwood (NU6.3) shielded protocol,
alongside `saplingBalance` and `orchardBalance`. Reading code keeps compiling, but any place that
enumerates the shielded pools by hand — totalling them, rendering a per-pool breakdown, deciding
whether a balance is fully shielded — needs to account for the third pool or it will silently
under-report once NU6.3 activates. The value stays zero until then.

`AccountBalance` and `PoolBalance` have no public initializer, so this cannot break construction in
your code; balances are only ever produced by the SDK.

## `Broadcaster` redesign (multi-server submission)

The `Broadcaster` API introduced in the 2.6.0-alpha tags has changed:

- Create APIs return `[CreatedTransaction]` (fields: `txId`, `raw` — non-optional, `expiryHeight`) instead of `[ZcashTransaction.Overview]`. The `.foundTransactions` event still emits overviews. A transaction created in a previous app session can be rebuilt for submission with `CreatedTransaction(overview:)`.
- `submit(_ rawTransaction: Data, to: LightWalletEndpoint)` is gone. Use:

```swift
let outcome = await synchronizer.broadcaster.submit(
    transaction: createdTransaction,
    to: endpoints           // [LightWalletEndpoint]; timing: defaults to SubmissionTiming.default
)
```

`submit` no longer throws — it returns a `TransactionSubmissionOutcome` (`accepted(by:)`, `rejected(code:message:)`, `unreachable`, `timedOut`, `notAttempted`, `cancelled`). Treat `timedOut` as pending: the transaction may still have been broadcast.

- Retry semantics: the endpoint list passed to `submit` is persisted as the transaction's retry plan. The SDK's background resubmission retries pending transactions through those endpoints (sequentially) instead of the synchronizer's default endpoint, and never auto-submits transactions created through `Broadcaster` that the app hasn't submitted yet. If the plan store cannot be read, background resubmission skips the affected transactions rather than falling back to the default endpoint. Transactions the store has no plan for at all — anything sent through `Synchronizer` rather than `Broadcaster`, including everything created before this release — keep the previous behaviour and are retried against the synchronizer's endpoint. Plans are kept until the transaction expires (so a chain reorg cannot detach a transaction from its recorded endpoints), and `Synchronizer.wipe()` deletes the plan database file.
- The retry plan is recorded before any network attempt and stays recorded when `submit` returns `.cancelled` or `.timedOut`: background resubmission may still broadcast the transaction later. Treat those outcomes as "outcome unknown", not as "not sent".
- `LightWalletEndpoint` now conforms to `Equatable`. If your app declared that conformance retroactively, remove your declaration.

## `Initializer.InitializationResult` gained `.seedNotRelevant`

`Initializer.InitializationResult` (returned by `Initializer.initialize` and `Synchronizer.prepare`) gained a new case, `.seedNotRelevant`, returned when the rust layer reports that the provided seed does not match the accounts already present in the wallet database. Any exhaustive `switch` over `InitializationResult` must add a case for it. `prepare`/`initialize` can now return `.seedNotRelevant` in situations where they previously returned `.success` over a mismatched database — handle it the same way you already handle `.seedRequired`.

## Unmined transactions past their expiry are reported as `.expired`

`ZcashTransaction.Overview.getState(for:)` now returns `.expired` for an unmined transaction whose
expiry height is non-zero and at or below the height you pass in, even when the wallet database's
`expired_unmined` flag has not been set. These transactions previously stayed `.pending`
indefinitely — most visibly sends that were unmined when the wallet migrated across a
consensus-rule change. Transactions with no expiry height (`0`) are unaffected and still report
`.pending` while unmined.

This is a behavioural change with no compile-time signal. Apps that key UI, retry, or bookkeeping off
`.pending` will now see those transactions move to `.expired`, which is the state they should already
have been in. Verify that your `.expired` handling is reachable and does something sensible; a
transaction can now arrive there without the database flag ever flipping.

## Already-accepted transactions no longer report a submit failure

`Synchronizer.createProposedTransactions` and `Synchronizer.createTransactionFromPCZT` emit
`TransactionSubmitResult.success` instead of `.submitFailure` when the submit RPC rejects a
transaction the server turns out to already hold. On a non-zero error code the SDK asks the same
lightwalletd whether the txid is in mempool or chain, and trusts that answer over the rejection.

Apps that surfaced every `.submitFailure` as a failed send will show fewer of them. If you matched on
specific error codes or message text to recognise "already in mempool" / "already in chain" yourself
(Zebra's `MempoolError::InMempool` and `AlreadyQueued`, zcashd's `RPC_VERIFY_ALREADY_IN_CHAIN`),
remove that special-casing — the SDK now resolves those cases before you see them.

## New wallets get a server-derived birthday

For `WalletInitMode.newWallet`, the birthday is taken from a lightwalletd tree state one reorg
horizon below the chain tip rather than from the bundled checkpoint, so first launch scans far less
history. `Initializer.walletBirthday` therefore reflects the server's tree state height, not a
checkpoint height, and the two will not agree. Apps that persist, display, or assert on the birthday
should read it back from the initializer after `prepare` instead of assuming a bundled checkpoint
value. If the server is unreachable the bundled checkpoint is still used.

# Migrating from previous versions to 0.20.0-beta
The `SDKSynchronizer` no longer uses `NotificationCenter` to send notifications.
Notifications are replaced with `Combine` publishers.

`stateStream` publisher replaces notifications related to `SyncStatus` changes.
These notifications are replaced by `stateStream`:
- .synchronizerStarted
- .synchronizerProgressUpdated
- .synchronizerStatusWillUpdate
- .synchronizerSynced
- .synchronizerStopped
- .synchronizerDisconnected
- .synchronizerSyncing
- .synchronizerEnhancing
- .synchronizerFetching
- .synchronizerFailed

`eventStream` publisher replaces notifications related to transactions and other stuff.
These notifications are replaced by `eventStream`:
- .synchronizerMinedTransaction
- .synchronizerFoundTransactions
- .synchronizerStoredUTXOs
- .synchronizerConnectionStateChanged

`latestState` is also new property that can be used to get the latest SDK state in a synchronous way.
`SDKSynchronizer.status` is no longer public. To get `SyncStatus` either subscribe to `stateStream` 
or use `latestState`. 

# Migrating from previous versions to 0.18.x
Compact block cache no longer uses a sqlite database. The existing database
should be deleted. `Initializer` now takes an `fsBlockDbRootURL` which is a 
URL pointing to a RW directory in the filesystem that will be used to store
the cached blocks and the companion database managed internally by the SDK.

`Initializer` provides a convenience initializer that takes the an optional
URL to the `cacheDb` location to migrate the internal state of the 
`CompactBlockProcessor` and delete that database. 

````Swift
    convenience public init(
        cacheDbURL: URL?,
        fsBlockDbRoot: URL,
        dataDbURL: URL,
        pendingDbURL: URL,
        endpoint: LightWalletEndpoint,
        network: ZcashNetwork,
        spendParamsURL: URL,
        outputParamsURL: URL,
        viewingKeys: [UnifiedFullViewingKey],
        walletBirthday: BlockHeight,
        alias: String = "",
        loggerProxy: Logger? = nil
    )
````

We do not make any efforts to extract the cached blocks in the sqlite
`cacheDb` and storing them on disk. Although this might be the logical 
step to do, we think such migration as little to gain since a migration
function will be a "run once" function with many different scenarios to
consider and possibly very error prone. On the other hand, we rather delete
the `cacheDb` altogether and free up that space on the users' devices since
we have surveyed that the `cacheDb` as been growing exponentially taking up
many gigabyte of disk space. We forsee that many possible attempts to copy
information from one cache to another, would possibly fail 

Consuming block cache information for other purposes is discouraged. Users
must not make assumptions on its contents or rely on its contents in any way. 
Maintainers assume that this state is internal and won't consider further
uses other than the intended for the current development. If you consider
your application needs any other information than the ones available through
public APIs, please file the corresponding feature request.

# Migrating from 0.16.x-beta to 0.17.0-alpha.x

## Changes to Demo APP
The demo application now uses the SDKSynchronizer to create addresses and
shield funds.
`DerivationToolViewController` was removed. See `DerivationTool` unit tests
for sample code.
`GetAddressViewController` now derives transparent and sapling addresses
from Unified Address
`SendViewController` uses Unified Spending Key and type-safe `Memo`

## Changes To SDK
### `CompactBlockProcessor`
`public func getUnifiedAddress(accountIndex: Int) -> UnifiedAddress?`
`public func getSaplingAddress(accountIndex: Int) -> SaplingAddress?` derived from UA
`public func getTransparentAddress(accountIndex: Int) -> TransparentAddress?`
is derived from UA
`public func getTransparentBalance(accountIndex: Int) throws -> WalletBalance` now
fetches from account exclusively
`func refreshUTXOs(tAddress: TransparentAddress, startHeight: BlockHeight) async throws -> RefreshedUTXOs`
uses `TransparentAddress`

### Initializer
Migration of DataDB and CacheDB are delegated to `librustzcash`

removed `public func getAddress(index account: Int = 0) -> String`


### Wallet Types
`UnifiedSpendingKey` to represent Unified Spending Keys. This is a binary
encoded not meant to be stored or backed up. This only serves the purpose
of letting clients use the least privilege keys at all times for every
operation.

### Synchronizer
`sendToAddress` and `shieldFunds` now take a `UnifiedSpendingKey` instead
of the respective spending and transparent private keys.
`refreshUTXOs` uses `TransparentAddress`

### KeyDeriving protocol
Addresses should be obtained from the `Synchronizer` by using the `get_address` functions
Transparent and Sapling receivers should be obtained by extracting the receivers of a UA
````Swift
public extension UnifiedAddress {
    /// Extracts the sapling receiver from this UA if available
    /// - Returns: an `Optional<SaplingAddress>`
    func saplingReceiver() -> SaplingAddress? {
        try? DerivationTool.saplingReceiver(from: self)
    }

    /// Extracts the transparent receiver from this UA if available
    /// - Returns: an `Optional<TransparentAddress>`
    func transparentReceiver() -> TransparentAddress? {
        try? DerivationTool.transparentReceiver(from: self)
    }
````

**Removed**
`func deriveUnifiedFullViewingKeys(seed: [UInt8], numberOfAccounts: Int) throws -> [UnifiedFullViewingKey]`
`func deriveViewingKey(spendingKey: SaplingExtendedSpendingKey) throws -> SaplingExtendedFullViewingKey`
`func deriveSpendingKeys(seed: [UInt8], numberOfAccounts: Int) throws -> [SaplingExtendedSpendingKey]`
`func deriveUnifiedAddress(from ufvk: UnifiedFullViewingKey) throws -> UnifiedAddress`
`func deriveTransparentAddress(seed: [UInt8], account: Int, index: Int) throws -> TransparentAddress`
`func deriveTransparentAccountPrivateKey(seed: [UInt8], account: Int) throws -> TransparentAccountPrivKey`
`func deriveTransparentAddressFromAccountPrivateKey(_ xprv: TransparentAccountPrivKey, index: Int) throws -> TransparentAddress`

**Added**
`static func saplingReceiver(from unifiedAddress: UnifiedAddress) throws -> SaplingAddress?`
`static func transparentReceiver(from unifiedAddress: UnifiedAddress) throws -> TransparentAddress?`
`static func receiverTypecodesFromUnifiedAddress(_ address: UnifiedAddress) throws -> [UnifiedAddress.ReceiverTypecodes]`
`func deriveUnifiedSpendingKey(seed: [UInt8], accountIndex: Int) throws -> UnifiedSpendingKey`
`public func deriveUnifiedFullViewingKey(from spendingKey: UnifiedSpendingKey) throws -> UnifiedFullViewingKey`

## Notes on Structured Concurrency

`CompactBlockProcessor` is now an Swift Actor. This makes it more robust and have its own
async environment.

SDK Clients will likely be affected by some `async` methods on `SDKSynchronizer`.

We recommend clients that don't support structured concurrency features, to work around this by  surrounding the these function calls either in @MainActor contexts either by marking callers as @MainActor or launching tasks on that actor with `Task { @MainActor in ... }`
