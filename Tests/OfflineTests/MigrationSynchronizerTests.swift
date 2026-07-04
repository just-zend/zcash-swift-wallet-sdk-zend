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

    private enum TestError: Error {
        case boom
    }

    // MARK: - submitNoteSplit

    func testSubmitNoteSplitSignsAndSubmitsThenReturnsSuccess() async throws {
        let prepared = makePreparedTx()
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSignNoteSplitProposalUskForReturnValue = prepared
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = extractedTxBytes
        rustBackend.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let proposal = NoteSplitProposal(outputNotes: [100, 200], fee: 10)
        let result = try await synchronizer.submitNoteSplit(
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
        let recorded = rustBackend.migrationRecordTransferResultTransferIdResultForReceivedArguments
        XCTAssertEqual(recorded?.transferId, prepared.id)
        XCTAssertEqual(recorded?.result, .success(txid: prepared.txid))
    }

    func testSubmitNoteSplitMapsGrpcFailureToRetryableNetworkError() async throws {
        let prepared = makePreparedTx()
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSignNoteSplitProposalUskForReturnValue = prepared
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = extractedTxBytes
        rustBackend.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let encoder = StubTransactionEncoder(createdTransactions: [])
        encoder.submitError = ZcashError.serviceSubmitFailed(.timeOut)
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let result = try await synchronizer.submitNoteSplit(
            proposal: NoteSplitProposal(outputNotes: [100], fee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey,
            options: options,
            for: account
        )

        XCTAssertEqual(result, .networkError(retryable: true))
    }

    func testSubmitNoteSplitMapsKnownToServerSubmitErrorToSuccess() async throws {
        let prepared = makePreparedTx()
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSignNoteSplitProposalUskForReturnValue = prepared
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = extractedTxBytes
        rustBackend.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let encoder = StubTransactionEncoder(createdTransactions: [])
        encoder.submitError = TransactionEncoderError.submitError(code: -1, message: "already in mempool")
        encoder.knownToServerTxIds = [expectedSubmittedTxId(prepared)]
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let result = try await synchronizer.submitNoteSplit(
            proposal: NoteSplitProposal(outputNotes: [100], fee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey,
            options: options,
            for: account
        )

        XCTAssertEqual(result, .success(txid: prepared.txid))
    }

    func testSubmitNoteSplitMapsUnknownSubmitErrorToNonRetryableNetworkError() async throws {
        let prepared = makePreparedTx()
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSignNoteSplitProposalUskForReturnValue = prepared
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = extractedTxBytes
        rustBackend.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let encoder = StubTransactionEncoder(createdTransactions: [])
        encoder.submitError = TransactionEncoderError.submitError(code: -1, message: "rejected")
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let result = try await synchronizer.submitNoteSplit(
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
        rustBackend.migrationExtractBroadcastTxPcztForThrowableError = TestError.boom
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        do {
            _ = try await synchronizer.submitNoteSplit(
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

    // MARK: - External signer (hardware wallet)

    func testProposeNoteSplitPCZTDelegatesToRustBackend() async throws {
        let unsigned = Pczt([0x01, 0x02, 0x03])
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationCreateUnsignedNoteSplitPCZTForReturnValue = unsigned
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        let result = try await synchronizer.proposeNoteSplitPCZT(for: account)

        XCTAssertEqual(result, unsigned)
        XCTAssertEqual(rustBackend.migrationCreateUnsignedNoteSplitPCZTForReceivedAccount, account)
    }

    func testSubmitSignedNoteSplitPCZTStoresSubmitsAndRecords() async throws {
        let prepared = makePreparedTx(id: "prep:run-1")
        let signedPczt = Pczt([0x0A, 0x0B])
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationStoreSignedNoteSplitPCZTPcztForReturnValue = prepared
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = extractedTxBytes
        rustBackend.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let result = try await synchronizer.submitSignedNoteSplitPCZT(signedPczt, for: account)

        XCTAssertEqual(result, .success(txid: prepared.txid))
        // The device-signed PCZT is handed to the store step, which returns the broadcastable form.
        XCTAssertEqual(rustBackend.migrationStoreSignedNoteSplitPCZTPcztForReceivedArguments?.pczt, signedPczt)
        XCTAssertEqual(rustBackend.migrationStoreSignedNoteSplitPCZTPcztForReceivedArguments?.account, account)
        // The *stored* PCZT (not the device-signed input) is extracted and broadcast.
        XCTAssertEqual(rustBackend.migrationExtractBroadcastTxPcztForReceivedArguments?.pczt, prepared.rawPczt)
        XCTAssertEqual(encoder.submittedTransactions.map(\.raw), [Data(extractedTxBytes)])
        // The outcome is recorded with the `prep:<run_id>` id so the split phase advances.
        let recorded = rustBackend.migrationRecordTransferResultTransferIdResultForReceivedArguments
        XCTAssertEqual(recorded?.transferId, prepared.id)
        XCTAssertEqual(recorded?.result, .success(txid: prepared.txid))
    }

    func testSubmitSignedNoteSplitPCZTPropagatesStoreErrorWithoutSubmitting() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationStoreSignedNoteSplitPCZTPcztForThrowableError = TestError.boom
        rustBackend.migrationNextDueTransferForReturnValue = nil
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        do {
            _ = try await synchronizer.submitSignedNoteSplitPCZT(Pczt([0x0A]), for: account)
            XCTFail("Expected submitSignedNoteSplitPCZT to propagate the store error")
        } catch {
            // expected
        }

        XCTAssertTrue(encoder.submittedTransactions.isEmpty)
        XCTAssertFalse(rustBackend.migrationRecordTransferResultTransferIdResultForCalled)
    }

    func testSubmitSignedNoteSplitPCZTRebroadcastsPendingPrepTxWhenStagingAlreadyConsumed() async throws {
        // Retry contract (MOB-1468): after a store-succeeded-broadcast-failed first attempt, the
        // failure sheet's Retry re-calls submitSignedNoteSplitPCZT with the SAME signed PCZT. The
        // staged original was consumed by that first store, so the store step now throws — the
        // still-pending `prep:<run_id>` transaction surfaced by `migrationNextDueTransfer` is what
        // must be re-broadcast (no device round-trip, no second run stored).
        let prepared = makePreparedTx(id: "prep:run-1")
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationStoreSignedNoteSplitPCZTPcztForThrowableError =
            ZcashError.rustMigrationStoreSignedNoteSplitPCZT("no staged note-split PCZT to store")
        rustBackend.migrationNextDueTransferForReturnValue = prepared
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = extractedTxBytes
        rustBackend.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let result = try await synchronizer.submitSignedNoteSplitPCZT(Pczt([0x0A, 0x0B]), for: account)

        XCTAssertEqual(result, .success(txid: prepared.txid))
        // The persisted prep tx (not the incoming device PCZT) is what gets extracted + broadcast.
        XCTAssertEqual(rustBackend.migrationExtractBroadcastTxPcztForReceivedArguments?.pczt, prepared.rawPczt)
        XCTAssertEqual(encoder.submittedTransactions.map(\.raw), [Data(extractedTxBytes)])
        let recorded = rustBackend.migrationRecordTransferResultTransferIdResultForReceivedArguments
        XCTAssertEqual(recorded?.transferId, prepared.id)
        XCTAssertEqual(recorded?.result, .success(txid: prepared.txid))
    }

    func testSubmitSignedNoteSplitPCZTRethrowsStoreErrorWhenNextDueIsARegularTransfer() async throws {
        // A pending non-prep transfer must not be hijacked by the note-split retry path: only a
        // `prep:`-prefixed next-due transaction identifies the consumed-staging retry state.
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationStoreSignedNoteSplitPCZTPcztForThrowableError = TestError.boom
        rustBackend.migrationNextDueTransferForReturnValue = makePreparedTx(id: "transfer-3")
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        do {
            _ = try await synchronizer.submitSignedNoteSplitPCZT(Pczt([0x0A]), for: account)
            XCTFail("Expected submitSignedNoteSplitPCZT to rethrow the store error")
        } catch {
            // expected
        }

        XCTAssertTrue(encoder.submittedTransactions.isEmpty)
        XCTAssertFalse(rustBackend.migrationRecordTransferResultTransferIdResultForCalled)
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
        rustBackend.migrationStoreSignedSchedulePCZTsPcztsForClosure = { _, _ in }
        let synchronizer = try makeSynchronizer(rustBackend: rustBackend)

        try await synchronizer.storeSignedMigrationTransferPCZTs(pairs, for: account)

        let args = rustBackend.migrationStoreSignedSchedulePCZTsPcztsForReceivedArguments
        XCTAssertEqual(args?.pczts, pairs)
        XCTAssertEqual(args?.account, account)
    }

    // MARK: - executeNextPendingTransfer

    func testExecuteNextPendingTransferReturnsNilWhenNoneDue() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationNextDueTransferForReturnValue = nil
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let result = try await synchronizer.executeNextPendingTransfer(options: options, for: account)

        XCTAssertNil(result)
        XCTAssertTrue(encoder.submittedTransactions.isEmpty)
        XCTAssertFalse(rustBackend.migrationRecordTransferResultTransferIdResultForCalled)
    }

    func testExecuteNextPendingTransferSubmitsAndRecordsSuccess() async throws {
        let prepared = makePreparedTx(id: "transfer-7")
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationNextDueTransferForReturnValue = prepared
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = extractedTxBytes
        rustBackend.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let result = try await synchronizer.executeNextPendingTransfer(options: options, for: account)

        XCTAssertEqual(result, .success(txid: prepared.txid))
        XCTAssertEqual(rustBackend.migrationExtractBroadcastTxPcztForReceivedArguments?.pczt, prepared.rawPczt)
        XCTAssertEqual(rustBackend.migrationExtractBroadcastTxPcztForReceivedArguments?.account, account)
        XCTAssertEqual(encoder.submittedTransactions.map(\.raw), [Data(extractedTxBytes)])
        let recorded = rustBackend.migrationRecordTransferResultTransferIdResultForReceivedArguments
        XCTAssertEqual(recorded?.transferId, prepared.id)
        XCTAssertEqual(recorded?.result, .success(txid: prepared.txid))
        XCTAssertEqual(recorded?.account, account)
    }

    func testExecuteNextPendingTransferRecordsRetryableNetworkErrorOnGrpcFailure() async throws {
        let prepared = makePreparedTx(id: "transfer-8")
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationNextDueTransferForReturnValue = prepared
        rustBackend.migrationExtractBroadcastTxPcztForReturnValue = extractedTxBytes
        rustBackend.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let encoder = StubTransactionEncoder(createdTransactions: [])
        encoder.submitError = ZcashError.serviceSubmitFailed(.timeOut)
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        let result = try await synchronizer.executeNextPendingTransfer(options: options, for: account)

        XCTAssertEqual(result, .networkError(retryable: true))
        XCTAssertEqual(
            rustBackend.migrationRecordTransferResultTransferIdResultForReceivedArguments?.result,
            .networkError(retryable: true)
        )
    }

    func testExecuteNextPendingTransferDoesNotRecordWhenNextDueThrows() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationNextDueTransferForThrowableError = TestError.boom
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        do {
            _ = try await synchronizer.executeNextPendingTransfer(options: options, for: account)
            XCTFail("Expected executeNextPendingTransfer to propagate the next-due error")
        } catch {
            // expected
        }

        XCTAssertFalse(rustBackend.migrationRecordTransferResultTransferIdResultForCalled)
        XCTAssertTrue(encoder.submittedTransactions.isEmpty)
    }

    func testExecuteNextPendingTransferDoesNotRecordWhenExtractThrows() async throws {
        let prepared = makePreparedTx(id: "transfer-9")
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationNextDueTransferForReturnValue = prepared
        rustBackend.migrationExtractBroadcastTxPcztForThrowableError = TestError.boom
        let encoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend)

        do {
            _ = try await synchronizer.executeNextPendingTransfer(options: options, for: account)
            XCTFail("Expected executeNextPendingTransfer to propagate the extract error")
        } catch {
            // expected
        }

        XCTAssertFalse(rustBackend.migrationRecordTransferResultTransferIdResultForCalled)
        XCTAssertTrue(encoder.submittedTransactions.isEmpty)
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

    func testSignAndStoreMigrationScheduleDelegatesToRustBackend() async throws {
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 7)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.migrationSignAndStoreScheduleUskForClosure = { _, _, _ in }
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
        txid: String = "0a0b0c0d",
        rawPczt: [UInt8] = [0x01, 0x02, 0x03, 0x04]
    ) -> PreparedTx {
        PreparedTx(id: id, txid: txid, rawPczt: rawPczt)
    }

    /// The internal-byte-order txid the broadcast helper is expected to derive from `prepared.txid`
    /// (decode the crate's display-order hex, then reverse).
    private func expectedSubmittedTxId(_ prepared: PreparedTx) -> Data {
        Data(Data(hexEncoded: prepared.txid)!.reversed())
    }

    private func makeSynchronizer(
        transactionEncoder: TransactionEncoder,
        rustBackend: ZcashRustBackendWelding
    ) throws -> SDKSynchronizer {
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
            syncSessionTicker: .live
        )
    }
}
