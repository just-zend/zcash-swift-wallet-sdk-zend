# Migrating from previous versions to _Unreleased_
PendingDb is no longer used. Wallet developers should take care about deleting
the database file since the SDK will no longer require it or any of the
information stored. 

Failed transactions will be treated as "Expired-Unmined" instead. The SDK won't 
track failures on its own. Wallet developers would have to account for those.

## Configurable activation heights (regtest / custom networks)

New, **additive** capability for pointing the SDK at a custom-parameter (regtest) `lightwalletd` — e.g. an Ironwood testing backend — whose network upgrades activate at arbitrary heights instead of the hardcoded mainnet/testnet values. Existing code is unaffected; you opt in by building a regtest `ZcashNetwork`:

```swift
let network = ZcashNetworkBuilder.regtest(activationHeights: NetworkActivationHeights(
    sapling: 1,
    nu5: 100,
    nu6: 200,
    nu6_3: 5000   // Ironwood
))
let initializer = Initializer(/* … */, network: network)
```

- Set the heights to mirror the `nuparams` of the node / `lightwalletd` you connect to. `nil` means "not activated".
- A regtest network reports its type as **Regtest**: addresses are regtest-encoded and its databases use a `ZcashSdk_regtest_` name prefix (no collision with mainnet/testnet data). The SDK expects the server to report `chainName == "regtest"`.
- Regtest ships no bundled checkpoints; a fresh wallet scans from the Sapling activation height (empty tree). For a higher birthday, seed a tree state via `Synchronizer.getTreeState(height:)`.
- Running the Orchard→Ironwood **migration** on regtest is not yet supported. See `docs/handoffs/ZODL-regtest-activation-heights.md`.

## Ironwood (NU6.3) balance on `AccountBalance`

`AccountBalance` gains a public `ironwoodBalance: PoolBalance` field (Ironwood is Orchard note-version V3, received at the account's existing Orchard receiver — there is no separate Ironwood address). The field is **additive** and is `.zero` for every wallet until NU6.3 activates and a lightwalletd serves Ironwood compact blocks. No action is required now; an app that wants to surface Ironwood can read/total it alongside `orchardBalance`. (If you construct `AccountBalance` yourself, e.g. in tests, the new field defaults to `.zero` via the memberwise initializer, so existing call sites keep compiling.)

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

## Orchard → Ironwood migration API on `Synchronizer`

The early anchored, pre-sign-all migration API has been replaced. Remove calls to
`proposeMigrationTransfers`, `proposeImmediateMigrationTransfers`,
`signAndStoreMigrationSchedule`, `proposeMigrationTransferPCZTs`,
`storeSignedMigrationTransferPCZTs`, `executeNextPendingTransfer`,
`refreshStaleTransfers`, and `restartCurrentMigrationStep`; they are no longer in the public
`Synchronizer` contract. The supported flow commits anchorless intents once and materializes at
most one due transaction with a fresh anchor and expiry window.

Migration UI and background workers must read one authoritative `migrationSnapshot(for:)` and
render its `phase`, `state`, `failureCode`, `recoveryAction`, and `nextAction`. Every mutation of an
existing run takes the caller's `expectedRunId` and `expectedRevision`. If either changed, discard
the result, refresh the snapshot, and re-drive from its new `nextAction`; never apply an action to a
replacement run merely because its revision number happens to match.

The principal APIs are:

- `beginPrivateMigration(externalSigner:options:for:)` validates the selected endpoint first, then
  atomically creates the private run and immutable submission policy. Endpoint validation cannot
  leave a policyless run or block ordinary spends while RPC is in flight.
- `proposePrivateMigrationIntents(for:)` and `proposeImmediateMigrationIntent(for:)` return the
  exact anchorless plan for confirmation. `commitMigrationIntents(_:externalSigner:options:for:)`
  validates the endpoint and atomically commits an Immediate run, its policy, and its intents; an
  existing Private run must already carry the same policy.
- `executeNextMigrationAction(expectedRunId:expectedRevision:spendingKey:options:for:)` performs at
  most one engine-authorized software/background step. Offline missed windows are rebased by the
  engine; signed or possibly submitted bytes are reconciled instead of blindly rebuilt.
- `stageNextDueMigrationPCZT`, `resumeNoteSplitExternalSigning`, and
  `resumeDueMigrationExternalSigning` also require the expected run/revision. They return the exact
  persisted signer envelope after process death. Signed-PCZT submission APIs require the caller's
  current revision and preserve the engine claim token through finalization and broadcast.
- `bindMigrationSubmissionPolicy(expectedRunId:expectedRevision:options:for:)` is only the explicit
  repair path for upgraded legacy runs. Chain-exposed policyless bytes remain quarantined until
  mining or positive consensus expiry resolves them.

`NetworkPrivacyOptions` is authoritative. Direct and Tor transports never silently fall back to
one another; the endpoint's TLS identity, chain name, sampled tip, consensus branch, transaction
branch, and expiry safety window are validated before submission. A nonzero lightwalletd submit
code is not success unless exact-txid reconciliation proves the transaction is known.

Snapshot read/decode/corruption failures surface as a non-operational
`.walletSchemaUnavailable` projection (`nextAction == .none`, ordinary spends blocked). Do not
render or execute a cached runnable snapshot in that state. Ordinary-spend reservations are scoped
to the migrating account, so another account in the same wallet remains usable when its own
authoritative guard succeeds.

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
