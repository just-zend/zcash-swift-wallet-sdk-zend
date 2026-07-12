//
//  MigrationSynchronizerTests.swift
//  OfflineTests
//
//  Unit tests for the public Orchard -> Ironwood migration API on `SDKSynchronizer`: the two
//  broadcast composites (submitNoteSplit / executeNextPendingTransfer) and the thin delegations to
//  the rust backend welding. The composites are driven against a `ZcashRustBackendWeldingMock` (the
//  sign / next-due / extract / record building blocks) and a `StubTransactionEncoder` (the old direct
//  submit path). End-to-end propose/sign/submit needs a seeded, synced DB and is out of scope here.
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class MigrationSynchronizerTests: ZcashTestCase {
    private let account = AccountUUID(id: [UInt8](repeating: 7, count: 16))
    private let options = NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil)
    /// The consensus tx bytes the welding's `migrationExtractBroadcastTx` returns. Deliberately
    /// distinct from any `PreparedTx.rawPczt` so the submit assertions verify that the *extracted*
    /// bytes are broadcast, not the PCZT itself.
    private let extractedTxBytes: [UInt8] = [0xAA, 0xBB, 0xCC]
    private let consensusFingerprint = String(repeating: "0", count: 64)

    private var submissionPolicy: BoundSubmissionPolicy {
        BoundSubmissionPolicy(
            policy: SubmissionPolicy(
                transport: .direct,
                endpointIdentity: LightWalletEndpointBuilder.default.urlString,
                consensusFingerprint: consensusFingerprint
            ),
            policyFingerprint: String(repeating: "1", count: 64),
            revision: 1
        )
    }

    private enum TestError: Error {
        case boom
    }

    func testFreshPrivateBeginValidatesBeforeAtomicRustInsert() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let submitter = MigrationTransactionSubmitterMock()
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend,
            migrationTransactionSubmitter: submitter
        )

        let snapshot = try await synchronizer.beginPrivateMigration(
            externalSigner: false,
            options: options,
            for: account
        )

        XCTAssertEqual(snapshot.submissionPolicy, submissionPolicy)
        XCTAssertEqual(submitter.validationCallsCount, 1)
        XCTAssertEqual(
            rustBackend.migrationBeginPrivateExternalSignerForReceivedArguments?.policy,
            submissionPolicy.policy
        )
        XCTAssertEqual(rustBackend.migrationBeginPrivateExternalSignerForReceivedArguments?.account, account)
        XCTAssertEqual(rustBackend.migrationBindSubmissionPolicyExpectedRevisionPolicyForCallsCount, 0)
    }

    func testFreshPrivateBeginDoesNotCreateRunWhenEndpointValidationFails() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let submitter = MigrationTransactionSubmitterMock()
        submitter.validationThrowableError = TestError.boom
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend,
            migrationTransactionSubmitter: submitter
        )

        do {
            _ = try await synchronizer.beginPrivateMigration(
                externalSigner: false,
                options: options,
                for: account
            )
            XCTFail("Expected validation failure")
        } catch TestError.boom {
            // expected
        }

        XCTAssertEqual(submitter.validationCallsCount, 1)
        XCTAssertEqual(rustBackend.migrationBeginPrivateExternalSignerForCallsCount, 0)
    }

    func testImmediateCommitPassesValidatedPolicyIntoAtomicRustCommit() async throws {
        let runId = "00000000-0000-4000-8000-000000000001"
        let schedule = MigrationIntentSchedule(
            runId: runId,
            expectedRevision: 0,
            intents: [
                MigrationIntent(
                    id: "\(runId)-0",
                    amount: 100,
                    fee: 10,
                    notBeforeHeight: 1,
                    targetWindowEndHeight: 1
                )
            ],
            estimatedDurationHours: 0
        )
        let rustBackend = ZcashRustBackendWeldingMock()
        let committed = makeSnapshot()
        rustBackend.migrationCommitIntentsScheduleExternalSignerForReturnValue = committed
        let submitter = MigrationTransactionSubmitterMock()
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend,
            migrationTransactionSubmitter: submitter
        )

        let snapshot = try await synchronizer.commitMigrationIntents(
            schedule,
            externalSigner: false,
            options: options,
            for: account
        )

        XCTAssertEqual(snapshot, committed)
        XCTAssertEqual(submitter.validationCallsCount, 1)
        XCTAssertEqual(
            rustBackend.migrationCommitIntentsScheduleExternalSignerForReceivedArguments?.policy,
            submissionPolicy.policy
        )
        XCTAssertEqual(
            rustBackend.migrationCommitIntentsScheduleExternalSignerForReceivedArguments?.schedule,
            schedule
        )
    }

    func testExecuteRejectsReplacementRunBeforeRPCBindOrMutation() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSnapshotForReturnValue = makeSnapshot(
            nextAction: .materializeDueTransaction,
            runId: "00000000-0000-4000-8000-000000000002",
            revision: 7
        )
        let submitter = MigrationTransactionSubmitterMock()
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend,
            migrationTransactionSubmitter: submitter
        )

        do {
            _ = try await synchronizer.executeNextMigrationAction(
                expectedRunId: "00000000-0000-4000-8000-000000000001",
                expectedRevision: 7,
                spendingKey: TestsData(networkType: .testnet).spendingKey,
                options: options,
                for: account
            )
            XCTFail("Expected replacement-run rejection")
        } catch let error as MigrationBroadcastError {
            XCTAssertEqual(error, .migrationSnapshotChanged)
        }

        XCTAssertEqual(submitter.validationCallsCount, 0)
        XCTAssertEqual(rustBackend.migrationBindSubmissionPolicyExpectedRevisionPolicyForCallsCount, 0)
        XCTAssertFalse(rustBackend.migrationMaterializeAndClaimNextDueLeaseDurationMsUskForCalled)
    }

    func testSoftwareNoteSplitDoesNotAdoptReplacementRunWithSameRevision() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSnapshotForReturnValue = makeSnapshot(
            runId: "00000000-0000-4000-8000-000000000002",
            revision: 7
        )
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        do {
            _ = try await synchronizer.submitNoteSplit(
                expectedRunId: "00000000-0000-4000-8000-000000000001",
                expectedRevision: 7,
                proposal: NoteSplitProposal(outputNotes: [100], fee: 10),
                spendingKey: TestsData(networkType: .testnet).spendingKey,
                options: options,
                for: account
            )
            XCTFail("Expected replacement run rejection")
        } catch let error as MigrationBroadcastError {
            XCTAssertEqual(error, .submissionPolicyMismatch)
        }

        XCTAssertFalse(rustBackend.migrationSignNoteSplitProposalUskForCalled)
    }

    func testExternalNoteSplitDoesNotAdoptReplacementRunWithSameRevision() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSnapshotForReturnValue = makeSnapshot(
            runId: "00000000-0000-4000-8000-000000000002",
            externalSigner: true,
            revision: 7
        )
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        do {
            _ = try await synchronizer.proposeNoteSplitPCZT(
                expectedRunId: "00000000-0000-4000-8000-000000000001",
                expectedRevision: 7,
                proposal: NoteSplitProposal(outputNotes: [100], fee: 10),
                options: options,
                for: account
            )
            XCTFail("Expected replacement run rejection")
        } catch let error as MigrationBroadcastError {
            XCTAssertEqual(error, .submissionPolicyMismatch)
        }

        XCTAssertFalse(rustBackend.migrationCreateUnsignedNoteSplitPCZTForCalled)
    }

    func testStalePolicyBindErrorIsNotMisclassifiedOrPersistedAsPolicyMismatch() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSnapshotForReturnValue = makeSnapshot(withSubmissionPolicy: false, revision: 8)
        rustBackend.migrationBindSubmissionPolicyExpectedRevisionPolicyForClosure = { _, _, _, _ in
            throw TestError.boom
        }
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend,
            migrationTransactionSubmitter: MigrationTransactionSubmitterMock()
        )

        do {
            _ = try await synchronizer.bindMigrationSubmissionPolicy(
                expectedRunId: "00000000-0000-4000-8000-000000000001",
                expectedRevision: 8,
                options: options,
                for: account
            )
            XCTFail("Expected original stale/CAS bind error")
        } catch TestError.boom {
            // The original non-policy error must survive unchanged.
        }

        XCTAssertEqual(
            rustBackend.migrationRecordSubmissionPolicyValidationFailureExpectedRevisionFailureForCallsCount,
            0
        )
    }

    func testTypedImmutablePolicyConflictIsDurablyRecorded() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSnapshotForReturnValue = makeSnapshot(withSubmissionPolicy: false, revision: 9)
        rustBackend.migrationBindSubmissionPolicyExpectedRevisionPolicyForClosure = { _, _, _, _ in
            throw MigrationSubmissionPolicyBindingError.immutablePolicyConflict
        }
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend,
            migrationTransactionSubmitter: MigrationTransactionSubmitterMock()
        )

        do {
            _ = try await synchronizer.bindMigrationSubmissionPolicy(
                expectedRunId: "00000000-0000-4000-8000-000000000001",
                expectedRevision: 9,
                options: options,
                for: account
            )
            XCTFail("Expected immutable policy conflict")
        } catch let error as MigrationBroadcastError {
            XCTAssertEqual(error, .submissionPolicyMismatch)
        }

        let recorded = rustBackend
            .migrationRecordSubmissionPolicyValidationFailureExpectedRevisionFailureForReceivedArguments
        XCTAssertEqual(recorded?.expectedRunId, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(recorded?.expectedRevision, 9)
        XCTAssertEqual(recorded?.failure, .submissionPolicyMismatch)
        XCTAssertEqual(recorded?.account, account)
    }

    // MARK: - submitNoteSplit

    func testSubmitNoteSplitSignsAndSubmitsThenReturnsSuccess() async throws {
        let prepared = makePreparedTx()
        let claim = makeClaim(prepared)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSignNoteSplitProposalUskForReturnValue = prepared
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = ExtractedTx(txid: prepared.txid, rawTx: extractedTxBytes)
        rustBackend.migrationClaimNoteSplitSubmissionLeaseDurationMsForReturnValue = claim
        rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForClosure = { _, _, _, _ in }
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let proposal = NoteSplitProposal(outputNotes: [100, 200], fee: 10)
        let result = try await synchronizer.submitNoteSplit(
            expectedRunId: "00000000-0000-4000-8000-000000000001",
            expectedRevision: 1,
            proposal: proposal,
            spendingKey: TestsData(networkType: .testnet).spendingKey,
            options: options,
            for: account
        )

        XCTAssertEqual(result, .success(txid: prepared.txid))
        XCTAssertEqual(rustBackend.migrationSignNoteSplitProposalUskForReceivedArguments?.proposal, proposal)
        XCTAssertEqual(rustBackend.migrationSignNoteSplitProposalUskForReceivedArguments?.account, account)
        // The signed PCZT is extracted before broadcast, and the *extracted* bytes are what get submitted.
        XCTAssertEqual(rustBackend.migrationExtractBroadcastTxPcztForReceivedArguments?.pczt, prepared.rawPczt)
        XCTAssertEqual(rustBackend.migrationExtractBroadcastTxPcztForReceivedArguments?.account, account)
        XCTAssertEqual(encoder.submittedTransactions.map(\.raw), [Data(extractedTxBytes)])
        XCTAssertEqual(encoder.submittedTransactions.first?.transactionId, expectedSubmittedTxId(prepared))
        // The broadcast outcome is recorded with the `prep:<run_id>` id so the split phase advances.
        let recorded = rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForReceivedArguments
        XCTAssertEqual(recorded?.transferId, prepared.id)
        XCTAssertEqual(recorded?.attemptToken, claim.attemptToken)
        XCTAssertEqual(recorded?.result, .success(txid: prepared.txid))
    }

    func testSubmitNoteSplitMapsAmbiguousTransportFailureToOutcomeUnknown() async throws {
        let prepared = makePreparedTx()
        let claim = makeClaim(prepared)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSignNoteSplitProposalUskForReturnValue = prepared
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = ExtractedTx(txid: prepared.txid, rawTx: extractedTxBytes)
        rustBackend.migrationClaimNoteSplitSubmissionLeaseDurationMsForReturnValue = claim
        rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForClosure = { _, _, _, _ in }
        let encoder = StubTransactionEncoder(createdTransactions: [])
        encoder.submitError = ZcashError.serviceSubmitFailed(.timeOut)
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let result = try await synchronizer.submitNoteSplit(
            expectedRunId: "00000000-0000-4000-8000-000000000001",
            expectedRevision: 1,
            proposal: NoteSplitProposal(outputNotes: [100], fee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey,
            options: options,
            for: account
        )

        XCTAssertEqual(result, .outcomeUnknown)
    }

    func testSubmitNoteSplitMapsKnownToServerSubmitErrorToSuccess() async throws {
        let prepared = makePreparedTx()
        let claim = makeClaim(prepared)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSignNoteSplitProposalUskForReturnValue = prepared
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = ExtractedTx(txid: prepared.txid, rawTx: extractedTxBytes)
        rustBackend.migrationClaimNoteSplitSubmissionLeaseDurationMsForReturnValue = claim
        rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForClosure = { _, _, _, _ in }
        let encoder = StubTransactionEncoder(createdTransactions: [])
        encoder.submitError = TransactionEncoderError.submitError(code: -1, message: "already in mempool")
        encoder.knownToServerTxIds = [expectedSubmittedTxId(prepared)]
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let result = try await synchronizer.submitNoteSplit(
            expectedRunId: "00000000-0000-4000-8000-000000000001",
            expectedRevision: 1,
            proposal: NoteSplitProposal(outputNotes: [100], fee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey,
            options: options,
            for: account
        )

        XCTAssertEqual(result, .success(txid: prepared.txid))
    }

    func testSubmitNoteSplitMapsUnknownSubmitErrorToNonRetryableNetworkError() async throws {
        let prepared = makePreparedTx()
        let claim = makeClaim(prepared)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSignNoteSplitProposalUskForReturnValue = prepared
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = ExtractedTx(txid: prepared.txid, rawTx: extractedTxBytes)
        rustBackend.migrationClaimNoteSplitSubmissionLeaseDurationMsForReturnValue = claim
        rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForClosure = { _, _, _, _ in }
        let encoder = StubTransactionEncoder(createdTransactions: [])
        encoder.submitError = TransactionEncoderError.submitError(code: -1, message: "rejected")
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let result = try await synchronizer.submitNoteSplit(
            expectedRunId: "00000000-0000-4000-8000-000000000001",
            expectedRevision: 1,
            proposal: NoteSplitProposal(outputNotes: [100], fee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey,
            options: options,
            for: account
        )

        XCTAssertEqual(result, .networkError(retryable: false))
    }

    func testSubmitNoteSplitPropagatesSigningErrorWithoutSubmitting() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSignNoteSplitProposalUskForThrowableError = TestError.boom
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        do {
            _ = try await synchronizer.submitNoteSplit(
                expectedRunId: "00000000-0000-4000-8000-000000000001",
                expectedRevision: 1,
                proposal: NoteSplitProposal(outputNotes: [100], fee: 10),
                spendingKey: TestsData(networkType: .testnet).spendingKey,
                options: options,
                for: account
            )
            XCTFail("Expected submitNoteSplit to propagate the signing error")
        } catch {
            // expected
        }

        XCTAssertTrue(encoder.submittedTransactions.isEmpty)
    }

    func testSubmitNoteSplitPropagatesExtractErrorWithoutSubmitting() async throws {
        let prepared = makePreparedTx()
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSignNoteSplitProposalUskForReturnValue = prepared
        rustBackend.migrationClaimNoteSplitSubmissionLeaseDurationMsForReturnValue = makeClaim(prepared)
        rustBackend.migrationExtractBroadcastTxPcztForThrowableError = TestError.boom
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        do {
            _ = try await synchronizer.submitNoteSplit(
                expectedRunId: "00000000-0000-4000-8000-000000000001",
                expectedRevision: 1,
                proposal: NoteSplitProposal(outputNotes: [100], fee: 10),
                spendingKey: TestsData(networkType: .testnet).spendingKey,
                options: options,
                for: account
            )
            XCTFail("Expected submitNoteSplit to propagate the extract error")
        } catch {
            // expected
        }

        XCTAssertTrue(encoder.submittedTransactions.isEmpty)
    }

    func testSubmitNoteSplitRejectsMalformedTxIDBeforeExtractionOrNetworking() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let prepared = makePreparedTx(txid: "0a0b")
        rustBackend.migrationSignNoteSplitProposalUskForReturnValue = prepared
        rustBackend.migrationClaimNoteSplitSubmissionLeaseDurationMsForReturnValue = makeClaim(prepared)
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .success(txid: "should-not-submit")
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend,
            migrationTransactionSubmitter: submitter
        )

        do {
            _ = try await synchronizer.submitNoteSplit(
                expectedRunId: "00000000-0000-4000-8000-000000000001",
                expectedRevision: 1,
                proposal: NoteSplitProposal(outputNotes: [100], fee: 10),
                spendingKey: TestsData(networkType: .testnet).spendingKey,
                options: options,
                for: account
            )
            XCTFail("Expected malformed transaction id to fail closed")
        } catch let error as MigrationBroadcastError {
            XCTAssertEqual(error, .invalidTransactionID)
        }

        XCTAssertFalse(rustBackend.migrationExtractBroadcastTxPcztForCalled)
        XCTAssertNil(submitter.receivedArguments)
        XCTAssertFalse(rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForCalled)
    }

    // MARK: - External signer (hardware wallet)

    func testProposeNoteSplitPCZTDelegatesToRustBackend() async throws {
        let unsigned = Pczt([0x01, 0x02, 0x03])
        let proposal = NoteSplitProposal(outputNotes: [100], fee: 10)
        let signerClaim = makeNoteSplitSignerClaim(pczt: unsigned)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSnapshotForReturnValue = makeSnapshot(externalSigner: true)
        rustBackend.migrationCreateUnsignedNoteSplitPCZTForReturnValue = signerClaim
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        let result = try await synchronizer.proposeNoteSplitPCZT(
            expectedRunId: "00000000-0000-4000-8000-000000000001",
            expectedRevision: 1,
            proposal: proposal,
            options: options,
            for: account
        )

        XCTAssertEqual(result, signerClaim)
        XCTAssertEqual(rustBackend.migrationCreateUnsignedNoteSplitPCZTForReceivedArguments?.proposal, proposal)
        XCTAssertEqual(rustBackend.migrationCreateUnsignedNoteSplitPCZTForReceivedArguments?.account, account)
    }

    func testSubmitSignedNoteSplitPCZTStoresSubmitsAndRecords() async throws {
        let prepared = makePreparedTx(id: "prep:run-1")
        let claim = makeClaim(prepared)
        let signedPczt = Pczt([0x0A, 0x0B])
        let signerClaim = makeNoteSplitSignerClaim()
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationStoreSignedNoteSplitPCZTPcztForReturnValue = prepared
        rustBackend.migrationClaimNoteSplitSubmissionLeaseDurationMsForReturnValue = claim
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = ExtractedTx(txid: prepared.txid, rawTx: extractedTxBytes)
        rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForClosure = { _, _, _, _ in }
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let result = try await synchronizer.submitSignedNoteSplitPCZT(
            signedPczt,
            for: signerClaim,
            expectedRevision: 1,
            options: options,
            account: account
        )

        XCTAssertEqual(result, .success(txid: prepared.txid))
        // The device-signed PCZT is handed to the store step, which returns the broadcastable form.
        XCTAssertEqual(rustBackend.migrationStoreSignedNoteSplitPCZTPcztForReceivedArguments?.pczt, signedPczt)
        XCTAssertEqual(rustBackend.migrationStoreSignedNoteSplitPCZTPcztForReceivedArguments?.account, account)
        // The *stored* PCZT (not the device-signed input) is extracted and broadcast.
        XCTAssertEqual(rustBackend.migrationExtractBroadcastTxPcztForReceivedArguments?.pczt, prepared.rawPczt)
        XCTAssertEqual(encoder.submittedTransactions.map(\.raw), [Data(extractedTxBytes)])
        // The outcome is recorded with the `prep:<run_id>` id so the split phase advances.
        let recorded = rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForReceivedArguments
        XCTAssertEqual(recorded?.transferId, prepared.id)
        XCTAssertEqual(recorded?.attemptToken, claim.attemptToken)
        XCTAssertEqual(recorded?.result, .success(txid: prepared.txid))
    }

    func testSubmitSignedNoteSplitPCZTPropagatesStoreErrorWithoutSubmitting() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationStoreSignedNoteSplitPCZTPcztForThrowableError = TestError.boom
        rustBackend.migrationNextDueTransferForReturnValue = nil
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        do {
            _ = try await synchronizer.submitSignedNoteSplitPCZT(
                Pczt([0x0A]),
                for: makeNoteSplitSignerClaim(),
                expectedRevision: 1,
                options: options,
                account: account
            )
            XCTFail("Expected submitSignedNoteSplitPCZT to propagate the store error")
        } catch {
            // expected
        }

        XCTAssertTrue(encoder.submittedTransactions.isEmpty)
        XCTAssertFalse(rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForCalled)
    }

    func testSubmitSignedNoteSplitPCZTRebroadcastsPendingPrepTxWhenStagingAlreadyConsumed() async throws {
        // Retry contract (MOB-1468): after a store-succeeded-broadcast-failed first attempt, the
        // failure sheet's Retry re-calls submitSignedNoteSplitPCZT with the SAME signed PCZT. The
        // staged original was consumed by that first store, so the store step now throws — the
        // still-pending `prep:<run_id>` transaction surfaced by `migrationNextDueTransfer` is what
        // must be re-broadcast (no device round-trip, no second run stored).
        let prepared = makePreparedTx(id: "prep:run-1")
        let claim = makeClaim(prepared)
        let signerClaim = makeNoteSplitSignerClaim()
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationStoreSignedNoteSplitPCZTPcztForThrowableError =
            ZcashError.rustMigrationStoreSignedNoteSplitPCZT("no staged note-split PCZT to store")
        rustBackend.migrationClaimNoteSplitSubmissionLeaseDurationMsForReturnValue = claim
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = ExtractedTx(txid: prepared.txid, rawTx: extractedTxBytes)
        rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForClosure = { _, _, _, _ in }
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let result = try await synchronizer.submitSignedNoteSplitPCZT(
            Pczt([0x0A, 0x0B]),
            for: signerClaim,
            expectedRevision: 1,
            options: options,
            account: account
        )

        XCTAssertEqual(result, .success(txid: prepared.txid))
        // The persisted prep tx (not the incoming device PCZT) is what gets extracted + broadcast.
        XCTAssertEqual(rustBackend.migrationExtractBroadcastTxPcztForReceivedArguments?.pczt, prepared.rawPczt)
        XCTAssertEqual(encoder.submittedTransactions.map(\.raw), [Data(extractedTxBytes)])
        let recorded = rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForReceivedArguments
        XCTAssertEqual(recorded?.transferId, prepared.id)
        XCTAssertEqual(recorded?.attemptToken, claim.attemptToken)
        XCTAssertEqual(recorded?.result, .success(txid: prepared.txid))
    }

    func testSubmitSignedNoteSplitPCZTRethrowsStoreErrorWhenNextDueIsARegularTransfer() async throws {
        // A pending non-prep transfer must not be hijacked by the note-split retry path: only a
        // `prep:`-prefixed next-due transaction identifies the consumed-staging retry state.
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationStoreSignedNoteSplitPCZTPcztForThrowableError = TestError.boom
        rustBackend.migrationClaimNoteSplitSubmissionLeaseDurationMsForReturnValue = nil
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        do {
            _ = try await synchronizer.submitSignedNoteSplitPCZT(
                Pczt([0x0A]),
                for: makeNoteSplitSignerClaim(),
                expectedRevision: 1,
                options: options,
                account: account
            )
            XCTFail("Expected submitSignedNoteSplitPCZT to rethrow the store error")
        } catch {
            // expected
        }

        XCTAssertTrue(encoder.submittedTransactions.isEmpty)
        XCTAssertFalse(rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForCalled)
    }

    func testProposeMigrationTransferPCZTsBuildsFromTheGivenSchedule() async throws {
        let schedule = MigrationSchedule(
            transfers: [
                TransferProposal(
                    id: "run-0",
                    amount: 990_000,
                    anchorHeight: 100,
                    nextExecutableAfterHeight: 200,
                    expiryHeight: 488
                )
            ],
            estimatedDurationHours: 0
        )
        let pairs = [MigrationTransferPCZT(id: "run-0", pczt: Pczt([0x01]))]
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationCreateUnsignedTransferPCZTsScheduleForReturnValue = pairs
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        let result = try await synchronizer.proposeMigrationTransferPCZTs(schedule, for: account)

        XCTAssertEqual(result, pairs)
        // The caller's confirmed schedule is what the PCZTs are built from — no internal
        // re-propose (denominations are randomized, so a fresh proposal would differ from the
        // schedule the user approved).
        XCTAssertFalse(rustBackend.migrationProposeTransfersForCalled)
        let args = rustBackend.migrationCreateUnsignedTransferPCZTsScheduleForReceivedArguments
        XCTAssertEqual(args?.schedule, schedule)
        XCTAssertEqual(args?.account, account)
    }

    func testProposeMigrationTransferPCZTsPropagatesBuildError() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationCreateUnsignedTransferPCZTsScheduleForThrowableError = TestError.boom
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        do {
            _ = try await synchronizer.proposeMigrationTransferPCZTs(
                MigrationSchedule(transfers: [], estimatedDurationHours: 0),
                for: account
            )
            XCTFail("Expected proposeMigrationTransferPCZTs to propagate the build error")
        } catch {
            // expected
        }
    }

    func testStoreSignedMigrationTransferPCZTsDelegatesToRustBackend() async throws {
        let pairs = [
            MigrationTransferPCZT(id: "run-0", pczt: Pczt([0x01])),
            MigrationTransferPCZT(id: "run-1", pczt: Pczt([0x02]))
        ]
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationStoreSignedSchedulePCZTsPcztsForClosure = { _, _, _ in }
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        try await synchronizer.storeSignedMigrationTransferPCZTs(pairs, for: account)

        let args = rustBackend.migrationStoreSignedSchedulePCZTsPcztsForReceivedArguments
        XCTAssertEqual(args?.pczts, pairs)
        XCTAssertEqual(args?.account, account)
    }

    // MARK: - executeNextPendingTransfer

    func testExecuteNextPendingTransferReturnsNilWhenNoneDue() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationClaimNoteSplitSubmissionLeaseDurationMsForReturnValue = nil
        rustBackend.migrationClaimNextDueTransferLeaseDurationMsForReturnValue = nil
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let result = try await synchronizer.executeNextPendingTransfer(options: options, for: account)

        XCTAssertNil(result)
        XCTAssertTrue(encoder.submittedTransactions.isEmpty)
        XCTAssertFalse(rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForCalled)
    }

    func testExecuteNextPendingTransferSubmitsAndRecordsSuccess() async throws {
        let prepared = makePreparedTx(id: "transfer-7")
        let claim = makeClaim(prepared)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationClaimNextDueTransferLeaseDurationMsForReturnValue = claim
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = ExtractedTx(txid: prepared.txid, rawTx: extractedTxBytes)
        rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForClosure = { _, _, _, _ in }
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let result = try await synchronizer.executeNextPendingTransfer(options: options, for: account)

        XCTAssertEqual(result, .success(txid: prepared.txid))
        XCTAssertEqual(rustBackend.migrationExtractBroadcastTxPcztForReceivedArguments?.pczt, prepared.rawPczt)
        XCTAssertEqual(rustBackend.migrationExtractBroadcastTxPcztForReceivedArguments?.account, account)
        XCTAssertEqual(encoder.submittedTransactions.map(\.raw), [Data(extractedTxBytes)])
        let recorded = rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForReceivedArguments
        XCTAssertEqual(recorded?.transferId, prepared.id)
        XCTAssertEqual(recorded?.attemptToken, claim.attemptToken)
        XCTAssertEqual(recorded?.result, .success(txid: prepared.txid))
        XCTAssertEqual(recorded?.account, account)
    }

    func testExecuteNextPendingTransferRecordsOutcomeUnknownOnAmbiguousTransportFailure() async throws {
        let prepared = makePreparedTx(id: "transfer-8")
        let claim = makeClaim(prepared)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationClaimNextDueTransferLeaseDurationMsForReturnValue = claim
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = ExtractedTx(txid: prepared.txid, rawTx: extractedTxBytes)
        rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForClosure = { _, _, _, _ in }
        let encoder = StubTransactionEncoder(createdTransactions: [])
        encoder.submitError = ZcashError.serviceSubmitFailed(.timeOut)
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let result = try await synchronizer.executeNextPendingTransfer(options: options, for: account)

        XCTAssertEqual(result, .outcomeUnknown)
        XCTAssertEqual(
            rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForReceivedArguments?.result,
            .outcomeUnknown
        )
    }

    func testExecuteNextPendingTransferDoesNotRecordWhenNextDueThrows() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationClaimNextDueTransferLeaseDurationMsForThrowableError = TestError.boom
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        do {
            _ = try await synchronizer.executeNextPendingTransfer(options: options, for: account)
            XCTFail("Expected executeNextPendingTransfer to propagate the next-due error")
        } catch {
            // expected
        }

        XCTAssertFalse(rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForCalled)
        XCTAssertTrue(encoder.submittedTransactions.isEmpty)
    }

    func testExecuteNextPendingTransferDoesNotRecordWhenExtractThrows() async throws {
        let prepared = makePreparedTx(id: "transfer-9")
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationClaimNextDueTransferLeaseDurationMsForReturnValue = makeClaim(prepared)
        rustBackend.migrationExtractBroadcastTxPcztForThrowableError = TestError.boom
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        do {
            _ = try await synchronizer.executeNextPendingTransfer(options: options, for: account)
            XCTFail("Expected executeNextPendingTransfer to propagate the extract error")
        } catch {
            // expected
        }

        XCTAssertFalse(rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForCalled)
        XCTAssertTrue(encoder.submittedTransactions.isEmpty)
    }

    // MARK: - Snapshot-driven v4 execution

    func testExecuteNextMigrationActionAwaitUserChoiceIsStrictNoOp() async throws {
        let snapshot = makeSnapshot(nextAction: .awaitUserChoice)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSnapshotForReturnValue = snapshot
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .success(txid: "must-not-submit")
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend,
            migrationTransactionSubmitter: submitter
        )

        let execution = try await synchronizer.executeNextMigrationAction(
            expectedRunId: try XCTUnwrap(snapshot.runId),
            expectedRevision: snapshot.revision,
            spendingKey: nil,
            options: options,
            for: account
        )

        XCTAssertEqual(execution.disposition, .noAction)
        XCTAssertNil(execution.submissionResult)
        XCTAssertEqual(execution.snapshot, snapshot)
        XCTAssertFalse(rustBackend.migrationClaimNoteSplitSubmissionLeaseDurationMsForCalled)
        XCTAssertFalse(rustBackend.migrationClaimNextDueTransferLeaseDurationMsForCalled)
        XCTAssertFalse(rustBackend.migrationMaterializeAndClaimNextDueLeaseDurationMsUskForCalled)
        XCTAssertFalse(rustBackend.migrationResumeStagedSubmissionLeaseDurationMsForCalled)
        XCTAssertNil(submitter.receivedArguments)
    }

    func testExecuteNextMigrationActionMaterializesOneClaimAndRecordsItsToken() async throws {
        let prepared = makePreparedTx(id: "intent-a")
        let claim = makeClaim(prepared, attemptToken: "token-a")
        let initial = makeSnapshot(nextAction: .materializeDueTransaction, revision: 7)
        let final = makeSnapshot(nextAction: .waitForConfirmation, revision: 9)
        let rustBackend = ZcashRustBackendWeldingMock()
        var snapshotCalls = 0
        rustBackend.migrationSnapshotForClosure = { _ in
            snapshotCalls += 1
            return snapshotCalls == 1 ? initial : final
        }
        rustBackend.migrationMaterializeAndClaimNextDueLeaseDurationMsUskForReturnValue = claim
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = ExtractedTx(
            txid: claim.txid,
            rawTx: extractedTxBytes
        )
        rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForClosure = { _, _, _, _ in }
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .success(txid: claim.txid)
        let spendingKey = TestsData(networkType: .testnet).spendingKey
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend,
            migrationTransactionSubmitter: submitter
        )

        let execution = try await synchronizer.executeNextMigrationAction(
            expectedRunId: try XCTUnwrap(initial.runId),
            expectedRevision: initial.revision,
            spendingKey: spendingKey,
            options: options,
            for: account
        )

        XCTAssertEqual(execution.disposition, .resultRecorded)
        XCTAssertEqual(execution.submissionResult, .success(txid: claim.txid))
        XCTAssertEqual(execution.snapshot, final)
        let materialized = rustBackend.migrationMaterializeAndClaimNextDueLeaseDurationMsUskForReceivedArguments
        XCTAssertEqual(materialized?.expectedRunId, initial.runId)
        XCTAssertEqual(materialized?.expectedRevision, initial.revision)
        XCTAssertEqual(materialized?.usk, spendingKey)
        XCTAssertEqual(materialized?.account, account)
        let recorded = rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForReceivedArguments
        XCTAssertEqual(recorded?.transferId, claim.id)
        XCTAssertEqual(recorded?.attemptToken, claim.attemptToken)
        XCTAssertEqual(recorded?.account, account)
    }

    func testRustComputedTxIDMismatchFailsBeforeTransportAndResultRecord() async throws {
        let prepared = makePreparedTx(id: "intent-mismatch")
        let claim = makeClaim(prepared)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSnapshotForReturnValue = makeSnapshot(nextAction: .materializeDueTransaction)
        rustBackend.migrationMaterializeAndClaimNextDueLeaseDurationMsUskForReturnValue = claim
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = ExtractedTx(
            txid: String(repeating: "0b", count: 32),
            rawTx: extractedTxBytes
        )
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .success(txid: claim.txid)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend,
            migrationTransactionSubmitter: submitter
        )

        do {
            _ = try await synchronizer.executeNextMigrationAction(
                expectedRunId: "00000000-0000-4000-8000-000000000001",
                expectedRevision: 1,
                spendingKey: TestsData(networkType: .testnet).spendingKey,
                options: options,
                for: account
            )
            XCTFail("Expected Rust-computed txid mismatch to fail closed")
        } catch let error as MigrationBroadcastError {
            XCTAssertEqual(error, .transactionIDMismatch)
        }

        XCTAssertNil(submitter.receivedArguments)
        XCTAssertFalse(rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForCalled)
    }

    func testDisplayOrderTxIDBecomesInternalLightwalletdBytesWithExactRustRawTransaction() async throws {
        let displayBytes = Array(UInt8(0) ... UInt8(31))
        let displayTxID = displayBytes.map { String(format: "%02x", $0) }.joined()
        let prepared = makePreparedTx(id: "intent-byte-order", txid: displayTxID)
        let claim = makeClaim(prepared)
        let exactRawTx: [UInt8] = [0x05, 0x00, 0x00, 0x80, 0xAB, 0xCD]
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSnapshotForReturnValue = makeSnapshot(nextAction: .materializeDueTransaction)
        rustBackend.migrationMaterializeAndClaimNextDueLeaseDurationMsUskForReturnValue = claim
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = ExtractedTx(
            txid: displayTxID,
            rawTx: exactRawTx
        )
        rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForClosure = { _, _, _, _ in }
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .success(txid: displayTxID)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend,
            migrationTransactionSubmitter: submitter
        )

        _ = try await synchronizer.executeNextMigrationAction(
            expectedRunId: "00000000-0000-4000-8000-000000000001",
            expectedRevision: 1,
            spendingKey: TestsData(networkType: .testnet).spendingKey,
            options: options,
            for: account
        )

        XCTAssertEqual(submitter.receivedArguments?.displayTransactionID, displayTxID)
        XCTAssertEqual(submitter.receivedArguments?.transaction.transactionId, Data(displayBytes.reversed()))
        XCTAssertEqual(submitter.receivedArguments?.transaction.raw, Data(exactRawTx))
    }

    func testResultCASExpiryReturnsFreshVerifyingSnapshotAndSuppressesStaleSuccess() async throws {
        let prepared = makePreparedTx(id: "intent-expired-lease")
        let claim = makeClaim(prepared, attemptToken: "expired-token")
        let initial = makeSnapshot(nextAction: .materializeDueTransaction, revision: 4)
        let verifying = makeSnapshot(nextAction: .resumeStagedSubmission, revision: 6)
        let rustBackend = ZcashRustBackendWeldingMock()
        var snapshotCalls = 0
        rustBackend.migrationSnapshotForClosure = { _ in
            snapshotCalls += 1
            return snapshotCalls == 1 ? initial : verifying
        }
        rustBackend.migrationMaterializeAndClaimNextDueLeaseDurationMsUskForReturnValue = claim
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = ExtractedTx(txid: claim.txid, rawTx: extractedTxBytes)
        rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForThrowableError = TestError.boom
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .success(txid: claim.txid)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend,
            migrationTransactionSubmitter: submitter
        )

        let execution = try await synchronizer.executeNextMigrationAction(
            expectedRunId: try XCTUnwrap(initial.runId),
            expectedRevision: initial.revision,
            spendingKey: TestsData(networkType: .testnet).spendingKey,
            options: options,
            for: account
        )

        XCTAssertEqual(execution.disposition, .verifying)
        XCTAssertNil(execution.submissionResult)
        XCTAssertEqual(execution.snapshot, verifying)
        XCTAssertEqual(rustBackend.migrationMaterializeAndClaimNextDueLeaseDurationMsUskForCallsCount, 1)
    }

    func testCancellationBeforeTransportLeavesClaimUnrecordedAndKnownUnsent() async throws {
        let prepared = makePreparedTx(id: "intent-cancel-before")
        let claim = makeClaim(prepared)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSnapshotForReturnValue = makeSnapshot(nextAction: .materializeDueTransaction)
        rustBackend.migrationMaterializeAndClaimNextDueLeaseDurationMsUskForReturnValue = claim
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .success(txid: claim.txid)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend,
            migrationTransactionSubmitter: submitter
        )

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await synchronizer.executeNextMigrationAction(
                expectedRunId: "00000000-0000-4000-8000-000000000001",
                expectedRevision: 1,
                spendingKey: TestsData(networkType: .testnet).spendingKey,
                options: options,
                for: account
            )
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation before transport")
        } catch is CancellationError {
            // expected
        }

        XCTAssertFalse(rustBackend.migrationExtractBroadcastTxPcztForCalled)
        XCTAssertNil(submitter.receivedArguments)
        XCTAssertFalse(rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForCalled)
    }

    func testCancellationAsSubmitReturnsRecordsOutcomeUnknownAndKeepsVerifyingState() async throws {
        let prepared = makePreparedTx(id: "intent-cancel-during")
        let claim = makeClaim(prepared)
        let initial = makeSnapshot(nextAction: .materializeDueTransaction, revision: 2)
        let verifying = makeSnapshot(nextAction: .waitForSubmissionResolution, revision: 3)
        let rustBackend = ZcashRustBackendWeldingMock()
        var snapshotCalls = 0
        rustBackend.migrationSnapshotForClosure = { _ in
            snapshotCalls += 1
            return snapshotCalls == 1 ? initial : verifying
        }
        rustBackend.migrationMaterializeAndClaimNextDueLeaseDurationMsUskForReturnValue = claim
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = ExtractedTx(txid: claim.txid, rawTx: extractedTxBytes)
        rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForClosure = { _, _, _, _ in }
        let submitter = MigrationTransactionSubmitterMock()
        submitter.closure = { _, _, _, _, _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return .success(txid: claim.txid)
        }
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend,
            migrationTransactionSubmitter: submitter
        )

        let execution = try await Task {
            try await synchronizer.executeNextMigrationAction(
                expectedRunId: try XCTUnwrap(initial.runId),
                expectedRevision: initial.revision,
                spendingKey: TestsData(networkType: .testnet).spendingKey,
                options: options,
                for: account
            )
        }.value

        XCTAssertEqual(execution.disposition, .verifying)
        XCTAssertEqual(execution.submissionResult, .outcomeUnknown)
        XCTAssertEqual(execution.snapshot, verifying)
        XCTAssertEqual(
            rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForReceivedArguments?.result,
            .outcomeUnknown
        )
    }

    func testExternalSignerStagesAndCarriesExactlyOneClaimObject() async throws {
        let external = ClaimedTransferPCZT(
            intentId: "external-1",
            pczt: Pczt([0x11, 0x22]),
            signerToken: "external-token",
            leaseExpiresAtMs: .max,
            expiryHeight: 1_000_000,
            submissionPolicy: submissionPolicy
        )
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSnapshotForReturnValue = makeSnapshot(
            nextAction: .stageDueExternalSignature,
            externalSigner: true
        )
        rustBackend.migrationStageNextDueExternalPCZTLeaseDurationMsForReturnValue = external
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        let staged = try await synchronizer.stageNextDueMigrationPCZT(
            expectedRunId: "00000000-0000-4000-8000-000000000001",
            expectedRevision: 1,
            options: options,
            for: account
        )

        XCTAssertEqual(staged, external)
        XCTAssertEqual(
            rustBackend.migrationStageNextDueExternalPCZTLeaseDurationMsForReceivedArguments?.account,
            account
        )
        XCTAssertEqual(
            rustBackend.migrationStageNextDueExternalPCZTLeaseDurationMsForReceivedArguments?.expectedRunId,
            "00000000-0000-4000-8000-000000000001"
        )
        XCTAssertEqual(
            rustBackend.migrationStageNextDueExternalPCZTLeaseDurationMsForReceivedArguments?.expectedRevision,
            1
        )
    }

    func testStageDueExternalSignerResumesExactPersistedEnvelopeAfterProcessDeath() async throws {
        let external = ClaimedTransferPCZT(
            intentId: "external-resume",
            pczt: Pczt([0x11, 0x22]),
            signerToken: "external-token",
            leaseExpiresAtMs: .max,
            expiryHeight: 1_000_000,
            submissionPolicy: submissionPolicy
        )
        let snapshot = makeSnapshot(nextAction: .awaitExternalSignature, externalSigner: true, revision: 7)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSnapshotForReturnValue = snapshot
        rustBackend.migrationResumeDueExternalPCZTForReturnValue = external
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        let resumed = try await synchronizer.stageNextDueMigrationPCZT(
            expectedRunId: try XCTUnwrap(snapshot.runId),
            expectedRevision: snapshot.revision,
            options: options,
            for: account
        )

        XCTAssertEqual(resumed, external)
        XCTAssertEqual(rustBackend.migrationResumeDueExternalPCZTForCallsCount, 1)
        XCTAssertFalse(rustBackend.migrationStageNextDueExternalPCZTLeaseDurationMsForCalled)
        let received = rustBackend.migrationResumeDueExternalPCZTForReceivedArguments
        XCTAssertEqual(received?.expectedRunId, snapshot.runId)
        XCTAssertEqual(received?.expectedRevision, snapshot.revision)
        XCTAssertEqual(received?.expectedPolicyFingerprint, submissionPolicy.policyFingerprint)
    }

    func testResumeNoteSplitExternalSignerReturnsExactPersistedEnvelope() async throws {
        let claim = makeNoteSplitSignerClaim(pczt: Pczt([0x33, 0x44]))
        let base = makeSnapshot(nextAction: .awaitExternalSignature, externalSigner: true, revision: 5)
        let snapshot = MigrationSnapshot(
            schemaVersion: base.schemaVersion,
            revision: base.revision,
            runId: base.runId,
            accountUuid: base.accountUuid,
            network: base.network,
            mode: base.mode,
            phase: .preparingDenominations,
            state: .splitPendingConfirmation,
            counts: base.counts,
            intents: base.intents,
            nextDueHeight: base.nextDueHeight,
            nextExpiryHeight: base.nextExpiryHeight,
            failureCode: base.failureCode,
            recoveryAction: base.recoveryAction,
            nextAction: base.nextAction,
            externalSigner: true,
            ordinarySpendsBlocked: true,
            schemaProvenance: base.schemaProvenance,
            consensusFingerprint: base.consensusFingerprint,
            submissionPolicy: base.submissionPolicy
        )
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSnapshotForReturnValue = snapshot
        rustBackend.migrationResumeNoteSplitExternalPCZTForReturnValue = claim
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        let resumed = try await synchronizer.resumeNoteSplitExternalSigning(
            expectedRunId: try XCTUnwrap(snapshot.runId),
            expectedRevision: snapshot.revision,
            options: options,
            for: account
        )

        XCTAssertEqual(resumed, claim)
        let received = rustBackend.migrationResumeNoteSplitExternalPCZTForReceivedArguments
        XCTAssertEqual(received?.expectedRunId, snapshot.runId)
        XCTAssertEqual(received?.expectedRevision, snapshot.revision)
        XCTAssertEqual(received?.expectedPolicyFingerprint, submissionPolicy.policyFingerprint)
        XCTAssertEqual(received?.account, account)
    }

    func testExternalSignedDueIntentUsesClaimTokenAndTokenizedRecord() async throws {
        let external = ClaimedTransferPCZT(
            intentId: "external-2",
            pczt: Pczt([0x01]),
            signerToken: "external-token-2",
            leaseExpiresAtMs: .max,
            expiryHeight: 1_000_000,
            submissionPolicy: submissionPolicy
        )
        let prepared = makePreparedTx(id: external.intentId)
        let submission = makeClaim(prepared, attemptToken: "network-token")
        let final = makeSnapshot(nextAction: .waitForConfirmation, externalSigner: true, revision: 11)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationStoreSignedDueIntentIntentIdAttemptTokenPcztLeaseDurationMsForReturnValue = submission
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = ExtractedTx(txid: submission.txid, rawTx: extractedTxBytes)
        rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForClosure = { _, _, _, _ in }
        rustBackend.migrationSnapshotForReturnValue = final
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .success(txid: submission.txid)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend,
            migrationTransactionSubmitter: submitter
        )
        let signed = Pczt([0xAA, 0xBB])

        let execution = try await synchronizer.submitSignedDueMigrationPCZT(
            signed,
            for: external,
            expectedRunId: "00000000-0000-4000-8000-000000000001",
            expectedRevision: final.revision,
            options: options,
            account: account
        )

        XCTAssertEqual(execution.disposition, .resultRecorded)
        XCTAssertEqual(execution.snapshot, final)
        let stored = rustBackend.migrationStoreSignedDueIntentIntentIdAttemptTokenPcztLeaseDurationMsForReceivedArguments
        XCTAssertEqual(stored?.intentId, external.intentId)
        XCTAssertEqual(stored?.signerToken, external.signerToken)
        XCTAssertEqual(stored?.pczt, signed)
        XCTAssertEqual(stored?.account, account)
        let recorded = rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForReceivedArguments
        XCTAssertEqual(recorded?.attemptToken, submission.attemptToken)
        XCTAssertEqual(recorded?.account, account)
    }

    func testSelectedAccountFlipCannotRetargetInFlightExecution() async throws {
        let accountB = AccountUUID(id: [UInt8](repeating: 8, count: 16))
        let selectedAccount = GenericActor(account)
        let prepared = makePreparedTx(id: "account-a-intent")
        let claim = makeClaim(prepared)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSnapshotForClosure = { requested in
            XCTAssertEqual(requested, self.account)
            _ = await selectedAccount.update(accountB)
            return self.makeSnapshot(nextAction: .claimDueTransaction)
        }
        rustBackend.migrationClaimNextDueTransferLeaseDurationMsForClosure = { _, _, _, _, requested in
            XCTAssertEqual(requested, self.account)
            return claim
        }
        rustBackend.migrationRenewClaimedTransferLeaseForClosure = { id, token, _, _, requested in
            XCTAssertEqual(requested, self.account)
            XCTAssertEqual(id, claim.id)
            XCTAssertEqual(token, claim.attemptToken)
            return claim
        }
        rustBackend.migrationExtractBroadcastTxPcztForClosure = { _, requested in
            XCTAssertEqual(requested, self.account)
            return ExtractedTx(
                txid: claim.txid,
                rawTx: self.extractedTxBytes,
                consensusBranchId: UInt32(bitPattern: Int32(bitPattern: 0xc2d6d0b4)),
                expiryHeight: claim.expiryHeight
            )
        }
        rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForClosure = { _, _, _, requested in
            XCTAssertEqual(requested, self.account)
        }
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .success(txid: claim.txid)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend,
            migrationTransactionSubmitter: submitter
        )

        _ = try await synchronizer.executeNextMigrationAction(
            expectedRunId: "00000000-0000-4000-8000-000000000001",
            expectedRevision: 1,
            spendingKey: nil,
            options: options,
            for: account
        )

        let selectedAfterExecution = await selectedAccount.value
        XCTAssertEqual(selectedAfterExecution, accountB)
    }

    func testTwoActiveAccountsKeepIndependentClaimsAndResultTokens() async throws {
        let accountB = AccountUUID(id: [UInt8](repeating: 8, count: 16))
        let preparedA = makePreparedTx(id: "account-a", txid: String(repeating: "0a", count: 32))
        let preparedB = makePreparedTx(id: "account-b", txid: String(repeating: "0b", count: 32))
        let claimA = makeClaim(preparedA, attemptToken: "token-a")
        let claimB = makeClaim(preparedB, attemptToken: "token-b")
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSnapshotForClosure = { _ in self.makeSnapshot(nextAction: .claimDueTransaction) }
        rustBackend.migrationClaimNextDueTransferLeaseDurationMsForClosure = { _, _, _, _, requested in
            requested == self.account ? claimA : claimB
        }
        rustBackend.migrationRenewClaimedTransferLeaseForClosure = { id, token, _, _, requested in
            let claim = requested == self.account ? claimA : claimB
            XCTAssertEqual(id, claim.id)
            XCTAssertEqual(token, claim.attemptToken)
            return claim
        }
        rustBackend.migrationExtractBroadcastTxPcztForClosure = { _, requested in
            let claim = requested == self.account ? claimA : claimB
            return ExtractedTx(
                txid: claim.txid,
                rawTx: self.extractedTxBytes,
                consensusBranchId: UInt32(bitPattern: Int32(bitPattern: 0xc2d6d0b4)),
                expiryHeight: claim.expiryHeight
            )
        }
        rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForClosure = { id, token, _, requested in
            if requested == self.account {
                XCTAssertEqual(id, claimA.id)
                XCTAssertEqual(token, claimA.attemptToken)
            } else {
                XCTAssertEqual(requested, accountB)
                XCTAssertEqual(id, claimB.id)
                XCTAssertEqual(token, claimB.attemptToken)
            }
        }
        let submitter = MigrationTransactionSubmitterMock()
        submitter.closure = { _, txid, _, _, _, _ in .success(txid: txid) }
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend,
            migrationTransactionSubmitter: submitter
        )

        let executionA = try await synchronizer.executeNextMigrationAction(
            expectedRunId: "00000000-0000-4000-8000-000000000001",
            expectedRevision: 1,
            spendingKey: nil,
            options: options,
            for: account
        )
        let executionB = try await synchronizer.executeNextMigrationAction(
            expectedRunId: "00000000-0000-4000-8000-000000000001",
            expectedRevision: 1,
            spendingKey: nil,
            options: options,
            for: accountB
        )

        XCTAssertEqual(executionA.submissionResult, .success(txid: claimA.txid))
        XCTAssertEqual(executionB.submissionResult, .success(txid: claimB.txid))
        XCTAssertEqual(rustBackend.migrationRecordClaimedTransferResultTransferIdAttemptTokenResultForCallsCount, 2)
    }

    // MARK: - Delegations

    func testMigrationStateDelegatesToRustBackend() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationStateForReturnValue = .readyToPropose
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        let result = try await synchronizer.migrationState(for: account)

        XCTAssertEqual(result, .readyToPropose)
        XCTAssertEqual(rustBackend.migrationStateForReceivedAccount, account)
    }

    func testMigrationProgressDelegatesToRustBackend() async throws {
        let progress = MigrationProgress(
            completedTransfers: 1,
            totalTransfers: 3,
            remainingOrchard: 1000,
            nextTransferReadyAtHeight: 42
        )
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationProgressForReturnValue = progress
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        let result = try await synchronizer.migrationProgress(for: account)

        XCTAssertEqual(result, progress)
        XCTAssertEqual(rustBackend.migrationProgressForReceivedAccount, account)
    }

    func testIsNoteSplitNeededDelegatesToRustBackend() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationIsNoteSplitNeededForReturnValue = true
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        let result = try await synchronizer.isNoteSplitNeeded(for: account)

        XCTAssertTrue(result)
        XCTAssertEqual(rustBackend.migrationIsNoteSplitNeededForReceivedAccount, account)
    }

    func testPrepareNoteSplitDelegatesToRustBackend() async throws {
        let proposal = NoteSplitProposal(outputNotes: [10, 20], fee: 5)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationPrepareNoteSplitForReturnValue = proposal
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        let result = try await synchronizer.prepareNoteSplit(for: account)

        XCTAssertEqual(result, proposal)
        XCTAssertEqual(rustBackend.migrationPrepareNoteSplitForReceivedAccount, account)
    }

    func testProposeMigrationTransfersDelegatesToRustBackend() async throws {
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 7)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationProposeTransfersForReturnValue = schedule
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        let result = try await synchronizer.proposeMigrationTransfers(for: account)

        XCTAssertEqual(result, schedule)
        XCTAssertEqual(rustBackend.migrationProposeTransfersForReceivedAccount, account)
    }

    func testPreviewImmediateMigrationDelegatesToReadOnlyRustBackend() async throws {
        let preview = ImmediateMigrationPreview.positiveBalanceAtOrBelowFee(
            spendableBalance: 19_999,
            fee: 20_000
        )
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationPreviewImmediateForReturnValue = preview
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        let result = try await synchronizer.previewImmediateMigration(for: account)

        XCTAssertEqual(result, preview)
        XCTAssertEqual(rustBackend.migrationPreviewImmediateForReceivedAccount, account)
    }

    func testSignAndStoreMigrationScheduleDelegatesToRustBackend() async throws {
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 7)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSignAndStoreScheduleUskForClosure = { _, _, _, _ in }
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        try await synchronizer.signAndStoreMigrationSchedule(
            schedule,
            spendingKey: TestsData(networkType: .testnet).spendingKey,
            for: account
        )

        let args = rustBackend.migrationSignAndStoreScheduleUskForReceivedArguments
        XCTAssertEqual(args?.schedule, schedule)
        XCTAssertEqual(args?.account, account)
    }

    func testIsSyncRequiredBeforeNextTransferDelegatesToRustBackend() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationIsSyncRequiredForReturnValue = true
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        let result = try await synchronizer.isSyncRequiredBeforeNextTransfer(for: account)

        XCTAssertTrue(result)
        XCTAssertEqual(rustBackend.migrationIsSyncRequiredForReceivedAccount, account)
    }

    func testHasOverdueTransfersDelegatesToRustBackend() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationHasOverdueTransfersForReturnValue = true
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        let result = try await synchronizer.hasOverdueTransfers(for: account)

        XCTAssertTrue(result)
        XCTAssertEqual(rustBackend.migrationHasOverdueTransfersForReceivedAccount, account)
    }

    func testHasInvalidTransfersDelegatesToRustBackend() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationHasInvalidTransfersForReturnValue = true
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        let result = try await synchronizer.hasInvalidTransfers(for: account)

        XCTAssertTrue(result)
        XCTAssertEqual(rustBackend.migrationHasInvalidTransfersForReceivedAccount, account)
    }

    func testRefreshStaleTransfersDelegatesToRustBackend() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationRefreshStaleTransfersUskForReturnValue = 3
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)
        let spendingKey = TestsData(networkType: .testnet).spendingKey

        let result = try await synchronizer.refreshStaleTransfers(spendingKey: spendingKey, for: account)

        XCTAssertEqual(result, 3)
        let args = rustBackend.migrationRefreshStaleTransfersUskForReceivedArguments
        XCTAssertEqual(args?.usk, spendingKey)
        XCTAssertEqual(args?.account, account)
    }

    func testRestartCurrentMigrationStepDelegatesToRustBackend() async throws {
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 2)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationRestartStepForReturnValue = schedule
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        let result = try await synchronizer.restartCurrentMigrationStep(for: account)

        XCTAssertEqual(result, schedule)
        XCTAssertEqual(rustBackend.migrationRestartStepForReceivedAccount, account)
    }

    func testInitializePostUpgradeDelegatesToRustBackend() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationInitializePostUpgradeForClosure = { _ in }
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        try await synchronizer.initializePostUpgrade(for: account)

        XCTAssertTrue(rustBackend.migrationInitializePostUpgradeForCalled)
        XCTAssertEqual(rustBackend.migrationInitializePostUpgradeForReceivedAccount, account)
    }

    // MARK: - Helpers

    private func makeSynchronizer(rustBackend: ZcashRustBackendWelding) throws -> SDKSynchronizer {
        try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: rustBackend
        )
    }

    private func makePreparedTx(
        id: String = "transfer-1",
        txid: String = String(repeating: "0a", count: 32),
        rawPczt: [UInt8] = [0x01, 0x02, 0x03, 0x04]
    ) -> PreparedTx {
        PreparedTx(id: id, txid: txid, rawPczt: rawPczt)
    }

    private func makeClaim(
        _ prepared: PreparedTx,
        attemptToken: String = "claim-token",
        leaseExpiresAtMs: UInt64 = .max,
        expiryHeight: UInt32? = 1_000_000
    ) -> ClaimedTx {
        ClaimedTx(
            id: prepared.id,
            txid: prepared.txid,
            rawPczt: prepared.rawPczt,
            attemptToken: attemptToken,
            leaseExpiresAtMs: leaseExpiresAtMs,
            expiryHeight: expiryHeight ?? 0,
            submissionPolicy: submissionPolicy
        )
    }

    private func makeNoteSplitSignerClaim(pczt: Pczt = Pczt([0x01])) -> ClaimedNoteSplitPCZT {
        ClaimedNoteSplitPCZT(
            runId: "00000000-0000-4000-8000-000000000001",
            pczt: pczt,
            signerToken: "signer-token",
            anchorHeight: 999_000,
            expiryHeight: 1_000_000,
            submissionPolicy: submissionPolicy
        )
    }

    private func makeSnapshot(
        nextAction: NextAction = .none,
        runId: String = "00000000-0000-4000-8000-000000000001",
        accountUuid: String = "07070707-0707-0707-0707-070707070707",
        externalSigner: Bool = false,
        withSubmissionPolicy: Bool = true,
        revision: UInt64 = 1
    ) -> MigrationSnapshot {
        MigrationSnapshot(
            schemaVersion: MigrationSnapshot.supportedSchemaVersion,
            revision: revision,
            runId: runId,
            accountUuid: accountUuid,
            network: "test",
            mode: .privateScheduled,
            phase: .broadcastScheduled,
            state: .inProgress(
                MigrationProgress(
                    completedTransfers: 0,
                    totalTransfers: 1,
                    remainingOrchard: 100,
                    nextTransferReadyAtHeight: 1
                )
            ),
            counts: MigrationCounts(
                preparedLocked: 0,
                preparedSpentMigration: 0,
                preparedSpentExternal: 0,
                preparedReleased: 0,
                intentsPlanned: 1,
                intentsMaterializing: 0,
                intentsStaged: 0,
                intentsAwaitingSignature: 0,
                intentsRejected: 0,
                intentsInvalidated: 0,
                intentsFeeReapprovalRequired: 0,
                intentsPlanReapprovalRequired: 0,
                transfersScheduled: 1,
                transfersSubmitting: 0,
                transfersBroadcasted: 0,
                transfersConfirmed: 0,
                transfersTotal: 1
            ),
            intents: [],
            nextDueHeight: 1,
            nextExpiryHeight: nil,
            failureCode: nil,
            recoveryAction: nil,
            nextAction: nextAction,
            externalSigner: externalSigner,
            ordinarySpendsBlocked: true,
            schemaProvenance: .compatible,
            consensusFingerprint: consensusFingerprint,
            submissionPolicy: withSubmissionPolicy ? submissionPolicy : nil
        )
    }

    /// The internal-byte-order txid the broadcast helper is expected to derive from `prepared.txid`
    /// (decode the crate's display-order hex, then reverse).
    private func expectedSubmittedTxId(_ prepared: PreparedTx) -> Data {
        Data(Data(hexEncoded: prepared.txid)!.reversed())
    }

    private func makeSynchronizer(
        transactionEncoder: TransactionEncoder,
        rustBackend: ZcashRustBackendWelding,
        migrationTransactionSubmitter: MigrationTransactionSubmitting? = nil
    ) throws -> SDKSynchronizer {
        if
            let mock = rustBackend as? ZcashRustBackendWeldingMock,
            mock.migrationSnapshotForReturnValue == nil
        {
            mock.migrationSnapshotForReturnValue = makeSnapshot()
        }
        if let mock = rustBackend as? ZcashRustBackendWeldingMock {
            mock.consensusChainNameReturnValue = "test"
            mock.consensusParametersFingerprintReturnValue = consensusFingerprint
            mock.consensusBranchIdForHeightReturnValue = Int32(bitPattern: 0xc2d6d0b4)
            mock.migrationBeginPrivateExternalSignerForClosure = { [weak mock] _, _, _ in
                mock?.migrationSnapshotForReturnValue ?? self.makeSnapshot()
            }
            if mock.migrationBindSubmissionPolicyExpectedRevisionPolicyForClosure == nil {
                mock.migrationBindSubmissionPolicyExpectedRevisionPolicyForClosure = { [weak mock] _, _, _, _ in
                    mock?.migrationSnapshotForLastReturnValue
                        ?? mock?.migrationSnapshotForReturnValue
                        ?? self.makeSnapshot()
                }
            }
            if mock.migrationRecordSubmissionPolicyValidationFailureExpectedRevisionFailureForClosure == nil {
                mock.migrationRecordSubmissionPolicyValidationFailureExpectedRevisionFailureForClosure = {
                    [weak mock] _, _, _, _ in
                    mock?.migrationSnapshotForReturnValue ?? self.makeSnapshot()
                }
            }
            mock.migrationRetryAutomaticRecoveryExpectedRevisionForClosure = { [weak mock] _, _, _ in
                mock?.migrationSnapshotForReturnValue ?? self.makeSnapshot()
            }
            if mock.migrationRenewClaimedTransferLeaseForClosure == nil {
                mock.migrationRenewClaimedTransferLeaseForClosure = { [weak mock] id, token, _, _, _ in
                    let candidates = [
                        mock?.migrationClaimNoteSplitSubmissionLeaseDurationMsForReturnValue,
                        mock?.migrationClaimNextDueTransferLeaseDurationMsForReturnValue,
                        mock?.migrationMaterializeAndClaimNextDueLeaseDurationMsUskForReturnValue,
                        mock?.migrationResumeStagedSubmissionLeaseDurationMsForReturnValue,
                        mock?.migrationStoreSignedDueIntentIntentIdAttemptTokenPcztLeaseDurationMsForReturnValue
                    ]
                    return candidates.compactMap { $0 }.first { $0.id == id && $0.attemptToken == token }
                }
            }
            mock.migrationReleaseClaimedTransferKnownUnsentForClosure = { _, _, _, _ in }
            mock.migrationRecordClaimedTransferLocalFailureForClosure = { _, _, _, _ in }
            if let extracted = mock.migrationExtractBroadcastTxPcztForReturnValue,
               extracted.expiryHeight == 0 {
                let expiry = [
                    mock.migrationClaimNoteSplitSubmissionLeaseDurationMsForReturnValue,
                    mock.migrationClaimNextDueTransferLeaseDurationMsForReturnValue,
                    mock.migrationMaterializeAndClaimNextDueLeaseDurationMsUskForReturnValue,
                    mock.migrationResumeStagedSubmissionLeaseDurationMsForReturnValue,
                    mock.migrationStoreSignedDueIntentIntentIdAttemptTokenPcztLeaseDurationMsForReturnValue
                ].compactMap { $0 }.first?.expiryHeight ?? 1_000_000
                mock.migrationExtractBroadcastTxPcztForReturnValue = ExtractedTx(
                    txid: extracted.txid,
                    rawTx: extracted.rawTx,
                    consensusBranchId: UInt32(bitPattern: Int32(bitPattern: 0xc2d6d0b4)),
                    expiryHeight: expiry
                )
            }
        }
        let serviceMock = LightWalletServiceMock()
        let transactionRepository = TransactionRepositoryMock()

        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackend }
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in serviceMock }
        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in transactionRepository }
        mockContainer.mock(type: Logger.self, isSingleton: true) { _ in submissionLifecycleLogger() }

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
            walletBirthdayProvider: { initializer.walletBirthday }
        )

        return SDKSynchronizer(
            status: .unprepared,
            initializer: initializer,
            transactionEncoder: transactionEncoder,
            transactionRepository: transactionRepository,
            blockProcessor: blockProcessor,
            syncSessionTicker: .live,
            migrationTransactionSubmitter: migrationTransactionSubmitter
                ?? MigrationTransactionSubmitterMock(transactionEncoder: transactionEncoder)
        )
    }
}
