//
//  OrchardMigrationCompositionTests.swift
//  OfflineTests
//
//  Actor-composition tests for `OrchardMigration`, driven through its internal injecting
//  initializer against `ZcashRustBackendWeldingMock` plus hand-written fakes for the
//  `MigrationBroadcasting` seam and a real, temp-file-backed `MigrationSyncGate` (as established by
//  MigrationLogicTests.swift's I1 canary test). No network, no real FFI: this file exercises the
//  composition wiring (call order, what gets recorded, when the sync gate is marked) over those
//  seams, complementing MigrationFFITests.swift (real FFI) and MigrationLogicTests.swift (pure
//  logic).
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class OrchardMigrationCompositionTests: ZcashTestCase {
    private let accountA = AccountUUID(id: [UInt8](repeating: 0x33, count: 16))
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let buffer: TimeInterval = 600
    private let defaultEndpoint = LightWalletEndpoint(address: "default.example", port: 9067)
    private let usk = UnifiedSpendingKey(network: .testnet, bytes: [UInt8](repeating: 0xEE, count: 32))

    private var welding: ZcashRustBackendWeldingMock!
    private var clock: TestClock!
    private var gate: MigrationSyncGate!

    override func setUp() {
        super.setUp()
        welding = ZcashRustBackendWeldingMock()
        clock = TestClock(referenceDate)
        gate = makeGate(account: accountA, clock: clock)
    }

    override func tearDown() {
        welding = nil
        clock = nil
        gate = nil
        super.tearDown()
    }

    // MARK: - submitNoteSplit composition

    /// Proves the full `sign -> broadcast -> gate marked -> record` order for the
    /// success path, and that the mapped result is returned. There is no extract step any more:
    /// the ceremony's handback comes through the store's broadcast seam already finalized, so what
    /// reaches the broadcaster is `prepared.pczt` verbatim. The `record` closure additionally
    /// asserts the gate is already marked at the moment it runs, pinning "the privacy gate marks
    /// strictly before record" — the buffer protects a landed broadcast even when the engine's
    /// record bookkeeping subsequently fails.
    func testSubmitNoteSplitOrdersSignBroadcastMarksGateThenRecordsOnSuccess() async throws {
        let recorder = CompositionOrderRecorder()
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(100_000)], fee: Zatoshi(5_000), proposalHandle: 1)
        let prepared = makePreparedTransfer(id: 0)

        welding.migrationSignNoteSplitProposalUskForClosure = { receivedProposal, receivedUsk, receivedAccount in
            recorder.record("sign")
            XCTAssertEqual(receivedProposal, proposal)
            XCTAssertEqual(receivedUsk, self.usk)
            XCTAssertEqual(receivedAccount, self.accountA)
            return prepared
        }
        // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
        welding.migrationTransactionStatusesForReturnValue = []
        welding.migrationRecordTransferResultTransferIdResultForClosure = { transferId, result, _ in
            recorder.record("record")
            XCTAssertEqual(transferId, prepared.id)
            XCTAssertEqual(result, MigrationTransferResult.success(txId: prepared.txid.toHexStringTxId()))
            // Ordering proof: the gate must already be marked when record runs.
            XCTAssertNotNil(self.gate.currentResumeAt())
        }

        let broadcaster = ScriptedBroadcaster(script: .outcome(.submitted))
        broadcaster.onBroadcast = { recorder.record("broadcast") }
        let migration = makeMigration(broadcaster: broadcaster)

        let result = try await migration.submitNoteSplit(
            proposal: proposal,
            usk: usk,
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
        )

        XCTAssertEqual(result, MigrationTransferResult.success(txId: prepared.txid.toHexStringTxId()))
        XCTAssertEqual(recorder.events, ["sign", "broadcast", "record"])
        XCTAssertEqual(broadcaster.receivedCalls.count, 1)
        XCTAssertEqual(
            broadcaster.receivedCalls.first?.rawTransaction,
            prepared.pczt,
            "the seam's finalized bytes are submitted verbatim, with no extract step"
        )
        XCTAssertEqual(broadcaster.receivedCalls.first?.endpoint, defaultEndpoint)
        XCTAssertFalse(
            welding.migrationExtractBroadcastTxPcztForCalled,
            "the broadcast path must not extract: its bytes are already a consensus transaction"
        )
        XCTAssertNotNil(gate.currentResumeAt(), "gate must be marked after a successful broadcast")
    }

    /// Transport failure is *returned*, not thrown: recorded as a retryable network error, and the
    /// privacy-buffer gate is left untouched (only a `.success` marks it).
    func testSubmitNoteSplitOnTransportFailureRecordsNetworkErrorAndLeavesGateUntouched() async throws {
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(100_000)], fee: Zatoshi(5_000), proposalHandle: 1)
        let prepared = makePreparedTransfer(id: 0)
        welding.migrationSignNoteSplitProposalUskForReturnValue = prepared
        // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
        welding.migrationTransactionStatusesForReturnValue = []
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let broadcaster = ScriptedBroadcaster(script: .outcome(.transportError))
        let migration = makeMigration(broadcaster: broadcaster)

        // A plain `try await` (no do/catch) already proves this does not throw; the assertions below
        // pin down the recorded/gate side effects.
        let result = try await migration.submitNoteSplit(
            proposal: proposal,
            usk: usk,
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
        )

        XCTAssertEqual(result, MigrationTransferResult.networkError(retryable: true))
        XCTAssertEqual(
            welding.migrationRecordTransferResultTransferIdResultForReceivedArguments?.result,
            MigrationTransferResult.networkError(retryable: true)
        )
        XCTAssertNil(gate.currentResumeAt())
    }

    /// The sibling of MigrationLogicTests' `testExecuteNextPendingTransferFailsClosedOnTor...`
    /// canary, driven through `submitNoteSplit` instead of `executeNextPendingTransfer`: both public
    /// entry points share the same private `broadcastAndRecord` composition, so the fail-closed Tor
    /// guarantee must hold from this call site too.
    func testSubmitNoteSplitFailsClosedOnTorUnavailableWithoutRecordingOrGating() async throws {
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(100_000)], fee: Zatoshi(5_000), proposalHandle: 1)
        let prepared = makePreparedTransfer(id: 0)
        welding.migrationSignNoteSplitProposalUskForReturnValue = prepared
        // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
        welding.migrationTransactionStatusesForReturnValue = []
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let broadcaster = ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable))
        let migration = makeMigration(broadcaster: broadcaster)

        do {
            _ = try await migration.submitNoteSplit(
                proposal: proposal,
                usk: usk,
                options: MigrationNetworkPrivacyOptions(useTor: true, submissionEndpoint: defaultEndpoint)
            )
            XCTFail("Expected migrationTorUnavailable to be thrown")
        } catch ZcashError.migrationTorUnavailable {
            // expected
        } catch {
            XCTFail("Expected migrationTorUnavailable but got \(error)")
        }

        XCTAssertEqual(broadcaster.receivedCalls.count, 1)
        XCTAssertFalse(welding.migrationRecordTransferResultTransferIdResultForCalled)
        XCTAssertNil(gate.currentResumeAt())
    }

    // MARK: - executeNextPendingTransfer composition

    func testExecuteNextPendingTransferReturnsNothingDueWithNoBroadcastNoRecordNoGateChange() async throws {
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .waiting, next: nil)
        let broadcaster = ScriptedBroadcaster(script: .throwing(StubEngineError()))
        let migration = makeMigration(broadcaster: broadcaster)

        let result = try await migration.executeNextPendingTransfer(
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint),
            useEstimatedTip: false
        )

        XCTAssertEqual(result, .nothingDue)
        XCTAssertEqual(broadcaster.receivedCalls.count, 0)
        XCTAssertFalse(welding.migrationRecordTransferResultTransferIdResultForCalled)
        XCTAssertNil(gate.currentResumeAt())
    }

    /// The third `MigrationTransferAttempt` outcome: the drive offers a PROVE batch whose first
    /// schedule-due member's proof does not exist yet, which reports `.awaitingProof(id:)` without
    /// ever reaching the broadcaster, recording nothing, and leaving the gate untouched --
    /// `finalizeReadyTransfers()` (the proving sweep), not this call, is what clears it.
    func testExecuteNextPendingTransferReportsAwaitingProofWithNoBroadcastNoRecordNoGateChange() async throws {
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(
            step: .prove(transactions: [
                MigrationProveTarget(id: 4, kind: .transfer(crossing: 0), isScheduleDue: false),
                MigrationProveTarget(id: 5, kind: .transfer(crossing: 1), isScheduleDue: true)
            ]),
            next: nil
        )
        let broadcaster = ScriptedBroadcaster(script: .throwing(StubEngineError()))
        let migration = makeMigration(broadcaster: broadcaster)

        let result = try await migration.executeNextPendingTransfer(
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint),
            useEstimatedTip: false
        )

        XCTAssertEqual(result, .awaitingProof(id: 5), "the first SCHEDULE-DUE batch member is named, not the first entry")
        XCTAssertFalse(
            welding.migrationTakeBroadcastTransactionIdForCalled,
            "a prove step is no instruction to serve anything for broadcast"
        )
        XCTAssertEqual(broadcaster.receivedCalls.count, 0)
        XCTAssertFalse(welding.migrationRecordTransferResultTransferIdResultForCalled)
        XCTAssertNil(gate.currentResumeAt())
    }

    /// A PROVE batch whose whole set is still ahead of its broadcast windows is opportunistic
    /// proving work, not delivery work: reporting it as `.awaitingProof` would have the host chase
    /// a proof for a broadcast it must not make yet.
    func testExecuteNextPendingTransferReportsNothingDueForAnEntirelyUndueProveBatch() async throws {
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(
            step: .prove(transactions: [
                MigrationProveTarget(id: 4, kind: .transfer(crossing: 0), isScheduleDue: false)
            ]),
            next: nil
        )
        let broadcaster = ScriptedBroadcaster(script: .throwing(StubEngineError()))
        let migration = makeMigration(broadcaster: broadcaster)

        let result = try await migration.executeNextPendingTransfer(
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint),
            useEstimatedTip: false
        )

        XCTAssertEqual(result, .nothingDue)
        XCTAssertEqual(broadcaster.receivedCalls.count, 0)
        XCTAssertNil(gate.currentResumeAt())
    }

    func testExecuteNextPendingTransferSuccessPathRecordsAndMarksGate() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .broadcast(id: prepared.id), next: nil)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
        welding.migrationTransactionStatusesForReturnValue = []
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let broadcaster = ScriptedBroadcaster(script: .outcome(.submitted))
        let migration = makeMigration(broadcaster: broadcaster)

        let result = try await migration.executeNextPendingTransfer(
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint),
            useEstimatedTip: false
        )

        XCTAssertEqual(result, .executed(.success(txId: prepared.txid.toHexStringTxId())))
        XCTAssertEqual(
            welding.migrationRecordTransferResultTransferIdResultForReceivedArguments?.result,
            MigrationTransferResult.success(txId: prepared.txid.toHexStringTxId())
        )
        XCTAssertNotNil(gate.currentResumeAt())
    }

    /// M5: seam-based coverage of the rejection branch's generic (non-expiry) message, at the
    /// composition level -- not just the pure `map` table already covered by MigrationLogicTests.
    func testExecuteNextPendingTransferInvalidNoteRejectionRecordsAndLeavesGateUntouched() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .broadcast(id: prepared.id), next: nil)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
        welding.migrationTransactionStatusesForReturnValue = []
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let broadcaster = ScriptedBroadcaster(script: .outcome(.rejected(errorCode: -25, message: "missing inputs")))
        let migration = makeMigration(broadcaster: broadcaster)

        let result = try await migration.executeNextPendingTransfer(
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint),
            useEstimatedTip: false
        )

        XCTAssertEqual(result, .executed(.invalidNote))
        XCTAssertEqual(
            welding.migrationRecordTransferResultTransferIdResultForReceivedArguments?.result,
            MigrationTransferResult.invalidNote
        )
        XCTAssertNil(gate.currentResumeAt())
    }

    /// M5: seam-based coverage of the rejection branch's expiry message, at the composition level.
    func testExecuteNextPendingTransferExpiredRejectionRecordsAndLeavesGateUntouched() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .broadcast(id: prepared.id), next: nil)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
        welding.migrationTransactionStatusesForReturnValue = []
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let broadcaster = ScriptedBroadcaster(script: .outcome(.rejected(errorCode: -26, message: "tx-expiring-soon")))
        let migration = makeMigration(broadcaster: broadcaster)

        let result = try await migration.executeNextPendingTransfer(
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint),
            useEstimatedTip: false
        )

        XCTAssertEqual(result, .executed(.expired))
        XCTAssertEqual(
            welding.migrationRecordTransferResultTransferIdResultForReceivedArguments?.result,
            MigrationTransferResult.expired
        )
        XCTAssertNil(gate.currentResumeAt())
    }

    /// Broadcaster single-endpoint discipline: exactly one call, to the options' required
    /// submission endpoint.
    func testBroadcasterReceivesExactlyOneCallToTheResolvedEndpoint() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .broadcast(id: prepared.id), next: nil)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
        welding.migrationTransactionStatusesForReturnValue = []
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let overrideEndpoint = LightWalletEndpoint(address: "override.example", port: 443)
        XCTAssertNotEqual(overrideEndpoint, defaultEndpoint)
        let broadcaster = ScriptedBroadcaster(script: .outcome(.submitted))
        let migration = makeMigration(broadcaster: broadcaster)

        _ = try await migration.executeNextPendingTransfer(
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: overrideEndpoint),
            useEstimatedTip: false
        )

        XCTAssertEqual(broadcaster.receivedCalls.count, 1)
        XCTAssertEqual(broadcaster.receivedCalls.first?.endpoint, overrideEndpoint)
    }

    // MARK: - Estimated-tip wiring

    /// `useEstimatedTip: true` projects the wall-clock chain-tip estimate from the wallet's most
    /// recently scanned blocks and feeds it into the welding's due-ness check; `useEstimatedTip:
    /// false` always passes `nil`, regardless of what samples are available -- the estimate may
    /// only ever accelerate due-ness, never enter the decision unless explicitly requested.
    func testExecuteNextPendingTransferPassesTheEstimatedTipOnlyWhenRequested() async throws {
        let sampleTime = referenceDate.addingTimeInterval(-100)
        welding.migrationBlockRateSamplesWindowReturnValue = [
            MigrationBlockRateSample(height: 3_000_000, unixTime: Int64(sampleTime.timeIntervalSince1970))
        ]
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .waiting, next: nil)
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))
        let options = MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)

        _ = try await migration.executeNextPendingTransfer(options: options, useEstimatedTip: false)
        XCTAssertNil(
            welding.migrationAdvanceStepForEstimatedTipReceivedArguments?.estimatedTip,
            "useEstimatedTip: false must pass nil regardless of available samples"
        )

        _ = try await migration.executeNextPendingTransfer(options: options, useEstimatedTip: true)
        XCTAssertNotNil(
            welding.migrationAdvanceStepForEstimatedTipReceivedArguments?.estimatedTip,
            "useEstimatedTip: true must project and pass a tip derived from the block-rate samples"
        )
    }

    /// An estimator failure (the block-rate-samples read throws) degrades to `nil` even when
    /// `useEstimatedTip: true` -- the estimate must never block or crash the call that consults it.
    func testExecuteNextPendingTransferDegradesToNilTipWhenBlockRateSamplesThrows() async throws {
        welding.migrationBlockRateSamplesWindowThrowableError = StubEngineError()
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .waiting, next: nil)
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        _ = try await migration.executeNextPendingTransfer(
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint),
            useEstimatedTip: true
        )

        XCTAssertNil(
            welding.migrationAdvanceStepForEstimatedTipReceivedArguments?.estimatedTip,
            "an estimator failure must degrade to nil, never block or crash the call"
        )
    }

    /// `advanceStep()` — the no-argument form the public conduit uses — ALWAYS drives the engine
    /// with both targets (the `advanceStep(useEstimatedTip:)` overload is for the lanes that opt
    /// out), so the only way the estimate can be lost HERE is silently, by reaching the welding as
    /// `nil`. Pins the exact projected value rather than just non-nil: one sample 150 s (two 75 s
    /// target-spacing blocks) before the frozen clock projects to height + 2, which neither a
    /// dropped estimate nor a wall-clock leak can produce.
    func testAdvanceStepPassesTheProjectedTipEstimateToTheWelding() async throws {
        let sampleTime = referenceDate.addingTimeInterval(-150)
        welding.migrationBlockRateSamplesWindowReturnValue = [
            MigrationBlockRateSample(height: 3_000_000, unixTime: Int64(sampleTime.timeIntervalSince1970))
        ]
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .waiting, next: nil)
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        let advance = try await migration.advanceStep()

        XCTAssertEqual(advance?.step, .waiting)
        let received = try XCTUnwrap(welding.migrationAdvanceStepForEstimatedTipReceivedArguments)
        XCTAssertEqual(received.account, accountA)
        XCTAssertEqual(
            received.estimatedTip,
            3_000_002,
            "the advance step must carry the tip projected at the actor's injected clock (height + floor(150/75))"
        )
    }

    /// The other half of the gating contract: an estimator failure degrades `advanceStep()` to the
    /// scanned-tip behavior (`nil`) instead of propagating — the estimate may accelerate the
    /// engine's scheduled-height due-ness, never block the call that consults it.
    func testAdvanceStepDegradesToNilTipWhenBlockRateSamplesThrows() async throws {
        welding.migrationBlockRateSamplesWindowThrowableError = StubEngineError()
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .waiting, next: nil)
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        let advance = try await migration.advanceStep()

        XCTAssertEqual(advance?.step, .waiting, "an estimator failure must not fail the advance step")
        XCTAssertNil(
            welding.migrationAdvanceStepForEstimatedTipReceivedArguments?.estimatedTip,
            "an estimator failure must degrade to the scanned-tip behavior"
        )
    }

    /// `hasOverdueTransfers(useEstimatedTip:)` mirrors the same wiring as
    /// `executeNextPendingTransfer` above: `true` feeds a projected tip into the welding's overdue
    /// check, `false` always passes `nil`.
    func testHasOverdueTransfersPassesTheEstimatedTipOnlyWhenRequested() async throws {
        let sampleTime = referenceDate.addingTimeInterval(-100)
        welding.migrationBlockRateSamplesWindowReturnValue = [
            MigrationBlockRateSample(height: 3_000_000, unixTime: Int64(sampleTime.timeIntervalSince1970))
        ]
        welding.migrationHasOverdueTransfersForEstimatedTipReturnValue = false
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        _ = try await migration.hasOverdueTransfers(useEstimatedTip: false)
        XCTAssertNil(welding.migrationHasOverdueTransfersForEstimatedTipReceivedArguments?.estimatedTip)

        _ = try await migration.hasOverdueTransfers(useEstimatedTip: true)
        XCTAssertNotNil(welding.migrationHasOverdueTransfersForEstimatedTipReceivedArguments?.estimatedTip)
    }

    // MARK: - Txid byte order (welding record path)

    /// Finding 12: pins the EXACT bytes `migrationRecordTransferResult` receives across the welding
    /// record boundary, using an ascending, asymmetric txid fixture -- reversing it changes every
    /// byte, so a byte-order regression cannot hide the way it could behind this file's other tests'
    /// symmetric `makePreparedTransfer`/`Data(repeating: 0xAB, count: 32)` fixture (reversing 32
    /// identical bytes is a no-op; those tests would stay green even if the byte-order reversal
    /// silently dropped out of `OrchardMigration.broadcastAndRecord`).
    ///
    /// `expectedDisplayTxId` is hand-derived from the documented convention (reverse `prepared.txid`'s
    /// byte order, then hex-encode -- see `PreparedMigrationTransfer.txid` and
    /// `MigrationTransferResult.success`'s doc comments) independently of `Data.toHexStringTxId()`,
    /// not produced by running it and pasting the output. See `TxIdTests` for the same convention
    /// pinned directly against the conversion helpers themselves, off the actor.
    func testExecuteNextPendingTransferRecordsTheDocumentedByteOrderForAnAsymmetricTxId() async throws {
        let rawTxId: [UInt8] = (0..<32).map { UInt8($0) }
        let expectedDisplayTxId = "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100"
        let prepared = PreparedMigrationTransfer(id: 1, txid: Data(rawTxId), pczt: Data([0x01, 0x02]))
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .broadcast(id: prepared.id), next: nil)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
        welding.migrationTransactionStatusesForReturnValue = []
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let broadcaster = ScriptedBroadcaster(script: .outcome(.submitted))
        let migration = makeMigration(broadcaster: broadcaster)

        let result = try await migration.executeNextPendingTransfer(
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint),
            useEstimatedTip: false
        )

        XCTAssertEqual(result, .executed(.success(txId: expectedDisplayTxId)))
        XCTAssertEqual(
            welding.migrationRecordTransferResultTransferIdResultForReceivedArguments?.result,
            MigrationTransferResult.success(txId: expectedDisplayTxId)
        )
    }

    // MARK: - Record failure after a successful broadcast

    /// When the broadcast succeeded but recording the result throws, the privacy gate must already
    /// be marked (the broadcast DID land — the 10-minute buffer protects it independently of engine
    /// bookkeeping), and the call must surface the distinguishable
    /// `migrationRecordFailedAfterBroadcast` so the host knows the engine reconciles later.
    func testExecuteNextPendingTransferRecordThrowAfterSuccessfulBroadcastMarksGateAndThrowsWrapped() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .broadcast(id: prepared.id), next: nil)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
        welding.migrationTransactionStatusesForReturnValue = []
        welding.migrationRecordTransferResultTransferIdResultForThrowableError = StubEngineError()
        let broadcaster = ScriptedBroadcaster(script: .outcome(.submitted))
        let migration = makeMigration(broadcaster: broadcaster)

        do {
            _ = try await migration.executeNextPendingTransfer(
                options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint),
                useEstimatedTip: false
            )
            XCTFail("Expected migrationRecordFailedAfterBroadcast to be thrown")
        } catch ZcashError.migrationRecordFailedAfterBroadcast {
            // expected
        } catch {
            XCTFail("Expected migrationRecordFailedAfterBroadcast but got \(error)")
        }

        XCTAssertEqual(broadcaster.receivedCalls.count, 1)
        XCTAssertNotNil(gate.currentResumeAt(), "a real broadcast must start the privacy buffer even when recording fails")
    }

    /// The sibling of the test above for the other public broadcast flow.
    func testSubmitNoteSplitRecordThrowAfterSuccessfulBroadcastMarksGateAndThrowsWrapped() async throws {
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(100_000)], fee: Zatoshi(5_000), proposalHandle: 1)
        welding.migrationSignNoteSplitProposalUskForReturnValue = makePreparedTransfer(id: 0)
        // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
        welding.migrationTransactionStatusesForReturnValue = []
        welding.migrationRecordTransferResultTransferIdResultForThrowableError = StubEngineError()
        let broadcaster = ScriptedBroadcaster(script: .outcome(.submitted))
        let migration = makeMigration(broadcaster: broadcaster)

        do {
            _ = try await migration.submitNoteSplit(
                proposal: proposal,
                usk: usk,
                options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
            )
            XCTFail("Expected migrationRecordFailedAfterBroadcast to be thrown")
        } catch ZcashError.migrationRecordFailedAfterBroadcast {
            // expected
        } catch {
            XCTFail("Expected migrationRecordFailedAfterBroadcast but got \(error)")
        }

        XCTAssertNotNil(gate.currentResumeAt(), "a real broadcast must start the privacy buffer even when recording fails")
    }

    /// A record failure on a non-success outcome (here a transport error — nothing verifiably
    /// landed) propagates the raw error unwrapped and the gate stays untouched: the
    /// record-failed-after-broadcast contract is reserved for outcomes that map to success.
    /// A11: the in-flight marker is RETAINED — a transport failure cannot prove the submit did
    /// not land, exactly the submit-to-record ambiguity the marker exists for (it self-expires).
    func testExecuteNextPendingTransferRecordThrowOnTransportErrorPropagatesRawAndLeavesGateUntouched() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .broadcast(id: prepared.id), next: nil)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
        welding.migrationTransactionStatusesForReturnValue = []
        welding.migrationRecordTransferResultTransferIdResultForThrowableError = StubEngineError()
        let broadcaster = ScriptedBroadcaster(script: .outcome(.transportError))
        let migration = makeMigration(broadcaster: broadcaster)

        do {
            _ = try await migration.executeNextPendingTransfer(
                options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint),
                useEstimatedTip: false
            )
            XCTFail("Expected the raw record error to be rethrown")
        } catch is StubEngineError {
            // expected
        } catch {
            XCTFail("Expected StubEngineError but got \(error)")
        }

        XCTAssertNil(gate.currentResumeAt())
        XCTAssertNotNil(
            gate.currentInFlightUntil(),
            "A11: a record throw on a network error must retain the protective in-flight marker"
        )
    }

    /// A11, the definitive-rejection half: when the server's answer PROVES nothing landed (an
    /// expired / invalid-note rejection), a record throw clears the in-flight marker first — the
    /// submit-to-record ambiguity is over, so sync must not stay blocked for the marker's full
    /// self-expiry window — and then rethrows the raw record error.
    func testExecuteNextPendingTransferRecordThrowOnDefinitiveRejectionClearsInFlightMarkerAndRethrows() async throws {
        let rejections: [(script: MigrationBroadcastOutcome, expected: MigrationTransferResult)] = [
            (MigrationBroadcastOutcome.rejected(errorCode: -25, message: "tx-expiring-soon"), MigrationTransferResult.expired),
            (MigrationBroadcastOutcome.rejected(errorCode: -25, message: "bad-txns-inputs-spent"), MigrationTransferResult.invalidNote)
        ]

        for (script, expected) in rejections {
            let prepared = makePreparedTransfer(id: 1)
            welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .broadcast(id: prepared.id), next: nil)
            welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
            // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
            welding.migrationTransactionStatusesForReturnValue = []
                welding.migrationRecordTransferResultTransferIdResultForThrowableError = StubEngineError()
            let broadcaster = ScriptedBroadcaster(script: .outcome(script))
            let migration = makeMigration(broadcaster: broadcaster)

            do {
                _ = try await migration.executeNextPendingTransfer(
                    options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint),
                    useEstimatedTip: false
                )
                XCTFail("Expected the raw record error to be rethrown for \(expected)")
            } catch is StubEngineError {
                // expected
            } catch {
                XCTFail("Expected StubEngineError but got \(error) for \(expected)")
            }

            // The mock throws before capturing arguments, so the mapped-result routing is pinned
            // by the non-throwing rejection tests above; here only the gate effects matter.
            XCTAssertNil(gate.currentResumeAt(), "a rejection must not start the privacy buffer")
            XCTAssertNil(
                gate.currentInFlightUntil(),
                "A11: a definitive rejection proves nothing landed — the marker must be cleared before the rethrow (\(expected))"
            )
        }
    }

    /// A11 control: with the record SUCCEEDING, a non-success outcome still ends with the marker
    /// cleared (the outcome is durably recorded, so the submit-to-record window is closed).
    func testExecuteNextPendingTransferRecordSuccessOnNetworkErrorClearsInFlightMarker() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .broadcast(id: prepared.id), next: nil)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
        welding.migrationTransactionStatusesForReturnValue = []
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .outcome(.transportError)))

        _ = try await migration.executeNextPendingTransfer(
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint),
            useEstimatedTip: false
        )

        XCTAssertNil(gate.currentInFlightUntil(), "a recorded outcome closes the submit-to-record window")
    }

    // MARK: - In-flight marker arming at submit time (A9)

    /// A9: the in-flight marker is (re-)armed via the broadcaster's `onWillSubmit` hook at the
    /// LAST pre-submit instant — after connection setup — so its 120 s window covers the actual
    /// submit-to-record span rather than being burned by a slow Tor bootstrap. Pinned by
    /// capturing, at the exact moment the fake fires the hook, that the marker was already armed
    /// once (the early belt) and that the hook re-arms it: the re-armed expiry read AFTER the
    /// hook equals the hook-time clock + guard, not the (earlier) flow-start arm.
    func testExecuteNextPendingTransferReArmsTheInFlightMarkerAtSubmitTimeViaTheHook() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .broadcast(id: prepared.id), next: nil)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
        welding.migrationTransactionStatusesForReturnValue = []
        welding.migrationRecordTransferResultTransferIdResultForThrowableError = StubEngineError()
        let broadcaster = ScriptedBroadcaster(script: .outcome(.transportError))

        // Stand in for a slow Tor bootstrap: by the time the fake reaches its pre-submit hook,
        // 90 s of the early (belt) marker's 120 s window have already elapsed.
        var armedAtHookTime: Date?
        broadcaster.onWillSubmitObserver = { [clock, gate] in
            armedAtHookTime = gate?.currentInFlightUntil()
            clock?.now = self.referenceDate.addingTimeInterval(90)
        }
        let migration = makeMigration(broadcaster: broadcaster)

        do {
            _ = try await migration.executeNextPendingTransfer(
                options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint),
                useEstimatedTip: false
            )
            XCTFail("Expected the record error to be rethrown (retaining the marker)")
        } catch is StubEngineError {
            // expected — a network-error record throw retains the marker (A11), letting this test
            // read the post-hook marker without the success path's clear.
        }

        XCTAssertEqual(broadcaster.onWillSubmitCallCount, 1)
        XCTAssertEqual(
            armedAtHookTime,
            referenceDate.addingTimeInterval(MigrationSyncGate.broadcastInFlightGuardDuration),
            "the early belt arm must already be in place when the hook fires"
        )
        XCTAssertEqual(
            gate.currentInFlightUntil(),
            referenceDate.addingTimeInterval(90 + MigrationSyncGate.broadcastInFlightGuardDuration),
            "the hook must RE-arm the marker at submit time, extending the window past the bootstrap"
        )
    }

    /// A9's no-submit half, via the composition: a fail-closed broadcaster throw means the hook
    /// never fired and the flow's early belt marker is cleared — nothing is in flight.
    func testExecuteNextPendingTransferFailClosedThrowNeverFiresTheHook() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .broadcast(id: prepared.id), next: nil)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
        welding.migrationTransactionStatusesForReturnValue = []
        let broadcaster = ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable))
        let migration = makeMigration(broadcaster: broadcaster)

        _ = try? await migration.executeNextPendingTransfer(
            options: MigrationNetworkPrivacyOptions(useTor: true, submissionEndpoint: defaultEndpoint),
            useEstimatedTip: false
        )

        XCTAssertEqual(broadcaster.onWillSubmitCallCount, 0, "a pre-submit throw must never fire the hook")
        XCTAssertNil(gate.currentInFlightUntil(), "the early belt marker is cleared when nothing reached the network")
    }

    // MARK: - finalizeReadyTransfers composition

    /// The sweep is a LOOP OVER THE DRIVE, not a single call that decides for itself what to
    /// prove: each pass advances, proves exactly the ids that pass named, and advances again —
    /// because proving a batch can unblock rows that were not in it. Pins the whole shape: the
    /// second batch's ids are the ones the SECOND advance named (not the first's), the total is
    /// the sum, and the loop stops on the pass that proves nothing rather than spinning on it.
    func testFinalizeReadyTransfersProvesEachAdvanceBatchUntilAPassProvesNothing() async throws {
        let batches: [[UInt32]] = [[7, 8], [9], [9]]
        var advanceCount = 0
        welding.migrationAdvanceStepForEstimatedTipClosure = { _, _ in
            defer { advanceCount += 1 }
            let ids = advanceCount < batches.count ? batches[advanceCount] : []
            return MigrationAdvance(
                step: .prove(transactions: ids.map {
                    MigrationProveTarget(id: $0, kind: .transfer(crossing: 0), isScheduleDue: false)
                }),
                next: nil
            )
        }
        var provedBatches: [[UInt32]] = []
        welding.migrationProveTransactionsIdsForClosure = { ids, _ in
            provedBatches.append(ids)
            // Two proofs from the first batch, one from the second, and the third pass — the same
            // still-unprovable row again — yields nothing, which must end the sweep.
            return provedBatches.count == 1 ? 2 : (provedBatches.count == 2 ? 1 : 0)
        }
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        let total = try await migration.finalizeReadyTransfers()

        XCTAssertEqual(total, 3, "the sweep reports every proof it made across the passes")
        XCTAssertEqual(
            provedBatches,
            [[7, 8], [9], [9]],
            "each pass must prove exactly the ids ITS advance named, re-advancing in between"
        )
        XCTAssertEqual(advanceCount, 3, "the pass that proved nothing is the last one")
    }

    /// A step the sweep cannot discharge ends it with the count so far, and the prove executor is
    /// never called. A due `.broadcast` is the load-bearing case: it outranks proving in the
    /// engine's own precedence, so a woken session delivers without ever paying proving latency
    /// (ZIP 318 permits a sync session to broadcast) — and this call, which never broadcasts,
    /// leaves that to the caller's own delivery pass.
    func testFinalizeReadyTransfersStopsOnANonProveStepWithoutProving() async throws {
        for step in [MigrationAdvanceStep.broadcast(id: 3), .waiting, .complete, .rebuild(id: 4)] {
            welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: step, next: nil)
            welding.migrationProveTransactionsIdsForCallsCount = 0
            let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

            let total = try await migration.finalizeReadyTransfers()

            XCTAssertEqual(total, 0, "\(step) is not proving work")
            XCTAssertEqual(
                welding.migrationProveTransactionsIdsForCallsCount,
                0,
                "\(step) must never reach the prove executor"
            )
        }
    }

    /// THE SWEEP ADVANCES AT THE SCANNED TIP, never the wall-clock estimate — pinned with samples
    /// available, so a `nil` here is the sweep's own choice rather than an absent projection (the
    /// companion `testAdvanceStepPassesTheProjectedTipEstimateToTheWelding` proves the same
    /// samples DO project a tip through `advanceStep()`).
    ///
    /// The estimate has no acceleration to offer a sweep — prove-readiness is anchor-gated at the
    /// SCANNED tip — so it could only decelerate: an earlier broadcast-precedence stop, and an
    /// earlier PERSISTED re-spread. It would also desynchronize the lanes, since
    /// `executeNextPendingTransfer`'s default judges at the scanned tip: inside the estimate's
    /// lead window the sweep would see `.broadcast` and prove nothing while delivery saw nothing
    /// due, and neither lane would progress until the scan caught up.
    func testFinalizeReadyTransfersAdvancesAtTheScannedTipNotTheEstimate() async throws {
        let sampleTime = referenceDate.addingTimeInterval(-150)
        welding.migrationBlockRateSamplesWindowReturnValue = [
            MigrationBlockRateSample(height: 3_000_000, unixTime: Int64(sampleTime.timeIntervalSince1970))
        ]
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .waiting, next: nil)
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        _ = try await migration.finalizeReadyTransfers()

        let received = try XCTUnwrap(welding.migrationAdvanceStepForEstimatedTipReceivedArguments)
        XCTAssertEqual(received.account, accountA)
        XCTAssertNil(
            received.estimatedTip,
            "the sweep must advance at the scanned tip even when a projectable sample exists"
        )
        XCTAssertFalse(
            welding.migrationBlockRateSamplesWindowCalled,
            "and must not even pay for the projection it would then discard"
        )
    }

    /// No stored run: the drive returns `nil` and the sweep is a benign `0`, so a host may call it
    /// unconditionally from its sync path.
    func testFinalizeReadyTransfersWithNoStoredRunProvesNothing() async throws {
        welding.migrationAdvanceStepForEstimatedTipReturnValue = nil
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        let total = try await migration.finalizeReadyTransfers()

        XCTAssertEqual(total, 0)
        XCTAssertFalse(welding.migrationProveTransactionsIdsForCalled)
    }

    // MARK: - Broadcast single-flight

    /// Pins the single-flight discipline of the broadcast flows: with one `executeNextPendingTransfer`
    /// deliberately suspended inside its broadcast, a second concurrent call must not re-fetch and
    /// re-broadcast the same bytes. It waits for the in-flight flow, then proceeds fresh — its own
    /// advance runs after the record, names nothing, and the call reports nothing due.
    /// Deterministic: the broadcaster suspends until the test opens it, and the welding's drive
    /// names the one due transfer only until its result is recorded.
    func testConcurrentExecuteNextPendingTransferBroadcastsExactlyOnce() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationAdvanceStepForEstimatedTipClosure = { [welding] _, _ in
            // The engine contract: the drive keeps naming the transfer for broadcast until its
            // result is recorded.
            welding?.migrationRecordTransferResultTransferIdResultForCalled == true
                ? MigrationAdvance(step: .waiting, next: nil)
                : MigrationAdvance(step: .broadcast(id: prepared.id), next: nil)
        }
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
        welding.migrationTransactionStatusesForReturnValue = []
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let broadcaster = GatedBroadcaster(outcome: MigrationBroadcastOutcome.submitted)
        let migration = makeMigration(broadcaster: broadcaster)
        let options = MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)

        let first = Task {
            try await migration.executeNextPendingTransfer(options: options, useEstimatedTip: false)
        }
        // The first caller is provably suspended inside its broadcast before the second one starts.
        await broadcaster.awaitBroadcastsStarted(1)
        let second = Task {
            try await migration.executeNextPendingTransfer(options: options, useEstimatedTip: false)
        }
        // Scheduling aid only (correctness must not depend on it): give the second caller ample
        // opportunity to reach the actor while the first broadcast is still in flight, so a missing
        // single-flight guard reliably manifests as a second fetch/broadcast.
        for _ in 0..<50 {
            await Task.yield()
        }
        await broadcaster.open()

        let firstResult = try await first.value
        let secondResult = try await second.value

        let broadcastsStarted = await broadcaster.startedCount
        XCTAssertEqual(broadcastsStarted, 1, "the same due transfer must be broadcast exactly once")
        XCTAssertEqual(firstResult, .executed(.success(txId: prepared.txid.toHexStringTxId())))
        XCTAssertEqual(secondResult, .nothingDue, "the concurrent caller must observe the recorded outcome and find nothing due")
        XCTAssertEqual(
            welding.migrationAdvanceStepForEstimatedTipCallsCount,
            2,
            "the concurrent caller re-advances after the in-flight flow finishes"
        )
        XCTAssertEqual(
            welding.migrationTakeBroadcastTransactionIdForCallsCount,
            1,
            "only the instruction the first advance issued is ever served"
        )
        XCTAssertEqual(welding.migrationRecordTransferResultTransferIdResultForCallsCount, 1)
    }

    /// The single-flight discipline spans the different broadcast entry points: a `submitNoteSplit`
    /// arriving while an `executeNextPendingTransfer` broadcast is in flight runs strictly after it —
    /// its signing does not even start until the in-flight flow has recorded. Both flows then
    /// broadcast their own (different) transactions.
    func testSubmitNoteSplitWaitsForInFlightExecuteNextPendingTransfer() async throws {
        let recorder = CompositionOrderRecorder()
        let dueTransfer = makePreparedTransfer(id: 1)
        let splitTransfer = makePreparedTransfer(id: 0)
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(100_000)], fee: Zatoshi(5_000), proposalHandle: 1)
        welding.migrationAdvanceStepForEstimatedTipClosure = { [welding] _, _ in
            welding?.migrationRecordTransferResultTransferIdResultForCalled == true
                ? MigrationAdvance(step: .waiting, next: nil)
                : MigrationAdvance(step: .broadcast(id: dueTransfer.id), next: nil)
        }
        welding.migrationTakeBroadcastTransactionIdForReturnValue = dueTransfer
        welding.migrationSignNoteSplitProposalUskForClosure = { _, _, _ in
            recorder.record("sign")
            return splitTransfer
        }
        // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
        welding.migrationTransactionStatusesForReturnValue = []
        welding.migrationRecordTransferResultTransferIdResultForClosure = { transferId, _, _ in
            recorder.record("record:\(transferId)")
        }
        let broadcaster = GatedBroadcaster(outcome: MigrationBroadcastOutcome.submitted)
        let migration = makeMigration(broadcaster: broadcaster)

        let transferCall = Task {
            try await migration.executeNextPendingTransfer(
                options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint),
                useEstimatedTip: false
            )
        }
        await broadcaster.awaitBroadcastsStarted(1)
        let splitCall = Task {
            try await migration.submitNoteSplit(
                proposal: proposal,
                usk: self.usk,
                options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
            )
        }
        // Scheduling aid only, as in the sibling test above.
        for _ in 0..<50 {
            await Task.yield()
        }
        await broadcaster.open()

        let transferResult = try await transferCall.value
        let splitResult = try await splitCall.value

        XCTAssertEqual(transferResult, .executed(.success(txId: dueTransfer.txid.toHexStringTxId())))
        XCTAssertEqual(splitResult, MigrationTransferResult.success(txId: splitTransfer.txid.toHexStringTxId()))
        let broadcastsStarted = await broadcaster.startedCount
        XCTAssertEqual(broadcastsStarted, 2, "each flow broadcasts its own transaction, strictly serialized")
        XCTAssertEqual(
            recorder.events,
            ["record:1", "sign", "record:0"],
            "the note split must not even sign until the in-flight transfer flow has recorded"
        )
    }

    // MARK: - Keystone flow

    /// Documents the engine's prep-first contract at the actor level: immediately after
    /// `storeSignedNoteSplitPCZTs`, the delivery lane serves the stored preparation transaction as
    /// next due (mirrored here by stubbing the drive to name the proven
    /// counterpart of the storage receipt), so `executeNextPendingTransfer` broadcasts it.
    func testKeystoneFlowStoreSignedNoteSplitPCZTsThenExecuteNextBroadcastsThePrepTransfer() async throws {
        let prepTransfer = makePreparedTransfer(id: 0)
        welding.migrationStoreSignedNoteSplitPcztsForReturnValue = prepTransfer
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .broadcast(id: prepTransfer.id), next: nil)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepTransfer
        // D2: broadcastAndRecord now reads statuses for the prep buffer exemption; empty = transfer treatment (buffer arms), the old semantics.
        welding.migrationTransactionStatusesForReturnValue = []
        welding.migrationExtractBroadcastTxPcztForClosure = { pczt, _ in
            XCTAssertEqual(pczt, prepTransfer.pczt)
            return Data([0x0A])
        }
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let broadcaster = ScriptedBroadcaster(script: .outcome(.submitted))
        let migration = makeMigration(broadcaster: broadcaster)

        let stored = try await migration.storeSignedNoteSplitPCZTs([
            MigrationSignedTransferPczt(id: prepTransfer.id, pczt: Data([0x09]))
        ])
        XCTAssertEqual(stored, prepTransfer)

        let result = try await migration.executeNextPendingTransfer(
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint),
            useEstimatedTip: false
        )

        XCTAssertEqual(result, .executed(.success(txId: prepTransfer.txid.toHexStringTxId())))
        XCTAssertEqual(welding.migrationRecordTransferResultTransferIdResultForReceivedArguments?.transferId, prepTransfer.id)
    }

    // MARK: - isSyncBlocked gate-file state

    /// `isSyncBlocked` answers from the persisted gate-file (privacy-buffer) state -- checked both
    /// with no gate file (unblocked) and with an active buffer (blocked), so the answer is proven
    /// to actually read the file rather than being a hardcoded constant.
    func testIsSyncBlockedAnswersFromThePersistedGateFileState() async throws {
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        let blockedWithNoGateFile = await migration.isSyncBlocked()
        XCTAssertFalse(blockedWithNoGateFile)

        gate.markBroadcast()

        let blockedWithGateFile = await migration.isSyncBlocked()
        XCTAssertTrue(blockedWithGateFile)
    }

    // MARK: - isSyncBlocked forward-looking policy (D1)

    /// D1 REVERSAL PIN (danny + nuttycom, 2026-08-05): the gate's forward-looking clause is
    /// deleted, so a migration with no buffer and no in-flight marker never blocks sync, and no
    /// gate path pays for the wall-clock chain-tip estimate the clause needed.
    func testIsSyncBlockedIgnoresForwardLookingWork() async throws {
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        let blocked = await migration.isSyncBlocked()

        XCTAssertFalse(blocked, "sync holds only for past/present broadcasts (buffer, in-flight marker)")
        XCTAssertFalse(welding.migrationBlockRateSamplesWindowCalled, "no gate path pays for the estimate anymore")
    }

    /// THE WEDGE (D1): a due-but-unproved row — `migrationHasOverdueTransfers` would answer `true`
    /// for it — must NOT block sync: its proof is produced AT sync wake-ups, so gating sync on it
    /// would starve the very work that clears it. The overdue query throwing loudly (rather than
    /// answering) additionally proves the gate no longer consults it at all.
    func testIsSyncBlockedDoesNotBlockForADueButUnprovedSignedRow() async throws {
        welding.migrationHasOverdueTransfersForEstimatedTipThrowableError = StubEngineError()
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        let blocked = await migration.isSyncBlocked()

        XCTAssertFalse(blocked, "a Signed-due row needs MORE syncing; it must never hold sync hostage")
        XCTAssertFalse(
            welding.migrationHasOverdueTransfersForEstimatedTipCalled,
            "no gate path may consult the overdue query anymore"
        )
    }

    // MARK: - Helpers

    private func makeMigration(broadcaster: any MigrationBroadcasting) -> OrchardMigration {
        // `isSyncBlocked()` and the `useEstimatedTip: true` paths unconditionally read
        // `migrationBlockRateSamples` (`ChainTipEstimator`'s raw input); default it to "no samples"
        // so a test that never cares about the estimate does not crash on the mock's un-stubbed,
        // implicitly-unwrapped `ReturnValue` -- a test that DOES care sets it itself before calling
        // this helper, which this guard leaves untouched.
        if welding.migrationBlockRateSamplesWindowReturnValue == nil {
            welding.migrationBlockRateSamplesWindowReturnValue = []
        }
        let clockValue = clock!
        return OrchardMigration(
            welding: welding,
            accountUUID: accountA,
            broadcaster: broadcaster,
            syncGate: gate,
            logger: logger,
            // The actor's estimate-consulting paths read the injected clock (U7), so the
            // fake-clock projection tests are deterministic.
            now: { clockValue.now }
        )
    }

    private func makeGate(account: AccountUUID, clock: TestClock) -> MigrationSyncGate {
        MigrationSyncGate(
            directory: testGeneralStorageDirectory,
            accountUUID: account,
            bufferDuration: buffer,
            // A long tick keeps the background re-evaluation out of these deterministic assertions.
            tickInterval: 3600,
            now: { clock.now },
            logger: logger
        )
    }

    private func makePreparedTransfer(id: UInt32) -> PreparedMigrationTransfer {
        PreparedMigrationTransfer(id: id, txid: Data(repeating: 0xAB, count: 32), pczt: Data([0x01, 0x02]))
    }
}

/// Records the order in which the broadcast composition's collaborators are invoked, so a test can
/// assert the exact sign -> extract -> broadcast -> record sequence
/// `OrchardMigration.broadcastAndRecord` promises. `OrchardMigration` is an actor and every awaited
/// call in the composition is sequential, so a plain array is sufficient.
private final class CompositionOrderRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

/// A ``MigrationBroadcasting`` fake with a test-controlled suspension: every `broadcast` call
/// suspends until ``open()`` is called, giving single-flight tests a deterministic in-flight window.
/// Starts are observable via ``awaitBroadcastsStarted(_:)``; once opened, suspended and future
/// broadcasts complete immediately with the scripted outcome. An actor, because these tests
/// deliberately call it from concurrent tasks.
private actor GatedBroadcaster: MigrationBroadcasting {
    private let outcome: MigrationBroadcastOutcome
    private var isOpen = false
    private(set) var startedCount = 0
    private var pendingBroadcasts: [CheckedContinuation<Void, Never>] = []
    private var startObservers: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(outcome: MigrationBroadcastOutcome) {
        self.outcome = outcome
    }

    func broadcast(
        rawTransaction: Data,
        to endpoint: LightWalletEndpoint,
        useTor: Bool,
        onWillSubmit: @Sendable () -> Void
    ) async throws -> MigrationBroadcastOutcome {
        startedCount += 1
        notifyStartObservers()
        if !isOpen {
            await withCheckedContinuation { continuation in
                pendingBroadcasts.append(continuation)
            }
        }
        // Per the production contract the hook fires at the last pre-submit instant; a returned
        // outcome means a submit happened.
        onWillSubmit()
        return outcome
    }

    /// Returns once at least `count` broadcasts have started (immediately when they already have).
    func awaitBroadcastsStarted(_ count: Int) async {
        if startedCount >= count {
            return
        }
        await withCheckedContinuation { continuation in
            startObservers.append((threshold: count, continuation: continuation))
        }
    }

    /// Releases every suspended broadcast and lets all future ones complete immediately.
    func open() {
        isOpen = true
        let pending = pendingBroadcasts
        pendingBroadcasts = []
        for continuation in pending {
            continuation.resume()
        }
    }

    private func notifyStartObservers() {
        let ready = startObservers.filter { $0.threshold <= startedCount }
        startObservers.removeAll { $0.threshold <= startedCount }
        for observer in ready {
            observer.continuation.resume()
        }
    }
}

/// A generic, non-`ZcashError` failure for stubbing welding calls that must fail for reasons
/// unrelated to what a given test is actually asserting (e.g. an engine call the test never expects
/// to succeed but also never inspects the error from).
private struct StubEngineError: Error {}
