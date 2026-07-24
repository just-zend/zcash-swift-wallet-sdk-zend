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
/// ``MigrationBroadcaster``, and a persisted ``MigrationSyncGate`` (the 10-minute post-broadcast
/// privacy buffer plus the overdue-transfer block). The engine owns all migration state, including
/// the committed schedule; the SDK keeps no local copy of the proposal list.
// swiftlint:disable:next type_body_length
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

    /// The post-broadcast privacy buffer: how long sync stays paused after a migration broadcast so
    /// the broadcast is not correlated with a fresh sync. A fixed production value.
    static let privacySyncBufferDuration: TimeInterval = 600

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
    private let transactionSubmitter: any MigrationTransactionSubmitting
    private let networkType: NetworkType
    private let expectedChainName: String
    private let syncGate: MigrationSyncGate
    private let logger: Logger

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
    ///   `MIGRATING.md`); a conflicting re-registration is a process-level host configuration error.
    init(config: Config, sharedBroadcaster: any MigrationBroadcasting) {
        if let activationHeights = config.network.customActivationHeights {
            let cleanRegistration = ZcashRustBackend.setCustomNetwork(
                base: config.network.customNetworkBase ?? config.network.networkType,
                activationHeights
            )
            if !cleanRegistration {
                // A different custom network was already registered in this process. Rust preserves
                // that configuration so existing wallets remain safe, but this migration instance
                // cannot operate with the requested parameters. Fail this process-level configuration
                // error consistently in release and debug builds.
                preconditionFailure(
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

        self.welding = welding
        self.accountUUID = accountUUID
        self.logger = logger
        self.broadcaster = sharedBroadcaster
        self.networkType = config.network.networkType
        self.expectedChainName = (config.network.customNetworkBase ?? config.network.networkType).chainName
        if let transportFactory = sharedBroadcaster as? any MigrationTransportCreating {
            self.transactionSubmitter = LiveMigrationTransactionSubmitter(
                transportFactory: transportFactory,
                logger: logger
            )
        } else {
            self.transactionSubmitter = UnavailableMigrationTransactionSubmitter()
        }
        self.syncGate = MigrationSyncGate(
            directory: config.generalStorageURL,
            accountUUID: accountUUID,
            bufferDuration: OrchardMigration.privacySyncBufferDuration,
            overdueProvider: {
                // Degrade to "not overdue" on any engine error so the reactive gate never crashes.
                (try? await welding.migrationHasOverdueTransfers(for: accountUUID)) ?? false
            },
            logger: logger
        )
    }

    /// Injecting initializer for tests: supply the welding, broadcaster, sync gate (with its test
    /// clock/ticker), and logger directly.
    init(
        welding: ZcashRustBackendWelding,
        accountUUID: AccountUUID,
        broadcaster: any MigrationBroadcasting,
        syncGate: MigrationSyncGate,
        logger: Logger,
        networkType: NetworkType = .testnet,
        expectedChainName: String? = nil,
        transactionSubmitter: (any MigrationTransactionSubmitting)? = nil
    ) {
        self.welding = welding
        self.accountUUID = accountUUID
        self.broadcaster = broadcaster
        self.networkType = networkType
        self.expectedChainName = expectedChainName ?? networkType.chainName
        self.transactionSubmitter = transactionSubmitter ?? UnavailableMigrationTransactionSubmitter()
        self.syncGate = syncGate
        self.logger = logger
    }

    // MARK: - State

    /// The current Orchard -> Ironwood migration state. A high-level read first gives the
    /// Rust-owned delivery runtime its opaque scheduled-run capability to reconcile canonical
    /// chain evidence, then reads the pure compatibility projection.
    func migrationState() async throws -> MigrationState {
        try await reconcileScheduledCanonicalChainBeforeProjection()
        return try await welding.migrationState(for: accountUUID)
    }

    /// One atomic projection of the canonical upstream migration state together with the
    /// Rust-owned delivery run and its opaque claim capabilities. Hosts should use this for
    /// orchestration instead of rebuilding a parallel state machine from several legacy reads.
    func runtimeSnapshot() async throws -> MigrationRuntimeSnapshot {
        try await reconciledRuntimeSnapshot()
    }

    /// Live migration progress, or `nil` when no migration is in progress.
    func migrationProgress() async throws -> MigrationProgress? {
        try await reconcileScheduledCanonicalChainBeforeProjection()
        return try await welding.migrationProgress(for: accountUUID)
    }

    /// The LIVE status of every committed migration transaction, keyed by its stable id -- the
    /// per-transaction detail view behind ``migrationProgress()``'s aggregate summary.
    func transactionStatuses() async throws -> [MigrationTransactionStatus] {
        try await reconcileScheduledCanonicalChainBeforeProjection()
        return try await welding.migrationTransactionStatuses(for: accountUUID)
    }

    /// Keeps low-level state/progress/status FFI reads side-effect free while ensuring the public
    /// orchestration surface observes current chain evidence. Only the Rust-owned runtime can
    /// supply the exact scheduled run capability required by the canonical reconciliation CAS.
    private func reconcileScheduledCanonicalChainBeforeProjection() async throws {
        _ = try await reconciledRuntimeSnapshot()
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

    // MARK: - Migration proposal

    /// The full migration schedule for the spendable Orchard balance.
    func proposeMigrationTransfers() async throws -> MigrationSchedule {
        try await welding.migrationProposeTransfers(for: accountUUID)
    }

    /// Atomically reserves, materializes, submits, and records one SDK-signed immediate migration.
    /// The proposal, sources, destination, expiry, branch, exact transaction, and submission policy
    /// are all sealed by Rust before any bytes can leave the wallet database. Swift never creates an
    /// ordinary send proposal and never records a caller-supplied transaction id. The gross ceiling
    /// is consumed when Rust creates fresh authority. Failed materialization is intentionally
    /// excluded here and requires the recovery-only API plus its snapshot-issued capability.
    func submitImmediateMigration(
        usk: UnifiedSpendingKey,
        maximumGrossAmount: Zatoshi,
        options: MigrationNetworkPrivacyOptions
    ) async throws -> MigrationSubmissionOutcome {
        try await serializedBroadcastFlow {
            let intent = LiveMigrationTransactionSubmitter.submissionIntent(
                options: options,
                networkType: networkType
            )
            let runtime = try await reconciledRuntimeSnapshot()
            if let recovered = try await resumeImmediateSDKSubmissionIfPresent(
                runtime: runtime,
                intent: intent,
                usk: usk
            ) {
                return recovered
            }
            let reserved = try await welding.migrationReserveImmediate(
                signer: .sdk,
                maximumGrossAmount: maximumGrossAmount,
                submission: intent,
                for: accountUUID
            )
            let staged: MigrationClaimHandle
            do {
                staged = try await welding.migrationMaterializeImmediateSDK(
                    claim: reserved,
                    usk: usk,
                    for: accountUUID
                )
            } catch {
                await releaseKnownUnsentClaim(reserved, failure: .materializationFailed)
                throw error
            }
            return try await acquireAndSubmitClaim(staged).outcome
        }
    }

    /// Recovers only the current unexposed immediate SDK-signing materialization failure. It accepts
    /// either an already-authorized run or a legacy row that lacks durable gross authorization. Unlike
    /// ``submitImmediateMigration(usk:maximumGrossAmount:options:)``, this API can never reserve a
    /// new run: the capability must match the fresh hidden account/artifact/signer/revision seal,
    /// and absent, replaced, or advanced state fails closed and requires canonical reentry.
    func recoverFailedImmediateMigration(
        recoveryCapability: ImmediateMigrationRecoveryCapability,
        usk: UnifiedSpendingKey,
        maximumGrossAmount: Zatoshi,
        options: MigrationNetworkPrivacyOptions
    ) async throws -> MigrationSubmissionOutcome {
        try await serializedBroadcastFlow {
            let intent = LiveMigrationTransactionSubmitter.submissionIntent(
                options: options,
                networkType: networkType
            )
            let runtime = try await reconciledRuntimeSnapshot()
            try requireExactRecoverableImmediateMaterializationFailure(
                runtime: runtime,
                signer: .sdk,
                recoveryCapability: recoveryCapability
            )
            guard let delivery = runtime.delivery else {
                throw MigrationDeliveryError.immediateRecoveryStateChanged
            }
            try await requireBoundSubmissionTarget(delivery, matches: intent)

            let reacquired = try await welding.migrationReacquireFailedImmediateMaterialization(
                claim: recoveryCapability.claimHandle,
                signer: .sdk,
                maximumGrossAmount: maximumGrossAmount,
                for: accountUUID
            )
            let staged: MigrationClaimHandle
            do {
                staged = try await welding.migrationMaterializeImmediateSDK(
                    claim: reacquired,
                    usk: usk,
                    for: accountUUID
                )
            } catch {
                await releaseKnownUnsentClaim(reacquired, failure: .materializationFailed)
                throw error
            }
            return try await acquireAndSubmitClaim(staged).outcome
        }
    }

    /// Reserves an external-signer immediate migration and returns only the PCZT Rust atomically
    /// built, proved, and staged under the returned request's opaque claim. Repeating this call
    /// after a process relaunch recovers the same Rust-owned artifact and exact staged PCZT; it
    /// never replaces an externally exposed artifact with a newly planned migration. Failed
    /// materialization is intentionally excluded and requires the recovery-only API.
    func prepareImmediateMigrationForExternalSigning(
        maximumGrossAmount: Zatoshi,
        options: MigrationNetworkPrivacyOptions
    ) async throws -> ImmediateMigrationExternalSigningRequest {
        try await serializedBroadcastFlow {
            let intent = LiveMigrationTransactionSubmitter.submissionIntent(
                options: options,
                networkType: networkType
            )
            if let recovered = try await recoverPreparedImmediateExternalSigning(
                intent: intent
            ) {
                return recovered
            }
            let reserved = try await welding.migrationReserveImmediate(
                signer: .external,
                maximumGrossAmount: maximumGrossAmount,
                submission: intent,
                for: accountUUID
            )
            let staged: MigrationClaimHandle
            do {
                staged = try await welding.migrationPrepareImmediateExternalSigning(
                    claim: reserved,
                    for: accountUUID
                )
            } catch {
                await releaseKnownUnsentClaim(reserved, failure: .materializationFailed)
                throw error
            }
            guard let pczt = try await welding.migrationClaimExternalSigningPCZT(staged) else {
                await releaseKnownUnsentClaim(staged, failure: .materializationFailed)
                throw MigrationDeliveryError.missingExternalSigningPCZT
            }
            return ImmediateMigrationExternalSigningRequest(pczt: pczt, claim: staged)
        }
    }

    /// Recovers only the current unexposed immediate external-signing materialization failure, with
    /// either existing durable authorization or a fresh cap for a legacy row. The caller must return
    /// the capability from the snapshot that rendered the failure. It never falls through to
    /// `migrationReserveImmediate`; a changed runtime must be re-projected by the host first.
    func recoverFailedImmediateMigrationForExternalSigning(
        recoveryCapability: ImmediateMigrationRecoveryCapability,
        maximumGrossAmount: Zatoshi,
        options: MigrationNetworkPrivacyOptions
    ) async throws -> ImmediateMigrationExternalSigningRequest {
        try await serializedBroadcastFlow {
            let intent = LiveMigrationTransactionSubmitter.submissionIntent(
                options: options,
                networkType: networkType
            )
            let runtime = try await reconciledRuntimeSnapshot()
            try requireExactRecoverableImmediateMaterializationFailure(
                runtime: runtime,
                signer: .external,
                recoveryCapability: recoveryCapability
            )
            guard let delivery = runtime.delivery else {
                throw MigrationDeliveryError.immediateRecoveryStateChanged
            }
            try await requireBoundSubmissionTarget(delivery, matches: intent)

            let reacquired = try await welding.migrationReacquireFailedImmediateMaterialization(
                claim: recoveryCapability.claimHandle,
                signer: .external,
                maximumGrossAmount: maximumGrossAmount,
                for: accountUUID
            )
            let staged: MigrationClaimHandle
            do {
                staged = try await welding.migrationPrepareImmediateExternalSigning(
                    claim: reacquired,
                    for: accountUUID
                )
            } catch {
                await releaseKnownUnsentClaim(reacquired, failure: .materializationFailed)
                throw error
            }
            guard let pczt = try await welding.migrationClaimExternalSigningPCZT(staged) else {
                await releaseKnownUnsentClaim(staged, failure: .materializationFailed)
                throw MigrationDeliveryError.missingExternalSigningPCZT
            }
            return ImmediateMigrationExternalSigningRequest(pczt: pczt, claim: staged)
        }
    }

    /// Merges an external signer's response against the exact staged PCZT, atomically finalizes the
    /// reserved transaction in Rust, then submits and records it through the same claim-owned lane
    /// as SDK signing.
    func submitExternallySignedImmediateMigration(
        request: ImmediateMigrationExternalSigningRequest,
        signedPCZT: Data
    ) async throws -> MigrationSubmissionOutcome {
        try await serializedBroadcastFlow {
            let runtime = try await reconciledRuntimeSnapshot()
            return try await resumeImmediateExternalSubmission(
                runtime: runtime,
                request: request,
                signedPCZT: signedPCZT
            )
        }
    }

    /// Resubmits only the current immediate external-signer artifact after Rust has durably merged
    /// the signature and staged exact transaction bytes. No signer response or process-local
    /// request is accepted, so relaunch recovery cannot re-sign or replace the artifact.
    func resumeStagedImmediateExternalSubmission() async throws -> MigrationSubmissionOutcome {
        try await serializedBroadcastFlow {
            let runtime = try await reconciledRuntimeSnapshot()
            guard case .available = runtime.availability,
                  let delivery = runtime.delivery,
                  delivery.lane == .immediate,
                  delivery.phase == .active,
                  delivery.claims.count == 1,
                  let summary = delivery.claims.first,
                  case .immediate = summary.artifact,
                  summary.signerOwnership == .external,
                  summary.status == .staged,
                  summary.externallyExposed,
                  summary.hasSignedPCZT,
                  summary.hasExactTransaction else {
                throw MigrationDeliveryError.externalSigningClaimUnavailable
            }
            return try await acquireAndSubmitClaim(summary.claimHandle).outcome
        }
    }

    /// The leftover Orchard balance a migration would not cross, when large enough to be worth
    /// offering the user a choice about; `nil` when there is no such residual.
    ///
    /// - Note: Requires at least one completed sync. On a wallet that has never completed a sync (no
    ///   chain tip known) this throws rather than returning `nil`.
    func residualAfterMigration() async throws -> Zatoshi? {
        try await welding.migrationResidualAfterMigration(for: accountUUID)
    }

    /// After strict public migration `Complete`, locks every currently-spendable,
    /// not-already-locked legacy-Orchard note until explicit unlock and returns the total value
    /// locked — the "Lock balance" choice. Rust re-audits exact outputs and clears the provisional
    /// migration owner before acquiring the distinct residual owner. A straight delegation to the
    /// welding lock call, bound to this actor's own account; not broadcast-performing, so it is not
    /// gated by ``serializedBroadcastFlow(_:)``.
    func lockMigrationResidual() async throws -> Zatoshi {
        try await welding.lockMigrationResidual(accountUUID: accountUUID)
    }

    /// Unlocks only outputs held by this account's residual-lock owner — the release half of
    /// ``lockMigrationResidual()`` — and returns the number of outputs unlocked. Migration,
    /// ordinary-PCZT, and foreign-owner locks remain intact. A straight delegation to the welding
    /// unlock call, bound to this actor's own account.
    func unlockMigrationResidual() async throws -> Int {
        try await welding.unlockMigrationResidual(accountUUID: accountUUID)
    }

    /// The multi-run ("rounds") estimate for migrating the whole spendable Orchard balance. A
    /// straight delegation to the welding estimate call, bound to this actor's own account; the
    /// zero-run estimate is a legitimate answer, not an error.
    func estimateMigrationRuns() async throws -> MigrationRunEstimate {
        try await welding.estimateMigrationRuns(accountUUID: accountUUID)
    }

    /// Commits the exact approved SDK-signed schedule and binds its submission policy. If the
    /// current scheduled run is terminal, the requested policy must match the immutable predecessor
    /// policy before Rust atomically rolls it into a successor that inherits that policy. This is
    /// the supported second-and-later-run path and prevents a post-CAS policy mismatch from
    /// stranding the new run.
    func signAndStoreMigrationSchedule(
        _ schedule: MigrationSchedule,
        usk: UnifiedSpendingKey,
        options: MigrationNetworkPrivacyOptions
    ) async throws {
        let runtime = try await reconciledRuntimeSnapshot()
        let intent = LiveMigrationTransactionSubmitter.submissionIntent(
            options: options,
            networkType: networkType
        )
        if Self.isTerminal(runtime.canonical.status) {
            guard let delivery = runtime.delivery, delivery.lane == .scheduled else {
                throw MigrationDeliveryError.scheduledDeliveryRunUnavailable
            }
            try await requireBoundSubmissionTarget(delivery, matches: intent)
            _ = try await welding.migrationRolloverInternalSchedule(
                schedule,
                predecessor: delivery.runHandle,
                usk: usk,
                for: accountUUID
            )
        } else {
            try await welding.migrationSignAndStoreSchedule(schedule, usk: usk, for: accountUUID)
            let committed = try await reconciledRuntimeSnapshot()
            guard let delivery = committed.delivery, delivery.lane == .scheduled else {
                throw MigrationDeliveryError.scheduledDeliveryRunUnavailable
            }
            try await bindSubmissionPolicy(intent, run: delivery.runHandle)
        }
    }

    /// Commits the exact approved external-signer schedule and binds its Rust-validated submission
    /// policy. A terminal predecessor is rolled over atomically; no PCZT bytes are exposed here.
    func commitMigrationScheduleForExternalSigning(
        _ schedule: MigrationSchedule,
        options: MigrationNetworkPrivacyOptions
    ) async throws -> MigrationRuntimeSnapshot {
        let runtime = try await reconciledRuntimeSnapshot()
        let intent = LiveMigrationTransactionSubmitter.submissionIntent(
            options: options,
            networkType: networkType
        )
        if Self.isTerminal(runtime.canonical.status) {
            guard let delivery = runtime.delivery, delivery.lane == .scheduled else {
                throw MigrationDeliveryError.scheduledDeliveryRunUnavailable
            }
            // Rollover atomically inherits the immutable predecessor policy. Validate the caller's
            // requested policy before the CAS so a mismatch cannot install a successor and fail only
            // afterward while trying to rebind it.
            try await requireBoundSubmissionTarget(delivery, matches: intent)
            _ = try await welding.migrationRolloverExternalSchedule(
                schedule,
                predecessor: delivery.runHandle,
                for: accountUUID
            )
        } else {
            let run = try await welding.migrationCommitExternalSchedule(schedule, for: accountUUID)
            try await bindSubmissionPolicy(intent, run: run)
        }
        return try await reconciledRuntimeSnapshot()
    }

    /// Returns the next exact canonical scheduled PCZT that Rust has durably staged for an
    /// external signer. On relaunch, an already-exposed artifact is resumed or reacquired by exact
    /// identity; this method never skips it or replaces it with a new transaction.
    func prepareNextMigrationTransactionForExternalSigning() async throws -> ScheduledMigrationExternalSigningRequest? {
        try await serializedBroadcastFlow {
            let runtime = try await reconciledRuntimeSnapshot()
            guard case .available = runtime.availability else {
                if case .unavailable(let reason) = runtime.availability {
                    throw MigrationDeliveryError.runtimeUnavailable(reason)
                }
                throw MigrationDeliveryError.runtimeUnavailable(.deliveryInconsistent)
            }
            guard let delivery = runtime.delivery, delivery.lane == .scheduled else {
                throw MigrationDeliveryError.scheduledDeliveryRunUnavailable
            }
            guard delivery.phase == .active else { return nil }

            let candidates = delivery.claims
                .compactMap { claim -> (UInt32, MigrationDeliveryClaimSummary)? in
                    guard case .scheduled(let transactionID) = claim.artifact,
                          claim.signerOwnership == .external else {
                        return nil
                    }
                    return (transactionID, claim)
                }
                .sorted { $0.0 < $1.0 }

            // An externally exposed artifact is irrevocable. Recover it before considering any
            // other row. `hasSignedPCZT` means a signer merge already crossed the durable boundary;
            // the submit path will resume canonical advancement/proving instead of merging it again.
            if let (transactionID, exposed) = candidates.first(where: {
                $0.1.externallyExposed &&
                    ($0.1.status == .awaitingExternalSignature ||
                        $0.1.status == .staged ||
                        $0.1.status == .submitting ||
                        $0.1.status == .outcomeUnknown ||
                        $0.1.status == .broadcasted ||
                        $0.1.status == .confirmed)
            }) {
                let recovered: MigrationClaimHandle
                if exposed.status == .awaitingExternalSignature {
                    recovered = try await resumableExternalSigningClaim(exposed.claimHandle)
                } else {
                    // Staged and network-outcome states need no signing lease. Their snapshot handle
                    // identifies the same exact artifact and can only authorize the status-appropriate
                    // submission or resolution transition.
                    recovered = exposed.claimHandle
                }
                return try await externalSigningRequest(transactionID: transactionID, claim: recovered)
            }

            for (transactionID, summary) in candidates {
                switch summary.status {
                case .confirmed, .broadcasted, .expiredUnmined, .externalSigningExpiredUnmined,
                    .staged, .submitting, .outcomeUnknown:
                    continue
                case .materializing, .materializationFailed, .awaitingExternalSignature:
                    break
                }

                let resumed = try await welding.migrationResumeClaim(
                    claim: summary.claimHandle,
                    for: accountUUID
                )
                let active: MigrationClaimHandle?
                if let resumed {
                    active = resumed
                } else {
                    active = try await welding.migrationClaimMaterialization(
                        transactionID: transactionID,
                        signer: .external,
                        run: delivery.runHandle,
                        for: accountUUID
                    )
                }
                guard let active else { continue }
                let staged = try await welding.migrationStageExternalSigningPCZT(
                    claim: active,
                    for: accountUUID
                )
                return try await externalSigningRequest(transactionID: transactionID, claim: staged)
            }
            return nil
        }
    }

    /// Applies the external signer's response to the exact opaque claim, advances the canonical
    /// transaction, proves and stages exact network bytes, and submits through the bound policy.
    func submitExternallySignedMigrationTransaction(
        request: ScheduledMigrationExternalSigningRequest,
        signedPCZT: Data
    ) async throws -> MigrationTransferResult {
        try await serializedBroadcastFlow {
            let runtime = try await reconciledRuntimeSnapshot()
            guard case .available = runtime.availability,
                  let delivery = runtime.delivery,
                  delivery.lane == .scheduled,
                  let summary = delivery.claims.first(where: {
                      $0.artifact == .scheduled(transactionID: request.transactionID) &&
                          $0.signerOwnership == .external
                  }) else {
                throw MigrationDeliveryError.externalSigningClaimUnavailable
            }
            guard let canonicalPCZT = try await welding.migrationClaimExternalSigningPCZT(summary.claimHandle),
                  canonicalPCZT == request.pczt else {
                throw MigrationDeliveryError.externalSigningClaimUnavailable
            }

            switch summary.status {
            case .awaitingExternalSignature:
                let active = try await resumableExternalSigningClaim(summary.claimHandle)
                let statuses = try await welding.migrationTransactionStatuses(for: accountUUID)
                guard let canonical = statuses.first(where: { $0.id == request.transactionID }) else {
                    throw MigrationDeliveryError.externalSigningClaimUnavailable
                }

                let signed: MigrationClaimHandle
                switch (canonical.state, summary.hasSignedPCZT) {
                case (.awaitingSignature, false):
                    let merged = try await welding.migrationStageSignedPCZT(
                        signedPCZT,
                        claim: active,
                        for: accountUUID
                    )
                    signed = try await welding.migrationAdvanceExternalSignature(
                        claim: merged,
                        for: accountUUID
                    )
                case (.awaitingSignature, true):
                    // The signer merge committed but canonical advancement did not. Consume the
                    // already-staged merge; never re-merge caller bytes.
                    signed = try await welding.migrationAdvanceExternalSignature(
                        claim: active,
                        for: accountUUID
                    )
                case (.signed, true):
                    // Relaunch after canonical AwaitingSignature -> Signed but before proving.
                    // The fresh runtime claim contains the durable merge and can resume proof.
                    signed = active
                default:
                    throw MigrationDeliveryError.externalSigningClaimUnavailable
                }

                let staged = try await welding.migrationProveClaim(claim: signed, for: accountUUID)
                return try await acquireAndSubmitClaim(staged).legacyTransferResult
            case .staged:
                guard summary.hasExactTransaction else {
                    throw MigrationDeliveryError.missingExactTransaction
                }
                return try await acquireAndSubmitClaim(summary.claimHandle).legacyTransferResult
            case .submitting:
                guard summary.activeClaimKind == .submission,
                      let resumed = try await welding.migrationResumeClaim(
                          claim: summary.claimHandle,
                          for: accountUUID
                      ) else {
                    return .networkError(retryable: false)
                }
                return try await submitActiveClaim(resumed).legacyTransferResult
            case .outcomeUnknown:
                let reconciled = try await reconcileUnknownSubmission(summary)
                return try legacyTransferResult(for: reconciled ?? summary)
            case .broadcasted, .confirmed:
                return try legacyTransferResult(for: summary)
            case .expiredUnmined, .externalSigningExpiredUnmined:
                return .networkError(retryable: false)
            case .materializing, .materializationFailed:
                throw MigrationDeliveryError.externalSigningClaimUnavailable
            }
        }
    }

    /// Resubmits one exact scheduled external-signer transaction whose signer response, proof, and
    /// network bytes are already durable. The transaction id is a selector only; Rust's fresh
    /// runtime claim supplies all mutation authority and no PCZT bytes are accepted from Swift.
    func resumeStagedScheduledExternalSubmission(
        transactionID: UInt32
    ) async throws -> MigrationTransferResult {
        try await serializedBroadcastFlow {
            let runtime = try await reconciledRuntimeSnapshot()
            guard case .available = runtime.availability,
                  let delivery = runtime.delivery,
                  delivery.lane == .scheduled,
                  delivery.phase == .active,
                  let summary = delivery.claims.first(where: {
                      $0.artifact == .scheduled(transactionID: transactionID) &&
                          $0.signerOwnership == .external
                  }),
                  summary.status == .staged,
                  summary.externallyExposed,
                  summary.hasSignedPCZT,
                  summary.hasExactTransaction else {
                throw MigrationDeliveryError.externalSigningClaimUnavailable
            }
            return try await acquireAndSubmitClaim(summary.claimHandle).legacyTransferResult
        }
    }

    /// Pauses the current delivery run without releasing reservations or exposed artifacts.
    func pauseDelivery() async throws -> MigrationRuntimeSnapshot {
        let delivery = try await currentDelivery()
        _ = try await welding.migrationPauseDelivery(run: delivery.runHandle, for: accountUUID)
        return try await reconciledRuntimeSnapshot()
    }

    /// Resumes the current paused delivery run.
    func resumeDelivery() async throws -> MigrationRuntimeSnapshot {
        let delivery = try await currentDelivery()
        _ = try await welding.migrationResumeDelivery(run: delivery.runHandle, for: accountUUID)
        return try await reconciledRuntimeSnapshot()
    }

    /// Begins safe abandonment while Rust retains every possibly exposed artifact and source.
    func beginAbandonment() async throws -> MigrationRuntimeSnapshot {
        let delivery = try await currentDelivery()
        _ = try await welding.migrationBeginAbandonment(run: delivery.runHandle, for: accountUUID)
        return try await reconciledRuntimeSnapshot()
    }

    /// Finishes abandonment only after Rust proves all exposed artifacts terminally safe.
    func finishAbandonment() async throws -> MigrationRuntimeSnapshot {
        let delivery = try await currentDelivery()
        _ = try await welding.migrationFinishAbandonment(run: delivery.runHandle, for: accountUUID)
        return try await reconciledRuntimeSnapshot()
    }

    /// Rebuilds exactly one positively expired SDK-signed attempt under its generation-bound
    /// claim. The regular execute-next API resumes and proves the replacement.
    func rebuildExpiredTransfer(transactionID: UInt32, usk: UnifiedSpendingKey) async throws -> MigrationRuntimeSnapshot {
        let summary = try await expiredTransfer(transactionID: transactionID, signer: .sdk)
        _ = try await welding.migrationRebuildExpiredTransfer(
            claim: summary.claimHandle,
            signer: .sdk,
            usk: usk,
            for: accountUUID
        )
        return try await reconciledRuntimeSnapshot()
    }

    /// Rebuilds exactly one positively expired external-signer attempt and atomically stages its
    /// replacement PCZT before exposing it.
    func rebuildExpiredTransferForExternalSigning(
        transactionID: UInt32
    ) async throws -> ScheduledMigrationExternalSigningRequest {
        let summary = try await expiredTransfer(transactionID: transactionID, signer: .external)
        let rebuilt = try await welding.migrationRebuildExpiredTransfer(
            claim: summary.claimHandle,
            signer: .external,
            usk: nil,
            for: accountUUID
        )
        let staged = try await welding.migrationStageExternalSigningPCZT(
            claim: rebuilt,
            for: accountUUID
        )
        return try await externalSigningRequest(transactionID: transactionID, claim: staged)
    }

    // MARK: - Background execution

    /// Executes at most one Rust-authorized scheduled delivery action and returns its legacy result
    /// projection, or `nil` when no SDK-signer artifact is currently actionable.
    ///
    /// The runtime snapshot, delivery run, transaction identity, claim lease, canonical PCZT,
    /// exact network bytes, txid, expiry, consensus branch, and submission policy are all owned by
    /// Rust. Swift supplies only raw transport intent, asks Rust for an opaque claim, and submits
    /// the exact bytes projected from that claim. It never fetches an unclaimed prepared
    /// transaction and never reports a caller-authored txid after broadcast.
    ///
    /// Claim-exposure and broadcast flows are single-flight on this actor. When another scheduled
    /// external-signing or broadcast-performing call is in flight, this call waits for it to finish
    /// and only then reads the Rust-owned runtime again, so a concurrent call cannot reuse authority
    /// for the in-flight artifact. It never throws on contention.
    ///
    /// - Important: This method must run only in a session that does **not** also sync. This actor
    ///   does not check sync state itself; the `Synchronizer` surface in front of it adds an
    ///   advisory point-in-time guard (``ZcashError/migrationBroadcastDuringSync``) plus the
    ///   10-minute privacy gate (see ``isSyncBlocked()``) — neither is a hard mutual-exclusion
    ///   lock, so hosts must still sequence sync and broadcast sessions.
    func executeNextPendingTransfer(options: MigrationNetworkPrivacyOptions) async throws -> MigrationTransferResult? {
        try await serializedBroadcastFlow { () async throws -> MigrationTransferResult? in
            var runtime = try await reconciledRuntimeSnapshot()
            guard let initialDelivery = runtime.delivery, initialDelivery.lane == .scheduled else {
                return nil
            }

            switch runtime.availability {
            case .available, .unavailable(.submissionPolicyMissing):
                break
            case .unavailable(let reason):
                throw MigrationDeliveryError.runtimeUnavailable(reason)
            }

            let intent = LiveMigrationTransactionSubmitter.submissionIntent(
                options: options,
                networkType: networkType
            )
            try await bindSubmissionPolicy(intent, run: initialDelivery.runHandle)
            runtime = try await reconciledRuntimeSnapshot()
            guard case .available = runtime.availability,
                  let delivery = runtime.delivery,
                  delivery.lane == .scheduled,
                  delivery.phase == .active else {
                if case .unavailable(let reason) = runtime.availability {
                    throw MigrationDeliveryError.runtimeUnavailable(reason)
                }
                return nil
            }

            // Ambiguous outcomes are resolution-only. Never turn them back into submission
            // authority; Rust reconciles them exclusively from wallet chain evidence.
            if let unknown = delivery.claims.first(where: { $0.status == .outcomeUnknown }),
               let resolution = try await welding.migrationClaimOutcomeResolution(
                   claim: unknown.claimHandle,
                   for: accountUUID
               ) {
                _ = try await welding.migrationReconcileSubmission(
                    claim: resolution,
                    for: accountUUID
                )
                return nil
            }

            // Resume a still-live same-process claim first. After relaunch, Rust's clock-session
            // recovery makes a possibly observed submission resolution-only instead.
            if let submitting = delivery.claims.first(where: {
                $0.signerOwnership == .sdk &&
                    $0.status == .submitting &&
                    $0.activeClaimKind == .submission
            }), let resumed = try await welding.migrationResumeClaim(
                claim: submitting.claimHandle,
                for: accountUUID
            ) {
                return try await submitActiveClaim(resumed).legacyTransferResult
            }

            if let staged = delivery.claims.first(where: {
                $0.signerOwnership == .sdk &&
                    $0.status == .staged &&
                    $0.hasExactTransaction
            }) {
                return try await acquireAndSubmitClaim(staged.claimHandle).legacyTransferResult
            }

            // The canonical engine decides readiness. Asking for a materialization claim on a
            // not-due/dependency-blocked transaction simply returns nil without host scheduling.
            let scheduled = delivery.claims.compactMap { claim -> (UInt32, MigrationDeliveryClaimSummary)? in
                guard case .scheduled(let transactionID) = claim.artifact,
                      claim.signerOwnership == .sdk else {
                    return nil
                }
                return (transactionID, claim)
            }.sorted { $0.0 < $1.0 }

            for (transactionID, summary) in scheduled {
                let materialization: MigrationClaimHandle?
                if summary.status == .materializing,
                   summary.activeClaimKind == .materialization {
                    materialization = try await welding.migrationResumeClaim(
                        claim: summary.claimHandle,
                        for: accountUUID
                    )
                } else if summary.status == .confirmed ||
                    summary.status == .broadcasted ||
                    summary.status == .expiredUnmined ||
                    summary.status == .externalSigningExpiredUnmined ||
                    summary.status == .awaitingExternalSignature {
                    materialization = nil
                } else {
                    materialization = try await welding.migrationClaimMaterialization(
                        transactionID: transactionID,
                        signer: .sdk,
                        run: delivery.runHandle,
                        for: accountUUID
                    )
                }

                guard let materialization else { continue }
                let staged: MigrationClaimHandle
                do {
                    staged = try await welding.migrationProveClaim(
                        claim: materialization,
                        for: accountUUID
                    )
                } catch {
                    await releaseKnownUnsentClaim(materialization, failure: .materializationFailed)
                    throw error
                }
                return try await acquireAndSubmitClaim(staged).legacyTransferResult
            }

            return nil
        }
    }

    // MARK: - Sync coordination

    /// Whether ordinary wallet sync should currently be paused for this migration.
    ///
    /// `true` when a transfer is overdue **or** the post-broadcast privacy buffer has not yet
    /// elapsed. The overdue query is engine-backed; if it throws, this degrades to the persisted
    /// gate-file (privacy-buffer) state rather than crashing the app's sync gating.
    ///
    /// - Note: The gate is per-account (by file name). An app running several migrating accounts must
    ///   consult each account's `OrchardMigration`; this instance answers only for its bound account.
    /// - Note: Always consults the overdue query fresh (`await`s the engine), unlike
    ///   ``syncBlockedStream``'s synchronous subscribe-time seed -- see that property's documented
    ///   caveat about the two briefly disagreeing right after relaunch.
    func isSyncBlocked() async -> Bool {
        let hasOverdue = (try? await welding.migrationHasOverdueTransfers(for: accountUUID)) ?? false
        return syncGate.currentlyBlocked(hasOverdue: hasOverdue)
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
    ///   privacy buffer, not overdue transfers -- overdue detection needs the engine query, which is
    ///   asynchronous. On relaunch with an overdue transfer and no active buffer, that first emission
    ///   can therefore briefly read `false` while ``isSyncBlocked()`` already reads `true`; the stream
    ///   corrects itself with its first asynchronous re-evaluation (the next tick, or sooner if a
    ///   broadcast happens first). A subscriber that must be correct from its very first value should
    ///   pair this stream with an initial ``isSyncBlocked()`` call rather than trusting the seed alone.
    nonisolated var syncBlockedStream: AnyPublisher<Bool, Never> {
        syncGate.blockedStream
    }

    // MARK: - On-launch reconciliation

    /// Whether any scheduled transfer is past its send height but not yet broadcast.
    func hasOverdueTransfers() async throws -> Bool {
        try await welding.migrationHasOverdueTransfers(for: accountUUID)
    }

    /// Whether the migration is in an invalid state (spendable Orchard remains but no scheduled
    /// transfer covers it).
    func hasInvalidTransfers() async throws -> Bool {
        try await welding.migrationHasInvalidTransfers(for: accountUUID)
    }

    /// The migration engine's next height-due pending transfer proposal, or `nil` when nothing is
    /// pending.
    ///
    /// A straight readback of the stored run's next due-and-unbroadcast transfer — deliberately
    /// with **no** local time-shifting of `nextExecutableAfterHeight` (the Android implementation
    /// clamps it to `now + interval` with a known unit bug the SDK does not port). The host re-arms
    /// its own background execution window from the returned proposal's heights; the local decision
    /// not to broadcast before that window *is* the reschedule, and the ZIP 318 "re-spread the
    /// remainder" property is carried by the delivery machinery itself (one broadcast per session,
    /// the 10-minute privacy buffer between sessions). `nil` means there is nothing to re-arm (no
    /// stored run, the run is terminal, or only preparation transactions are pending).
    /// - Throws: `rustMigrationPendingTransferProposal` if the engine returns an error.
    func rescheduleOverdueTransfer() async throws -> MigrationTransferProposal? {
        try await welding.migrationPendingTransferProposal(for: accountUUID)
    }

    // MARK: - Private

    private static func isTerminal(_ status: MigrationCanonicalStatus?) -> Bool {
        status == .complete || status == .failed
    }

    /// Returns a runtime projection that is never older than the scheduled canonical-chain CAS
    /// performed by this call. Immediate runs have no scheduled canonical state and are returned
    /// directly. Every high-level runtime operation uses this helper so a mined predecessor cannot
    /// be mistaken for a still-active run merely because the caller did not make a state read first.
    private func reconciledRuntimeSnapshot() async throws -> MigrationRuntimeSnapshot {
        let runtime = try await welding.migrationRuntimeSnapshot(for: accountUUID)
        guard let delivery = runtime.delivery, delivery.lane == .scheduled else {
            return runtime
        }
        // A missing policy is the only unavailable state that this layer is authorized to repair.
        // Every other unavailable projection is fail-closed: in particular, do not let a read or a
        // high-level operation acquire canonical-mutation authority before it reports the persisted
        // reason to its caller.
        switch runtime.availability {
        case .available, .unavailable(.submissionPolicyMissing):
            break
        case .unavailable:
            return runtime
        }
        _ = try await welding.migrationReconcileCanonicalChain(
            run: delivery.runHandle,
            for: accountUUID
        )
        return try await welding.migrationRuntimeSnapshot(for: accountUUID)
    }

    /// Binds raw host intent and verifies the returned Rust capability actually carries the
    /// normalized immutable target. Policy-validation failures are durable Rust state and return a
    /// fresh handle rather than an FFI error, so ignoring this projection would make schedule setup
    /// appear successful while leaving the run permanently unavailable.
    private func bindSubmissionPolicy(
        _ intent: MigrationSubmissionIntent,
        run: MigrationRunHandle
    ) async throws {
        let bound = try await welding.migrationBindSubmissionPolicy(
            intent,
            run: run,
            for: accountUUID
        )
        guard let target = try await welding.migrationBoundSubmissionTarget(for: bound),
              Self.submissionTarget(target, matches: intent) else {
            throw MigrationDeliveryError.runtimeUnavailable(.submissionPolicyMismatch)
        }
    }

    /// Requires that raw host intent matches the normalized immutable policy already owned by a
    /// run. This check grants no mutation authority. Rollover uses it before its atomic CAS because
    /// the successor deliberately inherits the predecessor policy in the same SQLite transaction.
    private func requireBoundSubmissionTarget(
        _ delivery: MigrationDeliverySnapshot,
        matches intent: MigrationSubmissionIntent
    ) async throws {
        guard delivery.hasSubmissionPolicy,
              let target = try await welding.migrationBoundSubmissionTarget(for: delivery.runHandle) else {
            throw MigrationDeliveryError.runtimeUnavailable(.submissionPolicyMissing)
        }
        guard Self.submissionTarget(target, matches: intent) else {
            throw MigrationDeliveryError.runtimeUnavailable(.submissionPolicyMismatch)
        }
    }

    /// Resumes an immediate SDK-signed run from durable Rust state before any new reservation is
    /// attempted. Only `.staged` or a still-live `.submitting` claim may reach the transport; an
    /// ambiguous prior attempt is resolution-only and never converted back into submission power.
    private func resumeImmediateSDKSubmissionIfPresent(
        runtime: MigrationRuntimeSnapshot,
        intent: MigrationSubmissionIntent,
        usk: UnifiedSpendingKey
    ) async throws -> MigrationSubmissionOutcome? {
        guard let delivery = runtime.delivery else { return nil }
        guard delivery.lane == .immediate else { return nil }
        guard delivery.phase == .active else {
            throw MigrationDeliveryError.claimUnavailable
        }
        try await requireBoundSubmissionTarget(delivery, matches: intent)
        guard let summary = delivery.claims.first(where: {
            if case .immediate = $0.artifact {
                return $0.signerOwnership == .sdk
            }
            return false
        }) else {
            throw MigrationDeliveryError.claimUnavailable
        }
        guard runtime.availability == .available else {
            if case .unavailable(let reason) = runtime.availability {
                throw MigrationDeliveryError.runtimeUnavailable(reason)
            }
            throw MigrationDeliveryError.runtimeUnavailable(.deliveryInconsistent)
        }

        switch summary.status {
        case .materializing:
            guard summary.activeClaimKind == .materialization,
                  let resumed = try await welding.migrationResumeClaim(
                      claim: summary.claimHandle,
                      for: accountUUID
                  ) else {
                throw MigrationDeliveryError.claimUnavailable
            }
            let staged: MigrationClaimHandle
            do {
                staged = try await welding.migrationMaterializeImmediateSDK(
                    claim: resumed,
                    usk: usk,
                    for: accountUUID
                )
            } catch {
                await releaseKnownUnsentClaim(resumed, failure: .materializationFailed)
                throw error
            }
            return try await acquireAndSubmitClaim(staged).outcome
        case .staged:
            guard summary.hasExactTransaction else {
                throw MigrationDeliveryError.missingExactTransaction
            }
            return try await acquireAndSubmitClaim(summary.claimHandle).outcome
        case .submitting:
            guard summary.activeClaimKind == .submission,
                  let resumed = try await welding.migrationResumeClaim(
                      claim: summary.claimHandle,
                      for: accountUUID
                  ) else {
                return .unknown
            }
            return try await submitActiveClaim(resumed).outcome
        case .outcomeUnknown:
            let reconciled = try await reconcileUnknownSubmission(summary)
            return submissionOutcome(for: reconciled ?? summary)
        case .broadcasted, .confirmed:
            return .accepted
        case .expiredUnmined, .externalSigningExpiredUnmined:
            return .unknown
        case .materializationFailed:
            // Failed materialization is a recovery-only capability domain. Keeping it out of this
            // create-or-resume method prevents stale retry intent from falling through to reserve.
            throw MigrationDeliveryError.claimUnavailable
        case .awaitingExternalSignature:
            throw MigrationDeliveryError.claimUnavailable
        }
    }

    /// Continues the immediate external-signer lane from the exact runtime artifact. The request's
    /// public PCZT is matched against Rust's canonical staged bytes before its opaque handle is
    /// ignored in favor of the fresh runtime handle, which is what makes process relaunch safe.
    private func resumeImmediateExternalSubmission(
        runtime: MigrationRuntimeSnapshot,
        request: ImmediateMigrationExternalSigningRequest,
        signedPCZT: Data
    ) async throws -> MigrationSubmissionOutcome {
        guard case .available = runtime.availability,
              let delivery = runtime.delivery,
              delivery.lane == .immediate,
              delivery.phase == .active,
              let summary = delivery.claims.first(where: {
                  if case .immediate = $0.artifact {
                      return $0.signerOwnership == .external
                  }
                  return false
              }) else {
            throw MigrationDeliveryError.externalSigningClaimUnavailable
        }
        guard let canonicalPCZT = try await welding.migrationClaimExternalSigningPCZT(summary.claimHandle),
              canonicalPCZT == request.pczt else {
            throw MigrationDeliveryError.externalSigningClaimUnavailable
        }

        switch summary.status {
        case .awaitingExternalSignature:
            let active = try await resumableExternalSigningClaim(summary.claimHandle)
            let signed: MigrationClaimHandle
            if summary.hasSignedPCZT {
                // The merge is already durable. Finalization consumes that exact merge and must not
                // inspect or persist the caller's retry bytes again.
                signed = active
            } else {
                signed = try await welding.migrationStageSignedPCZT(
                    signedPCZT,
                    claim: active,
                    for: accountUUID
                )
            }
            let staged = try await welding.migrationFinalizeImmediateExternalSigning(
                claim: signed,
                for: accountUUID
            )
            return try await acquireAndSubmitClaim(staged).outcome
        case .staged:
            guard summary.hasSignedPCZT, summary.hasExactTransaction else {
                throw MigrationDeliveryError.externalSigningClaimUnavailable
            }
            return try await acquireAndSubmitClaim(summary.claimHandle).outcome
        case .submitting:
            guard summary.activeClaimKind == .submission,
                  let resumed = try await welding.migrationResumeClaim(
                      claim: summary.claimHandle,
                      for: accountUUID
                  ) else {
                return .unknown
            }
            return try await submitActiveClaim(resumed).outcome
        case .outcomeUnknown:
            let reconciled = try await reconcileUnknownSubmission(summary)
            return submissionOutcome(for: reconciled ?? summary)
        case .broadcasted, .confirmed:
            return .accepted
        case .expiredUnmined, .externalSigningExpiredUnmined:
            return .unknown
        case .materializing, .materializationFailed:
            throw MigrationDeliveryError.externalSigningClaimUnavailable
        }
    }

    /// Uses only outcome-resolution authority, then returns the same artifact from a fresh runtime
    /// projection. A missing resolution lease is a harmless concurrent-worker outcome.
    private func reconcileUnknownSubmission(
        _ summary: MigrationDeliveryClaimSummary
    ) async throws -> MigrationDeliveryClaimSummary? {
        if let resolution = try await welding.migrationClaimOutcomeResolution(
            claim: summary.claimHandle,
            for: accountUUID
        ) {
            _ = try await welding.migrationReconcileSubmission(
                claim: resolution,
                for: accountUUID
            )
        }
        return try await reconciledRuntimeSnapshot().delivery?.claims.first(where: {
            $0.artifact == summary.artifact && $0.signerOwnership == summary.signerOwnership
        })
    }

    private func submissionOutcome(for summary: MigrationDeliveryClaimSummary) -> MigrationSubmissionOutcome {
        switch summary.status {
        case .broadcasted, .confirmed:
            return .accepted
        case .materializing, .materializationFailed, .awaitingExternalSignature, .staged:
            return .knownUnsent
        case .submitting, .outcomeUnknown, .expiredUnmined, .externalSigningExpiredUnmined:
            return .unknown
        }
    }

    private func legacyTransferResult(
        for summary: MigrationDeliveryClaimSummary
    ) throws -> MigrationTransferResult {
        switch summary.status {
        case .broadcasted, .confirmed:
            guard let txid = summary.txid else {
                throw MigrationDeliveryError.missingTransactionID
            }
            return .success(txId: txid.toHexStringTxId())
        case .staged:
            return .networkError(retryable: true)
        case .materializing, .materializationFailed, .awaitingExternalSignature, .submitting,
            .outcomeUnknown, .expiredUnmined, .externalSigningExpiredUnmined:
            return .networkError(retryable: false)
        }
    }

    private func currentDelivery() async throws -> MigrationDeliverySnapshot {
        let runtime = try await reconciledRuntimeSnapshot()
        guard let delivery = runtime.delivery else {
            throw MigrationDeliveryError.deliveryRunUnavailable
        }
        return delivery
    }

    private func expiredTransfer(
        transactionID: UInt32,
        signer: MigrationSignerOwnership
    ) async throws -> MigrationDeliveryClaimSummary {
        let runtime = try await reconciledRuntimeSnapshot()
        guard case .available = runtime.availability,
              let delivery = runtime.delivery,
              delivery.lane == .scheduled,
              let summary = delivery.claims.first(where: {
                  guard case .scheduled(let candidateID) = $0.artifact else { return false }
                  return candidateID == transactionID &&
                      $0.signerOwnership == signer &&
                      ($0.status == .expiredUnmined || $0.status == .externalSigningExpiredUnmined)
              }) else {
            throw MigrationDeliveryError.expiredTransferUnavailable(transactionID: transactionID)
        }
        return summary
    }

    private func resumableExternalSigningClaim(
        _ claim: MigrationClaimHandle
    ) async throws -> MigrationClaimHandle {
        let resumed: MigrationClaimHandle?
        do {
            resumed = try await welding.migrationResumeClaim(claim: claim, for: accountUUID)
        } catch {
            resumed = nil
        }
        if let resumed {
            return resumed
        }
        if let reacquired = try await welding.migrationReacquireExternalSigning(
            claim: claim,
            for: accountUUID
        ) {
            return reacquired
        }
        throw MigrationDeliveryError.externalSigningClaimUnavailable
    }

    private func externalSigningRequest(
        transactionID: UInt32,
        claim: MigrationClaimHandle
    ) async throws -> ScheduledMigrationExternalSigningRequest {
        guard let pczt = try await welding.migrationClaimExternalSigningPCZT(claim) else {
            throw MigrationDeliveryError.missingExternalSigningPCZT
        }
        return ScheduledMigrationExternalSigningRequest(
            transactionID: transactionID,
            pczt: pczt,
            claim: claim
        )
    }

    private struct ClaimSubmissionResult {
        let outcome: MigrationSubmissionOutcome
        let transactionID: Data

        var legacyTransferResult: MigrationTransferResult {
            switch outcome {
            case .accepted:
                return .success(txId: transactionID.toHexStringTxId())
            case .knownUnsent:
                return .networkError(retryable: true)
            case .unknown:
                // Retrying an ambiguous submission could reveal or duplicate the exact
                // transaction. Rust keeps it resolution-only until scanning settles it.
                return .networkError(retryable: false)
            }
        }
    }

    /// Recovers a Rust-staged external-signing artifact before a new immediate reservation is
    /// attempted. Runtime-projected handles are deliberately used instead of any handle retained
    /// by this actor, so this path also models a new SDK process over the same wallet database.
    private func recoverPreparedImmediateExternalSigning(
        intent: MigrationSubmissionIntent
    ) async throws -> ImmediateMigrationExternalSigningRequest? {
        let runtime = try await reconciledRuntimeSnapshot()
        guard let delivery = runtime.delivery else {
            return nil
        }
        guard delivery.lane == .immediate else {
            return nil
        }
        guard delivery.phase == .active else {
            throw MigrationDeliveryError.externalSigningClaimUnavailable
        }

        guard let summary = delivery.claims.first(where: { claim in
            guard case .immediate = claim.artifact else { return false }
            return claim.signerOwnership == .external
        }) else {
            // An immediate run already owns the sources. It may be an SDK-signer run or may have
            // advanced past signing; either way, starting a replacement external run is unsafe.
            throw MigrationDeliveryError.externalSigningClaimUnavailable
        }
        guard runtime.availability == .available else {
            if case .unavailable(let reason) = runtime.availability {
                throw MigrationDeliveryError.runtimeUnavailable(reason)
            }
            throw MigrationDeliveryError.runtimeUnavailable(.deliveryInconsistent)
        }
        try await requireBoundSubmissionTarget(delivery, matches: intent)

        let recoveredClaim: MigrationClaimHandle
        switch summary.status {
        case .materializationFailed:
            // Failed materialization must enter through the non-fallthrough recovery-only API.
            throw MigrationDeliveryError.externalSigningClaimUnavailable
        case .awaitingExternalSignature:
            guard summary.externallyExposed else {
                throw MigrationDeliveryError.externalSigningClaimUnavailable
            }
            // A same-process snapshot can still carry a live token. After relaunch, Rust rejects or
            // returns nil for that clock-session token and atomically reacquires a bounded token for
            // this exact externally exposed artifact without replanning it.
            recoveredClaim = try await resumableExternalSigningClaim(summary.claimHandle)
        case .staged, .submitting, .outcomeUnknown, .broadcasted, .confirmed, .expiredUnmined:
            guard summary.externallyExposed else {
                throw MigrationDeliveryError.externalSigningClaimUnavailable
            }
            // Return the same public PCZT plus a fresh runtime-projected artifact handle. The submit
            // API branches on durable status and never reapplies the signer response in these states.
            recoveredClaim = summary.claimHandle
        case .materializing, .externalSigningExpiredUnmined:
            throw MigrationDeliveryError.externalSigningClaimUnavailable
        }

        guard let pczt = try await welding.migrationClaimExternalSigningPCZT(recoveredClaim) else {
            throw MigrationDeliveryError.missingExternalSigningPCZT
        }
        return ImmediateMigrationExternalSigningRequest(pczt: pczt, claim: recoveredClaim)
    }

    /// Swift only routes a retry when the sanitized runtime projection proves the artifact is the
    /// same known-unsent, unexposed failure. Rust repeats this predicate against the opaque handle
    /// and persisted row before atomically checking the current gross ceiling and minting a token.
    private static func isRetryableImmediateMaterializationFailure(
        _ summary: MigrationDeliveryClaimSummary,
        signer: MigrationSignerOwnership
    ) -> Bool {
        guard case .immediate = summary.artifact else { return false }
        return summary.signerOwnership == signer &&
            summary.status == .materializationFailed &&
            summary.activeClaimKind == nil &&
            !summary.externallyExposed &&
            !summary.hasSignedPCZT &&
            !summary.hasExactTransaction &&
            summary.txid == nil &&
            matchesRetryableMaterializationFailure(summary.lastError)
    }

    /// Selects the only artifact accepted by the recovery-only APIs. The runtime state check is
    /// deliberately separate from the claim predicate so callers can distinguish stale canonical
    /// state from a malformed/wrong-signer claim without ever attempting a fresh reservation.
    private func requireExactRecoverableImmediateMaterializationFailure(
        runtime: MigrationRuntimeSnapshot,
        signer: MigrationSignerOwnership,
        recoveryCapability: ImmediateMigrationRecoveryCapability
    ) throws {
        guard recoveryCapability.account == accountUUID else {
            throw MigrationDeliveryError.immediateRecoveryStateChanged
        }
        let hasRecoveryAvailability = runtime.availability == .available
            || runtime.availability == .unavailable(.missingSpendAuthorization)
        guard hasRecoveryAvailability,
              let delivery = runtime.delivery,
              delivery.lane == .immediate,
              delivery.phase == .active,
              delivery.hasSubmissionPolicy,
              delivery.policyValidationFailure == nil,
              delivery.claims.count == 1 else {
            throw MigrationDeliveryError.immediateRecoveryStateChanged
        }
        guard recoveryCapability.signerOwnership == signer,
              let summary = delivery.claims.first,
              Self.isRetryableImmediateMaterializationFailure(summary, signer: signer) else {
            if signer == .external {
                throw MigrationDeliveryError.externalSigningClaimUnavailable
            }
            throw MigrationDeliveryError.claimUnavailable
        }
        guard runtime.immediateMigrationRecoveryCapability == recoveryCapability else {
            throw MigrationDeliveryError.immediateRecoveryStateChanged
        }
    }

    private static func matchesRetryableMaterializationFailure(
        _ failure: MigrationDeliveryFailureReason?
    ) -> Bool {
        switch failure {
        case .materializationFailed, .materializationLeaseExpired, .signingCancelled:
            return true
        case .transportSetupFailed, .transportDidNotBegin, .submissionLeaseExpired,
            .transportOutcomeUnknown, nil:
            return false
        }
    }

    /// Compares app input only with Rust's normalized, already-bound target. This check grants no
    /// authority; it merely prevents a relaunch caller from accidentally recovering a request
    /// whose eventual submission would use different privacy or endpoint options.
    private static func submissionTarget(
        _ target: MigrationBoundSubmissionTarget,
        matches intent: MigrationSubmissionIntent
    ) -> Bool {
        guard target.transport == intent.transport,
              let endpoint = try? LiveMigrationTransactionSubmitter.endpoint(for: target) else {
            return false
        }
        return LiveMigrationTransactionSubmitter.endpointIdentity(endpoint) == intent.endpoint
    }

    /// Acquires submission authority for exact staged bytes, then submits only those bytes.
    private func acquireAndSubmitClaim(
        _ stagedClaim: MigrationClaimHandle
    ) async throws -> ClaimSubmissionResult {
        guard let activeClaim = try await welding.migrationClaimSubmission(
            claim: stagedClaim,
            for: accountUUID
        ) else {
            throw MigrationDeliveryError.claimUnavailable
        }
        return try await submitActiveClaim(activeClaim)
    }

    /// Submits only the exact bytes projected from `activeClaim`. Once the transport method
    /// returns, the endpoint has observed a submission attempt even when Rust classifies it as
    /// known-unsent, so the privacy gate starts before durable outcome recording on every returned
    /// outcome. A thrown submitter error is guaranteed to precede the submit RPC and releases only
    /// Rust-validated known-unsent authority.
    private func submitActiveClaim(
        _ claimed: MigrationClaimHandle
    ) async throws -> ClaimSubmissionResult {
        var activeClaim = claimed
        let target: MigrationBoundSubmissionTarget
        let rawTransaction: Data
        let transactionID: Data
        let expiryHeight: BlockHeight
        let branchID: UInt32
        do {
            let run = try await welding.migrationClaimRun(activeClaim)
            guard let boundTarget = try await welding.migrationBoundSubmissionTarget(for: run) else {
                throw MigrationDeliveryError.submissionTargetUnavailable
            }
            guard let exactTransaction = try await welding.migrationClaimExactTransaction(activeClaim) else {
                throw MigrationDeliveryError.missingExactTransaction
            }
            guard let exactTransactionID = try await welding.migrationClaimTransactionID(activeClaim) else {
                throw MigrationDeliveryError.missingTransactionID
            }
            target = boundTarget
            rawTransaction = exactTransaction
            transactionID = exactTransactionID
            expiryHeight = try await welding.migrationClaimExpiryHeight(activeClaim)
            branchID = try await welding.migrationClaimConsensusBranchID(activeClaim)
        } catch {
            await releaseKnownUnsentClaim(activeClaim, failure: .transportSetupFailed)
            throw error
        }
        let transaction = EncodedTransaction(transactionId: transactionID, raw: rawTransaction)

        let outcome: MigrationSubmissionOutcome
        do {
            outcome = try await transactionSubmitter.submit(
                transaction: transaction,
                expiryHeight: expiryHeight,
                target: target,
                expectedChainName: expectedChainName,
                transactionConsensusBranchId: branchID,
                branchIdForHeight: { [welding] height in
                    try welding.consensusBranchIdFor(height: height)
                },
                renewLease: { [welding, accountUUID] in
                    guard let renewed = try await welding.migrationRenewClaim(
                        claim: activeClaim,
                        for: accountUUID
                    ) else {
                        throw MigrationDeliveryError.claimUnavailable
                    }
                    activeClaim = renewed
                }
            )
        } catch {
            await releaseKnownUnsentClaim(activeClaim, failure: .transportDidNotBegin)
            throw error
        }

        // Any returned outcome means the submit RPC began and exposed the exact transaction to the
        // selected migration endpoint. Start the anti-correlation buffer before recording so a
        // record failure cannot let ordinary sync resume early.
        syncGate.markBroadcast()
        do {
            _ = try await welding.migrationRecordSubmissionOutcome(
                outcome,
                claim: activeClaim,
                for: accountUUID
            )
        } catch {
            logger.error("OrchardMigration: failed to record a migration submission outcome: \(error)")
            throw ZcashError.migrationRecordFailedAfterBroadcast(error)
        }
        return ClaimSubmissionResult(outcome: outcome, transactionID: transactionID)
    }

    private func releaseKnownUnsentClaim(
        _ claim: MigrationClaimHandle,
        failure: MigrationDeliveryFailureReason
    ) async {
        do {
            _ = try await welding.migrationReleaseKnownUnsentClaim(
                claim: claim,
                failure: failure,
                for: accountUUID
            )
        } catch {
            logger.error("OrchardMigration: failed to release a known-unsent immediate claim: \(error)")
        }
    }

    /// Runs `flow` as the only claim-exposure or broadcast-performing flow on this actor.
    ///
    /// The actor's methods are reentrant: the broadcast composition suspends at the welding hops and
    /// for the whole broadcast (a Tor bootstrap can take seconds), while the engine keeps reporting
    /// the same transfer as next-due until its result is recorded — so without this guard, a
    /// concurrent execution or external-signing calls could reuse an in-flight claim. The
    /// serialization contract:
    /// - A concurrent caller never throws on contention and is never dropped: it awaits the
    ///   in-flight flow's completion (success or failure), then runs its own flow fresh, so its own
    ///   due-transfer fetch observes the recorded outcome (typically nil, or the next transfer).
    /// - Waiting is a suspension on a continuation that the finishing flow resumes exactly once —
    ///   no busy-waiting, and no unstructured tasks.
    /// - Cancelling a waiting caller never cancels the in-flight flow: the waiter holds no
    ///   reference to it. Once resumed, cancellation is checked before the caller can take
    ///   ownership or execute any welding mutation.
    private func serializedBroadcastFlow<T>(_ flow: () async throws -> T) async throws -> T {
        while isBroadcastFlowInFlight {
            await withCheckedContinuation { continuation in
                broadcastFlowWaiters.append(continuation)
            }
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        isBroadcastFlowInFlight = true
        defer {
            isBroadcastFlowInFlight = false
            let waiters = broadcastFlowWaiters
            broadcastFlowWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
        try Task.checkCancellation()
        return try await flow()
    }

}
