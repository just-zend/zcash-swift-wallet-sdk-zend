//
//  TxResubmitterTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// Drives `TxResubmitter` directly, rather than through `TxResubmissionAction`.
///
/// The plan-branch and pruning matrix is already covered by
/// `TxResubmissionActionTests`, which reaches the same code through the action's
/// one-line forward. What only shows up at this seam is the retry *policy*: the
/// 300-second throttle boundary, how `latestResolvedTime` advances across the
/// three outcomes, and that pruning is not gated by the throttle.
final class TxResubmitterTests: ZcashTestCase {
    private var transactionRepository: TransactionRepositoryMock!
    private var transactionEncoder: StubTransactionEncoder!
    private var submitPlanStore: SubmitPlanStoringMock!
    private var endpointSubmitter: EndpointSubmitterMock!

    private let latestBlockHeight = BlockHeight(2_000_000)

    /// `TxResubmitter.Constants.thresholdToTrigger`, which is private.
    private let throttleWindow = TimeInterval(300)

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
            totalReceived: nil,
            spentNoteCount: 0,
            poolCrossingValue: nil,
            isTrusted: false,
            zip318Kind: .notClassified
        )
    }

    /// Builds the resubmitter straight from a `DIContainer`, which is the only
    /// construction path it offers.
    private func makeResubmitter(
        candidates: [ZcashTransaction.Overview],
        encoderTransactions: [ZcashTransaction.Overview] = []
    ) -> TxResubmitter {
        transactionRepository = TransactionRepositoryMock()
        transactionRepository.findForResubmissionUpToClosure = { _ in candidates }
        transactionEncoder = StubTransactionEncoder(createdTransactions: encoderTransactions)
        submitPlanStore = SubmitPlanStoringMock()
        endpointSubmitter = EndpointSubmitterMock()

        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in self.transactionRepository }
        mockContainer.mock(type: TransactionEncoder.self, isSingleton: true) { _ in self.transactionEncoder }
        mockContainer.mock(type: SubmitPlanStoring.self, isSingleton: true) { _ in self.submitPlanStore }
        mockContainer.mock(type: Logger.self, isSingleton: true) { _ in submissionLifecycleLogger() }
        mockContainer.mock(type: SubmitPlanExecutor.self, isSingleton: true) { _ in
            SubmitPlanExecutor(endpointSubmitter: self.endpointSubmitter, logger: submissionLifecycleLogger())
        }

        return TxResubmitter(container: mockContainer)
    }

    private func hasResubmittedAnything() -> Bool {
        !transactionEncoder.submittedTransactions.isEmpty || !endpointSubmitter.recordedSubmissions().isEmpty
    }

    // MARK: - Throttle boundary

    /// Just inside the window: a candidate is present and eligible, but the last
    /// pass was under 300 s ago, so nothing is re-broadcast.
    func testCandidateIsNotResubmittedJustInsideTheThrottleWindow() async throws {
        let rawID = Data(repeating: 0x21, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let resubmitter = makeResubmitter(candidates: [candidate])
        transactionRepository.findRawIDClosure = { _ in candidate }
        resubmitter.latestResolvedTime = Date().timeIntervalSince1970 - (throttleWindow - 1)

        await resubmitter.checkAndResubmit(latestBlockHeight: latestBlockHeight)

        XCTAssertFalse(hasResubmittedAnything(), "A pass under \(throttleWindow) s old must not re-broadcast")
    }

    /// Just outside the window: the same candidate is re-broadcast.
    func testCandidateIsResubmittedJustOutsideTheThrottleWindow() async throws {
        let rawID = Data(repeating: 0x22, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let resubmitter = makeResubmitter(candidates: [candidate])
        transactionRepository.findRawIDClosure = { _ in candidate }
        resubmitter.latestResolvedTime = Date().timeIntervalSince1970 - (throttleWindow + 1)

        await resubmitter.checkAndResubmit(latestBlockHeight: latestBlockHeight)

        XCTAssertEqual(
            transactionEncoder.submittedTransactions.map(\.transactionId),
            [rawID],
            "A pass older than \(throttleWindow) s must re-broadcast"
        )
    }

    // MARK: - `latestResolvedTime` advancement

    /// No candidates: the clock advances, so an idle wallet does not accumulate
    /// a stale timestamp that would let the next real candidate through instantly.
    func testClockAdvancesWhenThereAreNoCandidates() async throws {
        let resubmitter = makeResubmitter(candidates: [])
        resubmitter.latestResolvedTime = 0

        let before = Date().timeIntervalSince1970
        await resubmitter.checkAndResubmit(latestBlockHeight: latestBlockHeight)

        XCTAssertGreaterThanOrEqual(resubmitter.latestResolvedTime, before)
    }

    /// A completed resubmission pass advances the clock, which is what re-arms
    /// the throttle for the next window.
    func testClockAdvancesAfterAResubmissionPass() async throws {
        let rawID = Data(repeating: 0x23, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let resubmitter = makeResubmitter(candidates: [candidate])
        transactionRepository.findRawIDClosure = { _ in candidate }
        resubmitter.latestResolvedTime = 0

        let before = Date().timeIntervalSince1970
        await resubmitter.checkAndResubmit(latestBlockHeight: latestBlockHeight)

        XCTAssertFalse(transactionEncoder.submittedTransactions.isEmpty, "Precondition: the pass must have resubmitted")
        XCTAssertGreaterThanOrEqual(resubmitter.latestResolvedTime, before)
    }

    /// A throttled call leaves the clock alone. If it advanced here, every check
    /// would push the deadline out and a candidate could be starved indefinitely.
    func testClockDoesNotAdvanceWhileThrottled() async throws {
        let rawID = Data(repeating: 0x24, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let resubmitter = makeResubmitter(candidates: [candidate])
        transactionRepository.findRawIDClosure = { _ in candidate }
        let pinned = Date().timeIntervalSince1970 - 100
        resubmitter.latestResolvedTime = pinned

        await resubmitter.checkAndResubmit(latestBlockHeight: latestBlockHeight)

        XCTAssertEqual(resubmitter.latestResolvedTime, pinned, "A throttled check must not push its own deadline out")
        XCTAssertFalse(hasResubmittedAnything())
    }

    // MARK: - Pruning is independent of the throttle

    /// Pruning runs before the throttle check, so a call that re-broadcasts
    /// nothing still drops plans whose transactions are gone.
    func testStalePlansArePrunedEvenWhileThrottled() async throws {
        let liveTxId = Data(repeating: 0x25, count: 32)
        let staleTxId = Data(repeating: 0x26, count: 32)
        let candidate = makeOverview(rawID: liveTxId)
        let resubmitter = makeResubmitter(candidates: [candidate])
        await submitPlanStore.recordPlan(txId: liveTxId, endpoints: [endpointA])
        await submitPlanStore.recordPlan(txId: staleTxId, endpoints: [endpointA])
        transactionRepository.findRawIDClosure = { rawID in
            guard rawID == liveTxId else { throw ZcashError.transactionRepositoryEntityNotFound }
            return candidate
        }
        // Throttled: candidates exist, but the window has not elapsed.
        resubmitter.latestResolvedTime = Date().timeIntervalSince1970

        await resubmitter.checkAndResubmit(latestBlockHeight: latestBlockHeight)

        let remaining = await submitPlanStore.allPlannedTransactionIds()
        XCTAssertEqual(Set(remaining), Set([liveTxId]), "Pruning must not be gated by the resubmission throttle")
        XCTAssertFalse(hasResubmittedAnything())
    }
}
