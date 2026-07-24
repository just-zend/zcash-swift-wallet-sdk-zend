//
//  MigrationTransactionSubmitterTests.swift
//  OfflineTests
//

import Foundation
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
            if let throwableError { throw throwableError }
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

    private let transaction = EncodedTransaction(
        transactionId: Data(repeating: 0xAB, count: 32),
        raw: Data([0x01, 0x02, 0x03])
    )
    private let directTarget = MigrationBoundSubmissionTarget(
        transport: .directTLS,
        endpoint: "https://submit.example:9067"
    )
    private let branch = UInt32(0xc2d6_d0b4)

    func testAcceptedSubmissionUsesOnlyTheRustBoundDirectTarget() async throws {
        let service = makeService(response: makeResponse())
        let factory = TransportFactoryMock(service: service, mode: .direct)

        let result = try await submit(using: makeSubmitter(factory: factory))

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(factory.receivedArguments?.endpoint.host, "submit.example")
        XCTAssertEqual(factory.receivedArguments?.endpoint.port, 9067)
        XCTAssertEqual(factory.receivedArguments?.endpoint.secure, true)
        XCTAssertEqual(factory.receivedArguments?.useTor, false)
        XCTAssertEqual(service.submitSpendTransactionModeReceivedArguments?.spendTransaction, transaction.raw)
        XCTAssertEqual(service.submitSpendTransactionModeReceivedArguments?.mode, .direct)
        XCTAssertTrue(service.closeConnectionsCalled)
    }

    func testTorTargetUsesOnlyTheBoundOnionEndpoint() async throws {
        let service = makeService(response: makeResponse())
        let factory = TransportFactoryMock(service: service, mode: .defaultTor)
        let target = MigrationBoundSubmissionTarget(
            transport: .torOnion,
            endpoint: "http://migrationexample.onion:80"
        )

        let result = try await submit(using: makeSubmitter(factory: factory), target: target)

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(factory.receivedArguments?.endpoint.host, "migrationexample.onion")
        XCTAssertEqual(factory.receivedArguments?.endpoint.port, 80)
        XCTAssertEqual(factory.receivedArguments?.useTor, true)
        XCTAssertEqual(service.submitSpendTransactionModeReceivedArguments?.mode, .defaultTor)
    }
}

extension MigrationTransactionSubmitterTests {
    func testPublicTLSTorIntentRemainsTorProxiedWithoutClaimingAnOnionEndpoint() {
        let intent = LiveMigrationTransactionSubmitter.submissionIntent(
            options: MigrationNetworkPrivacyOptions(
                useTor: true,
                submissionEndpoint: LightWalletEndpoint(address: "submit.example", port: 9067)
            ),
            networkType: .testnet
        )

        XCTAssertEqual(intent.transport, .torProxyTLS)
        XCTAssertEqual(intent.endpoint, "https://submit.example:9067")
    }

    func testOnionTorIntentKeepsTheOnionTransport() {
        let intent = LiveMigrationTransactionSubmitter.submissionIntent(
            options: MigrationNetworkPrivacyOptions(
                useTor: true,
                submissionEndpoint: LightWalletEndpoint(
                    address: "migrationexample.onion",
                    port: 80,
                    secure: false
                )
            ),
            networkType: .testnet
        )

        XCTAssertEqual(intent.transport, .torOnion)
        XCTAssertEqual(intent.endpoint, "http://migrationexample.onion:80")
    }

    func testTorProxyTLSTargetUsesOnlyTheBoundPublicEndpointOverTor() async throws {
        let service = makeService(response: makeResponse())
        let factory = TransportFactoryMock(service: service, mode: .defaultTor)
        let target = MigrationBoundSubmissionTarget(
            transport: .torProxyTLS,
            endpoint: "https://submit.example:9067"
        )

        let result = try await submit(using: makeSubmitter(factory: factory), target: target)

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(factory.receivedArguments?.endpoint.host, "submit.example")
        XCTAssertEqual(factory.receivedArguments?.endpoint.port, 9067)
        XCTAssertEqual(factory.receivedArguments?.endpoint.secure, true)
        XCTAssertEqual(factory.receivedArguments?.useTor, true)
        XCTAssertEqual(service.submitSpendTransactionModeReceivedArguments?.mode, .defaultTor)
    }

    func testTorProxyTLSRejectsCleartextBeforeTransportCreation() async throws {
        let service = makeService(response: makeResponse())
        let factory = TransportFactoryMock(service: service, mode: .defaultTor)

        do {
            _ = try await submit(
                using: makeSubmitter(factory: factory),
                target: MigrationBoundSubmissionTarget(
                    transport: .torProxyTLS,
                    endpoint: "http://submit.example:9067"
                )
            )
            XCTFail("expected invalidSubmissionEndpoint")
        } catch let error as MigrationBroadcastError {
            XCTAssertEqual(error, .invalidSubmissionEndpoint)
        }

        XCTAssertEqual(factory.callsCount, 0)
        XCTAssertFalse(service.submitSpendTransactionModeCalled)
    }

    func testPublicTLSTransportsRejectNonPublicDNSTargetsBeforeTransportCreation() throws {
        for transport in [MigrationSubmissionTransport.directTLS, .torProxyTLS] {
            for endpoint in [
                "https://migrationexample.onion:443",
                "https://localhost:9067",
                "https://127.0.0.2:9067",
                "https://10.0.0.1:9067",
                "https://169.254.169.254:9067",
                "https://2130706433:9067",
                "https://0x7f000001:9067",
                "https://0x7f.0x1:9067",
                "https://[::1]:9067"
            ] {
                XCTAssertThrowsError(
                    try LiveMigrationTransactionSubmitter.endpoint(
                        for: MigrationBoundSubmissionTarget(
                            transport: transport,
                            endpoint: endpoint
                        )
                    )
                )
            }
        }
    }

    func testMalformedOrTransportMismatchedBoundTargetFailsBeforeTransportCreation() async throws {
        let service = makeService(response: makeResponse())
        let factory = TransportFactoryMock(service: service, mode: .direct)
        let target = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "http://user:secret@submit.example:9067/path?leak=yes"
        )

        do {
            _ = try await submit(using: makeSubmitter(factory: factory), target: target)
            XCTFail("expected invalidSubmissionEndpoint")
        } catch let error as MigrationBroadcastError {
            XCTAssertEqual(error, .invalidSubmissionEndpoint)
        }

        XCTAssertEqual(factory.callsCount, 0)
        XCTAssertFalse(service.submitSpendTransactionModeCalled)
    }

    func testLoopbackDevelopmentAcceptsOnlyExplicitLoopbackHTTP() throws {
        let valid = try LiveMigrationTransactionSubmitter.endpoint(
            for: MigrationBoundSubmissionTarget(
                transport: .loopbackDevelopment,
                endpoint: "http://127.0.0.1:9067"
            )
        )
        XCTAssertEqual(valid.host, "127.0.0.1")
        XCTAssertFalse(valid.secure)

        for endpoint in ["http://example.com:9067", "https://127.0.0.1:9067"] {
            XCTAssertThrowsError(
                try LiveMigrationTransactionSubmitter.endpoint(
                    for: MigrationBoundSubmissionTarget(
                        transport: .loopbackDevelopment,
                        endpoint: endpoint
                    )
                )
            )
        }
    }

    func testTorSetupFailurePropagatesWithoutClearFallback() async throws {
        let service = makeService(response: makeResponse())
        let factory = TransportFactoryMock(service: service, mode: .defaultTor)
        factory.throwableError = TestError.torSetup

        do {
            _ = try await submit(
                using: makeSubmitter(factory: factory),
                target: MigrationBoundSubmissionTarget(
                    transport: .torOnion,
                    endpoint: "http://migrationexample.onion:80"
                )
            )
            XCTFail("expected Tor setup failure")
        } catch TestError.torSetup {
            // expected
        }

        XCTAssertEqual(factory.callsCount, 1)
        XCTAssertFalse(service.submitSpendTransactionModeCalled)
    }

    func testPreflightUsesHighestTipSampleAndRejectsExpiringBytesKnownUnsent() async throws {
        let service = makeService(response: makeResponse(), tip: 501)
        var sampledHeights: [BlockHeight] = [499, 501, 498]
        service.latestBlockHeightModeClosure = { _ in sampledHeights.removeFirst() }
        let factory = TransportFactoryMock(service: service, mode: .direct)

        do {
            _ = try await submit(using: makeSubmitter(factory: factory), expiryHeight: 500)
            XCTFail("expected expiry preflight failure")
        } catch let MigrationBroadcastError.selectedTransportTipWithinExpirySafetyMargin(tip, expiry, margin) {
            XCTAssertEqual(tip, 501)
            XCTAssertEqual(expiry, 500)
            XCTAssertEqual(margin, 4)
        }

        XCTAssertEqual(service.latestBlockHeightModeCallsCount, 3)
        XCTAssertFalse(service.submitSpendTransactionModeCalled)
        XCTAssertTrue(service.closeConnectionsCalled)
    }

    func testPreflightFailureClosesTransportWithoutSubmitting() async throws {
        let service = makeService(response: makeResponse())
        service.latestBlockHeightModeClosure = { _ in throw TestError.transport }
        let factory = TransportFactoryMock(service: service, mode: .direct)

        do {
            _ = try await submit(using: makeSubmitter(factory: factory))
            XCTFail("expected preflight failure")
        } catch TestError.transport {
            // expected
        }

        XCTAssertEqual(service.latestBlockHeightModeCallsCount, 3)
        XCTAssertFalse(service.submitSpendTransactionModeCalled)
        XCTAssertTrue(service.closeConnectionsCalled)
    }

    func testPreflightCancellationRemainsKnownUnsentAndNeverSubmits() async throws {
        let service = makeService(response: makeResponse())
        service.latestBlockHeightModeClosure = { _ in throw CancellationError() }

        do {
            _ = try await submit(
                using: makeSubmitter(
                    factory: TransportFactoryMock(service: service, mode: .direct)
                )
            )
            XCTFail("expected preflight cancellation")
        } catch is CancellationError {
            // Cancellation before the submit RPC begins is still provably unsent.
        }

        XCTAssertFalse(service.submitSpendTransactionModeCalled)
        XCTAssertTrue(service.closeConnectionsCalled)
    }

    func testTransportFailureAfterSubmitStartsIsUnknown() async throws {
        let service = makeService(response: makeResponse())
        service.submitSpendTransactionModeThrowableError = TestError.transport

        let result = try await submit(
            using: makeSubmitter(factory: TransportFactoryMock(service: service, mode: .direct))
        )

        XCTAssertEqual(result, .unknown)
        XCTAssertFalse(service.fetchTransactionTxIdModeCalled)
        XCTAssertTrue(service.closeConnectionsCalled)
    }

    func testCancellationAfterSubmitStartsIsOutcomeUnknown() async throws {
        let service = makeService(response: makeResponse())
        service.submitSpendTransactionModeThrowableError = CancellationError()

        let result = try await submit(
            using: makeSubmitter(factory: TransportFactoryMock(service: service, mode: .direct))
        )

        XCTAssertEqual(result, .unknown)
        XCTAssertFalse(service.fetchTransactionTxIdModeCalled)
        XCTAssertTrue(service.closeConnectionsCalled)
    }

    func testRejectedSubmissionKnownByExactTxidIsAccepted() async throws {
        let service = makeService(response: makeResponse(errorCode: -1, errorMessage: "already queued"))
        service.fetchTransactionTxIdModeReturnValue = (tx: nil, status: .notInMainChain)

        let result = try await submit(
            using: makeSubmitter(factory: TransportFactoryMock(service: service, mode: .direct))
        )

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(service.fetchTransactionTxIdModeReceivedArguments?.txId, transaction.transactionId)
    }

    func testRejectedSubmissionUnknownToEndpointIsKnownUnsent() async throws {
        let service = makeService(response: makeResponse(errorCode: -25, errorMessage: "missing inputs"))
        service.fetchTransactionTxIdModeReturnValue = (tx: nil, status: .txidNotRecognized)

        let result = try await submit(
            using: makeSubmitter(factory: TransportFactoryMock(service: service, mode: .direct))
        )

        XCTAssertEqual(result, .knownUnsent)
    }

    func testRejectedSubmissionWithFailedExactLookupIsUnknown() async throws {
        let service = makeService(response: makeResponse(errorCode: 7, errorMessage: "secret body"))
        service.fetchTransactionTxIdModeClosure = { _, _ in throw TestError.transport }

        let result = try await submit(
            using: makeSubmitter(factory: TransportFactoryMock(service: service, mode: .direct))
        )

        XCTAssertEqual(result, .unknown)
    }

    func testActivationBoundaryValidatesReportedBranchAndExactNextHeightBranch() async throws {
        let oldBranch = UInt32(0xc2d6_d0b4)
        let newBranch = UInt32(0xc8e7_1055)
        let service = makeService(
            response: makeResponse(),
            tip: 99,
            reportedBranch: String(format: "%08x", oldBranch)
        )
        let submitter = makeSubmitter(factory: TransportFactoryMock(service: service, mode: .direct))

        let result = try await submit(
            using: submitter,
            expiryHeight: 110,
            transactionBranch: newBranch,
            branchIdForHeight: { height in
                Int32(bitPattern: height < 100 ? oldBranch : newBranch)
            }
        )

        XCTAssertEqual(result, .accepted)
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

        do {
            _ = try await submit(
                using: makeSubmitter(factory: TransportFactoryMock(service: service, mode: .direct)),
                expiryHeight: 110,
                transactionBranch: oldBranch,
                branchIdForHeight: { height in
                    Int32(bitPattern: height < 100 ? oldBranch : newBranch)
                }
            )
            XCTFail("expected exact branch mismatch")
        } catch let error as MigrationBroadcastError {
            XCTAssertEqual(error, .transactionConsensusBranchMismatch)
        }

        XCTAssertFalse(service.submitSpendTransactionModeCalled)
        XCTAssertTrue(service.closeConnectionsCalled)
    }

    func testExportableLogsContainOnlyStableCodesAndNoSensitivePayloads() async throws {
        let logger = RecordingLogger()
        let secretServerBody = "secret-server-body"
        let service = makeService(response: makeResponse(errorCode: -25, errorMessage: secretServerBody))
        service.fetchTransactionTxIdModeReturnValue = (tx: nil, status: .txidNotRecognized)

        _ = try await submit(
            using: makeSubmitter(
                factory: TransportFactoryMock(service: service, mode: .direct),
                logger: logger
            )
        )

        XCTAssertEqual(logger.errors, ["migration_submit outcome=known_unsent code=server_rejected_-25"])
        let exported = logger.errors.joined(separator: " ")
        for secret in [secretServerBody, directTarget.endpoint, transaction.transactionId.base64EncodedString()] {
            XCTAssertFalse(exported.contains(secret), "exported logs leaked sentinel: \(secret)")
        }
    }

    private func submit(
        using submitter: LiveMigrationTransactionSubmitter,
        target: MigrationBoundSubmissionTarget? = nil,
        expiryHeight: BlockHeight = 1_000_000,
        transactionBranch: UInt32? = nil,
        branchIdForHeight: ((Int32) throws -> Int32)? = nil
    ) async throws -> MigrationSubmissionOutcome {
        let expectedBranch = transactionBranch ?? branch
        return try await submitter.submit(
            transaction: transaction,
            expiryHeight: expiryHeight,
            target: target ?? directTarget,
            expectedChainName: "test",
            transactionConsensusBranchId: expectedBranch,
            branchIdForHeight: branchIdForHeight ?? { _ in Int32(bitPattern: self.branch) },
            renewLease: {}
        )
    }

    private func makeSubmitter(
        factory: MigrationTransportCreating,
        logger: Logger = submissionLifecycleLogger()
    ) -> LiveMigrationTransactionSubmitter {
        LiveMigrationTransactionSubmitter(transportFactory: factory, logger: logger)
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
        service.closeConnectionsClosure = {}
        return service
    }

    private func makeResponse(errorCode: Int32 = 0, errorMessage: String = "") -> SendResponse {
        var response = SendResponse()
        response.errorCode = errorCode
        response.errorMessage = errorMessage
        return response
    }
}
