//
//  PendingSubmitPlanStoreTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class PendingSubmitPlanStoreTests: ZcashTestCase {
    func testCreatedTransactionsWaitForSubmitPlan() async throws {
        let transaction = makeTransaction(rawID: Data(repeating: 0xAB, count: 32))
        let store = PendingSubmitPlanStore(logger: NullLogger())

        await markAwaiting([transaction], in: store)

        switch await store.getSubmitPlan(for: transaction.rawID) {
        case .awaitingPlan:
            break
        default:
            XCTFail("Expected transaction to wait for a submit plan.")
        }
    }

    func testPersistsSubmitPlans() async throws {
        let persistence = InMemorySubmitPlanPersistence()
        let transaction = makeTransaction(rawID: Data(repeating: 0xAB, count: 32))
        let endpoint = LightWalletEndpointBuilder.default
        let firstStore = PendingSubmitPlanStore(persistence: persistence, logger: NullLogger())

        await markAwaiting([transaction], in: firstStore)
        await firstStore.addSubmitEndpoint(transaction: transaction, endpoint: endpoint)

        let secondStore = PendingSubmitPlanStore(persistence: persistence, logger: NullLogger())
        switch await secondStore.getSubmitPlan(for: transaction.rawID) {
        case .ready(let plan):
            XCTAssertEqual(plan.endpoints.count, 1)
            assertEndpoint(plan.endpoints[0], equals: endpoint)
        default:
            XCTFail("Expected persisted submit plan.")
        }
    }

    func testIgnoresPersistedSubmitPlansWithUnsupportedVersion() async throws {
        let persistence = InMemorySubmitPlanPersistence()
        let transaction = makeTransaction(rawID: Data(repeating: 0xAB, count: 32))
        persistence.data = """
        {
            "version": 2,
            "plansByTransactionId": {
                "\(transaction.rawID.hexEncodedString())": [
                    {
                        "host": "submit.z.cash",
                        "port": 443,
                        "secure": true,
                        "singleCallTimeoutInMillis": 1000,
                        "streamingCallTimeoutInMillis": 2000
                    }
                ]
            }
        }
        """.data(using: .utf8)

        let store = PendingSubmitPlanStore(persistence: persistence, logger: NullLogger())
        let plan = await store.getSubmitPlan(for: transaction.rawID)

        XCTAssertNil(plan)
    }

    func testDoesNotOverwritePersistedSubmitPlansWhenLoadFails() async throws {
        let persistence = InMemorySubmitPlanPersistence()
        let originalData = Data("persisted submit plans".utf8)
        let transaction = makeTransaction(rawID: Data(repeating: 0xAB, count: 32))
        persistence.data = originalData
        persistence.loadError = SubmitPlanPersistenceTestError.loadFailed
        let store = PendingSubmitPlanStore(persistence: persistence, logger: NullLogger())

        await markAwaiting([transaction], in: store)

        XCTAssertEqual(persistence.saveCallCount, 0)
        XCTAssertEqual(persistence.data, originalData)
    }

    func testAddsSubmittedEndpointsToExistingPlan() async throws {
        let transaction = makeTransaction(rawID: Data(repeating: 0xAB, count: 32))
        let firstEndpoint = LightWalletEndpoint(address: "a.z.cash", port: 443, secure: true)
        let secondEndpoint = LightWalletEndpoint(address: "b.z.cash", port: 443, secure: true)
        let store = PendingSubmitPlanStore(logger: NullLogger())

        await markAwaiting([transaction], in: store)
        await store.addSubmitEndpoint(transaction: transaction, endpoint: firstEndpoint)
        await store.addSubmitEndpoint(transaction: transaction, endpoint: secondEndpoint)

        switch await store.getSubmitPlan(for: transaction.rawID) {
        case .ready(let plan):
            XCTAssertEqual(plan.endpoints.count, 2)
            assertEndpoint(plan.endpoints[0], equals: firstEndpoint)
            assertEndpoint(plan.endpoints[1], equals: secondEndpoint)
        default:
            XCTFail("Expected submit plan with both endpoints.")
        }
    }

    func testAddsSubmittedEndpointByRawTransaction() async throws {
        let rawTransaction = Data([0x01, 0x02])
        let transaction = makeTransaction(rawID: Data(repeating: 0xAB, count: 32), raw: rawTransaction)
        let endpoint = LightWalletEndpoint(address: "submit.z.cash", port: 443, secure: true)
        let store = PendingSubmitPlanStore(logger: NullLogger())

        await markAwaiting([transaction], in: store)
        await store.addSubmitEndpoint(rawTransaction: rawTransaction, endpoint: endpoint)

        switch await store.getSubmitPlan(for: transaction.rawID) {
        case .ready(let plan):
            XCTAssertEqual(plan.endpoints.count, 1)
            assertEndpoint(plan.endpoints[0], equals: endpoint)
        default:
            XCTFail("Expected raw transaction submit path to register the endpoint.")
        }
    }

    func testPrunesPlansThatAreNoLongerResubmissionCandidates() async throws {
        let persistence = InMemorySubmitPlanPersistence()
        let prunedRawTransaction = Data([0x03, 0x04])
        let retainedTransaction = makeTransaction(
            rawID: Data(repeating: 0xAB, count: 32),
            raw: Data([0x01, 0x02])
        )
        let prunedTransaction = makeTransaction(
            rawID: Data(repeating: 0xCD, count: 32),
            raw: prunedRawTransaction
        )
        let store = PendingSubmitPlanStore(persistence: persistence, logger: NullLogger())

        await markAwaiting([retainedTransaction, prunedTransaction], in: store)
        await store.addSubmitEndpoint(transaction: retainedTransaction, endpoint: LightWalletEndpointBuilder.default)
        await store.addSubmitEndpoint(transaction: prunedTransaction, endpoint: LightWalletEndpointBuilder.eccTestnet)
        await loadAndRetain([retainedTransaction], in: store)
        await store.addSubmitEndpoint(rawTransaction: prunedRawTransaction, endpoint: LightWalletEndpointBuilder.eccTestnet)

        let reloadedStore = PendingSubmitPlanStore(persistence: persistence, logger: NullLogger())
        let retainedPlan = await reloadedStore.getSubmitPlan(for: retainedTransaction.rawID)
        let prunedPlan = await reloadedStore.getSubmitPlan(for: prunedTransaction.rawID)
        XCTAssertNotNil(retainedPlan)
        XCTAssertNil(prunedPlan)
    }

    func testRetainSkipsPruneWhenCreationCompletesDuringCandidateLookup() async throws {
        let transaction = makeTransaction(rawID: Data(repeating: 0xAB, count: 32))
        let store = PendingSubmitPlanStore(logger: NullLogger())
        let lookupStarted = AsyncSignal()
        let allowLookupToReturn = AsyncSignal()

        let retainTask = Task {
            await store.loadTransactionsAndRetainSubmitPlans(
                loadTransactions: {
                    await lookupStarted.signal()
                    await allowLookupToReturn.wait()
                    return [ZcashTransaction.Overview]()
                },
                transactionId: { $0.rawID }
            )
        }
        await lookupStarted.wait()

        await markAwaiting([transaction], in: store)
        await allowLookupToReturn.signal()
        _ = await retainTask.value

        switch await store.getSubmitPlan(for: transaction.rawID) {
        case .awaitingPlan:
            break
        default:
            XCTFail("Expected submit plan created during candidate lookup to survive stale pruning.")
        }
    }

    func testRetainSkipsPruneWhenCreationWasAlreadyActiveDuringCandidateLookup() async throws {
        let existingTransaction = makeTransaction(rawID: Data(repeating: 0xAB, count: 32))
        let store = PendingSubmitPlanStore(logger: NullLogger())
        let creationStarted = AsyncSignal()
        let allowCreationToReturn = AsyncSignal()
        let lookupStarted = AsyncSignal()
        let allowLookupToReturn = AsyncSignal()

        await markAwaiting([existingTransaction], in: store)

        let creationTask = Task {
            await store.createAndMarkAwaitingSubmitPlan {
                await creationStarted.signal()
                await allowCreationToReturn.wait()
                return []
            }
        }
        await creationStarted.wait()

        let retainTask = Task {
            await store.loadTransactionsAndRetainSubmitPlans(
                loadTransactions: {
                    await lookupStarted.signal()
                    await allowLookupToReturn.wait()
                    return [ZcashTransaction.Overview]()
                },
                transactionId: { $0.rawID }
            )
        }
        await lookupStarted.wait()

        await allowCreationToReturn.signal()
        _ = await creationTask.value
        await allowLookupToReturn.signal()
        _ = await retainTask.value

        switch await store.getSubmitPlan(for: existingTransaction.rawID) {
        case .awaitingPlan:
            break
        default:
            XCTFail("Expected stale pruning to be skipped when lookup started during transaction creation.")
        }
    }

    func testEndpointRegistrationDuringCandidateLookupInvalidatesPrune() async throws {
        let transaction = makeTransaction(rawID: Data(repeating: 0xAB, count: 32))
        let endpoint = LightWalletEndpoint(address: "submit.z.cash", port: 443, secure: true)
        let store = PendingSubmitPlanStore(logger: NullLogger())
        let lookupStarted = AsyncSignal()
        let allowLookupToReturn = AsyncSignal()

        let retainTask = Task {
            await store.loadTransactionsAndRetainSubmitPlans(
                loadTransactions: {
                    await lookupStarted.signal()
                    await allowLookupToReturn.wait()
                    return [ZcashTransaction.Overview]()
                },
                transactionId: { $0.rawID }
            )
        }
        await lookupStarted.wait()

        await store.addSubmitEndpoint(transaction: transaction, endpoint: endpoint)
        await allowLookupToReturn.signal()
        _ = await retainTask.value

        switch await store.getSubmitPlan(for: transaction.rawID) {
        case .ready(let plan):
            XCTAssertEqual(plan.endpoints.count, 1)
            assertEndpoint(plan.endpoints[0], equals: endpoint)
        default:
            XCTFail("Expected endpoint registration during candidate lookup to invalidate stale pruning.")
        }

        await loadAndRetain([], in: store)
        let planAfterCleanRetain = await store.getSubmitPlan(for: transaction.rawID)
        XCTAssertNil(planAfterCleanRetain)
    }

    func testOverlappingRetainsDoNotBothPruneFromStaleSnapshots() async throws {
        let firstTransaction = makeTransaction(rawID: Data(repeating: 0xAB, count: 32))
        let secondTransaction = makeTransaction(rawID: Data(repeating: 0xCD, count: 32))
        let store = PendingSubmitPlanStore(logger: NullLogger())
        let firstLookupStarted = AsyncSignal()
        let secondLookupStarted = AsyncSignal()
        let allowFirstLookupToReturn = AsyncSignal()
        let allowSecondLookupToReturn = AsyncSignal()

        await markAwaiting([firstTransaction, secondTransaction], in: store)

        let firstRetainTask = Task {
            await store.loadTransactionsAndRetainSubmitPlans(
                loadTransactions: {
                    await firstLookupStarted.signal()
                    await allowFirstLookupToReturn.wait()
                    return [firstTransaction]
                },
                transactionId: { $0.rawID }
            )
        }
        let secondRetainTask = Task {
            await store.loadTransactionsAndRetainSubmitPlans(
                loadTransactions: {
                    await secondLookupStarted.signal()
                    await allowSecondLookupToReturn.wait()
                    return [secondTransaction]
                },
                transactionId: { $0.rawID }
            )
        }
        await firstLookupStarted.wait()
        await secondLookupStarted.wait()

        await allowFirstLookupToReturn.signal()
        _ = await firstRetainTask.value
        await allowSecondLookupToReturn.signal()
        _ = await secondRetainTask.value

        let firstPlan = await store.getSubmitPlan(for: firstTransaction.rawID)
        let secondPlan = await store.getSubmitPlan(for: secondTransaction.rawID)
        XCTAssertNotNil(firstPlan)
        XCTAssertNil(secondPlan)
    }

    func testThrowingCreationDoesNotSuppressFuturePruning() async throws {
        let staleTransaction = makeTransaction(rawID: Data(repeating: 0xAB, count: 32))
        let store = PendingSubmitPlanStore(logger: NullLogger())

        await markAwaiting([staleTransaction], in: store)

        do {
            _ = try await store.createAndMarkAwaitingSubmitPlan {
                throw CancellationError()
            }
            XCTFail("Expected transaction creation to throw.")
        } catch is CancellationError {
            // Expected.
        }

        await loadAndRetain([], in: store)

        let plan = await store.getSubmitPlan(for: staleTransaction.rawID)
        XCTAssertNil(plan)
    }

    func testClearDuringCreationPreventsPlanFromBeingRecorded() async throws {
        let transaction = makeTransaction(rawID: Data(repeating: 0xAB, count: 32))
        let store = PendingSubmitPlanStore(logger: NullLogger())
        let creationStarted = AsyncSignal()
        let allowCreationToReturn = AsyncSignal()

        let creationTask = Task {
            await store.createAndMarkAwaitingSubmitPlan {
                await creationStarted.signal()
                await allowCreationToReturn.wait()
                return [transaction]
            }
        }
        await creationStarted.wait()

        await store.clear()
        await allowCreationToReturn.signal()
        _ = await creationTask.value

        let plan = await store.getSubmitPlan(for: transaction.rawID)
        XCTAssertNil(plan)
    }

    func testTxResubmissionSkipsTransactionsAwaitingSubmitPlan() async throws {
        let awaitingTransaction = makeTransaction(rawID: Data(repeating: 0xAB, count: 32))
        let legacyTransaction = makeTransaction(rawID: Data(repeating: 0xCD, count: 32))
        let transactionRepository = TransactionRepositoryMock()
        let transactionEncoder = RecordingTransactionEncoder()
        let store = PendingSubmitPlanStore(logger: NullLogger())
        let submitter = RecordingTransactionSubmitter()

        transactionRepository.findForResubmissionUpToReturnValue = [
            awaitingTransaction,
            legacyTransaction
        ]

        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in transactionRepository }
        mockContainer.mock(type: TransactionEncoder.self, isSingleton: true) { _ in transactionEncoder }
        mockContainer.mock(type: PendingSubmitPlanStore.self, isSingleton: true) { _ in store }
        mockContainer.mock(type: SubmitPlanExecutor.self, isSingleton: true) { _ in
            SubmitPlanExecutor(transactionSubmitter: submitter, logger: NullLogger())
        }
        mockContainer.mock(type: Logger.self, isSingleton: true) { _ in NullLogger() }

        await markAwaiting([awaitingTransaction], in: store)

        let action = TxResubmissionAction(container: mockContainer)
        action.latestResolvedTime = 0
        _ = try await action.run(with: resubmissionContext()) { _ in }

        XCTAssertEqual(transactionEncoder.submittedTransactions.map(\.transactionId), [legacyTransaction.rawID])
        XCTAssertTrue(submitter.submissions.isEmpty)
    }

    func testTxResubmissionUsesRegisteredSubmitPlan() async throws {
        let transaction = makeTransaction(rawID: Data(repeating: 0xAB, count: 32))
        let endpoint = LightWalletEndpoint(address: "submit.z.cash", port: 443, secure: true)
        let transactionRepository = TransactionRepositoryMock()
        let transactionEncoder = RecordingTransactionEncoder()
        let store = PendingSubmitPlanStore(logger: NullLogger())
        let submitter = RecordingTransactionSubmitter()

        transactionRepository.findForResubmissionUpToReturnValue = [transaction]

        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in transactionRepository }
        mockContainer.mock(type: TransactionEncoder.self, isSingleton: true) { _ in transactionEncoder }
        mockContainer.mock(type: PendingSubmitPlanStore.self, isSingleton: true) { _ in store }
        mockContainer.mock(type: SubmitPlanExecutor.self, isSingleton: true) { _ in
            SubmitPlanExecutor(transactionSubmitter: submitter, logger: NullLogger())
        }
        mockContainer.mock(type: Logger.self, isSingleton: true) { _ in NullLogger() }

        await markAwaiting([transaction], in: store)
        await store.addSubmitEndpoint(transaction: transaction, endpoint: endpoint)

        let action = TxResubmissionAction(container: mockContainer)
        action.latestResolvedTime = 0
        _ = try await action.run(with: resubmissionContext()) { _ in }

        XCTAssertTrue(transactionEncoder.submittedTransactions.isEmpty)
        XCTAssertEqual(submitter.submissions.map(\.transaction.transactionId), [transaction.rawID])
        assertEndpoint(try XCTUnwrap(submitter.submissions.first?.endpoint), equals: endpoint)
    }

    func testTxResubmissionDoesNotPrunePlanCreatedAfterCandidateLookup() async throws {
        let createdTransaction = makeTransaction(rawID: Data(repeating: 0xAB, count: 32))
        let transactionRepository = TransactionRepositoryMock()
        let transactionEncoder = RecordingTransactionEncoder()
        let store = PendingSubmitPlanStore(logger: NullLogger())
        let submitter = RecordingTransactionSubmitter()
        let lookupStarted = AsyncSignal()
        let allowLookupToReturn = AsyncSignal()

        transactionRepository.findForResubmissionUpToClosure = { _ in
            await lookupStarted.signal()
            await allowLookupToReturn.wait()
            return []
        }

        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in transactionRepository }
        mockContainer.mock(type: TransactionEncoder.self, isSingleton: true) { _ in transactionEncoder }
        mockContainer.mock(type: PendingSubmitPlanStore.self, isSingleton: true) { _ in store }
        mockContainer.mock(type: SubmitPlanExecutor.self, isSingleton: true) { _ in
            SubmitPlanExecutor(transactionSubmitter: submitter, logger: NullLogger())
        }
        mockContainer.mock(type: Logger.self, isSingleton: true) { _ in NullLogger() }

        let action = TxResubmissionAction(container: mockContainer)
        action.latestResolvedTime = 0
        let actionTask = Task {
            try await action.run(with: resubmissionContext()) { _ in }
        }
        await lookupStarted.wait()

        await markAwaiting([createdTransaction], in: store)
        await allowLookupToReturn.signal()
        _ = try await actionTask.value

        switch await store.getSubmitPlan(for: createdTransaction.rawID) {
        case .awaitingPlan:
            break
        default:
            XCTFail("Expected concurrent broadcaster transaction plan to survive pruning.")
        }
    }

    private func resubmissionContext() -> ActionContextMock {
        let context = ActionContextMock.default()
        context.underlyingSyncControlData = SyncControlData(
            latestBlockHeight: 1000,
            latestScannedHeight: nil,
            firstUnenhancedHeight: nil
        )
        return context
    }

    @discardableResult
    private func markAwaiting(
        _ transactions: [ZcashTransaction.Overview],
        in store: PendingSubmitPlanStore
    ) async -> [ZcashTransaction.Overview] {
        await store.createAndMarkAwaitingSubmitPlan { transactions }
    }

    @discardableResult
    private func loadAndRetain(
        _ transactions: [ZcashTransaction.Overview],
        in store: PendingSubmitPlanStore
    ) async -> [ZcashTransaction.Overview] {
        await store.loadTransactionsAndRetainSubmitPlans(
            loadTransactions: { transactions },
            transactionId: { $0.rawID }
        )
    }

    private func makeTransaction(
        rawID: Data,
        raw: Data = Data([0x01, 0x02])
    ) -> ZcashTransaction.Overview {
        ZcashTransaction.Overview(
            accountUUID: TestsData.mockedAccountUUID,
            blockTime: nil,
            expiryHeight: 123_456,
            fee: Zatoshi(10_000),
            index: 0,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: nil,
            raw: raw,
            rawID: rawID,
            receivedNoteCount: 0,
            sentNoteCount: 1,
            value: Zatoshi(-1_000),
            isExpiredUmined: false,
            totalSpent: nil,
            totalReceived: nil
        )
    }

    private func assertEndpoint(
        _ actual: LightWalletEndpoint,
        equals expected: LightWalletEndpoint,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.host, expected.host, file: file, line: line)
        XCTAssertEqual(actual.port, expected.port, file: file, line: line)
        XCTAssertEqual(actual.secure, expected.secure, file: file, line: line)
        XCTAssertEqual(
            actual.singleCallTimeoutInMillis,
            expected.singleCallTimeoutInMillis,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.streamingCallTimeoutInMillis,
            expected.streamingCallTimeoutInMillis,
            file: file,
            line: line
        )
    }
}

private final class InMemorySubmitPlanPersistence: PendingSubmitPlanPersistence {
    var data: Data?
    var loadError: Error?
    private(set) var saveCallCount = 0

    func load() throws -> Data? {
        if let loadError {
            throw loadError
        }
        return data
    }

    func save(_ data: Data) throws {
        saveCallCount += 1
        self.data = data
    }

    func clear() throws {
        data = nil
    }
}

private enum SubmitPlanPersistenceTestError: Error {
    case loadFailed
}

private actor AsyncSignal {
    private var isSignaled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !isSignaled else { return }

        isSignaled = true
        let continuations = self.continuations
        self.continuations = []
        continuations.forEach { $0.resume() }
    }

    func wait() async {
        if isSignaled {
            return
        }

        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private final class RecordingTransactionEncoder: TransactionEncoder {
    private(set) var submittedTransactions: [EncodedTransaction] = []

    func proposeTransfer(
        accountUUID: AccountUUID,
        recipient: String,
        amount: Zatoshi,
        memoBytes: MemoBytes?
    ) async throws -> Proposal {
        fatalError("Unused in test")
    }

    func proposeShielding(
        accountUUID: AccountUUID,
        shieldingThreshold: Zatoshi,
        memoBytes: MemoBytes?,
        transparentReceiver: String?
    ) async throws -> Proposal? {
        fatalError("Unused in test")
    }

    func createProposedTransactions(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey
    ) async throws -> [ZcashTransaction.Overview] {
        fatalError("Unused in test")
    }

    func proposeFulfillingPaymentFromURI(
        _ uri: String,
        accountUUID: AccountUUID
    ) async throws -> Proposal {
        fatalError("Unused in test")
    }

    func submit(transaction: EncodedTransaction) async throws {
        submittedTransactions.append(transaction)
    }

    func fetchTransactionsForTxIds(_ txIds: [Data]) async throws -> [ZcashTransaction.Overview] {
        fatalError("Unused in test")
    }

    func closeDBConnection() { }
}

private final class RecordingTransactionSubmitter: TransactionSubmitter {
    struct Submission {
        let transaction: EncodedTransaction
        let endpoint: LightWalletEndpoint
    }

    private(set) var submissions: [Submission] = []

    func submit(
        rawTransaction: Data,
        to endpoint: LightWalletEndpoint
    ) async throws {
        fatalError("Unused in test")
    }

    func submit(
        transaction: EncodedTransaction,
        to endpoint: LightWalletEndpoint
    ) async throws {
        submissions.append(Submission(transaction: transaction, endpoint: endpoint))
    }
}

private actor AsyncFlag {
    private var value = false

    func set() {
        value = true
    }

    func get() -> Bool {
        value
    }
}
