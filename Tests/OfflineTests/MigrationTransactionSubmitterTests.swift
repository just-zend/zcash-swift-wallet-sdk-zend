//
//  MigrationTransactionSubmitterTests.swift
//  OfflineTests
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class MigrationTransactionSubmitterTests: XCTestCase {
    private enum TestError: Error {
        case transport
        case torSetup
    }

    private final class TransportFactoryMock: MigrationTransportCreating {
        let service: LightWalletService
        let mode: ServiceMode
        var throwableError: Error?
        private(set) var receivedArguments: (endpoint: LightWalletEndpoint, useTor: Bool)?
        private(set) var callsCount = 0

        init(service: LightWalletService, mode: ServiceMode) {
            self.service = service
            self.mode = mode
        }

        func makeTransport(endpoint: LightWalletEndpoint, useTor: Bool) async throws -> MigrationTransport {
            callsCount += 1
            receivedArguments = (endpoint, useTor)
            if let throwableError {
                throw throwableError
            }
            return MigrationTransport(service: service, mode: mode)
        }
    }

    private final class RecordingLogger: Logger {
        private(set) var errors: [String] = []

        func maxLogLevel() -> OSLogger.LogLevel? { .debug }
        func debug(_ message: String, file: StaticString, function: StaticString, line: Int) {}
        func info(_ message: String, file: StaticString, function: StaticString, line: Int) {}
        func event(_ message: String, file: StaticString, function: StaticString, line: Int) {}
        func warn(_ message: String, file: StaticString, function: StaticString, line: Int) {}
        func error(_ message: String, file: StaticString, function: StaticString, line: Int) { errors.append(message) }
        func sync(_ message: String, file: StaticString, function: StaticString, line: Int) {}
    }

    private struct SentinelError: LocalizedError {
        let errorDescription: String?
    }

    private let fallbackEndpoint = LightWalletEndpoint(
        address: "sync.example",
        port: 9067,
        secure: true,
        singleCallTimeoutInMillis: 12_345,
        streamingCallTimeoutInMillis: 54_321
    )
    private let transaction = EncodedTransaction(
        transactionId: Data(repeating: 0xAB, count: 32),
        raw: Data([0x01, 0x02, 0x03])
    )
    private let displayTransactionID = String(repeating: "ab", count: 32)

    func testDirectUsesSyncEndpointWhenSubmissionEndpointIsNil() async throws {
        let service = makeService(response: makeResponse())
        let factory = TransportFactoryMock(service: service, mode: .direct)
        let submitter = makeSubmitter(factory: factory)

        let result = try await submitter.submit(
            transaction: transaction,
            displayTransactionID: displayTransactionID,
            expiryHeight: 1_000_000,
            options: NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil),
            defaultEndpoint: fallbackEndpoint
        )

        XCTAssertEqual(result, .success(txid: displayTransactionID))
        XCTAssertEqual(factory.receivedArguments?.endpoint, fallbackEndpoint)
        XCTAssertEqual(factory.receivedArguments?.useTor, false)
        XCTAssertEqual(service.submitSpendTransactionModeReceivedArguments?.spendTransaction, transaction.raw)
        XCTAssertEqual(service.submitSpendTransactionModeReceivedArguments?.mode, .direct)
        XCTAssertTrue(service.closeConnectionsCalled)
    }

    func testTorUsesRequestedSecondaryEndpointAndNeverConsultsGlobalTorState() async throws {
        let service = makeService(response: makeResponse())
        let factory = TransportFactoryMock(service: service, mode: .defaultTor)
        let submitter = makeSubmitter(factory: factory)

        let result = try await submitter.submit(
            transaction: transaction,
            displayTransactionID: displayTransactionID,
            expiryHeight: 1_000_000,
            options: NetworkPrivacyOptions(
                useTor: true,
                submissionEndpoint: "https://migration.example:9443"
            ),
            defaultEndpoint: fallbackEndpoint
        )

        XCTAssertEqual(result, .success(txid: displayTransactionID))
        XCTAssertEqual(factory.receivedArguments?.useTor, true)
        XCTAssertEqual(
            factory.receivedArguments?.endpoint,
            LightWalletEndpoint(
                address: "migration.example",
                port: 9443,
                secure: true,
                singleCallTimeoutInMillis: fallbackEndpoint.singleCallTimeoutInMillis,
                streamingCallTimeoutInMillis: fallbackEndpoint.streamingCallTimeoutInMillis
            )
        )
        XCTAssertEqual(service.submitSpendTransactionModeReceivedArguments?.mode, .defaultTor)
    }

    func testTorSetupFailurePropagatesWithoutClearFallback() async throws {
        let service = makeService(response: makeResponse())
        let factory = TransportFactoryMock(service: service, mode: .defaultTor)
        factory.throwableError = TestError.torSetup
        let submitter = makeSubmitter(factory: factory)

        do {
            _ = try await submitter.submit(
                transaction: transaction,
                displayTransactionID: displayTransactionID,
                expiryHeight: 1_000_000,
                options: NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil),
                defaultEndpoint: fallbackEndpoint
            )
            XCTFail("Expected Tor setup failure")
        } catch TestError.torSetup {
            // expected
        }

        XCTAssertEqual(factory.callsCount, 1)
        XCTAssertEqual(factory.receivedArguments?.useTor, true)
        XCTAssertFalse(service.submitSpendTransactionModeCalled)
    }

    func testMalformedSecondaryEndpointFailsBeforeTransportCreation() async throws {
        let service = makeService(response: makeResponse())
        let factory = TransportFactoryMock(service: service, mode: .direct)
        let submitter = makeSubmitter(factory: factory)

        for endpoint in [
            "migration.example:9067/path",
            "https://migration.example:0",
            "https://migration.example:65536",
            "https://user@migration.example"
        ] {
            do {
                _ = try await submitter.submit(
                    transaction: transaction,
                    displayTransactionID: displayTransactionID,
                    expiryHeight: 1_000_000,
                    options: NetworkPrivacyOptions(useTor: false, submissionEndpoint: endpoint),
                    defaultEndpoint: fallbackEndpoint
                )
                XCTFail("Expected invalid endpoint")
            } catch let error as MigrationBroadcastError {
                XCTAssertEqual(error, .invalidSubmissionEndpoint)
            }
        }

        XCTAssertEqual(factory.callsCount, 0)
    }

    func testCleartextEndpointFailsClosedOutsideExplicitLoopbackRegtest() throws {
        for network in [NetworkType.mainnet, .testnet, .regtest] {
            XCTAssertThrowsError(
                try LiveMigrationTransactionSubmitter.resolveEndpoint(
                    "http://migration.example:9067",
                    fallback: fallbackEndpoint,
                    networkType: network
                )
            ) { error in
                XCTAssertEqual(error as? MigrationBroadcastError, .invalidSubmissionEndpoint)
            }
        }

        for network in [NetworkType.mainnet, .testnet] {
            let insecureFallback = LightWalletEndpoint(address: "127.0.0.1", port: 9067, secure: false)
            XCTAssertThrowsError(
                try LiveMigrationTransactionSubmitter.resolveEndpoint(
                    nil,
                    fallback: insecureFallback,
                    networkType: network
                )
            )
        }
    }

    func testCleartextEndpointIsAllowedOnlyForCanonicalLoopbackOnRegtest() throws {
        for endpoint in ["http://localhost:9067", "http://127.0.0.1:9067", "http://[::1]:9067"] {
            let resolved = try LiveMigrationTransactionSubmitter.resolveEndpoint(
                endpoint,
                fallback: fallbackEndpoint,
                networkType: .regtest
            )
            XCTAssertFalse(resolved.secure)
        }

        for endpoint in ["http://127.0.0.1.example:9067", "http://127.00.0.1:9067", "http://0.0.0.0:9067"] {
            XCTAssertThrowsError(
                try LiveMigrationTransactionSubmitter.resolveEndpoint(
                    endpoint,
                    fallback: fallbackEndpoint,
                    networkType: .regtest
                )
            )
        }
    }

    func testTransportFailureAfterSubmitStartsIsOutcomeUnknown() async throws {
        let service = makeService(response: makeResponse())
        service.submitSpendTransactionModeThrowableError = TestError.transport
        let factory = TransportFactoryMock(service: service, mode: .direct)

        let result = try await makeSubmitter(factory: factory).submit(
            transaction: transaction,
            displayTransactionID: displayTransactionID,
            expiryHeight: 1_000_000,
            options: NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil),
            defaultEndpoint: fallbackEndpoint
        )

        XCTAssertEqual(result, .outcomeUnknown)
        XCTAssertFalse(service.fetchTransactionTxIdModeCalled)
        XCTAssertTrue(service.closeConnectionsCalled)
    }

    func testSelectedTransportPreflightUsesHighestSampleAndRefusesExpiredBytesWithoutSubmitting() async throws {
        let service = makeService(response: makeResponse(), tip: 501)
        var sampledHeights = [499, 501, 498]
        service.latestBlockHeightModeClosure = { _ in sampledHeights.removeFirst() }
        let factory = TransportFactoryMock(service: service, mode: .direct)

        do {
            _ = try await makeSubmitter(factory: factory).submit(
                transaction: transaction,
                displayTransactionID: displayTransactionID,
                expiryHeight: 500,
                options: NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil),
                defaultEndpoint: fallbackEndpoint
            )
            XCTFail("Expected selected transport tip at or past expiry to fail known-unsent")
        } catch let MigrationBroadcastError.selectedTransportTipWithinExpirySafetyMargin(tip, expiry, margin) {
            XCTAssertEqual(tip, 501)
            XCTAssertEqual(expiry, 500)
            XCTAssertEqual(margin, 4)
        }

        XCTAssertEqual(service.latestBlockHeightModeCallsCount, 3)
        XCTAssertFalse(service.submitSpendTransactionModeCalled)
        XCTAssertFalse(service.fetchTransactionTxIdModeCalled)
        XCTAssertTrue(service.closeConnectionsCalled)
    }

    func testSelectedTransportHonorsFourBlockExpiringSoonBoundary() async throws {
        let expiringSoon = makeService(response: makeResponse(), tip: 497)
        expiringSoon.latestBlockHeightModeReturnValue = 497
        let expiringFactory = TransportFactoryMock(service: expiringSoon, mode: .direct)

        do {
            _ = try await makeSubmitter(factory: expiringFactory).submit(
                transaction: transaction,
                displayTransactionID: displayTransactionID,
                expiryHeight: 500,
                options: NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil),
                defaultEndpoint: fallbackEndpoint
            )
            XCTFail("Expected zcashd's four-block expiring-soon boundary")
        } catch let MigrationBroadcastError.selectedTransportTipWithinExpirySafetyMargin(tip, expiry, margin) {
            XCTAssertEqual(tip, 497)
            XCTAssertEqual(expiry, 500)
            XCTAssertEqual(margin, 4)
        }
        XCTAssertFalse(expiringSoon.submitSpendTransactionModeCalled)

        let safe = makeService(response: makeResponse(), tip: 496)
        safe.latestBlockHeightModeReturnValue = 496
        let safeResult = try await makeSubmitter(
            factory: TransportFactoryMock(service: safe, mode: .direct)
        ).submit(
            transaction: transaction,
            displayTransactionID: displayTransactionID,
            expiryHeight: 500,
            options: NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil),
            defaultEndpoint: fallbackEndpoint
        )
        XCTAssertEqual(safeResult, .success(txid: displayTransactionID))
    }

    func testSelectedTransportTipFailurePropagatesBeforeSubmitAndClosesTransport() async throws {
        let service = makeService(response: makeResponse())
        service.latestBlockHeightModeClosure = { _ in throw TestError.transport }
        let factory = TransportFactoryMock(service: service, mode: .direct)

        do {
            _ = try await makeSubmitter(factory: factory).submit(
                transaction: transaction,
                displayTransactionID: displayTransactionID,
                expiryHeight: 500,
                options: NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil),
                defaultEndpoint: fallbackEndpoint
            )
            XCTFail("Expected preflight transport failure")
        } catch TestError.transport {
            // expected known-unsent failure
        }

        XCTAssertEqual(service.latestBlockHeightModeCallsCount, 3)
        XCTAssertFalse(service.submitSpendTransactionModeCalled)
        XCTAssertTrue(service.closeConnectionsCalled)
    }

    func testRejectedSubmissionKnownByExactTxIDIsAccepted() async throws {
        let service = makeService(response: makeResponse(errorCode: -1, errorMessage: "already in mempool"))
        service.fetchTransactionTxIdModeReturnValue = (tx: nil, status: .notInMainChain)
        let factory = TransportFactoryMock(service: service, mode: .direct)

        let result = try await makeSubmitter(factory: factory).submit(
            transaction: transaction,
            displayTransactionID: displayTransactionID,
            expiryHeight: 1_000_000,
            options: NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil),
            defaultEndpoint: fallbackEndpoint
        )

        XCTAssertEqual(result, .success(txid: displayTransactionID))
        XCTAssertEqual(service.fetchTransactionTxIdModeReceivedArguments?.txId, transaction.transactionId)
        XCTAssertEqual(service.fetchTransactionTxIdModeReceivedArguments?.mode, .direct)
    }

    func testRejectedSubmissionUnknownToEndpointIsNonRetryable() async throws {
        let service = makeService(response: makeResponse(errorCode: -25, errorMessage: "rejected"))
        service.fetchTransactionTxIdModeReturnValue = (tx: nil, status: .txidNotRecognized)
        let factory = TransportFactoryMock(service: service, mode: .direct)

        let result = try await makeSubmitter(factory: factory).submit(
            transaction: transaction,
            displayTransactionID: displayTransactionID,
            expiryHeight: 1_000_000,
            options: NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil),
            defaultEndpoint: fallbackEndpoint
        )

        XCTAssertEqual(result, .networkError(retryable: false))
    }

    func testPositiveNonzeroSubmissionCodeIsRejectedAndReconciled() async throws {
        let service = makeService(response: makeResponse(errorCode: 7, errorMessage: "positive rejection"))
        service.fetchTransactionTxIdModeReturnValue = (tx: nil, status: .txidNotRecognized)
        let factory = TransportFactoryMock(service: service, mode: .direct)

        let result = try await makeSubmitter(factory: factory).submit(
            transaction: transaction,
            displayTransactionID: displayTransactionID,
            expiryHeight: 1_000_000,
            options: NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil),
            defaultEndpoint: fallbackEndpoint
        )

        XCTAssertEqual(result, .networkError(retryable: false))
        XCTAssertTrue(service.fetchTransactionTxIdModeCalled)
        XCTAssertEqual(service.fetchTransactionTxIdModeReceivedArguments?.txId, transaction.transactionId)
    }

    func testActivationBoundaryValidatesReportedBranchAtInfoTipAndTransactionAtNextHeight() async throws {
        let oldBranch = UInt32(0xc2d6_d0b4)
        let newBranch = UInt32(0xc8e7_1055)
        let service = makeService(
            response: makeResponse(),
            tip: 99,
            reportedBranch: String(format: "%08x", oldBranch)
        )
        let submitter = makeSubmitter(factory: TransportFactoryMock(service: service, mode: .direct))

        let result = try await submitter.submit(
            transaction: transaction,
            displayTransactionID: displayTransactionID,
            expiryHeight: 110,
            options: NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil),
            defaultEndpoint: fallbackEndpoint,
            networkType: .testnet,
            expectedChainName: "test",
            boundPolicy: boundPolicy,
            transactionConsensusBranchId: newBranch,
            branchIdForHeight: { height in
                Int32(bitPattern: height < 100 ? oldBranch : newBranch)
            },
            renewLease: {}
        )

        XCTAssertEqual(result, .success(txid: displayTransactionID))
        XCTAssertTrue(service.submitSpendTransactionModeCalled)
    }

    func testActivationBoundaryRejectsTransactionEncodedForReportedTipBranch() async throws {
        let oldBranch = UInt32(0xc2d6_d0b4)
        let newBranch = UInt32(0xc8e7_1055)
        let service = makeService(
            response: makeResponse(),
            tip: 99,
            reportedBranch: String(format: "%08x", oldBranch)
        )
        let submitter = makeSubmitter(factory: TransportFactoryMock(service: service, mode: .direct))

        do {
            _ = try await submitter.submit(
                transaction: transaction,
                displayTransactionID: displayTransactionID,
                expiryHeight: 110,
                options: NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil),
                defaultEndpoint: fallbackEndpoint,
                networkType: .testnet,
                expectedChainName: "test",
                boundPolicy: boundPolicy,
                transactionConsensusBranchId: oldBranch,
                branchIdForHeight: { height in
                    Int32(bitPattern: height < 100 ? oldBranch : newBranch)
                },
                renewLease: {}
            )
            XCTFail("Expected an exact next-height transaction branch mismatch")
        } catch let error as MigrationBroadcastError {
            XCTAssertEqual(error, .transactionConsensusBranchMismatch)
        }

        XCTAssertFalse(service.submitSpendTransactionModeCalled)
        XCTAssertTrue(service.closeConnectionsCalled)
    }

    func testRejectedSubmissionWithFailedExactLookupIsOutcomeUnknown() async throws {
        let service = makeService(response: makeResponse(errorCode: -1, errorMessage: "already known"))
        service.fetchTransactionTxIdModeClosure = { _, _ in throw TestError.transport }
        let factory = TransportFactoryMock(service: service, mode: .defaultTor)

        let result = try await makeSubmitter(factory: factory).submit(
            transaction: transaction,
            displayTransactionID: displayTransactionID,
            expiryHeight: 1_000_000,
            options: NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil),
            defaultEndpoint: fallbackEndpoint
        )

        XCTAssertEqual(result, .outcomeUnknown)
        XCTAssertEqual(service.fetchTransactionTxIdModeReceivedArguments?.txId, transaction.transactionId)
    }

    func testExportableLogsContainOnlyStableCodesAndNoSensitivePayloads() async throws {
        let logger = RecordingLogger()
        let secretEndpoint = "secret-endpoint.example"
        let secretTxid = "secret-txid"
        let secretAmount = "4200000000"
        let secretAnchor = "2881234"
        let secretServerBody = "server-body-private"

        let submitFailure = makeService(response: makeResponse())
        submitFailure.submitSpendTransactionModeThrowableError = SentinelError(
            errorDescription: "\(secretEndpoint) \(secretTxid) \(secretAmount) \(secretAnchor)"
        )
        _ = try await makeSubmitter(
            factory: TransportFactoryMock(service: submitFailure, mode: .direct),
            logger: logger
        ).submit(
            transaction: transaction,
            displayTransactionID: displayTransactionID,
            expiryHeight: 1_000_000,
            options: NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil),
            defaultEndpoint: fallbackEndpoint
        )

        let rejected = makeService(response: makeResponse(errorCode: -25, errorMessage: secretServerBody))
        rejected.fetchTransactionTxIdModeReturnValue = (tx: nil, status: .txidNotRecognized)
        _ = try await makeSubmitter(
            factory: TransportFactoryMock(service: rejected, mode: .direct),
            logger: logger
        ).submit(
            transaction: transaction,
            displayTransactionID: displayTransactionID,
            expiryHeight: 1_000_000,
            options: NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil),
            defaultEndpoint: fallbackEndpoint
        )

        let lookupFailure = makeService(response: makeResponse(errorCode: -1, errorMessage: secretServerBody))
        lookupFailure.fetchTransactionTxIdModeClosure = { _, _ in
            throw SentinelError(errorDescription: "\(secretEndpoint) \(secretTxid)")
        }
        _ = try await makeSubmitter(
            factory: TransportFactoryMock(service: lookupFailure, mode: .direct),
            logger: logger
        ).submit(
            transaction: transaction,
            displayTransactionID: displayTransactionID,
            expiryHeight: 1_000_000,
            options: NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil),
            defaultEndpoint: fallbackEndpoint
        )

        XCTAssertEqual(
            logger.errors,
            [
                "migration_submit outcome=unknown code=transport_exception",
                "migration_submit outcome=rejected code=server_rejected",
                "migration_submit outcome=unknown code=reconciliation_failed"
            ]
        )
        let exported = logger.errors.joined(separator: " ")
        for secret in [secretEndpoint, secretTxid, secretAmount, secretAnchor, secretServerBody, displayTransactionID] {
            XCTAssertFalse(exported.contains(secret), "exported logs leaked sentinel: \(secret)")
        }
    }

    private func makeSubmitter(
        factory: MigrationTransportCreating,
        logger: Logger = submissionLifecycleLogger()
    ) -> LiveMigrationTransactionSubmitter {
        LiveMigrationTransactionSubmitter(
            transportFactory: factory,
            logger: logger
        )
    }

    private var boundPolicy: BoundSubmissionPolicy {
        BoundSubmissionPolicy(
            policy: SubmissionPolicy(
                transport: .direct,
                endpointIdentity: LiveMigrationTransactionSubmitter.endpointIdentity(fallbackEndpoint),
                consensusFingerprint: String(repeating: "0", count: 64)
            ),
            policyFingerprint: String(repeating: "1", count: 64),
            revision: 1
        )
    }

    private func makeService(
        response: LightWalletServiceResponse,
        tip: BlockHeight = 999_990,
        reportedBranch: String = "c2d6d0b4"
    ) -> LightWalletServiceMock {
        let service = LightWalletServiceMock()
        service.latestBlockHeightModeReturnValue = tip
        let info = LightWalletdInfoMock()
        info.underlyingChainName = "test"
        info.underlyingBlockHeight = UInt64(tip)
        info.underlyingConsensusBranchID = reportedBranch
        service.getInfoModeReturnValue = info
        service.submitSpendTransactionModeReturnValue = response
        service.closeConnectionsClosure = { }
        return service
    }

    private func makeResponse(errorCode: Int32 = 0, errorMessage: String = "") -> SendResponse {
        var response = SendResponse()
        response.errorCode = errorCode
        response.errorMessage = errorMessage
        return response
    }
}
