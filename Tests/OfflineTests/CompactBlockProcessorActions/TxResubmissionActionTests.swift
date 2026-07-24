//
//  TxResubmissionActionTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

// swiftlint:disable:next type_body_length
final class TxResubmissionActionTests: ZcashTestCase {
    private var transactionRepository: TransactionRepositoryMock!
    private var transactionEncoder: StubTransactionEncoder!
    private var rustBackend = ZcashRustBackendWeldingMock()
    private var submitPlanStore: SubmitPlanStoringMock!
    private var endpointSubmitter: EndpointSubmitterMock!

    private let latestBlockHeight = BlockHeight(2_000_000)

    private var endpointA: LightWalletEndpoint {
        LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
    }

    private func makeOverview(
        rawID: Data,
        minedHeight: BlockHeight? = nil,
        expiryHeight: BlockHeight? = 3_000_000
    ) -> ZcashTransaction.Overview {
        ZcashTransaction.Overview(
            accountUUID: TestsData.mockedAccountUUID,
            blockTime: nil,
            expiryHeight: expiryHeight,
            fee: Zatoshi(10_000),
            index: 0,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: minedHeight,
            raw: Data([0x01, 0x02, 0x03]),
            rawID: rawID,
            receivedNoteCount: 0,
            sentNoteCount: 1,
            value: Zatoshi(-1_000),
            isExpiredUmined: false,
            totalSpent: nil,
            totalReceived: nil
        )
    }

    private func setupAction(
        candidates: [ZcashTransaction.Overview],
        encoderTransactions: [ZcashTransaction.Overview] = []
    ) -> TxResubmissionAction {
        transactionRepository = TransactionRepositoryMock()
        transactionRepository.findForResubmissionUpToClosure = { _ in candidates }
        transactionEncoder = StubTransactionEncoder(createdTransactions: encoderTransactions)
        rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationRuntimeSnapshotsReturnValue = []
        submitPlanStore = SubmitPlanStoringMock()
        endpointSubmitter = EndpointSubmitterMock()

        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in self.transactionRepository }
        mockContainer.mock(type: TransactionEncoder.self, isSingleton: true) { _ in self.transactionEncoder }
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in self.rustBackend }
        mockContainer.mock(type: SubmitPlanStoring.self, isSingleton: true) { _ in self.submitPlanStore }
        mockContainer.mock(type: Logger.self, isSingleton: true) { _ in submissionLifecycleLogger() }
        mockContainer.mock(type: SubmitPlanExecutor.self, isSingleton: true) { _ in
            SubmitPlanExecutor(endpointSubmitter: self.endpointSubmitter, logger: submissionLifecycleLogger())
        }

        let action = TxResubmissionAction(container: mockContainer)
        // Push the throttle back so tests exercise the resubmit branch.
        // The first-invocation throttle is covered by its own test.
        action.latestResolvedTime = 0
        return action
    }

    private func makeContext() -> ActionContextMock {
        let context = ActionContextMock.default()
        context.prevState = .enhance
        context.underlyingSyncControlData = SyncControlData(
            latestBlockHeight: latestBlockHeight,
            latestScannedHeight: nil,
            firstUnenhancedHeight: nil
        )
        return context
    }

    func testAwaitingTransactionIsSkipped() async throws {
        let rawID = Data(repeating: 0x01, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        await submitPlanStore.markAwaitingSubmission(txIds: [rawID])
        // Make the repository confirm the candidate is alive so pruning keeps it.
        transactionRepository.findRawIDClosure = { _ in candidate }

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertTrue(transactionEncoder.submittedTransactions.isEmpty, "Awaiting transactions must not be submitted")
        XCTAssertTrue(endpointSubmitter.recordedSubmissions().isEmpty)
        let plan = await submitPlanStore.plan(for: rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.awaiting, "Awaiting plan must survive")
    }

    func testReadyTransactionIsResubmittedThroughPlanEndpoints() async throws {
        let rawID = Data(repeating: 0x02, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        await submitPlanStore.recordPlan(txId: rawID, endpoints: [endpointA])
        transactionRepository.findRawIDClosure = { _ in candidate }

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertEqual(endpointSubmitter.recordedSubmissions().map(\.host), ["a.example.com"])
        XCTAssertTrue(transactionEncoder.submittedTransactions.isEmpty, "Plan transactions must not use the default endpoint")
    }

    func testLegacyTransactionUsesDefaultEncoderSubmit() async throws {
        let rawID = Data(repeating: 0x03, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertEqual(transactionEncoder.submittedTransactions.count, 1)
        XCTAssertEqual(transactionEncoder.submittedTransactions.first?.transactionId, rawID)
        XCTAssertTrue(endpointSubmitter.recordedSubmissions().isEmpty)
    }

    func testRustOwnedMigrationTransactionNeverUsesOrdinaryResubmission() async throws {
        let rawID = Data(repeating: 0x13, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        transactionRepository.findForResubmissionUpToClosure = { _ in
            XCTAssertEqual(
                self.rustBackend.migrationRuntimeSnapshotsCallsCount,
                0,
                "The candidate list must be frozen before migration ownership is projected"
            )
            return [candidate]
        }
        rustBackend.migrationRuntimeSnapshotsClosure = {
            XCTAssertTrue(
                self.transactionRepository.findForResubmissionUpToCalled,
                "Migration ownership must be projected after the candidate list is frozen"
            )
            return [self.makeMigrationRuntime(transactionID: rawID)]
        }

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertTrue(transactionEncoder.submittedTransactions.isEmpty)
        XCTAssertTrue(endpointSubmitter.recordedSubmissions().isEmpty)
    }

    func testMigrationOwnershipReadFailureFailsClosedForOrdinaryResubmission() async throws {
        struct RuntimeReadError: Error {}
        let rawID = Data(repeating: 0x14, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        rustBackend.migrationRuntimeSnapshotsThrowableError = RuntimeReadError()

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertTrue(transactionEncoder.submittedTransactions.isEmpty)
        XCTAssertTrue(endpointSubmitter.recordedSubmissions().isEmpty)
        XCTAssertTrue(transactionRepository.findForResubmissionUpToCalled)
    }

    func testUnavailableMigrationRuntimeProjectionFailsClosedForOrdinaryResubmission() async throws {
        let rawID = Data(repeating: 0x18, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        rustBackend.migrationRuntimeSnapshotsReturnValue = [makeUnavailableMigrationRuntime()]

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertTrue(transactionEncoder.submittedTransactions.isEmpty)
        XCTAssertTrue(endpointSubmitter.recordedSubmissions().isEmpty)
        XCTAssertTrue(transactionRepository.findForResubmissionUpToCalled)
    }

    func testPruningRemovesExpiredMissingAndNilExpiryPlansButKeepsMinedUntilExpiry() async throws {
        let minedUnexpiredTxId = Data(repeating: 0x04, count: 32)
        let expiredTxId = Data(repeating: 0x05, count: 32)
        let minedExpiredTxId = Data(repeating: 0x0B, count: 32)
        let missingTxId = Data(repeating: 0x06, count: 32)
        let nilExpiryTxId = Data(repeating: 0x08, count: 32)
        let aliveTxId = Data(repeating: 0x07, count: 32)

        let action = setupAction(candidates: [])
        await submitPlanStore.recordPlan(txId: minedUnexpiredTxId, endpoints: [endpointA])
        await submitPlanStore.recordPlan(txId: expiredTxId, endpoints: [endpointA])
        await submitPlanStore.recordPlan(txId: minedExpiredTxId, endpoints: [endpointA])
        await submitPlanStore.recordPlan(txId: missingTxId, endpoints: [endpointA])
        await submitPlanStore.recordPlan(txId: nilExpiryTxId, endpoints: [endpointA])
        await submitPlanStore.recordPlan(txId: aliveTxId, endpoints: [endpointA])

        transactionRepository.findRawIDClosure = { rawID in
            if rawID == minedUnexpiredTxId {
                return self.makeOverview(rawID: rawID, minedHeight: 1_999_000)
            }
            if rawID == expiredTxId {
                return self.makeOverview(rawID: rawID, expiryHeight: 1_999_999)
            }
            if rawID == minedExpiredTxId {
                return self.makeOverview(rawID: rawID, minedHeight: 1_999_000, expiryHeight: 1_999_999)
            }
            if rawID == missingTxId {
                throw ZcashError.transactionRepositoryEntityNotFound
            }
            if rawID == nilExpiryTxId {
                return self.makeOverview(rawID: rawID, expiryHeight: nil)
            }
            return self.makeOverview(rawID: rawID)
        }

        _ = try await action.run(with: makeContext()) { _ in }

        let remaining = await submitPlanStore.allPlannedTransactionIds()
        // The mined-but-unexpired plan survives: a reorg could un-mine the
        // transaction, and its retries must still use the recorded endpoints.
        XCTAssertEqual(Set(remaining), Set([aliveTxId, minedUnexpiredTxId]))
    }

    func testStoreUnavailableSkipsResubmission() async throws {
        let rawID = Data(repeating: 0x0C, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        submitPlanStore.storeUnavailable = true
        transactionRepository.findRawIDClosure = { _ in candidate }

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertTrue(
            transactionEncoder.submittedTransactions.isEmpty,
            "An unreadable plan store must not fall back to the default-endpoint submit"
        )
        XCTAssertTrue(endpointSubmitter.recordedSubmissions().isEmpty)
    }

    func testOneFailingPlanDoesNotStarveOtherCandidates() async throws {
        let planTxId = Data(repeating: 0x0D, count: 32)
        let legacyTxId = Data(repeating: 0x0E, count: 32)
        let planCandidate = makeOverview(rawID: planTxId)
        let legacyCandidate = makeOverview(rawID: legacyTxId)
        let action = setupAction(candidates: [planCandidate, legacyCandidate])
        await submitPlanStore.recordPlan(txId: planTxId, endpoints: [endpointA])
        endpointSubmitter.set(behavior: .failTransport, for: endpointA)
        transactionRepository.findRawIDClosure = { rawID in
            rawID == planTxId ? planCandidate : legacyCandidate
        }

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertEqual(
            transactionEncoder.submittedTransactions.map(\.transactionId),
            [legacyTxId],
            "A failing plan retry must not abort resubmission of the remaining candidates"
        )
    }

    func testNoCandidatesStillPrunes() async throws {
        let staleTxId = Data(repeating: 0x09, count: 32)
        let action = setupAction(candidates: [])
        await submitPlanStore.recordPlan(txId: staleTxId, endpoints: [endpointA])
        transactionRepository.findRawIDClosure = { _ in
            throw ZcashError.transactionRepositoryEntityNotFound
        }

        _ = try await action.run(with: makeContext()) { _ in }

        let remaining = await submitPlanStore.allPlannedTransactionIds()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testFreshActionThrottlesFirstInvocation() async throws {
        let rawID = Data(repeating: 0x0F, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        // Undo the test-only push: a freshly constructed action should not
        // resubmit on its first invocation, even when candidates are present.
        action.latestResolvedTime = Date().timeIntervalSince1970
        transactionRepository.findRawIDClosure = { _ in candidate }

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertTrue(
            transactionEncoder.submittedTransactions.isEmpty,
            "Fresh action must not resubmit before the throttle window elapses"
        )
        XCTAssertTrue(endpointSubmitter.recordedSubmissions().isEmpty)
    }

    func testUnknownRepositoryErrorKeepsPlanDuringPruning() async throws {
        struct TransientDatabaseError: Error {}
        let txId = Data(repeating: 0x0A, count: 32)
        let action = setupAction(candidates: [])
        await submitPlanStore.recordPlan(txId: txId, endpoints: [endpointA])
        transactionRepository.findRawIDClosure = { _ in
            throw TransientDatabaseError()
        }

        _ = try await action.run(with: makeContext()) { _ in }

        let remaining = await submitPlanStore.allPlannedTransactionIds()
        XCTAssertEqual(remaining, [txId], "A transient repository error must not prune a live retry plan")
    }

    private func makeMigrationRuntime(transactionID: Data) -> MigrationRuntimeSnapshot {
        let claim = MigrationDeliveryClaimSummary(
            artifact: .immediate(identity: Data(repeating: 0x15, count: 32)),
            signerOwnership: .sdk,
            status: .broadcasted,
            activeClaimKind: nil,
            externallyExposed: false,
            hasSignedPCZT: false,
            hasExactTransaction: true,
            expiryHeight: 3_000_000,
            txid: transactionID,
            lastError: nil,
            claimHandle: makeClaimHandle(0x16)
        )
        let delivery = MigrationDeliverySnapshot(
            lane: .immediate,
            phase: .active,
            storageFinality: .active,
            activeSourceReservationCount: 1,
            hasSubmissionPolicy: true,
            policyValidationFailure: nil,
            safeToCancel: false,
            claims: [claim],
            runHandle: makeRunHandle(0x17),
            revision: 1
        )
        return MigrationRuntimeSnapshot(
            account: TestsData.mockedAccountUUID,
            canonical: MigrationCanonicalSummary(status: .inProgress, transactionCount: 1),
            schemaProvenance: .compatible(version: 1),
            legacyCutover: .fresh,
            destinationSpendability: .notSpendable,
            availability: .available,
            ordinarySpendAuthorization: .excludingMigrationSources(releaseAtHeight: 3_000_000),
            accountDeletionAuthorization: .blocked(.unresolvedDelivery),
            canonicalMutationAuthorization: .blocked(.deliveryOwned),
            aggregateStorageFinality: .active,
            delivery: delivery,
            retainedRuns: []
        )
    }

    private func makeUnavailableMigrationRuntime() -> MigrationRuntimeSnapshot {
        MigrationRuntimeSnapshot(
            account: TestsData.mockedAccountUUID,
            canonical: MigrationCanonicalSummary(status: nil, transactionCount: 0),
            schemaProvenance: .unavailable,
            legacyCutover: .fresh,
            destinationSpendability: .notApplicable,
            availability: .unavailable(.schemaUnavailable),
            ordinarySpendAuthorization: .blocked(.runtimeUnavailable),
            accountDeletionAuthorization: .blocked(.runtimeUnavailable),
            canonicalMutationAuthorization: .blocked(.runtimeUnavailable),
            aggregateStorageFinality: .noRun,
            delivery: nil,
            retainedRuns: []
        )
    }

    private func makeClaimHandle(_ identity: Int) -> MigrationClaimHandle {
        guard let pointer = OpaquePointer(bitPattern: identity) else {
            preconditionFailure("test migration claim identity must be nonzero")
        }
        return MigrationClaimHandle(
            storage: MigrationOpaqueHandleStorage(
                pointer: pointer,
                release: { _ in }
            )
        )
    }

    private func makeRunHandle(_ identity: Int) -> MigrationRunHandle {
        guard let pointer = OpaquePointer(bitPattern: identity) else {
            preconditionFailure("test migration run identity must be nonzero")
        }
        return MigrationRunHandle(
            storage: MigrationOpaqueHandleStorage(
                pointer: pointer,
                release: { _ in }
            )
        )
    }
}
