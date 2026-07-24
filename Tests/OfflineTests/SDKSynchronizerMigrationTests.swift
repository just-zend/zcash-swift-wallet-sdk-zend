//
//  SDKSynchronizerMigrationTests.swift
//  OfflineTests
//
//  Tests `SDKSynchronizer`'s claim-backed migration group as thin forwards to a seamed
//  `OrchardMigrationHost` -- except the DB-free, account-free Keystone batch-signing bridge,
//  which forwards straight to `initializer.rustBackend` -- and the two SDK-enforced
//  session-separation behaviors --
//  the start() privacy gate and the claim-backed submission broadcast
//  guard. Driven through the host's injecting initializer + a scripted actor factory, mirroring
//  R4-A's `OrchardMigrationHostTests` seam, with the host substituted into a real `SDKSynchronizer`
//  via the container-mock seam (`container.mock(type: OrchardMigrationHost.self, ...)`) that
//  `SDKSynchronizer.init` resolves against, same as `sdkFlags`/`submitPlanStore`.
//
//  No network, no real FFI beyond local SQLite/key-derivation calls that `Initializer`/
//  `TestsData` already make offline elsewhere in this suite.
//

import Combine
import Foundation
@testable import TestUtils
import XCTest
@testable import ZcashLightClientKit

final class SDKSynchronizerMigrationTests: ZcashTestCase {
    private let accountUUID = AccountUUID(id: [UInt8](repeating: 0x0A, count: 16))
    private let submissionEndpoint = LightWalletEndpoint(address: "submit.example", port: 9067)
    private var cancellables: [AnyCancellable] = []
    private static let uaString = """
    u1l9f0l4348negsncgr9pxd9d3qaxagmqv3lnexcplmufpq7muffvfaue6ksevfvd7wrz7xrvn95rc5zjtn7ugkmgh5rnxswmcj30y0pw52pn0zjvy38rn2esfgve64rj5pcmazxgpyuj
    """

    override func setUp() {
        super.setUp()
        cancellables = []
    }

    override func tearDown() {
        cancellables = []
        super.tearDown()
    }

    // MARK: - Forwarding (representatives: state, split, schedule, delivery, recovery, PCZT)

    func testMigrationStateForwardsToTheAccountsActor() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = Self.makeRuntimeSnapshot(account: accountUUID)
        welding.migrationStateForReturnValue = .notStarted
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let state = try await synchronizer.migrationState(accountUUID: accountUUID)

        XCTAssertEqual(state, .notStarted)
        XCTAssertEqual(welding.migrationStateForReceivedAccount, accountUUID)
    }

    func testMigrationRuntimeSnapshotForwardsToTheAccountsActor() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let expected = Self.makeRuntimeSnapshot(account: accountUUID)
        welding.migrationRuntimeSnapshotForReturnValue = expected
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let snapshot = try await synchronizer.migrationRuntimeSnapshot(accountUUID: accountUUID)

        XCTAssertEqual(snapshot, expected)
        XCTAssertEqual(welding.migrationRuntimeSnapshotForReceivedAccount, accountUUID)
    }

    func testPrepareNoteSplitForwardsToTheAccountsActor() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let expected = NoteSplitProposal(
            outputNotes: [Zatoshi(500), Zatoshi(500)],
            fee: Zatoshi(100),
            proposalHandle: 7
        )
        welding.migrationPrepareNoteSplitForReturnValue = expected
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let proposal = try await synchronizer.prepareNoteSplit(accountUUID: accountUUID)

        XCTAssertEqual(proposal, expected)
        XCTAssertEqual(welding.migrationPrepareNoteSplitForReceivedAccount, accountUUID)
    }

    func testProposeMigrationTransfersForwardsToTheAccountsActor() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let expected = MigrationSchedule(transfers: [], estimatedDurationHours: 3, proposalHandle: 11)
        welding.migrationProposeTransfersForReturnValue = expected
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let schedule = try await synchronizer.proposeMigrationTransfers(accountUUID: accountUUID)

        XCTAssertEqual(schedule, expected)
        XCTAssertEqual(welding.migrationProposeTransfersForReceivedAccount, accountUUID)
    }

    func testHasOverdueMigrationTransfersForwards() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationHasOverdueTransfersForReturnValue = true
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let overdue = try await synchronizer.hasOverdueMigrationTransfers(accountUUID: accountUUID)

        XCTAssertTrue(overdue)
        XCTAssertEqual(welding.migrationHasOverdueTransfersForReceivedAccount, accountUUID)
    }

    /// The live per-transaction status read behind `migrationProgress`'s aggregate summary --
    /// forwards to the per-account actor and returns the engine's rows untouched.
    func testMigrationTransactionStatusesForwardsToTheAccountsActor() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = Self.makeRuntimeSnapshot(account: accountUUID)
        let expected = [
            MigrationTransactionStatus(
                id: 3,
                kind: .transfer(crossing: 0),
                state: .awaitingSignature,
                scheduledHeight: 3_000_000,
                expiryHeight: 3_000_100,
                isReady: true,
                nextAction: .prove,
                blockedOn: nil
            )
        ]
        welding.migrationTransactionStatusesForReturnValue = expected
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let statuses = try await synchronizer.migrationTransactionStatuses(accountUUID: accountUUID)

        XCTAssertEqual(statuses, expected)
        XCTAssertEqual(welding.migrationTransactionStatusesForReceivedAccount, accountUUID)
    }

    /// The sequential-runs contract at the API level: `.complete` is the sole strict/reversible
    /// completion value supplied by Rust (there is no second host Boolean), but it remains per-run.
    /// The authority for "does anything remain to migrate" is a fresh propose — an empty schedule
    /// means no, a non-empty one is the next run's proposal. Hosts must not latch "never migrate
    /// again" off the state machine alone.
    func testAfterCompleteProposeMigrationTransfersAnswersWhetherAnythingRemains() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = Self.makeRuntimeSnapshot(account: accountUUID)
        welding.migrationStateForReturnValue = .complete
        welding.migrationProposeTransfersForReturnValue = MigrationSchedule(
            transfers: [],
            estimatedDurationHours: 0,
            proposalHandle: 0
        )
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let state = try await synchronizer.migrationState(accountUUID: accountUUID)
        XCTAssertEqual(state, .complete)

        let remains = try await synchronizer.proposeMigrationTransfers(accountUUID: accountUUID)
        XCTAssertTrue(remains.transfers.isEmpty, "an empty schedule is the 'nothing remains' answer")

        // Funds arrive later (or a large balance needed another round): the same call now answers
        // with the next run's proposal.
        let nextRun = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(
                    id: "3",
                    amount: Zatoshi(100_000_000),
                    anchorHeight: BlockHeight(1_000),
                    nextExecutableAfterHeight: BlockHeight(1_010),
                    expiryHeight: BlockHeight(70_000)
                )
            ],
            estimatedDurationHours: 1,
            proposalHandle: 12
        )
        welding.migrationProposeTransfersForReturnValue = nextRun
        let proposed = try await synchronizer.proposeMigrationTransfers(accountUUID: accountUUID)
        XCTAssertEqual(proposed, nextRun, "a non-empty schedule is the next run's proposal")
    }

    func testPrepareImmediateMigrationForExternalSigningUsesTheOpaqueClaimLane() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = Self.makeRuntimeSnapshot(account: accountUUID)
        welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForReturnValue = Self.makeClaimHandle(1)
        welding.migrationPrepareImmediateExternalSigningClaimForReturnValue = Self.makeClaimHandle(2)
        let expectedPCZT = Data([0x50, 0x43, 0x5A, 0x54])
        welding.migrationClaimExternalSigningPCZTReturnValue = expectedPCZT
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))
        let options = MigrationNetworkPrivacyOptions(
            useTor: false,
            submissionEndpoint: LightWalletEndpoint(address: "submit.example", port: 9067, secure: true)
        )
        let maximumGrossAmount = Zatoshi(100_000_000)

        let request = try await synchronizer.prepareImmediateMigrationForExternalSigning(
            accountUUID: accountUUID,
            maximumGrossAmount: maximumGrossAmount,
            options: options
        )

        XCTAssertEqual(request.pczt, expectedPCZT)
        XCTAssertEqual(
            welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForReceivedArguments?.signer,
            .external
        )
        XCTAssertEqual(
            welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForReceivedArguments?.account,
            accountUUID
        )
        XCTAssertEqual(
            welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForReceivedArguments?.maximumGrossAmount,
            maximumGrossAmount
        )
        XCTAssertEqual(
            welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForReceivedArguments?.submission,
            MigrationSubmissionIntent(transport: .directTLS, endpoint: "https://submit.example:9067")
        )
        XCTAssertEqual(welding.migrationPrepareImmediateExternalSigningClaimForCallsCount, 1)
        XCTAssertEqual(welding.migrationClaimExternalSigningPCZTCallsCount, 1)
    }

    /// `lockMigrationResidual` — the "Lock balance" choice at migration `Complete` — forwards to
    /// the per-account actor and returns the welding's locked total untouched. Like the rest of the
    /// group it needs no `prepare()` and carries no broadcast guard (locking is a data-db write,
    /// nothing is broadcast).
    func testLockMigrationResidualForwardsToTheAccountsActor() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.lockMigrationResidualAccountUUIDReturnValue = Zatoshi(21_500)
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let locked = try await synchronizer.lockMigrationResidual(accountUUID: accountUUID)

        XCTAssertEqual(locked, Zatoshi(21_500))
        XCTAssertEqual(welding.lockMigrationResidualAccountUUIDReceivedAccountUUID, accountUUID)
    }

    /// A lock failure (in particular the concurrent-lock race, which the caller may retry)
    /// propagates through the `Synchronizer` surface untouched.
    func testLockMigrationResidualPropagatesTheWeldingError() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.lockMigrationResidualAccountUUIDThrowableError = ZcashError.rustMigrationLockResidual("concurrent lock race")
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        do {
            _ = try await synchronizer.lockMigrationResidual(accountUUID: accountUUID)
            XCTFail("expected rustMigrationLockResidual to propagate")
        } catch ZcashError.rustMigrationLockResidual {
            // expected
        } catch {
            XCTFail("expected rustMigrationLockResidual, got \(error)")
        }
    }

    /// `unlockMigrationResidual` — the release half; "Migrate anyway" composes as this call
    /// followed by `submitImmediateMigration` — forwards to the per-account actor and returns the
    /// cleared-lock count untouched.
    func testUnlockMigrationResidualForwardsToTheAccountsActor() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.unlockMigrationResidualAccountUUIDReturnValue = 7
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let cleared = try await synchronizer.unlockMigrationResidual(accountUUID: accountUUID)

        XCTAssertEqual(cleared, 7)
        XCTAssertEqual(welding.unlockMigrationResidualAccountUUIDReceivedAccountUUID, accountUUID)
    }

    /// `estimateMigrationRuns` forwards to the per-account actor and hands the engine's
    /// `MigrationRunEstimate` through unchanged — pinned with a non-trivial two-run fixture so any
    /// field cross-wiring in the pass-through would break equality, and the derived signing-session
    /// math answers over exactly what the engine reported.
    func testEstimateMigrationRunsForwardsToTheAccountsActor() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let estimate = MigrationRunEstimate(
            runs: [
                MigrationRunEstimate.Run(
                    migratable: Zatoshi(75_000_000),
                    crossings: 15,
                    preparationLayers: 2,
                    preparationTransactions: 5
                ),
                MigrationRunEstimate.Run(
                    migratable: Zatoshi(1_200_000),
                    crossings: 3,
                    preparationLayers: 1,
                    preparationTransactions: 1
                )
            ],
            finalResidual: Zatoshi(42_000)
        )
        welding.estimateMigrationRunsAccountUUIDReturnValue = estimate
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let returned = try await synchronizer.estimateMigrationRuns(accountUUID: accountUUID)

        XCTAssertEqual(returned, estimate)
        XCTAssertEqual(welding.estimateMigrationRunsAccountUUIDReceivedAccountUUID, accountUUID)
        XCTAssertEqual(
            returned.totalSigningSessions(maxTransactionsPerSession: 8),
            estimate.totalSigningSessions(maxTransactionsPerSession: 8),
            "the derived signing-session math must answer over the forwarded runs"
        )
    }

    // MARK: - Forwarding: Keystone batch-signing bridge (DB-free, no host)
    //
    // Unlike the rest of this group, these four bypass `migrationHost.migration(for:)` entirely --
    // DB-free and account-free, they forward straight to `initializer.rustBackend` (see
    // `SDKSynchronizer.swift`'s own "ordinary PCZT operations" precedent: `createPCZTFromProposal`,
    // `redactPCZTForSigner`, et al.), mirroring `SlipstreamSynchronizer`'s override of the same
    // four. `ZcashRustBackendWelding` is substituted into the SAME container `SDKSynchronizer.init`
    // resolves `initializer.rustBackend` from (mirrors
    // `SynchronizerOfflineTests.testPreparePropagatesSeedNotRelevantFromRustBackend`'s seam), so
    // `welding` backs both the (here, unused) `OrchardMigrationHost` and the direct rust-backend
    // forward under test.

    func testBuildKeystoneSignBatchQRPartsForwardsToTheRustBackend() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let expectedParts = [
            "ur:zcash-migration-keystone-batch-sign-req/1-2/abcdefgh",
            "ur:zcash-migration-keystone-batch-sign-req/2-2/ijklmnop"
        ]
        welding.migrationKeystoneBuildSignBatchQrPartsRequestIdPcztsMaxFragmentLenReturnValue = expectedParts
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in welding }
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))
        let requestId = Data(repeating: 0x11, count: 16)
        let pczts = [
            MigrationUnsignedTransferPczt(id: "0", pczt: Data([0xAA, 0xBB])),
            MigrationUnsignedTransferPczt(id: "1", pczt: Data([0xCC, 0xDD, 0xEE]))
        ]

        let parts = try await synchronizer.buildKeystoneSignBatchQRParts(requestId: requestId, pczts: pczts, maxFragmentLen: 200)

        XCTAssertEqual(parts, expectedParts)
        XCTAssertEqual(welding.migrationKeystoneBuildSignBatchQrPartsRequestIdPcztsMaxFragmentLenCallsCount, 1)
        let received = welding.migrationKeystoneBuildSignBatchQrPartsRequestIdPcztsMaxFragmentLenReceivedArguments
        XCTAssertEqual(received?.requestId, requestId)
        XCTAssertEqual(received?.pczts, pczts)
        XCTAssertEqual(received?.maxFragmentLen, 200)
    }

    func testClaimOwnedKeystoneBuildForwardsOnlyTheOpaqueScheduledClaim() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let expectedParts = ["ur:zcash-sign-batch/1-1/claim-owned"]
        welding.migrationKeystoneBuildClaimOwnedSignBatchQrPartsRequestIdClaimForMaxFragmentLenReturnValue = expectedParts
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))
        let claim = Self.makeClaimHandle(71)
        let request = ScheduledMigrationExternalSigningRequest(
            transactionID: 7,
            pczt: Data([0x50, 0x43, 0x5A, 0x54]),
            claim: claim
        )
        let requestId = Data(repeating: 0x17, count: 16)

        let parts = try await synchronizer.buildKeystoneSignBatchQRParts(
            accountUUID: accountUUID,
            requestId: requestId,
            request: request,
            maxFragmentLen: 180
        )

        XCTAssertEqual(parts, expectedParts)
        let received = welding
            .migrationKeystoneBuildClaimOwnedSignBatchQrPartsRequestIdClaimForMaxFragmentLenReceivedArguments
        XCTAssertEqual(received?.requestId, requestId)
        XCTAssertEqual(received?.claim.pointer, claim.pointer)
        XCTAssertEqual(received?.account, accountUUID)
        XCTAssertEqual(received?.maxFragmentLen, 180)
        XCTAssertFalse(
            welding.migrationKeystoneBuildSignBatchQrPartsRequestIdPcztsMaxFragmentLenCalled,
            "the claim-owned path must not route caller-held PCZT bytes through the raw builder"
        )
    }

    /// Infallible and DB-free: pinned by call count alone, since there is no return value to
    /// round-trip.
    func testResetKeystoneSignBatchDecoderForwardsToTheRustBackend() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationKeystoneResetSignBatchDecoderClosure = { }
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in welding }
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        await synchronizer.resetKeystoneSignBatchDecoder()

        XCTAssertEqual(welding.migrationKeystoneResetSignBatchDecoderCallsCount, 1)
    }

    /// Pinned with a COMPLETE result carrying a firmware version, so any field cross-wiring in the
    /// pass-through would break equality.
    func testDecodeKeystoneSignBatchPartForwardsToTheRustBackend() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let expected = KeystoneBatchDecodeResult(
            complete: true,
            progress: 100,
            data: Data([0x01, 0x02, 0x03]),
            firmwareVersion: KeystoneFirmwareVersion(major: 1, minor: 2, build: 3)
        )
        welding.migrationKeystoneDecodeSignBatchPartExpectedRequestIdReturnValue = expected
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in welding }
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))
        let expectedRequestId = Data(repeating: 0x22, count: 16)
        let part = "ur:zcash-migration-keystone-batch-sign-res/1-1/qrpayload"

        let result = try await synchronizer.decodeKeystoneSignBatchPart(part, expectedRequestId: expectedRequestId)

        XCTAssertEqual(result, expected)
        XCTAssertEqual(welding.migrationKeystoneDecodeSignBatchPartExpectedRequestIdCallsCount, 1)
        let received = welding.migrationKeystoneDecodeSignBatchPartExpectedRequestIdReceivedArguments
        XCTAssertEqual(received?.part, part)
        XCTAssertEqual(received?.expectedRequestId, expectedRequestId)
    }

    func testApplyKeystoneBatchSignaturesForwardsToTheRustBackend() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let expected = [
            MigrationSignedTransferPczt(id: "0", pczt: Data([0xAA, 0xBB, 0x01])),
            MigrationSignedTransferPczt(id: "1", pczt: Data([0xCC, 0xDD, 0x02]))
        ]
        welding.migrationKeystoneApplyBatchSignaturesPcztsBatchSignResponseReturnValue = expected
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in welding }
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))
        let pczts = [
            MigrationUnsignedTransferPczt(id: "0", pczt: Data([0xAA, 0xBB])),
            MigrationUnsignedTransferPczt(id: "1", pczt: Data([0xCC, 0xDD]))
        ]
        let batchSignResponse = Data(repeating: 0x33, count: 8)

        let signed = try await synchronizer.applyKeystoneBatchSignatures(pczts: pczts, batchSignResponse: batchSignResponse)

        XCTAssertEqual(signed, expected)
        XCTAssertEqual(welding.migrationKeystoneApplyBatchSignaturesPcztsBatchSignResponseCallsCount, 1)
        let received = welding.migrationKeystoneApplyBatchSignaturesPcztsBatchSignResponseReceivedArguments
        XCTAssertEqual(received?.pczts, pczts)
        XCTAssertEqual(received?.batchSignResponse, batchSignResponse)
    }

    func testClaimOwnedKeystoneApplyUsesTheExactRetainedRequestPCZT() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let request = ScheduledMigrationExternalSigningRequest(
            transactionID: 7,
            pczt: Data([0x50, 0x43, 0x5A, 0x54]),
            claim: Self.makeClaimHandle(72)
        )
        let signedPCZT = Data([0x53, 0x49, 0x47])
        welding.migrationKeystoneApplyBatchSignaturesPcztsBatchSignResponseReturnValue = [
            MigrationSignedTransferPczt(id: "7", pczt: signedPCZT)
        ]
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in welding }
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))
        let response = Data(repeating: 0x33, count: 8)

        let result = try await synchronizer.applyKeystoneBatchSignatures(
            request: request,
            batchSignResponse: response
        )

        XCTAssertEqual(result, signedPCZT)
        let received = welding.migrationKeystoneApplyBatchSignaturesPcztsBatchSignResponseReceivedArguments
        XCTAssertEqual(received?.pczts, [MigrationUnsignedTransferPczt(id: "7", pczt: request.pczt)])
        XCTAssertEqual(received?.batchSignResponse, response)
    }

    // MARK: - Forwarding: wallet-scope gate members

    func testIsMigrationSyncBlockedForwardsToHostPredicate() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.listAccountsReturnValue = [makeAccount(accountUUID)]
        welding.migrationHasOverdueTransfersForReturnValue = true
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let blocked = await synchronizer.isMigrationSyncBlocked()

        // The inert protocol default always returns false; true here proves this is genuinely
        // wired to the host's own (engineered-non-default) predicate result.
        XCTAssertTrue(blocked)
    }

    func testMigrationSyncBlockedStreamForwardsToHostStream() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.listAccountsReturnValue = [makeAccount(accountUUID)]
        welding.migrationHasOverdueTransfersForReturnValue = true
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding, tickInterval: 0.02))

        var received: [Bool] = []
        let sawBlocked = expectation(description: "the forwarded stream observed the host's live blocked state")
        let cancellable = synchronizer.migrationSyncBlockedStream.sink { value in
            received.append(value)
            if value {
                sawBlocked.fulfill()
            }
        }
        cancellables.append(cancellable)

        await fulfillment(of: [sawBlocked], timeout: 5)
        // The inert protocol default only ever emits false; observing true here proves this is
        // genuinely wired to the host's own reactive stream, not the static default.
        XCTAssertEqual(received.first, false, "precondition: a fresh host seeds false")
        XCTAssertEqual(received.last, true)
    }

    func testMigrationPrivacySyncBufferDurationForwardsHostConstant() throws {
        let welding = ZcashRustBackendWeldingMock()
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        XCTAssertEqual(synchronizer.migrationPrivacySyncBufferDuration, OrchardMigration.privacySyncBufferDuration)
    }

    // MARK: - Enforcement: start() privacy gate

    func testStartThrowsMigrationSyncBlockedWhenHostReportsBlocked() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.listAccountsReturnValue = [makeAccount(accountUUID)]
        welding.migrationHasOverdueTransfersForReturnValue = true
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))
        await synchronizer.updateStatus(.stopped)

        do {
            try await synchronizer.start(retry: false)
            XCTFail("expected start() to throw migrationSyncBlocked")
        } catch let error as ZcashError {
            guard case .migrationSyncBlocked = error else {
                XCTFail("expected migrationSyncBlocked, got \(error)")
                return
            }
            XCTAssertEqual(error.code.rawValue, "ZRUST0125")
        } catch {
            XCTFail("expected a ZcashError, got \(error)")
        }
    }

    func testStartProceedsPastTheGateWhenHostReportsUnblocked() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.listAccountsReturnValue = []
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))
        await synchronizer.updateStatus(.stopped)

        do {
            try await synchronizer.start(retry: false)
            // Ideal outcome: the gate passed and start() ran to completion offline.
        } catch let error as ZcashError {
            if case .migrationSyncBlocked = error {
                XCTFail("start() must not report migrationSyncBlocked when the host reports unblocked")
            }
            // Any other ZcashError is an unrelated offline failure (no live lightwalletd) and is
            // acceptable here -- only the gate's behavior is under test.
        } catch {
            // Likewise tolerated as an unrelated offline failure.
        }

        synchronizer.stop()
    }

    // MARK: - Enforcement: broadcast guard

    func testSubmitExternallySignedMigrationTransactionThrowsDuringSyncWithoutTouchingTheHost() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let recorder = FactoryInvocationRecorder()
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding, factoryRecorder: recorder))
        await synchronizer.updateStatus(.syncing(0.5, false))

        let request = ScheduledMigrationExternalSigningRequest(
            transactionID: 7,
            pczt: Data([0x50, 0x43, 0x5A, 0x54]),
            claim: Self.makeClaimHandle(7)
        )

        do {
            _ = try await synchronizer.submitExternallySignedMigrationTransaction(
                accountUUID: accountUUID,
                request: request,
                signedPCZT: Data([0x53, 0x49, 0x47])
            )
            XCTFail("expected migrationBroadcastDuringSync")
        } catch let error as ZcashError {
            guard case .migrationBroadcastDuringSync = error else {
                XCTFail("expected migrationBroadcastDuringSync, got \(error)")
                return
            }
            XCTAssertEqual(error.code.rawValue, "ZRUST0126")
        } catch {
            XCTFail("expected a ZcashError, got \(error)")
        }

        XCTAssertEqual(recorder.callCount, 0, "the guard must throw before the host is ever consulted")
        XCTAssertFalse(welding.migrationResumeClaimClaimForCalled, "the engine must never see a during-sync submission")
    }

    func testExecuteNextPendingMigrationTransferThrowsDuringSyncWithoutTouchingTheHost() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let recorder = FactoryInvocationRecorder()
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding, factoryRecorder: recorder))
        await synchronizer.updateStatus(.syncing(0.5, false))

        let options = MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: submissionEndpoint)

        do {
            _ = try await synchronizer.executeNextPendingMigrationTransfer(accountUUID: accountUUID, options: options)
            XCTFail("expected migrationBroadcastDuringSync")
        } catch let error as ZcashError {
            guard case .migrationBroadcastDuringSync = error else {
                XCTFail("expected migrationBroadcastDuringSync, got \(error)")
                return
            }
            XCTAssertEqual(error.code.rawValue, "ZRUST0126")
        } catch {
            XCTFail("expected a ZcashError, got \(error)")
        }

        XCTAssertEqual(recorder.callCount, 0, "the guard must throw before the host is ever consulted")
        XCTAssertFalse(welding.migrationRuntimeSnapshotForCalled, "the engine must never see a during-sync execution attempt")
    }

    /// Not-syncing companion: the exact-request route reaches the per-account actor's runtime
    /// reconciliation boundary.
    func testSubmitExternallySignedMigrationTransactionForwardsWhenNotSyncing() async throws {
        struct StubRuntimeSnapshotFailure: Error, Equatable {}
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForThrowableError = StubRuntimeSnapshotFailure()
        let recorder = FactoryInvocationRecorder()
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding, factoryRecorder: recorder))
        await synchronizer.updateStatus(.stopped)

        let request = ScheduledMigrationExternalSigningRequest(
            transactionID: 7,
            pczt: Data([0x50, 0x43, 0x5A, 0x54]),
            claim: Self.makeClaimHandle(7)
        )

        do {
            _ = try await synchronizer.submitExternallySignedMigrationTransaction(
                accountUUID: accountUUID,
                request: request,
                signedPCZT: Data([0x53, 0x49, 0x47])
            )
            XCTFail("expected the stubbed runtime-snapshot failure to propagate")
        } catch let error as StubRuntimeSnapshotFailure {
            XCTAssertEqual(error, StubRuntimeSnapshotFailure())
        } catch {
            XCTFail("expected StubRuntimeSnapshotFailure, got \(error)")
        }

        XCTAssertEqual(recorder.callCount, 1, "the host must be consulted when the synchronizer is not syncing")
    }

    /// Not-syncing companion for `executeNextPendingMigrationTransfer`, mirroring
    /// `testSubmitNoteSplitForwardsWhenNotSyncing()`.
    func testExecuteNextPendingMigrationTransferForwardsWhenNotSyncing() async throws {
        struct StubRuntimeSnapshotFailure: Error, Equatable {}
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForThrowableError = StubRuntimeSnapshotFailure()
        let recorder = FactoryInvocationRecorder()
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding, factoryRecorder: recorder))
        await synchronizer.updateStatus(.stopped)

        let options = MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: submissionEndpoint)

        do {
            _ = try await synchronizer.executeNextPendingMigrationTransfer(accountUUID: accountUUID, options: options)
            XCTFail("expected the stubbed runtime-snapshot failure to propagate")
        } catch let error as StubRuntimeSnapshotFailure {
            XCTAssertEqual(error, StubRuntimeSnapshotFailure())
        } catch {
            XCTFail("expected StubRuntimeSnapshotFailure, got \(error)")
        }

        // See the note in `testSubmitNoteSplitForwardsWhenNotSyncing()`: `...ThrowableError` bypasses
        // the mock's `...CallsCount` bump, so the recorder + exact stub type are the proof here.
        XCTAssertEqual(recorder.callCount, 1, "the host must be consulted when the synchronizer is not syncing")
    }

    // MARK: - Resource lifecycle: migration-host registration must not retain the Initializer

    /// Regression test: `SDKSynchronizer.init` registers a factory closure for `OrchardMigrationHost`
    /// on `initializer.container`. If that closure captures `initializer` with no capture list, the
    /// result is a cycle -- `initializer` owns `container` (`Initializer.container: DIContainer`),
    /// `container` stores the closure, and the closure captures `initializer` right back
    /// (`initializer -> container -> closure -> initializer`). Once that happens, `initializer` (and
    /// everything it owns: the container, the resolved `OrchardMigrationHost`, every per-account actor)
    /// outlives the synchronizer that built it for as long as the container itself stays reachable --
    /// e.g. this test's `mockContainer`, which `ZcashTestCase` keeps alive for the whole test method,
    /// well past this test's own local scope.
    ///
    /// Deliberately does NOT go through `makeSynchronizer(migrationHost:)`/`makeHost(welding:)` like
    /// every other test in this file: pre-mocking `OrchardMigrationHost` would mean `SDKSynchronizer.init`
    /// resolves the *mock* dependency, and `DIContainer.resolve`'s singleton-cache write-back
    /// (`dependencies[key] = Dependency(factory: dependency.factory, ...)`) always writes into the
    /// non-mock `dependencies` dictionary, even when what it just resolved came from `mockedDependencies`
    /// -- so a pre-registered mock overwrites (and thereby immediately releases) the real,
    /// initializer-capturing closure before it is ever invoked, which would hide this exact bug. Letting
    /// `SDKSynchronizer.init` register and resolve the real `OrchardMigrationHost(initializer:)` is what
    /// exercises the production code path the bug lives in.
    ///
    /// Also deliberately does NOT go through `SDKSynchronizer.init(initializer:)` (the public convenience
    /// initializer): that convenience initializer builds its `CompactBlockProcessor` with
    /// `walletBirthdayProvider: { initializer.walletBirthday }`, an unrelated, pre-existing closure (predates
    /// this migration work) that captures `initializer` and ends up retained by the container too, via
    /// `Dependencies.setupCompactBlockProcessor`'s `UTXOFetcher` registration
    /// (`UTXOFetcherConfig(walletBirthdayProvider: config.walletBirthdayProvider)`). That is a second,
    /// independent container/`Initializer` cycle -- out of scope here (not part of the migration-host
    /// registration this test targets) -- that would otherwise keep `initializer` alive regardless of
    /// this fix and make the test unable to isolate the one cycle it exists to catch. Calling the
    /// designated initializer directly, with a `walletBirthdayProvider` that returns a constant instead of
    /// capturing `initializer`, sidesteps that unrelated cycle without touching any production code.
    func testMigrationHostRegistrationDoesNotLeakTheInitializer() throws {
        weak var weakInitializer: Initializer?
        weak var weakSynchronizer: SDKSynchronizer?

        func buildAndReleaseSynchronizer() throws {
            let initializer = Initializer(
                container: mockContainer,
                cacheDbURL: nil,
                fsBlockDbRoot: testTempDirectory,
                generalStorageURL: testGeneralStorageDirectory,
                dataDbURL: try __dataDbURL(),
                torDirURL: try __torDirURL(),
                endpoint: LightWalletEndpointBuilder.default,
                network: ZcashNetworkBuilder.network(for: .testnet),
                spendParamsURL: try __spendParamsURL(),
                outputParamsURL: try __outputParamsURL(),
                saplingParamsSourceURL: SaplingParamsSourceURL.tests,
                isTorEnabled: false,
                isExchangeRateEnabled: false
            )
            let blockProcessor = CompactBlockProcessor(
                initializer: initializer,
                walletBirthdayProvider: { 0 }
            )
            let synchronizer = SDKSynchronizer(
                status: .unprepared,
                initializer: initializer,
                transactionEncoder: WalletTransactionEncoder(initializer: initializer),
                transactionRepository: initializer.transactionRepository,
                blockProcessor: blockProcessor,
                syncSessionTicker: .live
            )

            weakInitializer = initializer
            weakSynchronizer = synchronizer
        }

        try buildAndReleaseSynchronizer()

        XCTAssertNil(weakSynchronizer, "SDKSynchronizer should deallocate once every strong reference to it goes out of scope")
        XCTAssertNil(
            weakInitializer,
            """
            Initializer should deallocate once its owning SDKSynchronizer is gone -- a non-nil value means the \
            OrchardMigrationHost registration closure is still retaining it (initializer -> container -> closure -> initializer)
            """
        )
    }

    // MARK: - Helpers

    /// Builds an `SDKSynchronizer` whose one `OrchardMigrationHost` is `migrationHost`, substituted
    /// via the same container-mock seam `SDKSynchronizer.init` resolves the production host through.
    private func makeSynchronizer(migrationHost: OrchardMigrationHost) throws -> SDKSynchronizer {
        mockContainer.mock(type: OrchardMigrationHost.self, isSingleton: true) { _ in migrationHost }

        let initializer = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: LightWalletEndpointBuilder.default,
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )

        return SDKSynchronizer(initializer: initializer)
    }

    /// Builds an `OrchardMigrationHost` via its injecting initializer, following R4-A's
    /// `OrchardMigrationHostTests` seam: `welding` backs both the wallet-scope predicate and every
    /// per-account actor the (scripted) `actorFactory` produces. `factoryRecorder`, when supplied,
    /// counts every `actorFactory` invocation -- i.e. every time `migrationHost.migration(for:)`
    /// actually built (or reused... no, `migration(for:)` caches, so this only fires once per
    /// account) a per-account actor, which is what the broadcast guard's "never touched the host"
    /// assertions pin.
    private func makeHost(
        welding: ZcashRustBackendWeldingMock,
        broadcaster: any MigrationBroadcasting = ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable)),
        tickInterval: TimeInterval = 3600,
        factoryRecorder: FactoryInvocationRecorder? = nil
    ) -> OrchardMigrationHost {
        let storage = testGeneralStorageDirectory!
        return OrchardMigrationHost(
            welding: welding,
            sharedBroadcaster: broadcaster,
            generalStorageURL: storage,
            tickInterval: tickInterval,
            now: { Date() },
            logger: logger,
            actorFactory: { accountUUID, broadcaster in
                factoryRecorder?.recordCall()
                return OrchardMigration(
                    welding: welding,
                    accountUUID: accountUUID,
                    broadcaster: broadcaster,
                    syncGate: MigrationSyncGate(
                        directory: storage,
                        accountUUID: accountUUID,
                        bufferDuration: 600,
                        tickInterval: tickInterval,
                        now: { Date() },
                        overdueProvider: { (try? await welding.migrationHasOverdueTransfers(for: accountUUID)) ?? false },
                        logger: logger
                    ),
                    logger: logger
                )
            }
        )
    }

    private static func makeClaimHandle(_ identity: Int) -> MigrationClaimHandle {
        MigrationClaimHandle(
            storage: MigrationOpaqueHandleStorage(
                pointer: OpaquePointer(bitPattern: identity)!,
                release: { _ in }
            )
        )
    }

    private static func makeRuntimeSnapshot(account: AccountUUID) -> MigrationRuntimeSnapshot {
        MigrationRuntimeSnapshot(
            account: account,
            canonical: MigrationCanonicalSummary(status: nil, transactionCount: 0),
            schemaProvenance: .compatible(version: 1),
            legacyCutover: .fresh,
            destinationSpendability: .notApplicable,
            availability: .available,
            ordinarySpendAuthorization: .unrestricted,
            accountDeletionAuthorization: .allowed,
            canonicalMutationAuthorization: .allowed,
            aggregateStorageFinality: .noRun,
            delivery: nil,
            retainedRuns: []
        )
    }

    private func makeAccount(_ uuid: AccountUUID) -> Account {
        Account(
            id: uuid,
            name: nil,
            keySource: nil,
            seedFingerprint: nil,
            hdAccountIndex: nil,
            ufvk: nil,
            uivk: nil
        )
    }
}

/// Records how many times a scripted `OrchardMigrationHost` `actorFactory` closure ran -- i.e. how
/// many times `migrationHost.migration(for:)` actually had to build a per-account actor. Mutated
/// synchronously from the (non-async) `actorFactory` closure, which this suite's tests only ever
/// invoke serially -- mirroring how `ZcashRustBackendWeldingMock`'s own plain `CallsCount` fields
/// are mutated in this codebase's generated mocks.
private final class FactoryInvocationRecorder {
    private(set) var callCount = 0

    func recordCall() {
        callCount += 1
    }
}
