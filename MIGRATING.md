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

## The shielded voting API is back, with breaking changes

The shielded voting API was removed on 2.7.0-rc.1 and is restored here on the
Ironwood (NU6.3) stack. `VotingRustBackend`, the `Voting*` types and
`PirSnapshotResolver`/`PirSnapshotProbing`/`HTTPPirSnapshotProbe` are available
again, but the API is not the one that shipped before 2.7.0-rc.1: `zcash_voting`
absorbed orchestration the SDK used to drive step by step, and made the
intermediate steps private. Wallet developers upgrading from a pre-2.7.0-rc.1
version must make the changes below. Wallet developers coming from 2.7.0-rc.1,
where voting was absent, can adopt the API as documented.

### Voting hotkeys are no longer derived from the wallet seed

This is the change most likely to affect a shipped wallet.

A voting hotkey is now an app-owned random value. `generateHotkey` is a type
method that takes only a network, and returns a `VotingHotkey` carrying a
`storedSecret`, the `rawOrchardAddress` derived from it, and that address's
`addressIndex`:

```swift
let hotkey = try VotingRustBackend.generateHotkey(networkId: networkId)
// Persist hotkey.storedSecret. Nothing else in VotingHotkey needs storing.
```

**The application must persist `storedSecret`.** It cannot be re-derived from
the wallet seed, so restoring a wallet from its seed phrase does not restore the
ability to vote with a hotkey whose secret was lost, and any voting power already
delegated to that hotkey becomes unusable. The SDK does not store it for you.
Calling `generateHotkey` again produces an unrelated hotkey rather than
recovering the previous one.

Hotkeys derived from a wallet seed by an earlier SDK version do not carry over.
Every API that previously took a hotkey seed now takes the stored secret instead.

`VotingHotkey` no longer exposes `secretKey`, `publicKey` or `address`; upstream
dropped the public key, and the address is now the raw Orchard address bytes.

### Committing a vote is a single call

`buildVoteCommitment`, `signCastVote`, `buildSharePayloads` and `encryptShares`
are replaced by one `commitVote`, which builds the proof, signs the cast vote,
derives the helper-share payloads and persists the recovery state. It is
idempotent: calling it again for the same round, bundle and proposal returns the
persisted result rather than rebuilding the proof.

The encrypted shares it returns are the ciphertexts the vote proof commits to.
There is no longer a standalone share-encryption step, because shares encrypted
outside the commitment would not correspond to any vote.

### Other API changes

- `decomposeWeight` is removed. It has no replacement: share construction is now
  entirely internal to the voting crate.
- `initRound` takes a `networkId`, which is persisted with the round so that
  governance PCZT consensus branch identifiers can be validated against it.
- `buildPczt` and `buildAndProveDelegation` take the hotkey stored secret in
  place of a raw hotkey address. `buildAndProveDelegation` additionally requires
  the sender FVK, seed fingerprint, account index and round name, which the
  voting crate now needs together in order to construct delegation keys.
- `markVoteSubmitted` requires the cast-vote transaction hash. A vote is recorded
  as submitted by persisting the transaction that carried it, so that a restarted
  wallet resumes polling for that transaction instead of rebuilding the vote.
- `recordShareDelegation` no longer accepts a nullifier. The voting crate derives
  it from the vote's recovery state, so a caller can no longer record a nullifier
  that disagrees with the share it belongs to.
- `storeCommitmentBundle` is replaced by `recordVcPosition`.
- `VotingBundleSetupResult` gained `droppedCount`, the number of notes the
  canonical bundling policy discarded. A non-zero value means the wallet holds
  voting notes that will not be voted with, which `eligibleWeight` alone does not
  reveal.
- `setupBundles` now rejects an empty note set instead of returning an empty
  bundle layout.
- Round identifiers must be 64 lowercase hexadecimal characters encoding a
  canonical Pallas field element. Shorter or non-canonical identifiers are
  rejected by `initRound`.
- Types that carry key material or note secrets — `VotingHotkey`,
  `VotingNoteInfo`, `VotingPczt` and `VotingDelegationKeyInputs` — now conform to
  `Undescribable`, so they render as `--redacted--` rather than exposing their
  contents through logging, string interpolation or reflection.

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
