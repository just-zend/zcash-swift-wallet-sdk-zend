# Migrating from previous versions to _Unreleased_

## The pool-migration surface rides the canonical engine

The Orchard→Ironwood migration group (never in a released SDK) now uses
`zcash_pool_migration` plus `zcash_client_sqlite::pool_migration` as its planner, persistence, and
lifecycle schema. The public Swift surface composes those upstream models with opaque Rust-owned
delivery capabilities; it does not expose the older transaction-by-transaction FFI ceremony.

- **`MigrationState.complete` is per run.** It means the stored run is fully mined, never that the
  account has nothing left to migrate. Call `proposeMigrationTransfers(accountUUID:)` again; an
  empty schedule means no balance remains. Passing a later approved schedule to
  `signAndStoreMigrationSchedule` or `commitMigrationScheduleForExternalSigning` atomically rolls a
  terminal run into its successor while retaining predecessor evidence and reservations.
- **SDK-held keys use high-level operations.** Confirm a gradual schedule with
  `signAndStoreMigrationSchedule`, then call
  `executeNextPendingMigrationTransfer(accountUUID:options:)` when due. Rust selects the exact
  canonical transaction, proves it, owns its submission claim, and records a typed outcome.
- **External signers use opaque request objects.** First call
  `commitMigrationScheduleForExternalSigning(accountUUID:_:options:)`. For each transaction, call
  `prepareNextMigrationTransactionForExternalSigning(accountUUID:)`, give the request's PCZT to the
  signer, and return that same request plus the signer response to
  `submitExternallySignedMigrationTransaction`. A relaunch resumes or reacquires the exact exposed
  artifact; callers never reconstruct a claim or choose a replacement transaction.
  These APIs represent one request at a time. A future batch-signing transport must use
  `redact_pczt_for_batch_signer`, retain every original PCZT, include the required derivation
  annotation, and correlate ordered signer responses with their originating requests; ordinary
  `redact_pczt_for_signer` is not a batch protocol.
- **Recovery is explicit and claim-backed.** Use `pauseMigrationDelivery`,
  `resumeMigrationDelivery`, `beginMigrationAbandonment`, and `finishMigrationAbandonment` for
  delivery control. Rebuild one positively expired attempt with
  `rebuildExpiredMigrationTransfer` (SDK signer) or
  `rebuildExpiredMigrationTransferForExternalSigning` (external signer). The former batch refresh,
  cancel-and-replan restart, raw unsigned/signed PCZT arrays, and caller-recorded result APIs are
  retired and are not compatibility entry points.
- **Removed enum cases and parameters stay removed.** `MigrationState.readyToPropose`,
  `MigrationAttentionReason.syncRequiredBeforeNext`, `includeResidual`, and
  `isSyncRequiredBeforeNextMigrationTransfer` do not exist in the consolidated API.
- **A preview carries process-local authority, not caller-field authority.** Rust assigns every
  note-split proposal and migration schedule a nonzero opaque `proposalHandle`. Fresh commit and
  terminal successor rollover pass only that handle back; a second preview supersedes the first,
  and a missing or stale handle throws `migrationPlanStale` (ZRUST0128). The handle is deliberately
  omitted from `MigrationSchedule` encoding and always resets to the zero sentinel on decode, so a
  persisted or restored schedule is display-only and must be re-proposed before commit. Resuming an
  existing nonterminal run uses its durable Rust run/claim capability instead. Hard proving failures
  surface as `migrationProvingUnavailable` (ZRUST0127).
- **`MigrationTransferProposal.anchorHeight` is a reference height** (the proposal-time tip), not
  a commitment-tree anchor: ZIP 374 defers real anchors to proving time.

## Immediate migration now consumes an opaque Rust delivery claim

The intermediate ordinary-send design has been retired. Immediate Orchard→Ironwood migration is
reserved, materialized, submitted, and recorded by the Rust-owned delivery runtime. Hosts can no
longer hold an ordinary proposal or tell the SDK which transaction id was broadcast:

- **Removed:** `proposeImmediateMigration(accountUUID:) -> ImmediateMigrationProposal` and
  `recordImmediateMigration(accountUUID:txid:)`. Do not execute immediate migration through
  `createProposedTransactions` / `createPCZTFromProposal`, and do not persist or replay a txid as
  migration authority.
- **SDK signer:** call
  `submitImmediateMigration(accountUUID:usk:maximumGrossAmount:options:) -> MigrationSubmissionOutcome`.
  `maximumGrossAmount` is the user's explicit ceiling for the sum of the selected Orchard inputs.
  Rust atomically selects the sources, derives their exact gross value from the canonical proposal,
  rejects an over-limit proposal before writing any run, reservation, lock, or claim, seals the
  destination, target height, expiry, consensus branch, and submission policy, builds and stores
  the exact transaction, then grants a one-shot submission claim. Swift submits only the exact
  bytes copied from that claim.
- **Pre-cap runtime rows:** delivery schema v2 records the exact approved ceiling beside every new
  immediate run. A v1 pre-exposure row has no durable evidence for a numeric spend authorization
  and is exposed as `MigrationRuntimeUnavailableReason.missingSpendAuthorization`. Treat it as
  recovery-only: do not substitute the wallet balance, total supply, or a legacy consent flag, and
  do not materialize, sign, or submit it automatically. An exact unexposed known-unsent failure may
  be reauthorized only with a newly supplied sufficient ceiling; already exposed rows continue
  outcome/finality reconciliation without gaining new submission authority. Read
  `MigrationRuntimeSnapshot.immediateMigrationRecoveryCapability` from the snapshot that rendered
  the recovery action and return that opaque value to `recoverFailedImmediateMigration` (SDK
  signer) or `recoverFailedImmediateMigrationForExternalSigning` (external signer). The capability
  seals the account, immediate artifact, signer, and hidden delivery revision plus the Rust claim
  handle. A later fresh read is only a state gate: it cannot replace the rendered capability with
  authority for a same-account, same-signer replacement run. Generic submit/prepare entry points
  reject `materializationFailed` state and never perform this recovery.
- **External signer:** call
  `prepareImmediateMigrationForExternalSigning(accountUUID:maximumGrossAmount:options:)` and give
  the returned request's `pczt` to the signer. Return that same opaque request plus the signer's
  response to `submitExternallySignedImmediateMigration(accountUUID:request:signedPCZT:)`. Rust
  validates the merge against the staged PCZT and finalizes the exact transaction atomically; the
  request's claim cannot be constructed or altered by the host. If materialization fails before
  exposure, call the external recovery-only API with the capability captured from the rendered
  failure and a sufficient current ceiling. Account, signer, policy, and matching display fields
  alone are not recovery authority. The SDK first requires the fresh runtime's hidden capability
  seal to match, then Rust CAS-validates and consumes the caller-bound claim handle to mint only a
  fresh bounded token for that exact proposal; it never replans or falls through to reservation. If the
  app relaunches after PCZT exposure, call `prepareImmediateMigrationForExternalSigning` again with
  the same options: the SDK recovers the exact staged PCZT rather than reserving a replacement
  artifact. After the signer response has been merged and Rust reports an exact `staged`
  transaction, retry with `resumeStagedImmediateExternalSubmission(accountUUID:)`; do not ask the
  signer again or replay the old process-local request. The scheduled lane uses
  `resumeStagedScheduledExternalSubmission(accountUUID:transactionID:)` under the same rule. These
  APIs accept no PCZT or transaction bytes and resume only Rust's current exact staged claim. A
  later lower ceiling cannot revoke or rewrite an already-authorized live, exposed, or submitted
  artifact; those states must be reconciled. Different transport or endpoint options fail closed
  against the persisted Rust policy.
- Every returned submission outcome (`accepted`, `knownUnsent`, or `unknown`) means the submit RPC
  began, so the 10-minute anti-correlation sync buffer is active before the outcome is recorded.
  A thrown pre-submit failure broadcasts nothing and releases only Rust-validated known-unsent
  authority. Stop synchronization before either submitting method; `SDKSynchronizer` enforces the
  existing `migrationBroadcastDuringSync` guard.
- `MigrationSchedule` remains the preview/consent model for gradual migration only.

### Retired Zend state-machine API mapping

The former Zend-only snapshot/intent API represented a second migration state machine and is not
preserved as a compatibility facade. Its replacement keeps planner and transaction state in the
upstream schema and keeps delivery authority in opaque Rust capabilities:

| Retired call/model | Replacement |
| --- | --- |
| `migrationSnapshot(for:) -> MigrationSnapshot` | `migrationRuntimeSnapshot(accountUUID:) -> MigrationRuntimeSnapshot`. Read this atomically before and after work; do not reconstruct run ids, revisions, claims, or policy fingerprints in the app. |
| `previewImmediateMigration(for:)` | No immediate read-only proposal. Immediate source selection and economics are reserved atomically at confirmation. Use `proposeMigrationTransfers(accountUUID:)` only for the gradual schedule preview. |
| `proposeImmediateMigrationIntent` + `commitMigrationIntents` | SDK signer: `submitImmediateMigration` with an explicit maximum gross amount. External signer: `prepareImmediateMigrationForExternalSigning` with the same explicit ceiling, followed by `submitExternallySignedImmediateMigration`. |
| Scheduled `commitMigrationIntents` | SDK signer: `signAndStoreMigrationSchedule`. External signer: `commitMigrationScheduleForExternalSigning`, then one opaque `prepareNextMigrationTransactionForExternalSigning` / `submitExternallySignedMigrationTransaction` round trip per canonical transaction. The delivery policy is bound before any PCZT is exposed. |
| `executeNextMigrationAction(expectedRunId:expectedRevision:...)` | `executeNextPendingMigrationTransfer(accountUUID:options:)`. Rust chooses readiness, consumes the opaque materialization/submission claim, and keeps ambiguous outcomes resolution-only. Refresh `migrationRuntimeSnapshot` afterward. |
| App-authored `runId`, numeric revision, txid, expiry, or branch | No replacement input. These values stay sealed in Rust run/claim handles; public fields are status projections only. |

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
  only outputs owned by the account's deterministic residual-lock owner and returns the cleared
  count. Migration-source, ordinary-PCZT, and foreign-owner locks remain intact. "Migrate anyway"
  over a locked residual composes as this call followed by
  `submitImmediateMigration(accountUUID:usk:maximumGrossAmount:options:)`; locked notes are excluded from note
  selection, so the unlock must come first.
- **New: `estimateMigrationRuns(accountUUID:) async throws -> MigrationRunEstimate`.** The rounds
  preview for the multi-round migration UI: how many migration RUNS ("rounds") migrating the whole
  spendable Orchard balance takes, per run both what it migrates and what preparing it costs, and
  the final residual that never migrates. External-signer session counts are a query on the result
  (`totalSigningSessions(maxTransactionsPerSession:)`), not a parameter. The zero-run estimate is a
  legitimate answer, not an error.

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
  action/blocker, keyed by a stable id. The public migration actor first reconciles a scheduled run
  through the Rust-owned opaque run capability, then returns a side-effect-free verbatim marshal of
  the engine's own `MigrationState::transaction_statuses`; an empty array means no stored run or no
  transactions, not an error. New error code
  `rustMigrationTransactionStatuses` (ZRUST0135).

## The Keystone batch-signing bridge joins the migration group

The SDK adopts upstream's four DB-free, account-free requirements exactly — no `accountUUID`
parameter, since those compatibility calls operate purely on caller-held PCZT bytes and a scanned
device response. These byte-oriented values are not migration authority. Like the rest of the
group, the three throwing members come with a protocol-extension default that throws an
"unimplemented" `LocalizedError`, so a custom `Synchronizer` conformer keeps compiling; the fourth
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
  element. This is the exact upstream compatibility codec; it does not grant delivery authority.

Zend adds the claim-owned scheduled adapter on top. For production migration delivery, call
`prepareNextMigrationTransactionForExternalSigning(accountUUID:)`, then
`buildKeystoneSignBatchQRParts(accountUUID:requestId:request:maxFragmentLen:)`. Rust accepts only
the request's private live claim, reloads the canonical PCZT from the delivery store, derives the
account's ZIP 32 metadata, and annotates only the transient QR copy. After decoding the matching
response, `applyKeystoneBatchSignatures(request:batchSignResponse:)` applies it to the exact PCZT
retained by that same request and returns one signed `Data` value. Submit that value with the
unchanged request through
`submitExternallySignedMigrationTransaction(accountUUID:request:signedPCZT:)`; the existing opaque
claim checks remain authoritative. The retired raw note-split/schedule storage APIs are not
restored.

New error codes `rustMigrationKeystoneBuildSignBatchQrParts` (ZRUST0136),
`rustMigrationKeystoneDecodeSignBatchPart` (ZRUST0137), and
`rustMigrationKeystoneApplyBatchSignatures` (ZRUST0138). Like the rest of the migration group, the
Closure/Combine wrapper synchronizers do not mirror these members. Zend's existing
`rustMigrationDelivery` moved from the colliding prerelease code ZRUST0136 to ZRUST0139.

## `prepare` now validates the seed against the existing wallet

If the wallet database already contains seed-derived account(s) and the seed passed to `prepare`
does not match them, `prepare` throws `ZcashError.initializerSeedMismatch` (`ZINIT0006`) instead of
silently opening the old wallet (which desynced the app's stored seed from the on-disk account).
Restoring a different wallet requires `wipe()` first. Wallets whose only accounts are imported
(hardware-wallet UFVKs) are exempt — there is no seed-derived account to compare.

PendingDb is no longer used. Wallet developers should take care about deleting
the database file since the SDK will no longer require it or any of the
information stored. 

Failed transactions will be treated as "Expired-Unmined" instead. The SDK won't 
track failures on its own. Wallet developers would have to account for those.

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
**different** custom network later in the same process is a configuration bug: Rust preserves the
first process-global configuration and reports the conflict instead of changing the consensus rules
under a live wallet. `Initializer` and the standalone migration runtime terminate on this error in
both debug and release builds because they cannot safely continue with the rejected configuration.

## Voting: submission contract and pre-1.0 database reset

The voting stack now rides upstream `zcash_voting` 1.0 (see the CHANGELOG for the full surface).
Two changes affect callers of the voting API directly:

- **`storeVoteTxHash` is what records submission.** Persisting the on-chain transaction hash now
  marks the vote submitted (submission state is derived from the stored hash and written atomically).
  Call `storeVoteTxHash` once the vote transaction is broadcast. `markVoteSubmitted` no longer stands
  alone — it re-applies that state idempotently (rejecting a conflicting hash) and throws if no hash
  has been stored yet. Any flow that previously called `markVoteSubmitted` as the submission mark must
  call `storeVoteTxHash` first.
- **Alpha-era voting databases are reset on open.** The voting database schema was rebuilt for 1.0;
  opening a voting database created by a 2.6.0-alpha build drops and recreates every voting table
  (rounds, votes, bundles, proofs, witnesses, share delegations, …). In-progress votes from an alpha
  build do not survive the upgrade and must be re-cast. This is the separate voting database only —
  wallet balances and the main wallet database are unaffected.

The voting hotkey contract also changed: `generateHotkey` takes `storedSecret:` (an app-owned
opaque secret) instead of `seed:`. Passing an empty array mints a fresh random hotkey; passing a
previously stored 64-byte secret deterministically reconstructs the same hotkey. Persisting that
secret is the only way to recover the same hotkey — the pre-1.0 seed-derived derivation is not
reproducible under 1.0.

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

- Retry semantics: the endpoint list passed to `submit` is persisted as the transaction's retry plan. The SDK's background resubmission retries pending transactions through those endpoints (sequentially) instead of the synchronizer's default endpoint, and never auto-submits transactions created through `Broadcaster` that the app hasn't submitted yet. If the plan store cannot be read, background resubmission skips the affected transactions rather than falling back to the default endpoint. Plans are kept until the transaction expires (so a chain reorg cannot detach a transaction from its recorded endpoints), and `Synchronizer.wipe()` deletes the plan database file.
- The retry plan is recorded before any network attempt and stays recorded when `submit` returns `.cancelled` or `.timedOut`: background resubmission may still broadcast the transaction later. Treat those outcomes as "outcome unknown", not as "not sent".
- `LightWalletEndpoint` now conforms to `Equatable`. If your app declared that conformance retroactively, remove your declaration.

## `Initializer.InitializationResult` gained `.seedNotRelevant`

`Initializer.InitializationResult` (returned by `Initializer.initialize` and `Synchronizer.prepare`) gained a new case, `.seedNotRelevant`, returned when the rust layer reports that the provided seed does not match the accounts already present in the wallet database. Any exhaustive `switch` over `InitializationResult` must add a case for it. `prepare`/`initialize` can now return `.seedNotRelevant` in situations where they previously returned `.success` over a mismatched database — handle it the same way you already handle `.seedRequired`.

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
