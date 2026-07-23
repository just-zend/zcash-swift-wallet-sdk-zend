//
//  SDKSynchronizer.swift
//  ZcashLightClientKit
//
//  Created by Francisco Gindre on 11/6/19.
//  Copyright © 2019 Electric Coin Company. All rights reserved.
//

import Foundation
import Combine

/// Synchronizer implementation for UIKit and iOS 13+
// swiftlint:disable type_body_length file_length
public class SDKSynchronizer: Synchronizer {
    private enum Constants {
        static let fixWitnessesLastVersionCall = "ud_fixWitnessesLastVersionCall"
        /// Long enough for a normal submit round-trip, short enough that a killed worker repairs
        /// itself promptly on the next foreground/background opportunity.
        static let migrationLeaseDurationMs: UInt64 = 15 * 60 * 1_000
    }

    private enum MigrationClaimLifecycleError: Error {
        case insufficientLeaseBudget
    }

    public var alias: ZcashSynchronizerAlias { initializer.alias }

    private lazy var streamsUpdateQueue = { DispatchQueue(label: "streamsUpdateQueue_\(initializer.alias.description)") }()
    private let stateSubject = CurrentValueSubject<SynchronizerState, Never>(.zero)
    public var stateStream: AnyPublisher<SynchronizerState, Never> { stateSubject.eraseToAnyPublisher() }
    public private(set) var latestState: SynchronizerState = .zero

    private let eventSubject = PassthroughSubject<SynchronizerEvent, Never>()
    public var eventStream: AnyPublisher<SynchronizerEvent, Never> { eventSubject.eraseToAnyPublisher() }

    private let exchangeRateUSDSubject = CurrentValueSubject<FiatCurrencyResult?, Never>(nil)
    public var exchangeRateUSDStream: AnyPublisher<FiatCurrencyResult?, Never> { exchangeRateUSDSubject.eraseToAnyPublisher() }

    let metrics: SDKMetrics
    public let logger: Logger
    var exchangeRateTor: TorClient?
    var httpTor: TorClient?
    let sdkFlags: SDKFlags

    // Don't read this variable directly. Use `status` instead. And don't update this variable directly use `updateStatus()` methods instead.
    private var underlyingStatus: GenericActor<InternalSyncStatus>
    var status: InternalSyncStatus {
        get async { await underlyingStatus.value }
    }

    let blockProcessor: CompactBlockProcessor
    lazy var blockProcessorEventProcessingQueue = { DispatchQueue(label: "blockProcessorEventProcessingQueue_\(initializer.alias.description)") }()

    public let initializer: Initializer
    public var connectionState: ConnectionState
    public let network: ZcashNetwork
    private var transactionEncoder: TransactionEncoder
    private let transactionRepository: TransactionRepository

    private let syncSessionIDGenerator: SyncSessionIDGenerator
    private let syncSession: SyncSession
    private let syncSessionTicker: SessionTicker
    var latestBlocksDataProvider: LatestBlocksDataProvider
    private let submitPlanStore: SubmitPlanStoring
    private let migrationTransactionSubmitter: MigrationTransactionSubmitting

    private var broadcasterStorage: SDKBroadcaster?
    public var broadcaster: Broadcaster { sdkBroadcaster }
    private var sdkBroadcaster: SDKBroadcaster {
        guard let broadcasterStorage else {
            preconditionFailure("Broadcaster accessed before initialization")
        }
        return broadcasterStorage
    }

    /// Creates an SDKSynchronizer instance
    /// - Parameter initializer: a wallet Initializer object
    public convenience init(initializer: Initializer) {
        self.init(
            status: .unprepared,
            initializer: initializer,
            transactionEncoder: WalletTransactionEncoder(initializer: initializer),
            transactionRepository: initializer.transactionRepository,
            blockProcessor: CompactBlockProcessor(
                initializer: initializer,
                walletBirthdayProvider: { initializer.walletBirthday }
            ),
            syncSessionTicker: .live
        )
    }

    init(
        status: InternalSyncStatus,
        initializer: Initializer,
        transactionEncoder: TransactionEncoder,
        transactionRepository: TransactionRepository,
        blockProcessor: CompactBlockProcessor,
        syncSessionTicker: SessionTicker,
        migrationTransactionSubmitter: MigrationTransactionSubmitting? = nil
    ) {
        self.connectionState = .idle
        self.underlyingStatus = GenericActor(status)
        self.initializer = initializer
        self.transactionEncoder = transactionEncoder
        self.transactionRepository = transactionRepository
        self.blockProcessor = blockProcessor
        self.network = initializer.network
        self.metrics = initializer.container.resolve(SDKMetrics.self)
        self.logger = initializer.logger
        self.syncSessionIDGenerator = initializer.container.resolve(SyncSessionIDGenerator.self)
        self.syncSession = SyncSession(.nullID)
        self.syncSessionTicker = syncSessionTicker
        self.latestBlocksDataProvider = initializer.container.resolve(LatestBlocksDataProvider.self)
        self.sdkFlags = initializer.container.resolve(SDKFlags.self)
        self.submitPlanStore = initializer.container.resolve(SubmitPlanStoring.self)
        self.migrationTransactionSubmitter = migrationTransactionSubmitter ?? LiveMigrationTransactionSubmitter(
            torClient: initializer.container.resolve(TorClient.self),
            logger: initializer.logger
        )

        self.broadcasterStorage = SDKBroadcaster(
            transactionEncoder: transactionEncoder,
            initializer: initializer,
            logger: logger,
            eventSubject: eventSubject,
            submitPlanStore: submitPlanStore,
            multiEndpointSubmitter: initializer.container.resolve(MultiEndpointSubmitter.self),
            statusCheck: { [weak self] in
                guard let self else {
                    throw ZcashError.synchronizerNotPrepared
                }
                try self.throwIfUnprepared()
            }
        )

        initializer.lightWalletService.connectionStateChange = { [weak self] oldState, newState in
            self?.connectivityStateChanged(oldState: oldState, newState: newState)
        }

        Task(priority: .high) { [weak self] in
            await self?.subscribeToProcessorEvents(blockProcessor)
        }
    }

    deinit {
        Task { [blockProcessor] in
            await blockProcessor.stop()
        }
    }

    func updateStatus(_ newValue: InternalSyncStatus, updateExternalStatus: Bool = true) async {
        let oldValue = await underlyingStatus.update(newValue)
        logger.info("Synchronizer's status updated from \(oldValue) to \(newValue)")
        await notify(oldStatus: oldValue, newStatus: newValue, updateExternalStatus: updateExternalStatus)
    }

    func throwIfUnprepared() throws {
        if !latestState.internalSyncStatus.isPrepared {
            throw ZcashError.synchronizerNotPrepared
        }
    }

    func checkIfCanContinueInitialisation() -> ZcashError? {
        if let initialisationError = initializer.urlsParsingError {
            return initialisationError
        }

        return nil
    }

    public func prepare(
        with seed: [UInt8]?,
        walletBirthday: BlockHeight,
        for walletMode: WalletInitMode,
        name: String,
        keySource: String?
    ) async throws -> Initializer.InitializationResult {
        guard await status == .unprepared else { return .success }

        if let error = checkIfCanContinueInitialisation() {
            throw error
        }

        let initResult = try await self.initializer.initialize(
            with: seed,
            walletBirthday: walletBirthday,
            for: walletMode,
            name: name,
            keySource: keySource
        )

        switch initResult {
        case .seedRequired, .seedNotRelevant:
            return initResult
        case .success:
            break
        }

        await latestBlocksDataProvider.updateWalletBirthday(initializer.walletBirthday)
        await latestBlocksDataProvider.updateScannedData()

        await updateStatus(.disconnected, updateExternalStatus: false)

        await resolveWitnessesFix()

        return .success
    }

    /// Starts the synchronizer
    /// - Throws: ZcashError when failures occur
    public func start(retry: Bool = false) async throws {
        switch await status {
        case .unprepared:
            throw ZcashError.synchronizerNotPrepared

        case .syncing:
            logger.warn("warning: Synchronizer started when already running. Next sync process will be started when the current one stops.")
            await exchangeRateTor?.wake()
            await httpTor?.wake()
            await sdkFlags.sdkStarted()
            /// This may look strange but `CompactBlockProcessor` has mechanisms which can handle this situation. So we are fine with calling
            /// it's start here.
            await blockProcessor.start(retry: retry)

        case .stopped, .synced, .disconnected, .error:
            await sdkFlags.sdkStarted()
            let walletSummary = try? await initializer.rustBackend.getWalletSummary()
            let recoveryProgress = walletSummary?.recoveryProgress

            var syncProgress: Float = 0.0
            var areFundsSpendable = false

            if let scanProgress = walletSummary?.scanProgress {
                let composedNumerator = Float(scanProgress.numerator) + Float(recoveryProgress?.numerator ?? 0)
                let composedDenominator = Float(scanProgress.denominator) + Float(recoveryProgress?.denominator ?? 0)

                let progress: Float
                if composedDenominator == 0 {
                    progress = 1.0
                } else {
                    progress = composedNumerator / composedDenominator
                }

                // this shouldn't happen but if it does, we need to get notified by clients and work on a fix
                if progress > 1.0 {
                    throw ZcashError.rustScanProgressOutOfRange("\(progress)")
                }

                areFundsSpendable = scanProgress.isComplete

                syncProgress = progress
            }
            await updateStatus(.syncing(syncProgress, areFundsSpendable))
            await exchangeRateTor?.wake()
            await httpTor?.wake()
            await blockProcessor.start(retry: retry)
        }
    }

    /// Stops the synchronizer
    public func stop() {
        // Calling `await blockProcessor.stop()` make take some time. If the downloading of blocks is in progress then this method inside waits until
        // downloading is really done. Which could block execution of the code on the client side. So it's better strategy to spin up new task and
        // exit fast on client side.
        Task(priority: .high) {
            await sdkFlags.sdkStopped()

            let status = await self.status
            guard status != .stopped, status != .disconnected else {
                logger.info("attempted to stop when status was: \(status)")
                return
            }

            await blockProcessor.stop()
            await exchangeRateTor?.sleep()
            await httpTor?.sleep()
        }
    }

    // MARK: Witnesses Fix

    private func resolveWitnessesFix() async {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

        guard let lastVersionCall = UserDefaults.standard.string(forKey: Constants.fixWitnessesLastVersionCall) else {
            // No recorded version — run the fix.
            await runWitnessesFix(appVersion: appVersion)
            return
        }

        guard lastVersionCall < appVersion else { return }

        await runWitnessesFix(appVersion: appVersion)
    }

    private func runWitnessesFix(appVersion: String) async {
        UserDefaults.standard.set(appVersion, forKey: Constants.fixWitnessesLastVersionCall)
        await initializer.rustBackend.fixWitnesses()
    }

    // MARK: Connectivity State

    func connectivityStateChanged(oldState: ConnectionState, newState: ConnectionState) {
        connectionState = newState
        streamsUpdateQueue.async { [weak self] in
            self?.eventSubject.send(.connectionStateChanged(newState))
        }
    }

    // MARK: Handle CompactBlockProcessor.Flow

    private func subscribeToProcessorEvents(_ processor: CompactBlockProcessor) async {
        let eventClosure: CompactBlockProcessor.EventClosure = { [weak self] event in
            switch event {
            case let .failed(error):
                await self?.failed(error: error)

            case let .finished(height):
                await self?.finished(lastScannedHeight: height)

            case let .foundTransactions(transactions, range):
                self?.foundTransactions(transactions: transactions, in: range)

            case let .handledReorg(reorgHeight, rewindHeight):
                // log reorg information
                self?.logger.info("handling reorg at: \(reorgHeight) with rewind height: \(rewindHeight)")

            case let .progressUpdated(syncProgress, areFundsSpendable):
                await self?.progressUpdated(syncProgress, areFundsSpendable)

            case .syncProgress:
                break

            case let .storedUTXOs(utxos):
                self?.storedUTXOs(utxos: utxos)

            case .startedEnhancing, .startedFetching, .startedSyncing:
                break

            case .stopped:
                await self?.updateStatus(.stopped)

            case .minedTransaction(let transaction):
                self?.notifyMinedTransaction(transaction)
            }
        }

        await processor.updateEventClosure(identifier: "SDKSynchronizer", closure: eventClosure)
    }

    private func failed(error: Error) async {
        await updateStatus(.error(error))
    }

    private func finished(lastScannedHeight: BlockHeight) async {
        await latestBlocksDataProvider.updateScannedData()

        await updateStatus(.synced)
    }

    private func foundTransactions(transactions: [ZcashTransaction.Overview], in range: CompactBlockRange) {
        guard !transactions.isEmpty else { return }

        streamsUpdateQueue.async { [weak self] in
            self?.eventSubject.send(.foundTransactions(transactions, range))
        }
    }

    private func progressUpdated(_ syncProgress: Float, _ areFundsSpendable: Bool) async {
        let newStatus = InternalSyncStatus(syncProgress, areFundsSpendable)
        await updateStatus(newStatus)
    }

    private func storedUTXOs(utxos: (inserted: [UnspentTransactionOutputEntity], skipped: [UnspentTransactionOutputEntity])) {
        streamsUpdateQueue.async { [weak self] in
            self?.eventSubject.send(.storedUTXOs(utxos.inserted, utxos.skipped))
        }
    }

    // MARK: Synchronizer methods

    public func listAccounts() async throws -> [Account] {
        try await initializer.rustBackend.listAccounts()
    }

    // swiftlint:disable:next function_parameter_count
    public func importAccount(
        ufvk: String,
        seedFingerprint: [UInt8]?,
        zip32AccountIndex: Zip32AccountIndex?,
        purpose: AccountPurpose,
        name: String,
        keySource: String?,
        birthday: BlockHeight? = nil
    ) async throws -> AccountUUID {
        // Stop sync if running
        let status = await self.status
        var stopped = false
        if status != .stopped && status != .disconnected {
            await blockProcessor.stop()
            await exchangeRateTor?.sleep()
            await httpTor?.sleep()
            stopped = true
        }

        // called when a new account is imported
        let chainTip = try? await UInt32(
            initializer.lightWalletService.latestBlockHeight(
                mode: await sdkFlags.ifTor(.uniqueTor)
            )
        )

        let checkpointSource = initializer.container.resolve(CheckpointSource.self)

        guard let chainTip else {
            throw ZcashError.synchronizerNotPrepared
        }

        let checkpoint = checkpointSource.birthday(for: birthday ?? BlockHeight(chainTip))

        let accountUUID = try await initializer.rustBackend.importAccount(
            ufvk: ufvk,
            seedFingerprint: seedFingerprint,
            zip32AccountIndex: zip32AccountIndex,
            treeState: checkpoint.treeState(),
            recoverUntil: chainTip,
            purpose: purpose,
            name: name,
            keySource: keySource
        )

        // Restart sync
        if stopped {
            try await start(retry: false)
        }

        return accountUUID
    }

    public func proposeTransfer(accountUUID: AccountUUID, recipient: Recipient, amount: Zatoshi, memo: Memo?) async throws -> Proposal {
        try throwIfUnprepared()

        if case Recipient.transparent = recipient, memo != nil {
            throw ZcashError.synchronizerSendMemoToTransparentAddress
        }

        let proposal = try await transactionEncoder.proposeTransfer(
            accountUUID: accountUUID,
            recipient: recipient.stringEncoded,
            amount: amount,
            memoBytes: memo?.asMemoBytes()
        )

        return proposal
    }

    public func proposeShielding(
        accountUUID: AccountUUID,
        shieldingThreshold: Zatoshi,
        memo: Memo,
        transparentReceiver: TransparentAddress? = nil
    ) async throws -> Proposal? {
        try throwIfUnprepared()

        return try await transactionEncoder.proposeShielding(
            accountUUID: accountUUID,
            shieldingThreshold: shieldingThreshold,
            memoBytes: memo.asMemoBytes(),
            transparentReceiver: transparentReceiver?.stringEncoded
        )
    }

    public func proposefulfillingPaymentURI(
        _ uri: String,
        accountUUID: AccountUUID
    ) async throws -> Proposal {
        do {
            try throwIfUnprepared()
            return try await transactionEncoder.proposeFulfillingPaymentFromURI(
                uri,
                accountUUID: accountUUID
            )
        } catch ZcashError.rustCreateToAddress(let error) {
            throw ZcashError.rustProposeTransferFromURI(error)
        } catch {
            throw error
        }
    }

    public func createProposedTransactions(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey
    ) async throws -> AsyncThrowingStream<TransactionSubmitResult, Error> {
        let transactions = try await sdkBroadcaster.createProposedTransactions(
            proposal: proposal,
            spendingKey: spendingKey,
            recordingPlans: false
        )

        return submitTransactions(transactions)
    }

    func submitTransactions(_ transactions: [CreatedTransaction]) -> AsyncThrowingStream<TransactionSubmitResult, Error> {
        var iterator = transactions.makeIterator()
        var submitFailed = false

        return AsyncThrowingStream(unfolding: {
            guard let transaction = iterator.next() else { return nil }

            if submitFailed {
                return .notAttempted(txId: transaction.txId)
            } else {
                do {
                    try await self.transactionEncoder.submit(transaction: transaction.encodedTransaction)
                    return TransactionSubmitResult.success(txId: transaction.txId)
                } catch ZcashError.serviceSubmitFailed(let error) {
                    submitFailed = true
                    return TransactionSubmitResult.grpcFailure(txId: transaction.txId, error: error)
                } catch TransactionEncoderError.submitError(let code, let message) {
                    // Trust the network over the submit-side error: if the server confirms
                    // it has this tx, the broadcast already landed (e.g. Zebra's
                    // MempoolError::InMempool / AlreadyQueued, zcashd's "already in chain",
                    // or any future variant). Treat as success and skip the failure screen.
                    if await self.transactionEncoder.isTransactionKnownToServer(txId: transaction.txId) {
                        return TransactionSubmitResult.success(txId: transaction.txId)
                    }
                    submitFailed = true
                    return TransactionSubmitResult.submitFailure(txId: transaction.txId, code: code, description: message)
                }
            }
        })
    }

    // MARK: - Ironwood migration

    public func migrationState(for account: AccountUUID) async throws -> MigrationState {
        try await initializer.rustBackend.migrationState(for: account)
    }

    public func migrationSnapshot(for account: AccountUUID) async throws -> MigrationSnapshot {
        try await initializer.rustBackend.migrationSnapshot(for: account)
    }

    public func beginPrivateMigration(
        externalSigner: Bool,
        options: NetworkPrivacyOptions,
        for account: AccountUUID
    ) async throws -> MigrationSnapshot {
        let policy = try await validatedSubmissionPolicy(options: options).policy
        let started = try await initializer.rustBackend.migrationBeginPrivate(
            externalSigner: externalSigner,
            policy: policy,
            for: account
        )
        guard started.submissionPolicy?.policy == policy else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        return started
    }

    public func bindMigrationSubmissionPolicy(
        expectedRunId: String,
        expectedRevision: UInt64,
        options: NetworkPrivacyOptions,
        for account: AccountUUID
    ) async throws -> MigrationSnapshot {
        let snapshot = try await migrationSnapshot(
            expectedRunId: expectedRunId,
            expectedRevision: expectedRevision,
            for: account
        )
        return try await validatedAndBindSubmissionPolicy(
            options: options,
            snapshot: snapshot,
            for: account
        ).snapshot
    }

    public func pauseMigration(
        expectedRunId: String,
        expectedRevision: UInt64,
        for account: AccountUUID
    ) async throws -> MigrationSnapshot {
        try await initializer.rustBackend.migrationPause(
            expectedRunId: expectedRunId,
            expectedRevision: expectedRevision,
            for: account
        )
    }

    public func retryAutomaticMigrationRecovery(
        expectedRunId: String,
        expectedRevision: UInt64,
        for account: AccountUUID
    ) async throws -> MigrationSnapshot {
        try await initializer.rustBackend.migrationRetryAutomaticRecovery(
            expectedRunId: expectedRunId,
            expectedRevision: expectedRevision,
            for: account
        )
    }

    public func resumeMigration(
        expectedRunId: String,
        expectedRevision: UInt64,
        for account: AccountUUID
    ) async throws -> MigrationSnapshot {
        try await initializer.rustBackend.migrationResume(
            expectedRunId: expectedRunId,
            expectedRevision: expectedRevision,
            for: account
        )
    }

    public func requestMigrationAbandonment(
        expectedRunId: String,
        expectedRevision: UInt64,
        for account: AccountUUID
    ) async throws -> MigrationSnapshot {
        try await initializer.rustBackend.migrationRequestAbandonment(
            expectedRunId: expectedRunId,
            expectedRevision: expectedRevision,
            for: account
        )
    }

    public func migrationProgress(for account: AccountUUID) async throws -> MigrationProgress? {
        try await initializer.rustBackend.migrationProgress(for: account)
    }

    public func isNoteSplitNeeded(for account: AccountUUID) async throws -> Bool {
        try await initializer.rustBackend.migrationIsNoteSplitNeeded(for: account)
    }

    public func prepareNoteSplit(for account: AccountUUID) async throws -> NoteSplitProposal {
        try await initializer.rustBackend.migrationPrepareNoteSplit(for: account)
    }

    public func submitNoteSplit(
        expectedRunId: String,
        expectedRevision: UInt64,
        proposal: NoteSplitProposal,
        spendingKey: UnifiedSpendingKey,
        options: NetworkPrivacyOptions,
        for account: AccountUUID
    ) async throws -> TransferResult {
        let current = try await initializer.rustBackend.migrationSnapshot(for: account)
        guard current.runId == expectedRunId,
              current.revision == expectedRevision,
              !current.externalSigner else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        let binding = try await validatedAndBindSubmissionPolicy(
            options: options,
            snapshot: current,
            for: account
        )
        guard binding.snapshot.runId == expectedRunId else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        let boundPolicy = binding.policy
        let claim: ClaimedTx?
        do {
            _ = try await initializer.rustBackend.migrationSignNoteSplit(
                expectedRunId: expectedRunId,
                expectedRevision: binding.snapshot.revision,
                proposal: proposal,
                usk: spendingKey,
                expectedPolicyFingerprint: boundPolicy.policyFingerprint,
                for: account
            )
            claim = try await claimNoteSplitSubmission(
                expectedRunId: expectedRunId,
                expectedPolicyFingerprint: boundPolicy.policyFingerprint,
                for: account
            )
        } catch {
            // If persistence completed before a crash/retry, signing correctly rejects creating a
            // second split. Resume the engine-owned bytes; otherwise preserve the original error.
            guard let recovered = try await claimNoteSplitSubmission(
                expectedRunId: expectedRunId,
                expectedPolicyFingerprint: boundPolicy.policyFingerprint,
                for: account
            ) else { throw error }
            claim = recovered
        }
        guard let claim else {
            throw ZcashError.rustMigrationClaimNoteSplitSubmission("persisted note split was not claimable")
        }
        let execution = try await submitMigrationClaim(claim, options: options, for: account)
        return execution.submissionResult ?? .outcomeUnknown
    }

    public func proposeNoteSplitPCZT(
        expectedRunId: String,
        expectedRevision: UInt64,
        proposal: NoteSplitProposal,
        options: NetworkPrivacyOptions,
        for account: AccountUUID
    ) async throws -> ClaimedNoteSplitPCZT {
        let current = try await initializer.rustBackend.migrationSnapshot(for: account)
        guard current.runId == expectedRunId,
              current.revision == expectedRevision,
              current.externalSigner else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        let binding = try await validatedAndBindSubmissionPolicy(
            options: options,
            snapshot: current,
            for: account
        )
        guard binding.snapshot.runId == expectedRunId else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        return try await initializer.rustBackend.migrationCreateUnsignedNoteSplitPCZT(
            expectedRunId: expectedRunId,
            expectedRevision: binding.snapshot.revision,
            proposal: proposal,
            expectedPolicyFingerprint: binding.policy.policyFingerprint,
            for: account
        )
    }

    public func submitSignedNoteSplitPCZT(
        _ pczt: Pczt,
        for signerClaim: ClaimedNoteSplitPCZT,
        expectedRevision: UInt64,
        options: NetworkPrivacyOptions,
        account: AccountUUID
    ) async throws -> TransferResult {
        let current = try await migrationSnapshot(
            expectedRunId: signerClaim.runId,
            expectedRevision: expectedRevision,
            for: account
        )
        let binding = try await validatedAndBindSubmissionPolicy(
            options: options,
            snapshot: current,
            for: account
        )
        guard binding.policy == signerClaim.submissionPolicy else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        let claim: ClaimedTx?
        do {
            _ = try await initializer.rustBackend.migrationStoreSignedNoteSplitPCZT(
                claim: signerClaim,
                pczt: pczt,
                expectedPolicyFingerprint: binding.policy.policyFingerprint,
                for: account
            )
            claim = try await claimNoteSplitSubmission(
                expectedRunId: signerClaim.runId,
                expectedPolicyFingerprint: binding.policy.policyFingerprint,
                for: account
            )
        } catch {
            guard let recovered = try await claimNoteSplitSubmission(
                expectedRunId: signerClaim.runId,
                expectedPolicyFingerprint: binding.policy.policyFingerprint,
                for: account
            ) else { throw error }
            claim = recovered
        }
        guard let claim else {
            throw ZcashError.rustMigrationClaimNoteSplitSubmission("persisted note split was not claimable")
        }
        let execution = try await submitMigrationClaim(claim, options: options, for: account)
        return execution.submissionResult ?? .outcomeUnknown
    }

    public func proposePrivateMigrationIntents(for account: AccountUUID) async throws -> MigrationIntentSchedule {
        try await initializer.rustBackend.migrationProposePrivateIntents(for: account)
    }

    public func proposeImmediateMigrationIntent(for account: AccountUUID) async throws -> MigrationIntentSchedule {
        try await initializer.rustBackend.migrationProposeImmediateIntent(for: account)
    }

    public func previewImmediateMigration(for account: AccountUUID) async throws -> ImmediateMigrationPreview {
        try await initializer.rustBackend.migrationPreviewImmediate(for: account)
    }

    public func commitMigrationIntents(
        _ schedule: MigrationIntentSchedule,
        externalSigner: Bool,
        options: NetworkPrivacyOptions,
        for account: AccountUUID
    ) async throws -> MigrationSnapshot {
        let policy = try await validatedSubmissionPolicy(options: options).policy
        let committed = try await initializer.rustBackend.migrationCommitIntents(
            schedule: schedule,
            externalSigner: externalSigner,
            policy: policy,
            for: account
        )
        guard committed.runId == schedule.runId,
              committed.submissionPolicy?.policy == policy else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        return committed
    }

    public func executeNextMigrationAction(
        expectedRunId: String,
        expectedRevision: UInt64,
        spendingKey: UnifiedSpendingKey?,
        options: NetworkPrivacyOptions,
        for account: AccountUUID
    ) async throws -> MigrationExecutionResult {
        let snapshot = try await migrationSnapshot(
            expectedRunId: expectedRunId,
            expectedRevision: expectedRevision,
            for: account
        )
        guard [
            NextAction.claimDueTransaction,
            .materializeDueTransaction,
            .resumeStagedSubmission
        ].contains(snapshot.nextAction) else {
            return MigrationExecutionResult(disposition: .noAction, submissionResult: nil, snapshot: snapshot)
        }
        let binding = try await validatedAndBindSubmissionPolicy(
            options: options,
            snapshot: snapshot,
            for: account
        )
        guard binding.snapshot.runId == expectedRunId else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        let claim: ClaimedTx?
        switch binding.snapshot.nextAction {
        case .claimDueTransaction:
            claim = try await claimPersistedSubmission(
                snapshot: binding.snapshot,
                expectedPolicyFingerprint: binding.policy.policyFingerprint,
                for: account
            )
        case .materializeDueTransaction:
            guard let spendingKey else {
                return MigrationExecutionResult(disposition: .noAction, submissionResult: nil, snapshot: binding.snapshot)
            }
            claim = try await initializer.rustBackend.migrationMaterializeAndClaimNextDue(
                expectedRunId: expectedRunId,
                expectedRevision: binding.snapshot.revision,
                leaseDurationMs: Constants.migrationLeaseDurationMs,
                usk: spendingKey,
                expectedPolicyFingerprint: binding.policy.policyFingerprint,
                for: account
            )
        case .resumeStagedSubmission:
            claim = try await initializer.rustBackend.migrationResumeStagedSubmission(
                expectedRunId: expectedRunId,
                expectedRevision: binding.snapshot.revision,
                leaseDurationMs: Constants.migrationLeaseDurationMs,
                expectedPolicyFingerprint: binding.policy.policyFingerprint,
                for: account
            )
        case .initialize, .awaitUserChoice, .waitForSync, .preparePrivateSplit,
             .waitForSplitConfirmation, .proposePrivateSchedule, .stageNoteSplitExternalSignature,
             .stageDueExternalSignature, .waitForWorkerLease, .awaitExternalSignature,
             .waitForDueHeight, .waitForConfirmation, .waitForSubmissionResolution,
             .reviewUpdatedIntentFee, .reviewUpdatedMigrationPlan, .resumeMigration,
             .waitForCancellationSafety, .recover, .none:
            return MigrationExecutionResult(disposition: .noAction, submissionResult: nil, snapshot: binding.snapshot)
        }
        guard let claim else {
            let refreshed = try await initializer.rustBackend.migrationSnapshot(for: account)
            return MigrationExecutionResult(disposition: .noAction, submissionResult: nil, snapshot: refreshed)
        }
        return try await submitMigrationClaim(claim, options: options, for: account)
    }

    public func stageNextDueMigrationPCZT(
        expectedRunId: String,
        expectedRevision: UInt64,
        options: NetworkPrivacyOptions,
        for account: AccountUUID
    ) async throws -> ClaimedTransferPCZT? {
        let snapshot = try await migrationSnapshot(
            expectedRunId: expectedRunId,
            expectedRevision: expectedRevision,
            for: account
        )
        let isNewRound = snapshot.nextAction == .stageDueExternalSignature
        let isResumableRound = snapshot.nextAction == .awaitExternalSignature
            && snapshot.phase.map { [.broadcastScheduled, .broadcasting].contains($0) } == true
        guard isNewRound || isResumableRound else { return nil }
        let binding = try await validatedAndBindSubmissionPolicy(
            options: options,
            snapshot: snapshot,
            for: account
        )
        guard binding.snapshot.runId == expectedRunId else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        if binding.snapshot.nextAction == .awaitExternalSignature {
            return try await initializer.rustBackend.migrationResumeDueExternalPCZT(
                expectedRunId: expectedRunId,
                expectedRevision: binding.snapshot.revision,
                leaseDurationMs: Constants.migrationLeaseDurationMs,
                expectedPolicyFingerprint: binding.policy.policyFingerprint,
                for: account
            )
        }
        return try await initializer.rustBackend.migrationStageNextDueExternalPCZT(
            expectedRunId: expectedRunId,
            expectedRevision: binding.snapshot.revision,
            leaseDurationMs: Constants.migrationLeaseDurationMs,
            expectedPolicyFingerprint: binding.policy.policyFingerprint,
            for: account
        )
    }

    public func resumeNoteSplitExternalSigning(
        expectedRunId: String,
        expectedRevision: UInt64,
        options: NetworkPrivacyOptions,
        for account: AccountUUID
    ) async throws -> ClaimedNoteSplitPCZT? {
        let snapshot = try await migrationSnapshot(
            expectedRunId: expectedRunId,
            expectedRevision: expectedRevision,
            for: account
        )
        guard snapshot.nextAction == .awaitExternalSignature,
              snapshot.phase == .preparingDenominations else { return nil }
        let binding = try await validatedAndBindSubmissionPolicy(options: options, snapshot: snapshot, for: account)
        guard binding.snapshot.runId == expectedRunId else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        return try await initializer.rustBackend.migrationResumeNoteSplitExternalPCZT(
            expectedRunId: expectedRunId,
            expectedRevision: binding.snapshot.revision,
            expectedPolicyFingerprint: binding.policy.policyFingerprint,
            for: account
        )
    }

    public func resumeDueMigrationExternalSigning(
        expectedRunId: String,
        expectedRevision: UInt64,
        options: NetworkPrivacyOptions,
        for account: AccountUUID
    ) async throws -> ClaimedTransferPCZT? {
        let snapshot = try await migrationSnapshot(
            expectedRunId: expectedRunId,
            expectedRevision: expectedRevision,
            for: account
        )
        guard snapshot.nextAction == .awaitExternalSignature,
              snapshot.phase.map({ [.broadcastScheduled, .broadcasting].contains($0) }) == true else { return nil }
        let binding = try await validatedAndBindSubmissionPolicy(options: options, snapshot: snapshot, for: account)
        guard binding.snapshot.runId == expectedRunId else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        return try await initializer.rustBackend.migrationResumeDueExternalPCZT(
            expectedRunId: expectedRunId,
            expectedRevision: binding.snapshot.revision,
            leaseDurationMs: Constants.migrationLeaseDurationMs,
            expectedPolicyFingerprint: binding.policy.policyFingerprint,
            for: account
        )
    }

    public func submitSignedDueMigrationPCZT(
        _ signedPCZT: Pczt,
        for claim: ClaimedTransferPCZT,
        expectedRunId: String,
        expectedRevision: UInt64,
        options: NetworkPrivacyOptions,
        account: AccountUUID
    ) async throws -> MigrationExecutionResult {
        let current = try await migrationSnapshot(
            expectedRunId: expectedRunId,
            expectedRevision: expectedRevision,
            for: account
        )
        let binding = try await validatedAndBindSubmissionPolicy(
            options: options,
            snapshot: current,
            for: account
        )
        guard binding.policy == claim.submissionPolicy else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        guard let submission = try await initializer.rustBackend.migrationStoreSignedDueIntent(
            intentId: claim.intentId,
            signerToken: claim.signerToken,
            pczt: signedPCZT,
            leaseDurationMs: Constants.migrationLeaseDurationMs,
            expectedPolicyFingerprint: binding.policy.policyFingerprint,
            for: account
        ) else {
            let snapshot = try await initializer.rustBackend.migrationSnapshot(for: account)
            return MigrationExecutionResult(disposition: .noAction, submissionResult: nil, snapshot: snapshot)
        }
        return try await submitMigrationClaim(submission, options: options, for: account)
    }

    /// Internal legacy-fixture compatibility only. The production Synchronizer contract exposes
    /// only anchorless intent commit plus one-due-intent JIT materialization.
    func proposeMigrationTransferPCZTs(
        _ schedule: MigrationSchedule,
        for account: AccountUUID
    ) async throws -> [MigrationTransferPCZT] {
        // The caller's confirmed schedule is authoritative: schedules carry randomized
        // denominations, so re-proposing here would build (and later sign) a different plan than
        // the one the user approved on screen.
        let policy = try await requiredBoundMigrationPolicy(for: account)
        return try await initializer.rustBackend.migrationCreateUnsignedTransferPCZTs(
            schedule: schedule,
            expectedPolicyFingerprint: policy.policyFingerprint,
            for: account
        )
    }

    func storeSignedMigrationTransferPCZTs(_ pczts: [MigrationTransferPCZT], for account: AccountUUID) async throws {
        let policy = try await requiredBoundMigrationPolicy(for: account)
        try await initializer.rustBackend.migrationStoreSignedSchedulePCZTs(
            pczts: pczts,
            expectedPolicyFingerprint: policy.policyFingerprint,
            for: account
        )
    }

    func proposeMigrationTransfers(for account: AccountUUID) async throws -> MigrationSchedule {
        try await initializer.rustBackend.migrationProposeTransfers(for: account)
    }

    func proposeImmediateMigrationTransfers(for account: AccountUUID) async throws -> MigrationSchedule {
        try await initializer.rustBackend.migrationProposeImmediate(for: account)
    }

    func signAndStoreMigrationSchedule(
        _ schedule: MigrationSchedule,
        spendingKey: UnifiedSpendingKey,
        for account: AccountUUID
    ) async throws {
        let policy = try await requiredBoundMigrationPolicy(for: account)
        try await initializer.rustBackend.migrationSignAndStore(
            schedule: schedule,
            usk: spendingKey,
            expectedPolicyFingerprint: policy.policyFingerprint,
            for: account
        )
    }

    public func isSyncRequiredBeforeNextTransfer(for account: AccountUUID) async throws -> Bool {
        try await initializer.rustBackend.migrationIsSyncRequired(for: account)
    }

    func executeNextPendingTransfer(
        options: NetworkPrivacyOptions,
        for account: AccountUUID
    ) async throws -> TransferResult? {
        let snapshot = try await initializer.rustBackend.migrationSnapshot(for: account)
        let binding = try await validatedAndBindSubmissionPolicy(
            options: options,
            snapshot: snapshot,
            for: account
        )
        guard let claim = try await claimPersistedSubmission(
            snapshot: binding.snapshot,
            expectedPolicyFingerprint: binding.policy.policyFingerprint,
            for: account
        ) else { return nil }
        let execution = try await submitMigrationClaim(claim, options: options, for: account)
        return execution.submissionResult ?? .outcomeUnknown
    }

    private func validatedAndBindSubmissionPolicy(
        options: NetworkPrivacyOptions,
        snapshot: MigrationSnapshot,
        for account: AccountUUID
    ) async throws -> (snapshot: MigrationSnapshot, policy: BoundSubmissionPolicy) {
        guard let expectedRunId = snapshot.runId else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        let consensusFingerprint = try initializer.rustBackend.consensusParametersFingerprint()
        guard snapshot.consensusFingerprint == consensusFingerprint else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        let policy: SubmissionPolicy
        do {
            policy = try await validatedSubmissionPolicy(options: options).policy
        } catch let error as MigrationBroadcastError {
            if let failure = Self.policyValidationFailure(for: error) {
                _ = try await initializer.rustBackend.migrationRecordSubmissionPolicyValidationFailure(
                    expectedRunId: expectedRunId,
                    expectedRevision: snapshot.revision,
                    failure: failure,
                    for: account
                )
            }
            throw error
        }

        let boundSnapshot: MigrationSnapshot
        do {
            boundSnapshot = try await initializer.rustBackend.migrationBindSubmissionPolicy(
                expectedRunId: expectedRunId,
                expectedRevision: snapshot.revision,
                policy: policy,
                for: account
            )
        } catch MigrationSubmissionPolicyBindingError.immutablePolicyConflict {
            // A changed immutable policy is an actionable, stable run state. Persist it before
            // surfacing the typed SDK error so a background driver does not hot-loop on the same
            // endpoint preference. CAS races intentionally propagate from the record call and are
            // retried from a fresh snapshot by the caller.
            _ = try await initializer.rustBackend.migrationRecordSubmissionPolicyValidationFailure(
                expectedRunId: expectedRunId,
                expectedRevision: snapshot.revision,
                failure: .submissionPolicyMismatch,
                for: account
            )
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        guard let boundPolicy = boundSnapshot.submissionPolicy,
              boundPolicy.policy == policy,
              boundPolicy.policy.consensusFingerprint == consensusFingerprint else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        return (boundSnapshot, boundPolicy)
    }

    /// Performs all network/RPC validation before a fresh run is inserted. Keeping this helper
    /// independent of mutation is what lets private begin and immediate commit persist their run,
    /// immutable policy, and first durable work in one Rust transaction with no policyless crash
    /// window and no ordinary-spend lock while an endpoint is being sampled.
    private func validatedSubmissionPolicy(
        options: NetworkPrivacyOptions
    ) async throws -> (policy: SubmissionPolicy, consensusFingerprint: String) {
        let expectedChainName = try initializer.rustBackend.consensusChainName()
        let consensusFingerprint = try initializer.rustBackend.consensusParametersFingerprint()
        let policy = try await migrationTransactionSubmitter.validateSubmissionPolicy(
            options: options,
            defaultEndpoint: initializer.endpoint,
            networkType: network.networkType,
            expectedChainName: expectedChainName,
            consensusFingerprint: consensusFingerprint,
            branchIdForHeight: { [rustBackend = initializer.rustBackend] height in
                try rustBackend.consensusBranchIdFor(height: height)
            }
        )
        return (policy, consensusFingerprint)
    }

    /// Rejects a caller's stale UI/background envelope before endpoint validation, policy binding,
    /// or any Rust mutation. A same-run revision that advances during subsequent RPC validation is
    /// safe: Rust returns that run's current bound snapshot and every acquisition uses its fresh
    /// revision CAS token.
    private func migrationSnapshot(
        expectedRunId: String,
        expectedRevision: UInt64,
        for account: AccountUUID
    ) async throws -> MigrationSnapshot {
        let snapshot = try await initializer.rustBackend.migrationSnapshot(for: account)
        guard snapshot.runId == expectedRunId,
              snapshot.revision == expectedRevision else {
            throw MigrationBroadcastError.migrationSnapshotChanged
        }
        return snapshot
    }

    private static func policyValidationFailure(
        for error: MigrationBroadcastError
    ) -> SubmissionPolicyValidationFailure? {
        switch error {
        case .migrationSnapshotChanged:
            return nil
        case .invalidSubmissionEndpoint, .submissionPolicyMismatch:
            return .submissionPolicyMismatch
        case .selectedEndpointChainMismatch, .selectedEndpointConsensusBranchMismatch,
             .selectedEndpointInfoBehindSampledTip:
            return .endpointConsensusMismatch
        case .invalidTransactionID, .transactionIDMismatch, .transactionConsensusBranchMismatch,
             .missingExpiryHeight, .selectedTransportTipWithinExpirySafetyMargin:
            return nil
        }
    }

    private func requiredBoundMigrationPolicy(for account: AccountUUID) async throws -> BoundSubmissionPolicy {
        let snapshot = try await initializer.rustBackend.migrationSnapshot(for: account)
        let consensusFingerprint = try initializer.rustBackend.consensusParametersFingerprint()
        guard let policy = snapshot.submissionPolicy,
              snapshot.consensusFingerprint == consensusFingerprint,
              policy.policy.consensusFingerprint == consensusFingerprint else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        return policy
    }

    private func claimNoteSplitSubmission(
        expectedRunId: String?,
        expectedPolicyFingerprint: String,
        for account: AccountUUID
    ) async throws -> ClaimedTx? {
        let snapshot = try await initializer.rustBackend.migrationSnapshot(for: account)
        guard let expectedRunId,
              snapshot.runId == expectedRunId,
              snapshot.submissionPolicy?.policyFingerprint == expectedPolicyFingerprint else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        return try await initializer.rustBackend.migrationClaimNoteSplitSubmission(
            expectedRunId: expectedRunId,
            expectedRevision: snapshot.revision,
            leaseDurationMs: Constants.migrationLeaseDurationMs,
            expectedPolicyFingerprint: expectedPolicyFingerprint,
            for: account
        )
    }

    private func claimPersistedSubmission(
        snapshot: MigrationSnapshot,
        expectedPolicyFingerprint: String,
        for account: AccountUUID
    ) async throws -> ClaimedTx? {
        guard let expectedRunId = snapshot.runId,
              snapshot.submissionPolicy?.policyFingerprint == expectedPolicyFingerprint else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        if let prep = try await initializer.rustBackend.migrationClaimNoteSplitSubmission(
            expectedRunId: expectedRunId,
            expectedRevision: snapshot.revision,
            leaseDurationMs: Constants.migrationLeaseDurationMs,
            expectedPolicyFingerprint: expectedPolicyFingerprint,
            for: account
        ) {
            return prep
        }
        return try await initializer.rustBackend.migrationClaimNextDueTransfer(
            expectedRunId: expectedRunId,
            expectedRevision: snapshot.revision,
            leaseDurationMs: Constants.migrationLeaseDurationMs,
            expectedPolicyFingerprint: expectedPolicyFingerprint,
            for: account
        )
    }

    // All transport outcomes converge here so every claim token is finalized exactly once.
    // swiftlint:disable:next cyclomatic_complexity
    private func submitMigrationClaim(
        _ claim: ClaimedTx,
        options: NetworkPrivacyOptions,
        for account: AccountUUID
    ) async throws -> MigrationExecutionResult {
        let currentFingerprint = try initializer.rustBackend.consensusParametersFingerprint()
        guard claim.submissionPolicy.policy.consensusFingerprint == currentFingerprint else {
            await releaseMigrationClaimKnownUnsent(claim, reason: .submissionPolicyMismatch, for: account)
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        guard claim.txid.utf8.count == 64,
              let displayOrderTxID = Data(hexEncoded: claim.txid),
              displayOrderTxID.count == 32 else {
            try await recordMigrationLocalFailure(.txidMismatch, claim: claim, for: account)
            throw MigrationBroadcastError.invalidTransactionID
        }

        let renewLease = { [initializer] in
            try Task.checkCancellation()
            guard let renewed = try await initializer.rustBackend.migrationRenewClaimedTransferLease(
                transferId: claim.id,
                attemptToken: claim.attemptToken,
                leaseDurationMs: Constants.migrationLeaseDurationMs,
                expectedPolicyFingerprint: claim.submissionPolicy.policyFingerprint,
                for: account
            ), renewed.id == claim.id,
               renewed.txid == claim.txid,
               renewed.rawPczt == claim.rawPczt,
               renewed.attemptToken == claim.attemptToken,
               renewed.expiryHeight == claim.expiryHeight,
               renewed.submissionPolicy == claim.submissionPolicy,
               renewed.leaseExpiresAtMs >= Self.minimumRequiredMigrationLeaseExpiryMs(
                   endpoint: initializer.endpoint
               ) else {
                throw MigrationClaimLifecycleError.insufficientLeaseBudget
            }
        }

        do {
            try await renewLease()
        } catch {
            await releaseMigrationClaimKnownUnsent(
                claim,
                reason: error is CancellationError ? .cancelledBeforeTransport : .insufficientLeaseBudget,
                for: account
            )
            throw error
        }

        do {
            let snapshot = try await initializer.rustBackend.migrationSnapshot(for: account)
            try await renewLease()
            guard snapshot.submissionPolicy == claim.submissionPolicy else {
                await releaseMigrationClaimKnownUnsent(claim, reason: .submissionPolicyMismatch, for: account)
                throw MigrationBroadcastError.submissionPolicyMismatch
            }
        } catch is CancellationError {
            await releaseMigrationClaimKnownUnsent(claim, reason: .cancelledBeforeTransport, for: account)
            throw CancellationError()
        } catch MigrationBroadcastError.submissionPolicyMismatch {
            throw MigrationBroadcastError.submissionPolicyMismatch
        } catch {
            await releaseMigrationClaimKnownUnsent(claim, reason: .insufficientLeaseBudget, for: account)
            throw error
        }

        let extracted: ExtractedTx
        do {
            extracted = try await initializer.rustBackend.migrationExtractBroadcastTx(
                pczt: claim.rawPczt,
                for: account
            )
            try await renewLease()
        } catch is CancellationError {
            await releaseMigrationClaimKnownUnsent(claim, reason: .cancelledBeforeTransport, for: account)
            throw CancellationError()
        } catch let error as MigrationClaimLifecycleError {
            await releaseMigrationClaimKnownUnsent(claim, reason: .insufficientLeaseBudget, for: account)
            throw error
        } catch {
            try await recordMigrationLocalFailure(.malformedPczt, claim: claim, for: account)
            throw error
        }

        guard
            extracted.txid == claim.txid,
            extracted.txid.utf8.count == 64,
            let computedDisplayOrderTxID = Data(hexEncoded: extracted.txid),
            computedDisplayOrderTxID.count == 32,
            computedDisplayOrderTxID == displayOrderTxID,
            extracted.expiryHeight == claim.expiryHeight
        else {
            try await recordMigrationLocalFailure(.txidMismatch, claim: claim, for: account)
            throw MigrationBroadcastError.transactionIDMismatch
        }

        let submittedResult: TransferResult
        do {
            submittedResult = try await migrationTransactionSubmitter.submit(
                transaction: EncodedTransaction(
                    transactionId: Data(computedDisplayOrderTxID.reversed()),
                    raw: Data(extracted.rawTx)
                ),
                displayTransactionID: claim.txid,
                expiryHeight: BlockHeight(claim.expiryHeight),
                options: options,
                defaultEndpoint: initializer.endpoint,
                networkType: network.networkType,
                expectedChainName: try initializer.rustBackend.consensusChainName(),
                boundPolicy: claim.submissionPolicy,
                transactionConsensusBranchId: extracted.consensusBranchId,
                branchIdForHeight: { [rustBackend = initializer.rustBackend] height in
                    try rustBackend.consensusBranchIdFor(height: height)
                },
                renewLease: renewLease
            )
        } catch is CancellationError {
            await releaseMigrationClaimKnownUnsent(claim, reason: .cancelledBeforeTransport, for: account)
            throw CancellationError()
        } catch MigrationClaimLifecycleError.insufficientLeaseBudget {
            await releaseMigrationClaimKnownUnsent(claim, reason: .insufficientLeaseBudget, for: account)
            throw MigrationClaimLifecycleError.insufficientLeaseBudget
        } catch MigrationBroadcastError.submissionPolicyMismatch {
            await releaseMigrationClaimKnownUnsent(claim, reason: .submissionPolicyMismatch, for: account)
            throw MigrationBroadcastError.submissionPolicyMismatch
        } catch MigrationBroadcastError.invalidSubmissionEndpoint {
            await releaseMigrationClaimKnownUnsent(claim, reason: .submissionPolicyMismatch, for: account)
            throw MigrationBroadcastError.invalidSubmissionEndpoint
        } catch MigrationBroadcastError.selectedEndpointChainMismatch {
            await releaseMigrationClaimKnownUnsent(claim, reason: .endpointConsensusMismatch, for: account)
            throw MigrationBroadcastError.selectedEndpointChainMismatch
        } catch MigrationBroadcastError.selectedEndpointConsensusBranchMismatch {
            await releaseMigrationClaimKnownUnsent(claim, reason: .endpointConsensusMismatch, for: account)
            throw MigrationBroadcastError.selectedEndpointConsensusBranchMismatch
        } catch let error as MigrationBroadcastError {
            switch error {
            case .selectedEndpointInfoBehindSampledTip:
                await releaseMigrationClaimKnownUnsent(claim, reason: .endpointConsensusMismatch, for: account)
            case .transactionConsensusBranchMismatch:
                await releaseMigrationClaimKnownUnsent(claim, reason: .transactionBranchNotCurrent, for: account)
            case .selectedTransportTipWithinExpirySafetyMargin:
                await releaseMigrationClaimKnownUnsent(claim, reason: .transactionExpiryWindowClosed, for: account)
            default:
                await releaseMigrationClaimKnownUnsent(claim, reason: .transportSetupFailed, for: account)
            }
            throw error
        } catch {
            await releaseMigrationClaimKnownUnsent(claim, reason: .transportSetupFailed, for: account)
            throw error
        }
        // Cancellation after networking begins cannot safely mean "unsent". Preserve the exact
        // engine claim and record an ambiguous outcome even if a transport double raced back with
        // a nominal result while cancellation was being delivered.
        let result: TransferResult = Task.isCancelled ? .outcomeUnknown : submittedResult
        do {
            try await initializer.rustBackend.migrationRecordClaimedTransferResult(
                transferId: claim.id,
                attemptToken: claim.attemptToken,
                result: result,
                for: account
            )
        } catch {
            // A lease can expire after the server responds but before CAS. Never surface that stale
            // response as durable truth. If the engine is readable, its fresh snapshot is the only
            // safe result and recovery will resume the same staged bytes/token path.
            let snapshot = try await initializer.rustBackend.migrationSnapshot(for: account)
            return MigrationExecutionResult(disposition: .verifying, submissionResult: nil, snapshot: snapshot)
        }
        let snapshot = try await initializer.rustBackend.migrationSnapshot(for: account)
        return MigrationExecutionResult(
            disposition: result == .outcomeUnknown ? .verifying : .resultRecorded,
            submissionResult: result,
            snapshot: snapshot
        )
    }

    private static func minimumRequiredMigrationLeaseExpiryMs(endpoint: LightWalletEndpoint) -> UInt64 {
        let nowMs = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
        let timeoutMs = UInt64(max(0, endpoint.singleCallTimeoutInMillis))
        return nowMs.addingReportingOverflow(timeoutMs + 30_000).partialValue
    }

    private func releaseMigrationClaimKnownUnsent(
        _ claim: ClaimedTx,
        reason: KnownUnsentReason,
        for account: AccountUUID
    ) async {
        try? await initializer.rustBackend.migrationReleaseClaimedTransferKnownUnsent(
            transferId: claim.id,
            attemptToken: claim.attemptToken,
            reason: reason,
            for: account
        )
    }

    private func recordMigrationLocalFailure(
        _ failure: LocalSubmissionFailure,
        claim: ClaimedTx,
        for account: AccountUUID
    ) async throws {
        try await initializer.rustBackend.migrationRecordClaimedTransferLocalFailure(
            transferId: claim.id,
            attemptToken: claim.attemptToken,
            failure: failure,
            for: account
        )
    }

    public func hasOverdueTransfers(for account: AccountUUID) async throws -> Bool {
        try await initializer.rustBackend.migrationHasOverdueTransfers(for: account)
    }

    public func hasInvalidTransfers(for account: AccountUUID) async throws -> Bool {
        try await initializer.rustBackend.migrationHasInvalidTransfers(for: account)
    }

    func refreshStaleTransfers(spendingKey: UnifiedSpendingKey, for account: AccountUUID) async throws -> UInt32 {
        let policy = try await requiredBoundMigrationPolicy(for: account)
        return try await initializer.rustBackend.migrationRefreshStaleTransfers(
            usk: spendingKey,
            expectedPolicyFingerprint: policy.policyFingerprint,
            for: account
        )
    }

    func restartCurrentMigrationStep(for account: AccountUUID) async throws -> MigrationSchedule {
        try await initializer.rustBackend.migrationRestartStep(for: account)
    }

    public func initializePostUpgrade(for account: AccountUUID) async throws {
        try await initializer.rustBackend.migrationInitializePostUpgrade(for: account)
    }

    public func createPCZTFromProposal(accountUUID: AccountUUID, proposal: Proposal) async throws -> Pczt {
        try await initializer.rustBackend.createPCZTFromProposal(
            accountUUID: accountUUID,
            proposal: proposal.inner
        )
    }

    public func redactPCZTForSigner(pczt: Pczt) async throws -> Pczt {
        try await initializer.rustBackend.redactPCZTForSigner(
            pczt: pczt
        )
    }

    public func PCZTRequiresSaplingProofs(pczt: Pczt) async -> Bool {
        await initializer.rustBackend.PCZTRequiresSaplingProofs(
            pczt: pczt
        )
    }

    public func addProofsToPCZT(pczt: Pczt) async throws -> Pczt {
        // TODO [#1724]: zcash_client_backend: Make Sapling parameters optional for extract_and_store_transaction
        // TODO [#1724]: https://github.com/zcash/librustzcash/issues/1724
//        if await initializer.rustBackend.PCZTRequiresSaplingProofs(pczt: pczt) {
        try await SaplingParameterDownloader.downloadParamsIfnotPresent(
            spendURL: initializer.spendParamsURL,
            spendSourceURL: initializer.saplingParamsSourceURL.spendParamFileURL,
            outputURL: initializer.outputParamsURL,
            outputSourceURL: initializer.saplingParamsSourceURL.outputParamFileURL,
            logger: logger
        )
//        }

        return try await initializer.rustBackend.addProofsToPCZT(
            pczt: pczt
        )
    }

    public func createTransactionFromPCZT(pcztWithProofs: Pczt, pcztWithSigs: Pczt) async throws -> AsyncThrowingStream<TransactionSubmitResult, Error> {
        let transactions = try await sdkBroadcaster.createTransactionFromPCZT(
            pcztWithProofs: pcztWithProofs,
            pcztWithSigs: pcztWithSigs,
            recordingPlans: false
        )

        return submitTransactions(transactions)
    }

    public func fetchTxidsWithMemoContaining(searchTerm: String) async throws -> [Data] {
        try await transactionRepository.fetchTxidsWithMemoContaining(searchTerm: searchTerm)
    }

    public func allReceivedTransactions() async throws -> [ZcashTransaction.Overview] {
        try await enhanceRawTransactionsWithState(
            rawTransactions: try await transactionRepository.findReceived(offset: 0, limit: Int.max)
        )
    }

    public func allTransactions() async throws -> [ZcashTransaction.Overview] {
        try await enhanceRawTransactionsWithState(
            rawTransactions: try await transactionRepository.find(offset: 0, limit: Int.max, kind: .all)
        )
    }

    public func allSentTransactions() async throws -> [ZcashTransaction.Overview] {
        try await enhanceRawTransactionsWithState(
            rawTransactions: try await transactionRepository.findSent(offset: 0, limit: Int.max)
        )
    }

    public func allTransactions(from transaction: ZcashTransaction.Overview, limit: Int) async throws -> [ZcashTransaction.Overview] {
        try await enhanceRawTransactionsWithState(
            rawTransactions: try await transactionRepository.find(from: transaction, limit: limit, kind: .all)
        )
    }

    private func enhanceRawTransactionsWithState(rawTransactions: [ZcashTransaction.Overview]) async throws -> [ZcashTransaction.Overview] {
        var latestKnownBlockHeight = await latestBlocksDataProvider.latestBlockHeight
        if latestKnownBlockHeight == 0 {
            latestKnownBlockHeight = try await initializer.rustBackend.maxScannedHeight() ?? .zero
        }

        return rawTransactions.map { rawTransaction in
            var copyOfRawTransaction = rawTransaction

            copyOfRawTransaction.state = rawTransaction.getState(for: latestKnownBlockHeight)

            return copyOfRawTransaction
        }
    }

    public func paginatedTransactions(of kind: TransactionKind = .all) -> PaginatedTransactionRepository {
        PagedTransactionRepositoryBuilder.build(initializer: initializer, kind: .all)
    }

    public func getMemos(for rawID: Data) async throws -> [Memo] {
        return try await transactionRepository.findMemos(for: rawID)
    }

    public func getMemos(for transaction: ZcashTransaction.Overview) async throws -> [Memo] {
        return try await transactionRepository.findMemos(for: transaction.rawID)
    }

    public func getRecipients(for transaction: ZcashTransaction.Overview) async -> [TransactionRecipient] {
        return (try? await transactionRepository.getRecipients(for: transaction.rawID)) ?? []
    }

    public func getTransactionOutputs(for transaction: ZcashTransaction.Overview) async -> [ZcashTransaction.Output] {
        return (try? await transactionRepository.getTransactionOutputs(for: transaction.rawID)) ?? []
    }

    public func latestHeight() async throws -> BlockHeight {
        try await blockProcessor.latestHeight(mode: await sdkFlags.ifTor(.torInGroup("SDKSynchronizer.latestHeight")))
    }

    public func networkUpgradeActivationHeight(_ upgrade: NetworkUpgrade) throws -> BlockHeight? {
        try initializer.rustBackend.networkUpgradeActivationHeight(upgrade)
    }

    public func nu6_3ActivationHeight() throws -> BlockHeight? {
        try initializer.rustBackend.nu6_3ActivationHeight()
    }

    public func consensusChainName() throws -> String {
        try initializer.rustBackend.consensusChainName()
    }

    public func consensusParametersFingerprint() throws -> String {
        try initializer.rustBackend.consensusParametersFingerprint()
    }

    public func refreshUTXOs(address: TransparentAddress, from height: BlockHeight) async throws -> RefreshedUTXOs {
        try throwIfUnprepared()
        return try await blockProcessor.refreshUTXOs(tAddress: address, startHeight: height)
    }

    public func getAccountsBalances() async throws -> [AccountUUID: AccountBalance] {
        try await initializer.rustBackend.getWalletSummary()?.accountBalances ?? [:]
    }

    /// Fetches the latest ZEC-USD exchange rate.
    public func refreshExchangeRateUSD() {
        Task {
            // ignore when Tor is not enabled
            guard await sdkFlags.exchangeRateEnabled else {
                return
            }

            // ignore refresh request when one is already in flight
            if let latestState = await exchangeRateTor?.cachedFiatCurrencyResult?.state, latestState == .fetching {
                return
            }

            // broadcast cached value but update the state
            if let cachedFiatCurrencyResult = await exchangeRateTor?.cachedFiatCurrencyResult {
                var fetchingState = cachedFiatCurrencyResult
                fetchingState.state = .fetching
                await exchangeRateTor?.updateCachedFiatCurrencyResult(fetchingState)

                exchangeRateUSDSubject.send(fetchingState)
            }

            do {
                if exchangeRateTor == nil {
                    logger.info("Bootstrapping Tor client for fetching exchange rates")
                    let torClient = initializer.container.resolve(TorClient.self)
                    exchangeRateTor = try await torClient.isolatedClient()
                }
                // broadcast new value in case of success
                exchangeRateUSDSubject.send(try await exchangeRateTor?.getExchangeRateUSD())
            } catch {
                // broadcast cached value but update the state
                var errorState = await exchangeRateTor?.cachedFiatCurrencyResult
                errorState?.state = .error
                await exchangeRateTor?.updateCachedFiatCurrencyResult(errorState)

                exchangeRateUSDSubject.send(errorState)
            }
        }
    }

    public func getUnifiedAddress(accountUUID: AccountUUID) async throws -> UnifiedAddress {
        try await blockProcessor.getUnifiedAddress(accountUUID: accountUUID)
    }

    public func getSaplingAddress(accountUUID: AccountUUID) async throws -> SaplingAddress {
        try await blockProcessor.getSaplingAddress(accountUUID: accountUUID)
    }

    public func getTransparentAddress(accountUUID: AccountUUID) async throws -> TransparentAddress {
        try await blockProcessor.getTransparentAddress(accountUUID: accountUUID)
    }

    public func getCustomUnifiedAddress(accountUUID: AccountUUID, receivers: Set<ReceiverType>) async throws -> UnifiedAddress {
        try await blockProcessor.getCustomUnifiedAddress(accountUUID: accountUUID, receivers: receivers)
    }

    // MARK: Rescan

    public func rescanFrom(height: BlockHeight) async throws {
        // Ensure sapling activation is the lowest possible
        let saplingActivationHeight = network.saplingActivationHeight

        guard height >= saplingActivationHeight else {
            throw ZcashError.rescanFromHeightBellowSaplingActivation
        }

        let checkpointSource = initializer.container.resolve(CheckpointSource.self)

        let checkpoint = checkpointSource.birthday(for: height)

        try await initializer.rustBackend.truncateToChainState(chainState: checkpoint.treeState())
    }

    // MARK: Rewind

    public func rewind(_ policy: RewindPolicy) -> AnyPublisher<Void, Error> {
        let subject = PassthroughSubject<Void, Error>()
        Task(priority: .high) {
            if !latestState.internalSyncStatus.isPrepared {
                subject.send(completion: .failure(ZcashError.synchronizerNotPrepared))
                return
            }

            let height: BlockHeight?

            switch policy {
            case .quick:
                height = nil

            case .birthday:
                let birthday = await self.blockProcessor.config.walletBirthday
                height = birthday

            case .height(let rewindHeight):
                height = rewindHeight

            case .transaction(let transaction):
                guard let txHeight = transaction.anchor(network: self.network) else {
                    throw ZcashError.synchronizerRewindUnknownArchorHeight
                }
                height = txHeight
            }

            let context = AfterSyncHooksManager.RewindContext(
                height: height,
                completion: { result in
                    switch result {
                    case .success:
                        subject.send(completion: .finished)

                    case let .failure(error):
                        subject.send(completion: .failure(error))
                    }
                }
            )

            do {
                try await blockProcessor.rewind(context: context)
            } catch {
                subject.send(completion: .failure(error))
            }
        }
        return subject.eraseToAnyPublisher()
    }

    // MARK: Wipe

    public func wipe() -> AnyPublisher<Void, Error> {
        let subject = PassthroughSubject<Void, Error>()
        Task(priority: .high) {
            if let error = checkIfCanContinueInitialisation() {
                subject.send(completion: .failure(error))
                return
            }

            let context = AfterSyncHooksManager.WipeContext(
                prewipe: { [weak self] in
                    self?.transactionEncoder.closeDBConnection()
                    self?.transactionRepository.closeDBConnection()
                },
                completion: { [weak self] possibleError in
                    if possibleError == nil {
                        await self?.submitPlanStore.wipe()
                    }
                    await self?.updateStatus(.unprepared)
                    if let error = possibleError {
                        subject.send(completion: .failure(error))
                    } else {
                        subject.send(completion: .finished)
                    }
                }
            )

            do {
                try await blockProcessor.wipe(context: context)
            } catch {
                subject.send(completion: .failure(error))
            }
        }

        return subject.eraseToAnyPublisher()
    }

    public func isSeedRelevantToAnyDerivedAccount(seed: [UInt8]) async throws -> Bool {
        try await initializer.rustBackend.isSeedRelevantToAnyDerivedAccount(seed: seed)
    }

    /// Takes the list of endpoints and runs it through a series of checks to evaluate its performance.
    /// - Parameters:
    ///    - endpoints: Array of endpoints to evaluate.
    ///    - latencyThresholdMillis: The mean latency of `getInfo` and `getTheLatestHeight` calls must be below this threshold. The default is 300 ms.
    ///    - fetchThresholdSeconds: The time to download `nBlocksToFetch` blocks from the stream must be below this threshold. The default is 60 seconds.
    ///    - nBlocksToFetch: The number of blocks expected to be downloaded from the stream, with the time compared to `fetchThresholdSeconds`. The default is 100.
    ///    - kServers: The expected number of endpoints in the output. The default is 3.
    ///    - network: Mainnet or testnet. The default is mainnet.
    // swiftlint:disable:next cyclomatic_complexity
    public func evaluateBestOf(
        endpoints: [LightWalletEndpoint],
        fetchThresholdSeconds: Double = 60.0,
        nBlocksToFetch: UInt64 = 100,
        kServers: Int = 3,
        network: NetworkType = .mainnet
    ) async -> [LightWalletEndpoint] {
        struct Service {
            let originalEndpoint: LightWalletEndpoint
            let service: LightWalletGRPCService
            let url: String
        }

        struct CheckResult {
            let id: String
            let info: LightWalletdInfo?
            let getInfoTime: TimeInterval
            let latestBlockHeight: BlockHeight?
            let latestBlockHeightTime: TimeInterval
            let mean: TimeInterval
            let service: Service
            var blockTime: TimeInterval
        }

        let torClient = initializer.container.resolve(TorClient.self)

        // Initialize services for the endpoints
        let services = endpoints.map {
            Service(
                originalEndpoint: $0,
                service: LightWalletGRPCServiceOverTor(endpoint: $0, tor: torClient),
                url: "\($0.host):\($0.port)"
            )
        }

        // Parallel part
        var checkResults: [String: CheckResult] = [:]
        let sdkFlagsRef = sdkFlags

        await withTaskGroup(of: CheckResult.self) { group in
            for service in services {
                group.addTask {
                    let startTime = Date().timeIntervalSince1970

                    // called when performance of servers is evaluated
                    let mode = await sdkFlagsRef.ifTor(ServiceMode.torInGroup("SDKSynchronizer.evaluateBestOf(\(service.originalEndpoint))"))

                    let info = try? await service.service.getInfo(mode: mode)
                    let markTime = Date().timeIntervalSince1970
                    // called when performance of servers is evaluated
                    let latestBlockHeight = try? await service.service.latestBlockHeight(mode: mode)
                    let endTime = Date().timeIntervalSince1970

                    let getInfoTime = markTime - startTime
                    let latestBlockHeightTime = endTime - markTime
                    let mean = (getInfoTime + latestBlockHeightTime) / 2

                    return CheckResult(
                        id: service.url,
                        info: info,
                        getInfoTime: getInfoTime,
                        latestBlockHeight: latestBlockHeight,
                        latestBlockHeightTime: latestBlockHeightTime,
                        mean: mean,
                        service: service,
                        blockTime: 0
                    )
                }
            }

            var tmpResults: [String: CheckResult] = [:]

            for await result in group {
                // rule out results where calls failed
                guard let info = result.info, result.latestBlockHeight != nil else {
                    continue
                }

                // rule out if mismatch of networks
                guard (info.chainName == "main" && network == .mainnet)
                    || (info.chainName == "test" && network == .testnet)
                    || (info.chainName == "regtest" && network == .regtest) else {
                    continue
                }

                // rule out mismatch of consensus branch IDs
                guard let localBranchID = await blockProcessor.consensusBranchIdFor(Int32(info.blockHeight)) else {
                    continue
                }

                guard let remoteBranchID = ConsensusBranchID.fromString(info.consensusBranchID) else {
                    continue
                }

                guard remoteBranchID == localBranchID else {
                    continue
                }

                // Rule out servers that are syncing, stuck, or probably on the wrong fork.
                // To avoid falsely ruling out all servers this can only be a very loose check
                // (i.e. `ZcashSDK.syncedThresholdBlocks` should not be too small),
                // because `info.estimatedHeight` may be quite inaccurate.
                guard info.blockHeight + ZcashSDK.syncedThresholdBlocks >= info.estimatedHeight else {
                    continue
                }

                tmpResults[result.id] = result
            }

            // sort the server responses by mean
            let sortedCheckResults = tmpResults.sorted {
                $0.value.mean < $1.value.mean
            }

            // retain k servers
            let sortedKOnly = sortedCheckResults.prefix(kServers)

            sortedKOnly.forEach {
                checkResults[$0.key] = $0.value
            }
        }

        // Sequential part
        var blockResults: [String: CheckResult] = [:]

        for serviceDict in checkResults {
            guard let info = serviceDict.value.info else {
                continue
            }

            let service = serviceDict.value.service

            guard info.blockHeight >= nBlocksToFetch else {
                continue
            }

            do {
                // Fetched the same way as in `BlockDownloader`.
                let stream = try service.service.blockStream(
                    startHeight: BlockHeight(info.blockHeight - nBlocksToFetch),
                    endHeight: BlockHeight(info.blockHeight),
                    mode: .direct
                )

                let startTime = Date().timeIntervalSince1970
                var endTime = startTime
                for try await _ in stream {
                    endTime = Date().timeIntervalSince1970
                    if endTime - startTime >= fetchThresholdSeconds {
                        break
                    }
                }

                let blockTime = endTime - startTime

                // rule out servers that can't fetch `nBlocksToFetch` blocks under fetchThresholdSeconds
                if blockTime < fetchThresholdSeconds {
                    var value = serviceDict.value
                    value.blockTime = blockTime

                    blockResults[serviceDict.key] = value
                }
            } catch {
                continue
            }
        }

        // return what's left
        let sortedServers = blockResults.sorted {
            $0.value.blockTime < $1.value.blockTime
        }

        let finalResult = sortedServers.map {
            $0.value.service.originalEndpoint
        }

        return finalResult
    }

    public func estimateBirthdayHeight(for date: Date) -> BlockHeight {
        initializer.container.resolve(CheckpointSource.self).estimateBirthdayHeight(for: date)
    }

    public func estimateTimestamp(for height: BlockHeight) -> TimeInterval? {
        initializer.container.resolve(CheckpointSource.self).estimateTimestamp(for: height)
    }

    public func tor(enabled: Bool) async throws {
        let isExchangeRateEnabled = await sdkFlags.exchangeRateEnabled

        // turn Tor on
        if enabled && !isExchangeRateEnabled {
            try await enableAndStartupTorClient()
        }

        // turn Tor off
        if !enabled && !isExchangeRateEnabled {
            try await disableAndCleanupTorClients()
        }

        await sdkFlags.torFlagUpdate(enabled)
    }

    public func exchangeRateOverTor(enabled: Bool) async throws {
        let isTorEnabled = await sdkFlags.torEnabled

        // turn Tor on
        if enabled && !isTorEnabled {
            try await enableAndStartupTorClient()
        }

        // turn Tor off
        if !enabled && !isTorEnabled {
            try await disableAndCleanupTorClients()
        }

        await sdkFlags.exchangeRateFlagUpdate(enabled)
    }

    private func enableAndStartupTorClient() async throws {
        let torClient = initializer.container.resolve(TorClient.self)
        try await torClient.prepare()
    }

    private func disableAndCleanupTorClients() async throws {
        await sdkFlags.torClientInitializationSuccessfullyDoneFlagUpdate(nil)

        // case when previous was enabled and newly is required to be stopped
        let torClient = initializer.container.resolve(TorClient.self)
        // close of the initial TorClient, it's used for creation of isolated clients
        try await torClient.close()
        // deinit of isolated TorClient used for fetching exchange rates
        exchangeRateTor = nil
        // deinit of isolated TorClient used for http requests
        httpTor = nil
        // close all connections
        let lwdService = initializer.container.resolve(LightWalletService.self)
        await lwdService.closeConnections()
    }

    public func isTorSuccessfullyInitialized() async -> Bool? {
        await sdkFlags.torClientInitializationSuccessfullyDone
    }

    public func httpRequestOverTor(for request: URLRequest, retryLimit: UInt8 = 3) async throws -> (data: Data, response: HTTPURLResponse) {
        let torEnabled = await sdkFlags.torEnabled
        let exchangeRateEnabled = await sdkFlags.exchangeRateEnabled

        guard torEnabled || exchangeRateEnabled else {
            throw ZcashError.torNotEnabled
        }

        if httpTor == nil {
            logger.info("Bootstrapping Tor client for making http requests")
            if let torService = initializer.container.resolve(LightWalletService.self) as? LightWalletGRPCServiceOverTor {
                httpTor = try await torService.tor.isolatedClient()
            }
        }

        guard let httpTor else {
            throw ZcashError.torClientUnavailable
        }

        return try await httpTor.isolatedClient().httpRequest(for: request, retryLimit: retryLimit)
    }

    public func debugDatabase(sql: String) -> String {
        transactionRepository.debugDatabase(sql: sql)
    }

    public func getTreeState(height: UInt64) async throws -> Data {
        let treeState = try await initializer.lightWalletService.getTreeState(
            BlockID(height: height),
            mode: await sdkFlags.ifTor(.uniqueTor)
        )
        return try treeState.serializedData()
    }

    public func getSingleUseTransparentAddress(accountUUID: AccountUUID) async throws -> SingleUseTransparentAddress {
        try await initializer.rustBackend.getSingleUseTransparentAddress(accountUUID: accountUUID)
    }

    public func checkSingleUseTransparentAddresses(accountUUID: AccountUUID) async throws -> TransparentAddressCheckResult {
        let dbData = initializer.dataDbURL.osStr()

        return try await initializer.lightWalletService.checkSingleUseTransparentAddresses(
            dbData: dbData,
            networkType: network.networkType,
            accountUUID: accountUUID,
            mode: await sdkFlags.ifTor(.uniqueTor)
        )
    }

    public func updateTransparentAddressTransactions(address: String) async throws -> TransparentAddressCheckResult {
        let dbData = initializer.dataDbURL.osStr()

        return try await initializer.lightWalletService.updateTransparentAddressTransactions(
            address: address,
            start: 0,
            end: -1,
            dbData: dbData,
            networkType: network.networkType,
            mode: await sdkFlags.ifTor(.uniqueTor)
        )
    }

    public func fetchUTXOsBy(address: String, accountUUID: AccountUUID) async throws -> TransparentAddressCheckResult {
        let dbData = initializer.dataDbURL.osStr()

        return try await initializer.lightWalletService.fetchUTXOsByAddress(
            address: address,
            dbData: dbData,
            networkType: network.networkType,
            accountUUID: accountUUID,
            mode: await sdkFlags.ifTor(.uniqueTor)
        )
    }

    public func enhanceTransactionBy(txId: TxId) async throws -> Void {
        let txIdData = txId.id.data

        let response = try await initializer.blockDownloaderService.fetchTransaction(
            txId: txIdData,
            mode: await sdkFlags.ifTor(ServiceMode.txIdGroup(prefix: "fetch", txId: txIdData))
        )

        if response.status == .txidNotRecognized {
            try await initializer.rustBackend.setTransactionStatus(txId: txIdData, status: .txidNotRecognized)
        } else if let fetchedTransaction = response.tx {
            _ = try await initializer.rustBackend.decryptAndStoreTransaction(
                txBytes: fetchedTransaction.raw.bytes,
                minedHeight: fetchedTransaction.minedHeight
            )
        }
    }

    public func deleteAccount(_ accountUUID: AccountUUID) async throws {
        try await initializer.rustBackend.deleteAccount(accountUUID)
    }

    // MARK: Server switch

    public func switchTo(endpoint: LightWalletEndpoint) async throws {
        // Stop synchronization
        let status = await self.status
        if status != .stopped && status != .disconnected {
            await blockProcessor.stop()
        }

        let torClient = initializer.container.resolve(TorClient.self)

        // Validation of the server is first because any custom endpoint can be passed here
        // Extra instance of the service is created with lower timeout for a single call
        initializer.container.register(type: LightWalletService.self, isSingleton: true) { _ in
            LightWalletGRPCServiceOverTor(endpoint: endpoint, tor: torClient, singleCallTimeout: 5000)
        }

        let validateSever = ValidateServerAction(
            container: initializer.container,
            configProvider: CompactBlockProcessor.ConfigProvider(config: await blockProcessor.config)
        )

        do {
            _ = try await validateSever.run(with: ActionContextImpl(state: .idle)) { _ in }
        } catch {
            throw ZcashError.synchronizerServerSwitch
        }

        // The `ValidateServerAction` confirmed the server is ok and we can continue
        // final instance of the service will be instantiated and propagated to the all parties

        // SWITCH TO NEW ENDPOINT

        // LightWalletService dependency update
        initializer.container.register(type: LightWalletService.self, isSingleton: true) { _ in
            LightWalletGRPCServiceOverTor(endpoint: endpoint, tor: torClient)
        }

        // DEPENDENCIES

        // BlockDownloaderService dependency update
        initializer.container.register(type: BlockDownloaderService.self, isSingleton: true) { di in
            let service = di.resolve(LightWalletService.self)
            let storage = di.resolve(CompactBlockRepository.self)

            return BlockDownloaderServiceImpl(service: service, storage: storage)
        }

        // LatestBlocksDataProvider dependency update
        initializer.container.register(type: LatestBlocksDataProvider.self, isSingleton: true) { di in
            let service = di.resolve(LightWalletService.self)
            let rustBackend = di.resolve(ZcashRustBackendWelding.self)
            let sdkFlags = di.resolve(SDKFlags.self)

            return LatestBlocksDataProviderImpl(service: service, rustBackend: rustBackend, sdkFlags: sdkFlags)
        }

        // TransactionEncoder dependency update
        let config = await blockProcessor.config
        let fsBlockDbRoot = initializer.fsBlockDbRoot

        initializer.container.register(type: TransactionEncoder.self, isSingleton: true) { di in
            let service = di.resolve(LightWalletService.self)
            let logger = di.resolve(Logger.self)
            let transactionRepository = di.resolve(TransactionRepository.self)
            let rustBackend = di.resolve(ZcashRustBackendWelding.self)
            let sdkFlags = di.resolve(SDKFlags.self)

            return WalletTransactionEncoder(
                rustBackend: rustBackend,
                dataDb: config.dataDb,
                fsBlockDbRoot: fsBlockDbRoot,
                service: service,
                repository: transactionRepository,
                outputParams: config.outputParamsURL,
                spendParams: config.spendParamsURL,
                networkType: config.network.networkType,
                logger: logger,
                sdkFlags: sdkFlags
            )
        }

        // CompactBlockProcessor dependency update
        Dependencies.setupCompactBlockProcessor(
            in: initializer.container,
            config: await blockProcessor.config
        )

        // INITIALIZER
        initializer.lightWalletService = initializer.container.resolve(LightWalletService.self)
        initializer.blockDownloaderService = initializer.container.resolve(BlockDownloaderService.self)
        initializer.endpoint = endpoint

        // SELF
        self.latestBlocksDataProvider = initializer.container.resolve(LatestBlocksDataProvider.self)
        self.transactionEncoder = initializer.container.resolve(TransactionEncoder.self)

        // COMPACT BLOCK PROCESSOR
        await blockProcessor.updateService(initializer.container)

        // Start synchronization
        if status != .unprepared {
            try await start(retry: true)
        }
    }

    // MARK: notify state

    private func snapshotState(status: InternalSyncStatus) async -> SynchronizerState {
        await SynchronizerState(
            syncSessionID: syncSession.value,
            accountsBalances: (try? await getAccountsBalances()) ?? [:],
            internalSyncStatus: status,
            latestBlockHeight: latestBlocksDataProvider.latestBlockHeight,
            fullyScannedHeight: latestBlocksDataProvider.fullyScannedHeight
        )
    }

    private func notify(oldStatus: InternalSyncStatus, newStatus: InternalSyncStatus, updateExternalStatus: Bool = true) async {
        guard oldStatus != newStatus else { return }

        let newState: SynchronizerState

        // When the wipe happens status is switched to `unprepared`. And we expect that everything is deleted. All the databases including data DB.
        // When new snapshot is created balance is checked. And when balance is checked and data DB doesn't exist then rust initialise new database.
        // So it's necessary to not create new snapshot after status is switched to `unprepared` otherwise data DB exists after wipe
        if newStatus == .unprepared {
            var nextState = SynchronizerState.zero

            let nextSessionID = await self.syncSession.update(.nullID)

            nextState.syncSessionID = nextSessionID
            newState = nextState
        } else {
            if SessionTicker.live.isNewSyncSession(oldStatus, newStatus) {
                await self.syncSession.newSession(with: self.syncSessionIDGenerator)
            }
            newState = await snapshotState(status: newStatus)
        }

        latestState = newState

        if updateExternalStatus {
            updateStateStream(with: latestState)
        }
    }

    private func updateStateStream(with newState: SynchronizerState) {
        streamsUpdateQueue.async { [weak self] in
            self?.stateSubject.send(newState)
        }
    }

    private func notifyMinedTransaction(_ transaction: ZcashTransaction.Overview) {
        streamsUpdateQueue.async { [weak self] in
            self?.eventSubject.send(.minedTransaction(transaction))
        }
    }
}

extension SDKSynchronizer {
    public var transactions: [ZcashTransaction.Overview] {
        get async {
            (try? await self.allTransactions()) ?? []
        }
    }

    public var sentTransactions: [ZcashTransaction.Overview] {
        get async {
            (try? await allSentTransactions()) ?? []
        }
    }

    public var receivedTransactions: [ZcashTransaction.Overview] {
        get async {
            (try? await allReceivedTransactions()) ?? []
        }
    }
}

extension InternalSyncStatus {
    func isDifferent(from otherStatus: InternalSyncStatus) -> Bool {
        switch (self, otherStatus) {
        case (.unprepared, .unprepared): return false
        case (.syncing, .syncing): return false
        case (.synced, .synced): return false
        case (.stopped, .stopped): return false
        case (.disconnected, .disconnected): return false
        case (.error, .error): return false
        default: return true
        }
    }
}

struct SessionTicker {
    /// Helper function to determine whether we are in front of a SyncSession change for a given syncStatus
    /// transition we consider that every sync attempt is a new sync session and should have it's unique UUID reported.
    var isNewSyncSession: (InternalSyncStatus, InternalSyncStatus) -> Bool
}

extension SessionTicker {
    static let live = SessionTicker { oldStatus, newStatus in
        // if the state hasn't changed to a different syncStatus member
        guard oldStatus.isDifferent(from: newStatus) else { return false }

        switch (oldStatus, newStatus) {
        case (.unprepared, .syncing):
            return true
        case (.error, .syncing),
            (.disconnected, .syncing),
            (.stopped, .syncing),
            (.synced, .syncing):
            return true
        default:
            return false
        }
    }
}
