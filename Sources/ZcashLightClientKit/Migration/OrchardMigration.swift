//
//  OrchardMigration.swift
//  ZcashLightClientKit
//

import Combine
import Foundation

/// Per-broadcast network-privacy options for a migration transfer.
///
/// Independent of the app's global Tor toggle and of the synchronizer's networking: each migration
/// broadcast decides for itself whether to use Tor and which endpoint to hit.
///
/// - Note: Not declared `Sendable` because it stores a `LightWalletEndpoint`, which the pinned SDK
///   does not (yet) declare `Sendable`. Under this package's Swift 5.6 minimal concurrency checking
///   that is a non-issue; it should gain `Sendable` once the core endpoint type does.
public struct MigrationNetworkPrivacyOptions: Equatable {
    /// Whether to broadcast over the dedicated migration Tor client. When `true`, the broadcast is
    /// fail-closed: if Tor cannot be established it throws rather than falling back to a direct
    /// connection (see ``MigrationBroadcaster``).
    public let useTor: Bool

    /// The endpoint this broadcast is submitted to. The app picks the submission server explicitly
    /// for every migration transfer; the SDK never supplies a default. Per the migration privacy
    /// spec this should differ from the wallet's ordinary sync server, so a migration broadcast is
    /// not correlated with the wallet's sync traffic. A typed endpoint (an iOS-specific choice; the
    /// Android SDK passes a `host:port` string).
    public let submissionEndpoint: LightWalletEndpoint

    /// Creates network-privacy options.
    public init(useTor: Bool, submissionEndpoint: LightWalletEndpoint) {
        self.useTor = useTor
        self.submissionEndpoint = submissionEndpoint
    }
}

/// The app-facing entry point for driving an Orchard -> Ironwood pool migration for one
/// account.
///
/// `OrchardMigration` is deliberately independent of ``Synchronizer``: the app needs
/// ``isSyncBlocked()`` *before* any synchronizer exists (it gates whether sync should run at all), so
/// this type resolves everything from the wallet's data-db path and holds its own Rust backend rather
/// than borrowing the synchronizer's. One instance is bound to one account
/// (``Config/accountUUID``).
///
/// It composes three collaborators: the migration welding (the Rust engine surface), a fail-closed
/// ``MigrationBroadcaster``, and a persisted ``MigrationSyncGate`` (the network-scaled
/// post-broadcast privacy buffer, the in-flight broadcast marker, plus the ready-broadcast
/// block). The engine owns all migration state, including
/// the committed schedule; the SDK keeps no local copy of the proposal list.
actor OrchardMigration {
    /// The immutable configuration an ``OrchardMigration`` is built from.
    ///
    /// Beyond the migration's own inputs, this carries the paths the underlying `ZcashRustBackend`
    /// initializer requires. Migration signing itself needs no Sapling parameter files (the
    /// Orchard/Ironwood proving keys are internal to the Rust crate); `spendParamsURL` /
    /// `outputParamsURL` / `fsBlockDbRoot` exist purely because the shared backend initializer
    /// demands them, and are otherwise unused by the migration flow.
    ///
    /// - Note: Not declared `Sendable`. It holds `ZcashNetwork`, `LightWalletEndpoint`, and
    ///   `Initializer.LoggingPolicy` — none of which the pinned SDK declares `Sendable`, and
    ///   `LoggingPolicy.custom(Logger)` cannot be (a `Logger` is a non-`Sendable` reference). The
    ///   conformance is not needed: a `Config` only flows through this actor's synchronous
    ///   (nonisolated) initializer, never across an isolation boundary.
    struct Config {
        /// The wallet's data database — the migration engine's entire persisted state lives here.
        let dataDbURL: URL
        /// Filesystem root of the compact-block cache. Pass-through: required by the backend
        /// initializer, unused by migration.
        let fsBlockDbRoot: URL
        /// Sapling spend-parameters file. Pass-through: required by the backend initializer, unused
        /// by migration signing.
        let spendParamsURL: URL
        /// Sapling output-parameters file. Pass-through: required by the backend initializer, unused
        /// by migration signing.
        let outputParamsURL: URL
        /// The network this wallet is on.
        let network: ZcashNetwork
        /// The account this migration is bound to.
        let accountUUID: AccountUUID
        /// The main Tor directory; the dedicated migration Tor client is provisioned in its
        /// `migration_tor` subdirectory.
        let torDirURL: URL
        /// Directory for the SDK's general storage; the per-account sync-gate file lives here.
        let generalStorageURL: URL
        /// The logging policy, mirroring ``Initializer``'s.
        let loggingPolicy: Initializer.LoggingPolicy

        /// Creates a configuration.
        ///
        /// - Parameters:
        ///   - dataDbURL: the wallet's data database.
        ///   - fsBlockDbRoot: compact-block cache root (pass-through for the backend initializer).
        ///   - spendParamsURL: Sapling spend params (pass-through for the backend initializer).
        ///   - outputParamsURL: Sapling output params (pass-through for the backend initializer).
        ///   - network: the wallet's network.
        ///   - accountUUID: the account this migration is bound to.
        ///   - torDirURL: the main Tor directory.
        ///   - generalStorageURL: directory for the per-account sync-gate file.
        ///   - loggingPolicy: the logging policy.
        init(
            dataDbURL: URL,
            fsBlockDbRoot: URL,
            spendParamsURL: URL,
            outputParamsURL: URL,
            network: ZcashNetwork,
            accountUUID: AccountUUID,
            torDirURL: URL,
            generalStorageURL: URL,
            loggingPolicy: Initializer.LoggingPolicy = Initializer.LoggingPolicy.default(.debug)
        ) {
            self.dataDbURL = dataDbURL
            self.fsBlockDbRoot = fsBlockDbRoot
            self.spendParamsURL = spendParamsURL
            self.outputParamsURL = outputParamsURL
            self.network = network
            self.accountUUID = accountUUID
            self.torDirURL = torDirURL
            self.generalStorageURL = generalStorageURL
            self.loggingPolicy = loggingPolicy
        }
    }

    /// The post-broadcast privacy buffer for `networkType`: how long sync stays paused after a
    /// migration broadcast so the broadcast is not correlated with a fresh sync. Network-scaled:
    /// 600 s on mainnet (the production privacy requirement), 180 s on testnet/regtest — where
    /// traffic-correlation privacy is moot and the full 10 minutes only slows QA cycles down.
    static func privacySyncBufferDuration(for networkType: NetworkType) -> TimeInterval {
        switch networkType {
        case .mainnet:
            return 600
        case .testnet, .regtest:
            return 180
        }
    }

    /// The mainnet post-broadcast privacy buffer — DERIVED from
    /// ``privacySyncBufferDuration(for:)`` for `.mainnet` (never an independently maintained
    /// number), kept as a static constant for the network-less contexts that need one (the
    /// `Synchronizer` protocol's default `migrationPrivacySyncBufferDuration`, which has no
    /// network to scale by; real synchronizers forward their host's network-scaled value instead).
    static let privacySyncBufferDuration: TimeInterval = privacySyncBufferDuration(for: .mainnet)

    /// The NU6.3 (Ironwood) activation height for `networkType`, or `nil` when NU6.3 is unset for
    /// that network. Stateless — no database access, and safe to call before constructing an
    /// ``OrchardMigration``.
    ///
    /// SDK-internal: `OrchardMigration` is not `public`, so apps cannot reach this helper. The
    /// app-facing surface for the same value is the public ``ZcashNetwork/ironwoodActivationHeight``
    /// (`Model/ZcashNetwork+IronwoodActivation.swift`), which this delegates to so the SDK has a
    /// single path to the underlying backend rather than two independent forwarders.
    ///
    /// - Note: Also returns `nil` for a network id outside `{testnet, mainnet}` (e.g. `.regtest`),
    ///   which has no fixed NU6.3 height; callers are expected to pass `.testnet`/`.mainnet`.
    static func ironwoodActivationHeight(for networkType: NetworkType) -> BlockHeight? {
        ZcashNetworkBuilder.network(for: networkType).ironwoodActivationHeight
    }

    private let welding: ZcashRustBackendWelding
    private let accountUUID: AccountUUID
    private let broadcaster: any MigrationBroadcasting
    private let syncGate: MigrationSyncGate
    private let logger: Logger

    /// The clock every estimate-consulting path on this actor reads (mirroring
    /// ``OrchardMigrationHost``'s injected `now`), so tests can drive the wall-clock tip
    /// projection deterministically. Production passes the real clock.
    private let now: @Sendable () -> Date

    /// Whether a broadcast-performing flow is currently in flight. Together with
    /// `broadcastFlowWaiters`, this implements ``serializedBroadcastFlow(_:)``'s single-flight
    /// discipline. Not a cache: it only ever describes the presently running call.
    private var isBroadcastFlowInFlight = false

    /// Callers waiting for the in-flight broadcast flow to finish, resumed in bulk when it does.
    private var broadcastFlowWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates an `OrchardMigration` from `config`, building its own Rust backend, a dedicated
    /// ``MigrationBroadcaster``, and sync gate. Standalone construction: use
    /// ``init(config:sharedBroadcaster:)`` instead when several accounts must share one broadcaster
    /// (as ``OrchardMigrationHost`` does) so they do not each race an independent Tor bootstrap
    /// against the shared `migration_tor` directory.
    init(config: Config) {
        let logger = config.loggingPolicy.makeLogger(category: "migrationLogs")
        self.init(
            config: config,
            sharedBroadcaster: MigrationBroadcaster(torDirURL: config.torDirURL, logger: logger)
        )
    }

    /// Creates an `OrchardMigration` from `config` and an externally owned `sharedBroadcaster`,
    /// building everything ``init(config:)`` does (its own Rust backend and sync gate, and the
    /// custom-network registration) except the broadcaster, which is supplied so several per-account
    /// migrations can share a single one (see ``OrchardMigrationHost``).
    ///
    /// - Note: When `config.network` is a custom network (``ZcashNetwork/customActivationHeights``
    ///   non-`nil`), this registers it with the Rust core exactly as `Initializer.setup` does, before
    ///   building the backend: `OrchardMigration` deliberately does not share the synchronizer's
    ///   backend (see the type doc), so it cannot rely on an `Initializer` having already registered
    ///   it -- an app may construct this before any `Initializer` exists at all. Process-global (see
    ///   `MIGRATING.md`); a conflicting re-registration is a host configuration bug (`assertionFailure`).
    init(config: Config, sharedBroadcaster: any MigrationBroadcasting) {
        if let activationHeights = config.network.customActivationHeights {
            let cleanRegistration = ZcashRustBackend.setCustomNetwork(
                base: config.network.customNetworkBase ?? config.network.networkType,
                activationHeights
            )
            if !cleanRegistration {
                // A different custom network was already registered in this process. The new values
                // are applied (last writer wins), but per-instance state of any earlier registrant
                // (e.g. its checkpoint source) no longer matches the process-global parameters -- a
                // host configuration bug worth failing fast on during development.
                assertionFailure(
                    "Conflicting custom-network registration: a different custom network was already registered in this process."
                )
            }
        }

        let logger = config.loggingPolicy.makeLogger(category: "migrationLogs")
        let welding = ZcashRustBackend(
            dbData: config.dataDbURL,
            fsBlockDbRoot: config.fsBlockDbRoot,
            spendParamsPath: config.spendParamsURL,
            outputParamsPath: config.outputParamsURL,
            networkType: config.network.networkType,
            logLevel: config.loggingPolicy.makeRustLogging(),
            // Migration welding calls are data-db operations that never consult these flags; the
            // dedicated broadcaster owns all migration networking.
            sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false)
        )
        let accountUUID = config.accountUUID
        let now: @Sendable () -> Date = { Date() }

        self.welding = welding
        self.accountUUID = accountUUID
        self.logger = logger
        self.broadcaster = sharedBroadcaster
        self.now = now
        self.syncGate = MigrationSyncGate(
            directory: config.generalStorageURL,
            accountUUID: accountUUID,
            bufferDuration: OrchardMigration.privacySyncBufferDuration(for: config.network.networkType),
            readyBroadcastProvider: {
                // The gate's work-pending clause (D1): a PROVED, due, unexpired, valid transfer
                // servable right now — never the broader overdue query, whose due-but-unproved
                // `Signed` rows need MORE syncing rather than a broadcast session. Estimate-aware
                // with the scanned tip asked FIRST (U8), degrading to "no ready broadcast" on any
                // engine error so the reactive gate never crashes.
                await OrchardMigration.gateReadyBroadcast(welding: welding, accountUUID: accountUUID, now: now)
            },
            logger: logger
        )
    }

    /// Injecting initializer for tests: supply the welding, broadcaster, sync gate (with its test
    /// clock/ticker), logger, and — for the actor's own estimate-consulting paths — a clock,
    /// directly. `now` defaults to the real clock so call sites that do not exercise the
    /// estimate stay unchanged.
    init(
        welding: ZcashRustBackendWelding,
        accountUUID: AccountUUID,
        broadcaster: any MigrationBroadcasting,
        syncGate: MigrationSyncGate,
        logger: Logger,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.welding = welding
        self.accountUUID = accountUUID
        self.broadcaster = broadcaster
        self.syncGate = syncGate
        self.logger = logger
        self.now = now
    }

    // MARK: - State

    /// The engine's next step to advance the stored run, driven with the wallet's scanned target
    /// and wall-clock estimated target. `nil` means no run is stored; a
    /// terminal (complete or cancelled) run reports ``MigrationAdvanceStep/complete``. See
    /// ``MigrationAdvanceStep`` for the step semantics and the discharge mapping.
    func advanceStep() async throws -> MigrationAdvanceStep? {
        let estimatedTip = await MigrationTipEstimation.gatingEstimatedTip(welding: welding, now: now())
        return try await welding.migrationAdvanceStep(for: accountUUID, estimatedTip: estimatedTip)
    }

    /// Live migration progress, or `nil` when no snapshot is reportable: present only while an
    /// engine run is ACTIVE or a recorded immediate sweep is pending (unmined and unexpired);
    /// terminal — complete or cancelled — runs report `nil`.
    func migrationProgress() async throws -> MigrationProgress? {
        try await welding.migrationProgress(for: accountUUID)
    }

    /// The LIVE status of every committed migration transaction, keyed by its stable id -- the
    /// per-transaction detail view behind ``migrationProgress()``'s aggregate summary.
    func transactionStatuses() async throws -> [MigrationTransactionStatus] {
        try await welding.migrationTransactionStatuses(for: accountUUID)
    }

    /// The stored run's sync/proving wake-up schedule as of the scanned tip — the heights at
    /// which the host should wake, sync, and run ``finalizeReadyTransfers()``, plus the transfer
    /// ids each wake-up covers. Jitter is re-drawn on every call; recompute (and re-register with
    /// the OS) after any state change rather than caching. Empty when there is nothing left to
    /// prove.
    func syncWakeups() async throws -> [MigrationSyncWakeup] {
        try await welding.migrationSyncWakeups(for: accountUUID)
    }

    /// Repairs the committed run where this process submitted a transaction that mined but never
    /// recorded the broadcast; returns whether this call repaired a row. Local-database only —
    /// never touches the network — so it is safe in a sync session; the 120-second
    /// in-flight-broadcast guard (during which a just-broadcast transfer must not be probed) is
    /// primarily enforced by the sync gate the broadcast path arms, and — as optional hardening —
    /// honored here directly too: while the persisted in-flight marker is live this call no-ops
    /// (returns `false` without touching the engine), so a caller that bypasses the gate cannot
    /// drive the probe into the submit-to-record window either. That guard is exactly why the
    /// repair cannot simply run on every read: inside the submit-to-record window, the row it
    /// would "repair" is one whose broadcast is still being recorded.
    func reconcileUnrecordedBroadcasts() async throws -> Bool {
        // Optional hardening (belt to the sync gate's suspenders): the probe's own crash
        // heuristics are the primary defense, but there is no reason to let it observe a
        // just-broadcast transfer at all while the submit-to-record window is provably open.
        if syncGate.isBroadcastInFlight() {
            return false
        }
        return try await welding.migrationReconcileUnrecordedBroadcasts(for: accountUUID)
    }

    /// Proves every migration transaction whose anchor the wallet can resolve right now and
    /// returns how many were proved (`0` is the ordinary "nothing left to prove" answer). Run it
    /// at sync wake-ups (``syncWakeups()``), never on the broadcast path — proving needs the
    /// wallet's commitment tree and takes real time, while a broadcast session must stay a pure
    /// delivery step. A straight delegation to the welding proving sweep, bound to this actor's
    /// own account.
    func finalizeReadyTransfers() async throws -> Int {
        try await welding.migrationProvePending(for: accountUUID)
    }

    // MARK: - Chain-tip estimation
    //
    // The public estimated-tip members (`estimatedMigrationChainTip()` /
    // `estimatedMigrationSecondsPerBlock()`) are WALLET-scoped, not account-scoped, so they live
    // on `OrchardMigrationHost` rather than on this per-account actor; this actor consults the
    // same shared `MigrationTipEstimation` composition only for its gate/delivery due-ness
    // checks below.

    /// The gate's estimate-aware work-pending clause (D1): whether a PROVED, schedule-due,
    /// unexpired, valid transfer is servable RIGHT NOW — the one situation where the wallet
    /// should broadcast instead of syncing. Never the broader overdue query: a due-but-unproved
    /// `Signed` row needs MORE syncing, so it must never block sync.
    ///
    /// Asks at the SCANNED tip first (U8): the estimate may only ACCELERATE due-ness, so a `true`
    /// scanned answer is final and the sample read is skipped entirely; only a `false` answer
    /// pays for the projection and re-asks with the estimate. Any engine or estimator failure
    /// degrades to `false`/`nil` (never blocks, never crashes the gate). Static (welding and
    /// clock passed in) so the init-time `readyBroadcastProvider` closure can share it before
    /// `self` exists.
    private static func gateReadyBroadcast(
        welding: ZcashRustBackendWelding,
        accountUUID: AccountUUID,
        now: @Sendable () -> Date
    ) async -> Bool {
        if (try? await welding.migrationHasReadyBroadcast(for: accountUUID, estimatedTip: nil)) ?? false {
            return true
        }
        guard let estimatedTip = await MigrationTipEstimation.gatingEstimatedTip(welding: welding, now: now()) else {
            return false
        }
        return (try? await welding.migrationHasReadyBroadcast(for: accountUUID, estimatedTip: estimatedTip)) ?? false
    }

    // MARK: - Note splitting

    /// Whether the account's Orchard notes must be split before migration.
    ///
    /// - Note: Requires at least one completed sync. On a wallet that has never completed a sync (no
    ///   chain tip known) this throws rather than returning `false`.
    func isNoteSplitNeeded() async throws -> Bool {
        try await welding.migrationIsNoteSplitNeeded(for: accountUUID)
    }

    /// The optimal note split for the spendable Orchard balance.
    func prepareNoteSplit() async throws -> NoteSplitProposal {
        try await welding.migrationPrepareNoteSplit(for: accountUUID)
    }

    /// Signs, extracts, broadcasts, and records the note-split transaction, returning the broadcast
    /// outcome.
    ///
    /// Composition: sign the split, extract the broadcast bytes, broadcast once, and — only on a
    /// success outcome — start the privacy buffer, *before* recording the mapped result: the gate
    /// marks on submit success, independent of record bookkeeping. A transport failure or a server
    /// rejection is *returned* as a ``MigrationTransferResult`` (and recorded first, gate untouched).
    ///
    /// Throws: a pre-broadcast failure throws untouched (a signing error, or
    /// ``ZcashError/migrationTorUnavailable`` when `options.useTor` is set and Tor cannot be
    /// established — nothing was broadcast and nothing is recorded). A record failure *after* a
    /// successful broadcast throws ``ZcashError/migrationRecordFailedAfterBroadcast(_:)`` — the
    /// broadcast DID land and the privacy buffer is already running; the failure is transient from
    /// the migration's point of view, because a later execution window self-heals (re-submitting
    /// draws a duplicate rejection, which records as success).
    ///
    /// Broadcast flows are single-flight on this actor: when another broadcast-performing call
    /// (this method or ``executeNextPendingTransfer(options:useEstimatedTip:)``) is in flight, this call first waits
    /// for it to finish — it never broadcasts concurrently with it and never throws on contention.
    func submitNoteSplit(
        proposal: NoteSplitProposal,
        usk: UnifiedSpendingKey,
        options: MigrationNetworkPrivacyOptions
    ) async throws -> MigrationTransferResult {
        try await serializedBroadcastFlow { () async throws -> MigrationTransferResult in
            let prepared = try await welding.migrationSignNoteSplit(proposal: proposal, usk: usk, for: accountUUID)
            return try await broadcastAndRecord(prepared: prepared, options: options)
        }
    }

    // MARK: - Migration proposal

    /// The full migration schedule for the spendable Orchard balance.
    func proposeMigrationTransfers() async throws -> MigrationSchedule {
        try await welding.migrationProposeTransfers(for: accountUUID)
    }

    /// Proposes the immediate (single-transaction) migration: an ordinary send-max that spends ALL
    /// spendable Orchard notes and pays everything minus the ZIP-317 fee to the account's own
    /// unified address -- post-NU6.3 the payment lands in the Ironwood pool (the UA's Orchard
    /// receiver doubles as the Ironwood receiver). Entirely outside the migration engine: the
    /// returned proposal is an ORDINARY proposal held by the caller, so no engine plan-cache
    /// staleness applies to it (unlike ``proposeMigrationTransfers()``).
    func proposeImmediateMigration() async throws -> ImmediateMigrationProposal {
        let ownAddress = try await welding.getCurrentAddress(accountUUID: accountUUID)
        let ffiProposal = try await welding.proposeSendMaxTransfer(
            accountUUID: accountUUID,
            recipient: ownAddress.stringEncoded,
            memo: nil,
            orchardOnly: true
        )
        let proposal = Proposal(inner: ffiProposal)
        let fee = proposal.totalFeeRequired()
        let amount = OrchardMigration.sweptPaymentValue(of: ffiProposal) - fee
        return ImmediateMigrationProposal(proposal: proposal, amount: amount, fee: fee)
    }

    /// Records a broadcast immediate-migration sweep. The immediate lane surfaces ONLY through
    /// ``migrationProgress()`` — no engine state machine is involved: while the recorded sweep is
    /// unmined and unexpired, progress reports a `0` of `1` snapshot flagged
    /// ``MigrationProgress/isImmediate``; once it mines (consumed) or expires (the offer
    /// re-arms), progress reports `nil`. Not broadcast-performing itself (the broadcast rides
    /// the ordinary `createProposedTransactions`/`createTransactionFromPCZT` pipeline, already
    /// guarded there) -- this only records the outcome, so it is not gated by
    /// ``serializedBroadcastFlow(_:)``.
    func recordImmediateMigration(txid: Data) async throws {
        try await welding.migrationRecordImmediateRun(txid: txid, for: accountUUID)
    }

    /// The leftover Orchard balance a migration would not cross, when large enough to be worth
    /// offering the user a choice about; `nil` when there is no such residual.
    ///
    /// - Note: Requires at least one completed sync. On a wallet that has never completed a sync (no
    ///   chain tip known) this throws rather than returning `nil`.
    func residualAfterMigration() async throws -> Zatoshi? {
        try await welding.migrationResidualAfterMigration(for: accountUUID)
    }

    /// Locks every currently-spendable, not-already-locked legacy-Orchard note until explicit
    /// unlock and returns the total value locked — the "Lock balance" choice at migration
    /// `Complete`. A straight delegation to the welding lock call, bound to this actor's own
    /// account; not broadcast-performing, so it is not gated by ``serializedBroadcastFlow(_:)``.
    func lockMigrationResidual() async throws -> Zatoshi {
        try await welding.lockMigrationResidual(accountUUID: accountUUID)
    }

    /// Unlocks the account's locked outputs — the release half of ``lockMigrationResidual()`` —
    /// and returns the number of outputs unlocked. A straight delegation to the welding unlock
    /// call, bound to this actor's own account.
    func unlockMigrationResidual() async throws -> Int {
        try await welding.unlockMigrationResidual(accountUUID: accountUUID)
    }

    /// The multi-run ("rounds") estimate for migrating the whole spendable Orchard balance. A
    /// straight delegation to the welding estimate call, bound to this actor's own account; the
    /// zero-run estimate is a legitimate answer, not an error.
    func estimateMigrationRuns() async throws -> MigrationRunEstimate {
        try await welding.estimateMigrationRuns(accountUUID: accountUUID)
    }

    /// Pre-signs and persists every transfer in `schedule` in the migration engine.
    ///
    /// The SDK does not retain the proposal list: hosts that need to render the committed schedule
    /// later must persist it themselves at confirmation time.
    func signAndStoreMigrationSchedule(_ schedule: MigrationSchedule, usk: UnifiedSpendingKey) async throws {
        try await welding.migrationSignAndStoreSchedule(schedule, usk: usk, for: accountUUID)
    }

    // MARK: - Background execution

    /// Broadcasts the next height-due, ALREADY-PROVEN transaction, or reports why nothing was
    /// broadcast — see ``MigrationTransferAttempt`` for the three outcomes. BROADCAST-ONLY: this
    /// call never proves (``MigrationTransferAttempt/awaitingProof(id:)`` is cleared by
    /// ``finalizeReadyTransfers()`` at a sync wake-up, never here), so a broadcast session stays a
    /// pure delivery step.
    ///
    /// `useEstimatedTip` opts the due-ness check into the wall-clock chain-tip estimate (see
    /// ``ChainTipEstimator``): the estimate may only ACCELERATE scheduled-height due-ness — expiry
    /// is always evaluated against the scanned tip — and an estimator failure degrades to the
    /// scanned-tip behavior rather than blocking the attempt.
    ///
    /// Composition mirrors ``submitNoteSplit(proposal:usk:options:)``: fetch the next due transfer
    /// (empty outcomes leave the gate untouched), extract, broadcast once, and — only on a
    /// success outcome — start the privacy buffer, *before* recording the mapped result: the gate
    /// marks on submit success, independent of record bookkeeping. Transport/rejection outcomes are
    /// returned (recorded first, gate untouched). Pre-broadcast failures throw untouched; a record
    /// failure *after* a successful broadcast throws
    /// ``ZcashError/migrationRecordFailedAfterBroadcast(_:)`` — the broadcast DID land and the
    /// privacy buffer is already running; a later execution window self-heals the engine state
    /// (re-submitting draws a duplicate rejection, which records as success).
    ///
    /// Broadcast flows are single-flight on this actor: when another broadcast-performing call
    /// (this method or ``submitNoteSplit(proposal:usk:options:)``) is in flight, this call first
    /// waits for it to finish and only then fetches the next due transfer — so a concurrent call
    /// can never re-broadcast the in-flight transfer, and typically reports
    /// ``MigrationTransferAttempt/nothingDue`` once the in-flight flow has recorded. It never
    /// throws on contention.
    ///
    /// - Important: This method must run only in a session that does **not** also sync. This actor
    ///   does not check sync state itself; the `Synchronizer` surface in front of it adds an
    ///   advisory point-in-time guard (``ZcashError/migrationBroadcastDuringSync``) plus the
    ///   privacy gate (see ``isSyncBlocked()``) — neither is a hard mutual-exclusion
    ///   lock, so hosts must still sequence sync and broadcast sessions.
    /// - Note: The engine serves preparation transactions and transfers alike, in scheduled
    ///   order — after an external-signer store, the pending preparations are what comes due
    ///   first, and only once they are broadcast (and mined) do the scheduled transfers follow.
    func executeNextPendingTransfer(
        options: MigrationNetworkPrivacyOptions,
        useEstimatedTip: Bool
    ) async throws -> MigrationTransferAttempt {
        try await serializedBroadcastFlow { () async throws -> MigrationTransferAttempt in
            // The estimate only ever accelerates due-ness; estimator failure degrades to nil
            // (scanned-tip behavior) and never blocks the attempt.
            let estimatedTip = useEstimatedTip ? await MigrationTipEstimation.gatingEstimatedTip(welding: welding, now: now()) : nil
            switch try await welding.migrationNextDueTransfer(for: accountUUID, estimatedTip: estimatedTip) {
            case .nothingDue:
                return .nothingDue
            case .ready(let prepared):
                return .executed(try await broadcastAndRecord(prepared: prepared, options: options))
            case .awaitingProof(let id):
                // Due, but the proving sweep has not produced its proof yet. Nothing to broadcast
                // this window; `finalizeReadyTransfers()` at a sync wake-up clears it.
                logger.debug("migration transfer \(id) is due but awaiting its proof; nothing broadcast")
                return .awaitingProof(id: id)
            }
        }
    }

    // MARK: - Sync coordination

    /// Whether ordinary wallet sync should currently be paused for this migration.
    ///
    /// `true` when a READY broadcast is waiting (a proved, schedule-due, unexpired, valid
    /// transfer the wallet should serve instead of syncing — never a `Signed` or awaiting-proof
    /// row, which needs MORE syncing), **or** the post-broadcast privacy buffer has not yet
    /// elapsed, **or** an in-flight broadcast marker is live. The ready-broadcast query is
    /// engine-backed and estimate-aware (scanned tip asked first — U8); if it throws, this
    /// degrades to the persisted gate-file (privacy-buffer/in-flight) state rather than crashing
    /// the app's sync gating.
    ///
    /// - Note: The gate is per-account (by file name). An app running several migrating accounts must
    ///   consult each account's `OrchardMigration`; this instance answers only for its bound account.
    /// - Note: Always consults the ready-broadcast query fresh (`await`s the engine), unlike
    ///   ``syncBlockedStream``'s synchronous subscribe-time seed -- see that property's documented
    ///   caveat about the two briefly disagreeing right after relaunch.
    func isSyncBlocked() async -> Bool {
        let hasReadyBroadcast = await OrchardMigration.gateReadyBroadcast(welding: welding, accountUUID: accountUUID, now: now)
        return syncGate.currentlyBlocked(hasReadyBroadcast: hasReadyBroadcast)
    }

    /// A stream of ``isSyncBlocked()``: emits the current value on subscribe, re-evaluates every 15 s
    /// and after every broadcast, and collapses consecutive duplicates.
    ///
    /// `nonisolated` so sync-gating UI/logic can subscribe without awaiting the actor; it is backed by
    /// the internally synchronized ``MigrationSyncGate``: concurrent recomputes (the ticker and every
    /// post-broadcast re-evaluation) publish through one lock-guarded, generation-ordered funnel, so a
    /// recompute that started earlier but finishes later after a fresher one already published is
    /// dropped rather than emitted — subscribers only ever see values in latest-wins order, never a
    /// stale one overwriting a fresher one.
    ///
    /// - Important: The value delivered synchronously on subscribe reflects only the persisted
    ///   privacy buffer and in-flight marker, not ready broadcasts -- ready-broadcast detection
    ///   needs the engine query, which is asynchronous. On relaunch with a ready broadcast and no
    ///   active buffer, that first emission can therefore briefly read `false` while
    ///   ``isSyncBlocked()`` already reads `true`; the stream corrects itself with its first
    ///   asynchronous re-evaluation (the next tick, or sooner if a broadcast happens first). A
    ///   subscriber that must be correct from its very first value should pair this stream with
    ///   an initial ``isSyncBlocked()`` call rather than trusting the seed alone.
    nonisolated var syncBlockedStream: AnyPublisher<Bool, Never> {
        syncGate.blockedStream
    }

    /// The sync gate's LIVE in-memory inputs — the privacy-buffer expiry and the (clamped)
    /// in-flight marker expiry — for the host's wallet-scope predicate (A8): the gate persists
    /// file-first, but a FAILED file write still updates the cache, so the wallet-scope reader
    /// must consult this live view alongside the file and let blocked win, or a full disk (or any
    /// write failure) would silently blind it to a mark this process just made. `nonisolated`
    /// (the gate is internally lock-synchronized) so the host can read it without awaiting the
    /// actor.
    nonisolated func liveGateInputs() -> (resumeAt: Date?, inFlightUntil: Date?) {
        (syncGate.currentResumeAt(), syncGate.currentInFlightUntil())
    }

    // MARK: - On-launch reconciliation

    /// Whether any scheduled transfer is past its send height but not yet broadcast — the
    /// delivery lane's "is there actionable work" query, counting an already-proved due
    /// transaction AND a due, dependency-satisfied `Signed` one the delivery call would drive
    /// through proving. An informational query for hosts (re-arm background execution, launch
    /// reconciliation); deliberately NOT consulted by any sync-gate path, which asks the
    /// narrower ready-broadcast predicate instead (a due-but-unproved row must never block
    /// sync — see ``isSyncBlocked()``).
    ///
    /// `useEstimatedTip` opts the check into the wall-clock chain-tip estimate: the estimate may
    /// only ACCELERATE due-ness (expiry stays scanned-tip), and an estimator failure degrades to
    /// the scanned-tip behavior — the same plumbing as
    /// ``executeNextPendingTransfer(options:useEstimatedTip:)``.
    func hasOverdueTransfers(useEstimatedTip: Bool) async throws -> Bool {
        let estimatedTip = useEstimatedTip ? await MigrationTipEstimation.gatingEstimatedTip(welding: welding, now: now()) : nil
        return try await welding.migrationHasOverdueTransfers(for: accountUUID, estimatedTip: estimatedTip)
    }

    /// Whether the migration is in an invalid state (spendable Orchard remains but no scheduled
    /// transfer covers it).
    func hasInvalidTransfers() async throws -> Bool {
        try await welding.migrationHasInvalidTransfers(for: accountUUID)
    }

    /// The migration engine's next height-due pending transfer proposal, or `nil` when nothing is
    /// pending — a straight readback of the stored run's next due-and-unbroadcast transfer
    /// (`zcashlc_migration_pending_transfer_proposal`).
    ///
    /// Deliberately with **no** local time-shifting of `nextExecutableAfterHeight` (the Android
    /// implementation clamps it to `now + interval` with a known unit bug the SDK does not port).
    /// The host re-arms its own background execution window from the returned proposal's heights;
    /// the local decision not to broadcast before that window *is* the reschedule, and the ZIP 318
    /// "re-spread the remainder" property is carried by the delivery machinery itself (one
    /// broadcast per session, the privacy buffer between sessions). `nil` means there is nothing
    /// to re-arm (no stored run, the run is terminal, or only preparation transactions are
    /// pending).
    /// - Throws: `rustMigrationPendingTransferProposal` if the engine returns an error.
    func pendingTransferProposal() async throws -> MigrationTransferProposal? {
        try await welding.migrationPendingTransferProposal(for: accountUUID)
    }

    // MARK: - Invalidity recovery

    /// Cancels the stored run and previews a fresh schedule against the live balance.
    ///
    /// The stored run is persisted as cancelled (its pre-signed transactions are abandoned;
    /// already-broadcast ones are unaffected on-chain), the invalid marks are cleared, and a fresh
    /// plan is previewed for the re-confirm lane — the follow-up
    /// ``signAndStoreMigrationSchedule(_:usk:)`` / ``submitNoteSplit(proposal:usk:options:)`` (or
    /// PCZT store) then commits it.
    func restartCurrentMigrationStep() async throws -> MigrationSchedule {
        try await welding.migrationRestartStep(for: accountUUID)
    }

    /// Rebuilds every EXPIRED transfer of the stored migration run in place through the engine and
    /// returns the run's FULL transfer schedule as stored AFTER the refresh (the current stored
    /// schedule when nothing had expired; empty when no run is stored or the run is terminal).
    ///
    /// Each rebuilt transfer re-spends the SAME funding note (recovered from the expired PCZT by
    /// nullifier identity, never an equal-value substitute) on a fresh schedule — a fresh
    /// memoryless delay from the current tip, a fresh canonical expiry, and a freshly drawn
    /// boundary anchor. The rebuilt rows' fresh scheduled/expiry heights exist nowhere but in the
    /// returned schedule — the atomically-persisted post-refresh truth the host must re-display.
    /// Once a run is stored (as it must be, to have anything to refresh), every subsequent
    /// commit-shaped call (``signAndStoreMigrationSchedule(_:usk:)``,
    /// ``createUnsignedNoteSplitPCZTs(for:)``, ``createUnsignedTransferPCZTs(for:)``) resumes it
    /// handle-free — the `schedule` argument identifies nothing at that point, so it is the stored
    /// run itself (already refreshed) that the external-signer ceremony converges on, not a
    /// comparison against whatever copy the host happens to pass. Passing a spending key signs each
    /// rebuilt transfer anew in-process; passing `nil` (an external-signer account, whose spend
    /// authority never exists on this device) leaves it awaiting its signature, so the
    /// ``createUnsignedTransferPCZTs(for:)`` / ``storeSignedSchedulePCZTs(_:)`` ceremony
    /// re-serves and completes it.
    /// - Throws: notably, a `FundingNoteUnavailable`-class failure when an expired transfer's exact
    ///   funding note was spent outside the migration, where the message names
    ///   ``restartCurrentMigrationStep()`` (cancel and re-plan) as the remedy. Rebuilds are
    ///   persisted ALL-OR-NOTHING: a mid-refresh throw (including this one) persists NONE of the
    ///   batch's rebuilds, so a non-throwing return's schedule is exactly what was atomically
    ///   persisted, never a partial batch.
    func refreshStaleTransfers(usk: UnifiedSpendingKey?) async throws -> MigrationSchedule {
        try await welding.migrationRefreshStaleTransfers(usk: usk, for: accountUUID)
    }

    // MARK: - Debug/QA

    /// DEBUG/QA ONLY — rewrites the stored migration schedule's transfer heights (first due in ~2
    /// blocks, then 4-block strides) and the earliest transfer's anchor boundary so real broadcast
    /// delivery can be exercised without waiting out ZIP 318's privacy delay. Not for production
    /// flows.
    ///
    /// Returns the number of transfers rescheduled (`0` when nothing is stored). Already-
    /// broadcast and already-mined transfers, and every preparation (note-split) transaction, are
    /// left untouched.
    func debugRescheduleTransfers() async throws -> Int {
        try await welding.migrationDebugRescheduleTransfers(for: accountUUID)
    }

    // MARK: - External signing (PCZT)

    /// Builds the whole previewed migration UNSIGNED — the run is created by this call — and
    /// returns the preparation (note-split) subset of its PCZTs for the signing ceremony. The
    /// transfer subset of the same build is served by ``createUnsignedTransferPCZTs(for:)``, so one
    /// ceremony signs everything. Resumes a stored non-terminal run handle-free; replaces a
    /// terminal one. Only `schedule.proposalHandle` crosses to the native side, and only when this
    /// call is the one creating the run — the display fields are never echoed back.
    func createUnsignedNoteSplitPCZTs(for schedule: MigrationSchedule) async throws -> [MigrationUnsignedTransferPczt] {
        try await welding.migrationCreateUnsignedNoteSplitPczts(for: schedule, for: accountUUID)
    }

    /// Applies the ceremony's signatures to the run's preparation (note-split) transactions,
    /// all-or-nothing, and returns a STORAGE RECEIPT for the first one (its `txid` is zeroed — the
    /// broadcastable, proven value is served by the delivery lane).
    func storeSignedNoteSplitPCZTs(_ signed: [MigrationSignedTransferPczt]) async throws -> PreparedMigrationTransfer {
        try await welding.migrationStoreSignedNoteSplitPczts(signed, for: accountUUID)
    }

    /// Builds one unsigned, proven PCZT per transfer of `schedule` for an external signer.
    func createUnsignedTransferPCZTs(for schedule: MigrationSchedule) async throws -> [MigrationUnsignedTransferPczt] {
        try await welding.migrationCreateUnsignedTransferPczts(for: schedule, for: accountUUID)
    }

    /// Accepts the full set of externally signed transfer PCZTs (all-or-nothing), persisting them in
    /// the migration engine.
    ///
    /// The SDK does not retain the proposal list: hosts that need to render the committed schedule
    /// later must persist it themselves at confirmation time.
    func storeSignedSchedulePCZTs(_ signed: [MigrationSignedTransferPczt]) async throws {
        try await welding.migrationStoreSignedSchedulePczts(signed, for: accountUUID)
    }

    // MARK: - Private

    /// Runs `flow` as the only broadcast-performing flow on this actor.
    ///
    /// The actor's methods are reentrant: the broadcast composition suspends at the welding hops and
    /// for the whole broadcast (a Tor bootstrap can take seconds), while the engine keeps reporting
    /// the same transfer as next-due until its result is recorded — so without this guard, a
    /// concurrent `executeNextPendingTransfer`/`submitNoteSplit` could re-fetch and re-broadcast the
    /// same bytes mid-flight. The serialization contract:
    /// - A concurrent caller never throws on contention and is never dropped: it awaits the
    ///   in-flight flow's completion (success or failure), then runs its own flow fresh, so its own
    ///   due-transfer fetch observes the recorded outcome (typically nil, or the next transfer).
    /// - Waiting is a suspension on a continuation that the finishing flow resumes exactly once —
    ///   no busy-waiting, and no unstructured tasks.
    /// - Cancelling a waiting caller never cancels the in-flight flow: the waiter holds no
    ///   reference to it, and the waiter's own cancellation is observed only by its own flow once
    ///   it proceeds.
    private func serializedBroadcastFlow<T>(_ flow: () async throws -> T) async rethrows -> T {
        while isBroadcastFlowInFlight {
            await withCheckedContinuation { continuation in
                broadcastFlowWaiters.append(continuation)
            }
        }
        isBroadcastFlowInFlight = true
        defer {
            isBroadcastFlowInFlight = false
            let waiters = broadcastFlowWaiters
            broadcastFlowWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
        return try await flow()
    }

    /// Shared broadcast/record composition for a prepared transfer: extract the broadcast bytes,
    /// broadcast once to the resolved endpoint, and classify the outcome. On a success outcome the
    /// privacy buffer starts *before* the result is recorded — ``MigrationSyncGate/markBroadcast()``
    /// is a non-throwing local write, and a record failure after a real broadcast must never skip
    /// the buffer; a record failure on that path throws
    /// ``ZcashError/migrationRecordFailedAfterBroadcast(_:)``. Non-success outcomes are recorded
    /// first and returned with the gate untouched (only success outcomes mark it, unchanged); a
    /// record throw on that path clears the in-flight marker first only for a DEFINITIVE
    /// rejection (`.expired`/`.invalidNote` — the server's answer proves nothing landed, so the
    /// window is over), while a `.networkError` record throw keeps the marker (protective: a
    /// transport failure cannot prove the submit did not land, exactly the ambiguity the marker
    /// exists for) — the raw record error rethrows either way. Only pre-broadcast failures throw
    /// untouched.
    ///
    /// The whole submit-to-record window is additionally bracketed by the sync gate's persisted
    /// in-flight marker (``MigrationSyncGate/markBroadcastInFlight()``): armed before the flow as
    /// a belt, RE-armed at the last instant before the submit RPC via the broadcaster's
    /// `onWillSubmit` hook (A9 — after the Tor bootstrap/connection setup, which can take many
    /// seconds and would otherwise burn the marker's 120 s window before anything reached the
    /// network), and cleared once the outcome is recorded — or immediately when the broadcaster
    /// throws before submitting anything (its fail-closed contract: a throw means nothing reached
    /// the network). A crash — or a record throw the rules above retain it for — between submit
    /// and record leaves the marker behind, and it self-expires at
    /// ``MigrationSyncGate/broadcastInFlightGuardDuration`` (120 s); while it lives, sync (and
    /// with it the reconciliation probe that must not observe a just-broadcast transfer) stays
    /// blocked.
    private func broadcastAndRecord(
        prepared: PreparedMigrationTransfer,
        options: MigrationNetworkPrivacyOptions
    ) async throws -> MigrationTransferResult {
        let rawTransaction = try await welding.migrationExtractBroadcastTx(pczt: prepared.pczt, for: accountUUID)

        // Arm the in-flight marker before the submit can reach the network (belt); the
        // broadcaster's onWillSubmit hook re-arms it at the last pre-submit instant so the 120 s
        // window covers the actual submit-to-record span rather than the Tor bootstrap. A crash
        // from the submit until the record lands leaves it to self-expire.
        syncGate.markBroadcastInFlight()

        let outcome: MigrationBroadcastOutcome
        do {
            let syncGate = self.syncGate
            outcome = try await broadcaster.broadcast(
                rawTransaction: rawTransaction,
                to: options.submissionEndpoint,
                useTor: options.useTor,
                onWillSubmit: { syncGate.markBroadcastInFlight() }
            )
        } catch {
            // The broadcaster throws only when nothing was submitted (fail-closed Tor, a
            // pre-connect failure): nothing is in flight, so clear the marker rather than
            // leaving sync blocked for the full self-expiry window.
            syncGate.clearBroadcastInFlight()
            throw error
        }

        let result = MigrationBroadcaster.map(outcome: outcome, successTxId: prepared.txid.toHexStringTxId())
        if case MigrationTransferResult.success = result {
            // The broadcast landed (or a duplicate rejection proved an earlier one did): start the
            // privacy buffer first, so a record failure cannot skip it.
            syncGate.markBroadcast()
            do {
                try await welding.migrationRecordTransferResult(transferId: prepared.id, result: result, for: accountUUID)
            } catch {
                // Deliberately NOT clearing the in-flight marker: the result was never recorded,
                // which is exactly the submit-to-record gap the marker guards; it self-expires.
                logger.error("OrchardMigration: failed to record a successfully submitted broadcast: \(error)")
                throw ZcashError.migrationRecordFailedAfterBroadcast(error)
            }
        } else {
            do {
                try await welding.migrationRecordTransferResult(transferId: prepared.id, result: result, for: accountUUID)
            } catch {
                // A11: the record failed, so the engine still thinks the transfer is pending.
                // For a DEFINITIVE rejection the server's answer proves nothing landed — the
                // submit-to-record ambiguity is over, so clear the marker rather than blocking
                // sync for the full self-expiry window. A network error proves nothing (the
                // submit may have landed and the response been lost), so the marker stays —
                // mirroring the success path's retained-marker rationale above.
                switch result {
                case .expired, .invalidNote:
                    syncGate.clearBroadcastInFlight()
                case .networkError, .success:
                    break
                }
                throw error
            }
        }

        // The outcome is durably recorded: the submit-to-record window is closed.
        syncGate.clearBroadcastInFlight()
        return result
    }
}

// MARK: - Account-free static utilities

// Hosted in an extension rather than the actor body: neither touches per-account state (both take
// everything they need as parameters), so they sit with the actor for discoverability without
// growing its stateful core.
extension OrchardMigration {
    /// The order-preserving session split behind the synchronizers' account-free
    /// `batchMigrationPcztsForSigning(_:maxActionsPerSession:)`: the welding computes
    /// the per-session COUNTS from the rows' action weights (`MigrationUnsignedTransferPczt.actions`;
    /// upstream `NextFit` — order-preserving greedy, never the estimate's reorder-free optimal
    /// packing), and this re-slices the caller's own ordered array by them, so ids/bytes never
    /// round-trip through the FFI. Static (welding passed in) because the split is account-free —
    /// it weighs caller-held rows, never the wallet database — so it has no per-account instance
    /// counterpart on this actor.
    static func batchPcztsForSigning(
        welding: ZcashRustBackendWelding,
        pczts: [MigrationUnsignedTransferPczt],
        maxActionsPerSession: Int
    ) async throws -> [[MigrationUnsignedTransferPczt]] {
        // A row's `actions` weight outside `UInt32`'s range can only be a caller-constructed
        // value (the CREATE/RE-SERVE rows carry 16/3): reject it as the same caller bug the
        // welding reports for a wrong weight, never trap on the conversion (A7).
        let actionWeights = try pczts.map { pczt -> UInt32 in
            guard let actions = UInt32(exactly: pczt.actions) else {
                throw ZcashError.rustMigrationBatchPcztsByActions(
                    "`batchPcztsForSigning` was given a PCZT row whose `actions` weight (\(pczt.actions)) is outside the FFI's UInt32 range"
                )
            }
            return actions
        }

        let sizes = try await welding.migrationBatchPcztsByActions(
            actions: actionWeights,
            maxActionsPerSession: maxActionsPerSession
        )

        // The FFI contract guarantees the per-session counts sum to the input length; guard it
        // anyway (defensive, like the marshal-layer decode guards) so a drift can never crash the
        // re-slice below with an out-of-bounds range.
        guard sizes.reduce(0, +) == pczts.count else {
            throw ZcashError.rustMigrationBatchPcztsByActions(
                "`migrationBatchPcztsByActions` returned session sizes that do not sum to the batch size"
            )
        }

        var sessions: [[MigrationUnsignedTransferPczt]] = []
        sessions.reserveCapacity(sizes.count)
        var nextIndex = 0
        for size in sizes {
            sessions.append(Array(pczts[nextIndex ..< nextIndex + size]))
            nextIndex += size
        }
        return sessions
    }

    /// The net value swept by an immediate-migration `FfiProposal` before its fee is subtracted:
    /// the total value of the notes it consumes, minus any declared change. A send-max proposal
    /// declares no change (there is nothing left to return), so this is ordinarily just the input
    /// total; the change subtraction is defensive rather than load-bearing.
    private static func sweptPaymentValue(of proposal: FfiProposal) -> Zatoshi {
        proposal.steps.reduce(Zatoshi.zero) { total, step in
            let stepInput = step.inputs.reduce(Zatoshi.zero) { inputTotal, input in
                guard case .receivedOutput(let output) = input.value else {
                    return inputTotal
                }
                return inputTotal + Zatoshi(Int64(output.value))
            }
            let stepChange = step.balance.proposedChange.reduce(Zatoshi.zero) { changeTotal, change in
                changeTotal + Zatoshi(Int64(change.value))
            }
            return total + stepInput - stepChange
        }
    }
}
