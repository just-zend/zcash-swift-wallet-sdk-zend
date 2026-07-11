//
//  MigrationModelTests.swift
//  OfflineTests
//
//  Verifies the migration Codable models decode the exact JSON the `zodl_ironwood_migration` crate
//  emits (serde external tagging + snake_case), and that the hand-written enum coders round-trip.
//

import XCTest
@testable import ZcashLightClientKit

final class MigrationModelTests: XCTestCase {
    private let consensusFingerprint = String(repeating: "0", count: 64)
    private var boundPolicy: BoundSubmissionPolicy {
        BoundSubmissionPolicy(
            policy: SubmissionPolicy(
                transport: .direct,
                endpointIdentity: "https://test.example:443",
                consensusFingerprint: consensusFingerprint
            ),
            policyFingerprint: String(repeating: "1", count: 64),
            revision: 1
        )
    }
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func testMigrationStateUnitVariants() throws {
        XCTAssertEqual(try decode(MigrationState.self, "\"NotStarted\""), .notStarted)
        XCTAssertEqual(try decode(MigrationState.self, "\"SplitPendingConfirmation\""), .splitPendingConfirmation)
        XCTAssertEqual(try decode(MigrationState.self, "\"ReadyToPropose\""), .readyToPropose)
        XCTAssertEqual(try decode(MigrationState.self, "\"Complete\""), .complete)
    }

    func testMigrationStateInProgress() throws {
        let json = """
        {"InProgress":{"completed_transfers":1,"total_transfers":3,"remaining_orchard":600000000,"next_transfer_ready_at_height":2880864}}
        """
        let expected = MigrationState.inProgress(
            MigrationProgress(
                completedTransfers: 1,
                totalTransfers: 3,
                remainingOrchard: 600_000_000,
                nextTransferReadyAtHeight: 2_880_864
            )
        )
        XCTAssertEqual(try decode(MigrationState.self, json), expected)
        XCTAssertEqual(try roundTrip(expected), expected)
    }

    func testMigrationStateRequiresAttentionNestedEnum() throws {
        XCTAssertEqual(
            try decode(MigrationState.self, "{\"RequiresAttention\":\"TransferExpired\"}"),
            .requiresAttention(.transferExpired)
        )
        XCTAssertEqual(
            try decode(MigrationState.self, "{\"RequiresAttention\":{\"InvalidTransfer\":{\"transfer_id\":\"x\"}}}"),
            .requiresAttention(.invalidTransfer(transferId: "x"))
        )
        XCTAssertEqual(
            try roundTrip(MigrationState.requiresAttention(.syncRequiredBeforeNext)),
            .requiresAttention(.syncRequiredBeforeNext)
        )
        XCTAssertEqual(
            try decode(MigrationState.self, "{\"RequiresAttention\":\"SchemaIncompatible\"}"),
            .requiresAttention(.schemaIncompatible)
        )
        XCTAssertEqual(
            try roundTrip(MigrationState.requiresAttention(.submissionOutcomeUnknown)),
            .requiresAttention(.submissionOutcomeUnknown)
        )
        XCTAssertEqual(
            try roundTrip(MigrationState.requiresAttention(.recoveryRequired)),
            .requiresAttention(.recoveryRequired)
        )
    }

    func testTransferResultVariants() throws {
        XCTAssertEqual(try decode(TransferResult.self, "{\"Success\":{\"txid\":\"abc\"}}"), .success(txid: "abc"))
        XCTAssertEqual(try decode(TransferResult.self, "{\"NetworkError\":{\"retryable\":true}}"), .networkError(retryable: true))
        XCTAssertEqual(try decode(TransferResult.self, "\"InvalidNote\""), .invalidNote)
        XCTAssertEqual(try decode(TransferResult.self, "\"Expired\""), .expired)
        XCTAssertEqual(try decode(TransferResult.self, "\"OutcomeUnknown\""), .outcomeUnknown)
        for value in [
            TransferResult.success(txid: "z"),
            .networkError(retryable: false),
            .invalidNote,
            .expired,
            .outcomeUnknown
        ] {
            XCTAssertEqual(try roundTrip(value), value)
        }
    }

    func testPreparedTxDecodesRawPcztArray() throws {
        let tx = try decode(PreparedTx.self, "{\"id\":\"t1\",\"txid\":\"deadbeef\",\"raw_pczt\":[5,0,255]}")
        XCTAssertEqual(tx, PreparedTx(id: "t1", txid: "deadbeef", rawPczt: [5, 0, 255]))
    }

    func testMigrationTransferPCZTDecodesRawPcztArrayIntoData() throws {
        let pair = try decode(MigrationTransferPCZT.self, "{\"id\":\"run-3\",\"raw_pczt\":[80,67,90,84]}")
        XCTAssertEqual(pair, MigrationTransferPCZT(id: "run-3", pczt: Pczt([80, 67, 90, 84])))
        XCTAssertEqual(try roundTrip(pair), pair)
        // The crate expects the byte-array wire format back (`raw_pczt` key, numeric array).
        let encoded = String(decoding: try JSONEncoder().encode(pair), as: UTF8.self)
        XCTAssertTrue(encoded.contains("\"raw_pczt\":[80,67,90,84]"))
    }

    func testNoteSplitProposalSnakeCase() throws {
        XCTAssertEqual(
            try decode(NoteSplitProposal.self, "{\"output_notes\":[100000000,34500000],\"fee\":10000}"),
            NoteSplitProposal(outputNotes: [100_000_000, 34_500_000], fee: 10_000)
        )
    }

    func testScheduleAndProposalDecodeAndRoundTrip() throws {
        let json = """
        {"transfers":[{"id":"t1","amount":1000000000,"anchor_height":2880000,"next_executable_after_height":2880288,"expiry_height":2880576}],"estimated_duration_hours":6}
        """
        let decoded = try decode(MigrationSchedule.self, json)
        XCTAssertEqual(decoded.transfers.first?.amount, 1_000_000_000)
        XCTAssertEqual(decoded.transfers.first?.nextExecutableAfterHeight, 2_880_288)
        XCTAssertEqual(decoded.estimatedDurationHours, 6)
        XCTAssertEqual(try roundTrip(decoded), decoded)
    }

    func testIntentScheduleIsAnchorlessAndCarriesRevisionToken() throws {
        let json = """
        {
          "run_id":"run-7",
          "expected_revision":42,
          "intents":[{
            "id":"run-7-0",
            "amount":1000000000,
            "fee":20000,
            "not_before_height":2880288,
            "target_window_end_height":2880576
          }],
          "estimated_duration_hours":6
        }
        """
        let decoded = try decode(MigrationIntentSchedule.self, json)
        XCTAssertEqual(decoded.runId, "run-7")
        XCTAssertEqual(decoded.expectedRevision, 42)
        XCTAssertEqual(
            decoded.intents,
            [
                MigrationIntent(
                    id: "run-7-0",
                    amount: 1_000_000_000,
                    fee: 20_000,
                    notBeforeHeight: 2_880_288,
                    targetWindowEndHeight: 2_880_576
                )
            ]
        )
        XCTAssertEqual(try roundTrip(decoded), decoded)

        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(encoded.contains("anchor"))
        XCTAssertFalse(encoded.contains("expiry"))
    }

    func testAuthoritativeSnapshotDecodesEveryExecutionField() throws {
        let json = """
        {
          "schema_version":4,
          "revision":47,
          "run_id":"run-7",
          "account_uuid":"00000000-0000-0000-0000-000000000007",
          "network":"test",
          "consensus_fingerprint":"\(consensusFingerprint)",
          "mode":"private_scheduled",
          "phase":"broadcasting",
          "state":{"InProgress":{
            "completed_transfers":2,
            "total_transfers":5,
            "remaining_orchard":300000000,
            "next_transfer_ready_at_height":2880864
          }},
          "counts":{
            "prepared_locked":3,
            "prepared_spent_migration":2,
            "prepared_spent_external":1,
            "prepared_released":0,
            "intents_planned":1,
            "intents_materializing":0,
            "intents_staged":1,
            "intents_awaiting_signature":0,
            "intents_submitting":1,
            "intents_outcome_unknown":0,
            "intents_broadcasted":0,
            "intents_confirmed":0,
            "intents_rejected":0,
            "intents_invalidated":0,
            "intents_fee_reapproval_required":0,
            "intents_plan_reapproval_required":0,
            "transfers_scheduled":2,
            "transfers_submitting":1,
            "transfers_broadcasted":0,
            "transfers_confirmed":2,
            "transfers_total":5
          },
          "intents":[{
            "id":"run-7-2",
            "sequence_index":2,
            "amount":100000000,
            "fee":20000,
            "required_fee":null,
            "not_before_height":2880864,
            "target_window_end_height":2881152,
            "materialized_expiry_height":2881152,
            "status":"submitting"
          }],
          "next_due_height":2880864,
          "next_expiry_height":2881152,
          "failure_code":"submission_outcome_unknown",
          "recovery_action":"wait_for_submission_resolution",
          "next_action":"wait_for_submission_resolution",
          "external_signer":true,
          "ordinary_spends_blocked":true,
          "schema_provenance":"compatible",
          "submission_policy":{"policy":{"transport":"direct","endpoint_identity":"https://test.example:443","consensus_fingerprint":"\(consensusFingerprint)"},"policy_fingerprint":"\(String(repeating: "1", count: 64))","revision":1}
        }
        """
        let snapshot = try decode(MigrationSnapshot.self, json)

        XCTAssertEqual(snapshot.schemaVersion, MigrationSnapshot.supportedSchemaVersion)
        XCTAssertEqual(snapshot.revision, 47)
        XCTAssertEqual(snapshot.runId, "run-7")
        XCTAssertEqual(snapshot.mode, .privateScheduled)
        XCTAssertEqual(snapshot.phase, .broadcasting)
        XCTAssertEqual(snapshot.counts.intentsStaged, 1)
        XCTAssertEqual(snapshot.counts.preparedSpentMigration, 2)
        XCTAssertEqual(snapshot.counts.preparedSpentExternal, 1)
        XCTAssertEqual(snapshot.counts.transfersConfirmed, 2)
        XCTAssertEqual(
            snapshot.intents,
            [
                MigrationIntentSummary(
                    id: "run-7-2",
                    sequenceIndex: 2,
                    amount: 100_000_000,
                    fee: 20_000,
                    requiredFee: nil,
                    notBeforeHeight: 2_880_864,
                    targetWindowEndHeight: 2_881_152,
                    materializedExpiryHeight: 2_881_152,
                    status: .submitting
                )
            ]
        )
        XCTAssertEqual(snapshot.failureCode, .submissionOutcomeUnknown)
        XCTAssertEqual(snapshot.recoveryAction, .waitForSubmissionResolution)
        XCTAssertEqual(snapshot.nextAction, .waitForSubmissionResolution)
        XCTAssertTrue(snapshot.externalSigner)
        XCTAssertTrue(snapshot.ordinarySpendsBlocked)
        XCTAssertEqual(snapshot.schemaProvenance, .compatible)
        XCTAssertEqual(try roundTrip(snapshot), snapshot)
    }

    func testSnapshotSchemaFailureStatesRemainMachineActionable() throws {
        let json = """
        {
          "schema_version":4,
          "revision":0,
          "run_id":null,
          "account_uuid":"00000000-0000-0000-0000-000000000000",
          "network":"test",
          "consensus_fingerprint":"\(consensusFingerprint)",
          "mode":null,
          "phase":null,
          "state":{"RequiresAttention":"SchemaIncompatible"},
          "counts":{
            "prepared_locked":0,"prepared_spent_migration":0,"prepared_spent_external":0,"prepared_released":0,
            "intents_planned":0,"intents_materializing":0,"intents_staged":0,
            "intents_awaiting_signature":0,"intents_rejected":0,"intents_invalidated":0,
            "intents_submitting":0,"intents_outcome_unknown":0,"intents_broadcasted":0,"intents_confirmed":0,
            "intents_fee_reapproval_required":0,
            "intents_plan_reapproval_required":0,
            "transfers_scheduled":0,"transfers_submitting":0,"transfers_broadcasted":0,
            "transfers_confirmed":0,"transfers_total":0
          },
          "intents":[],
          "next_due_height":null,
          "next_expiry_height":null,
          "failure_code":"schema_incompatible",
          "recovery_action":"wipe_and_rescan_testnet",
          "next_action":"recover",
          "external_signer":false,
          "ordinary_spends_blocked":false,
          "schema_provenance":"fork_incompatible_shared_migration_id",
          "submission_policy":null
        }
        """
        let snapshot = try decode(MigrationSnapshot.self, json)

        XCTAssertEqual(snapshot.state, .requiresAttention(.schemaIncompatible))
        XCTAssertEqual(snapshot.failureCode, .schemaIncompatible)
        XCTAssertEqual(snapshot.recoveryAction, .wipeAndRescanTestnet)
        XCTAssertEqual(snapshot.nextAction, .recover)
        XCTAssertEqual(snapshot.schemaProvenance, .forkIncompatibleSharedMigrationId)
    }

    func testFeeDriftSnapshotExposesApprovedAndReplacementExactFeesForReapproval() throws {
        let json = """
        {
          "schema_version":4,"revision":8,"run_id":"run-fee","account_uuid":"account","network":"test",
          "consensus_fingerprint":"\(consensusFingerprint)",
          "mode":"immediate","phase":"failed_recoverable","state":{"RequiresAttention":"TransferExpired"},
          "counts":{
            "prepared_locked":0,"prepared_spent_migration":0,"prepared_spent_external":0,"prepared_released":0,
            "intents_planned":0,"intents_materializing":0,"intents_staged":0,
            "intents_awaiting_signature":0,"intents_rejected":0,"intents_invalidated":0,
            "intents_submitting":0,"intents_outcome_unknown":0,"intents_broadcasted":0,"intents_confirmed":0,
            "intents_fee_reapproval_required":1,
            "intents_plan_reapproval_required":0,
            "transfers_scheduled":1,"transfers_submitting":0,"transfers_broadcasted":0,
            "transfers_confirmed":0,"transfers_total":1
          },
          "intents":[{
            "id":"run-fee-0","sequence_index":0,"amount":999980000,
            "fee":20000,"required_fee":25000,"not_before_height":100,
            "target_window_end_height":100,"materialized_expiry_height":null,
            "status":"fee_reapproval_required"
          }],
          "next_due_height":100,"next_expiry_height":null,
          "failure_code":"approved_fee_changed","recovery_action":"require_user_reapproval",
          "next_action":"review_updated_intent_fee","external_signer":false,
          "ordinary_spends_blocked":true,"schema_provenance":"compatible",
          "submission_policy":{"policy":{"transport":"direct","endpoint_identity":"https://test.example:443","consensus_fingerprint":"\(consensusFingerprint)"},"policy_fingerprint":"\(String(repeating: "1", count: 64))","revision":1}
        }
        """

        let snapshot = try decode(MigrationSnapshot.self, json)

        XCTAssertEqual(snapshot.failureCode, .approvedFeeChanged)
        XCTAssertEqual(snapshot.recoveryAction, .requireUserReapproval)
        XCTAssertEqual(snapshot.nextAction, .reviewUpdatedIntentFee)
        XCTAssertEqual(snapshot.intents.first?.status, .feeReapprovalRequired)
        XCTAssertEqual(snapshot.intents.first?.fee, 20_000)
        XCTAssertEqual(snapshot.intents.first?.requiredFee, 25_000)
    }

    func testAbandoningSnapshotKeepsOrdinarySpendsBlockedUntilCancellationIsSafe() throws {
        let json = """
        {
          "schema_version":4,"revision":9,"run_id":"run-cancel","account_uuid":"account","network":"test",
          "consensus_fingerprint":"\(consensusFingerprint)",
          "mode":"private_scheduled","phase":"abandoning","state":{"InProgress":{
            "completed_transfers":0,"total_transfers":1,"remaining_orchard":100000000,
            "next_transfer_ready_at_height":100
          }},
          "counts":{
            "prepared_locked":1,"prepared_spent_migration":0,"prepared_spent_external":0,"prepared_released":0,
            "intents_planned":0,"intents_materializing":0,"intents_staged":0,
            "intents_awaiting_signature":0,"intents_rejected":0,"intents_invalidated":0,
            "intents_submitting":0,"intents_outcome_unknown":0,"intents_broadcasted":1,"intents_confirmed":0,
            "intents_fee_reapproval_required":0,"intents_plan_reapproval_required":0,
            "transfers_scheduled":1,"transfers_submitting":0,"transfers_broadcasted":1,
            "transfers_confirmed":0,"transfers_total":1
          },
          "intents":[],"next_due_height":100,"next_expiry_height":120,
          "failure_code":null,"recovery_action":null,"next_action":"wait_for_cancellation_safety",
          "external_signer":false,"ordinary_spends_blocked":true,"schema_provenance":"compatible",
          "submission_policy":{"policy":{"transport":"direct","endpoint_identity":"https://test.example:443","consensus_fingerprint":"\(consensusFingerprint)"},"policy_fingerprint":"\(String(repeating: "1", count: 64))","revision":1}
        }
        """

        let snapshot = try decode(MigrationSnapshot.self, json)

        XCTAssertEqual(snapshot.phase, .abandoning)
        XCTAssertEqual(snapshot.nextAction, .waitForCancellationSafety)
        XCTAssertTrue(snapshot.ordinarySpendsBlocked)
        XCTAssertNil(snapshot.failureCode)
        XCTAssertNil(snapshot.recoveryAction)
    }

    func testPlanSemanticsDriftRequiresWholePlanReapprovalWithoutMasqueradingAsFeeDrift() throws {
        let json = """
        {
          "schema_version":4,"revision":10,"run_id":"run-plan","account_uuid":"account","network":"test",
          "consensus_fingerprint":"\(consensusFingerprint)",
          "mode":"private_scheduled","phase":"failed_recoverable",
          "state":{"RequiresAttention":"TransferExpired"},
          "counts":{
            "prepared_locked":1,"prepared_spent_migration":0,"prepared_spent_external":0,"prepared_released":0,
            "intents_planned":0,"intents_materializing":0,"intents_staged":0,
            "intents_awaiting_signature":0,"intents_rejected":0,"intents_invalidated":0,
            "intents_submitting":0,"intents_outcome_unknown":0,"intents_broadcasted":0,"intents_confirmed":0,
            "intents_fee_reapproval_required":0,"intents_plan_reapproval_required":1,
            "transfers_scheduled":1,"transfers_submitting":0,"transfers_broadcasted":0,
            "transfers_confirmed":0,"transfers_total":1
          },
          "intents":[{
            "id":"run-plan-0","sequence_index":0,"amount":100000000,"fee":20000,"required_fee":null,
            "not_before_height":100,"target_window_end_height":120,"materialized_expiry_height":null,
            "status":"plan_reapproval_required"
          }],
          "next_due_height":100,"next_expiry_height":null,
          "failure_code":"plan_semantics_changed","recovery_action":"require_user_reapproval",
          "next_action":"review_updated_migration_plan","external_signer":false,
          "ordinary_spends_blocked":true,"schema_provenance":"compatible",
          "submission_policy":{"policy":{"transport":"direct","endpoint_identity":"https://test.example:443","consensus_fingerprint":"\(consensusFingerprint)"},"policy_fingerprint":"\(String(repeating: "1", count: 64))","revision":1}
        }
        """

        let snapshot = try decode(MigrationSnapshot.self, json)

        XCTAssertEqual(snapshot.failureCode, .planSemanticsChanged)
        XCTAssertEqual(snapshot.recoveryAction, .requireUserReapproval)
        XCTAssertEqual(snapshot.nextAction, .reviewUpdatedMigrationPlan)
        XCTAssertEqual(snapshot.counts.intentsPlanReapprovalRequired, 1)
        XCTAssertEqual(snapshot.counts.intentsFeeReapprovalRequired, 0)
        XCTAssertEqual(snapshot.intents.first?.status, .planReapprovalRequired)
        XCTAssertEqual(snapshot.intents.first?.fee, 20_000)
        XCTAssertNil(snapshot.intents.first?.requiredFee)
        XCTAssertTrue(snapshot.ordinarySpendsBlocked)
    }

    func testSnapshotFailsClosedForUnknownIntentStatus() throws {
        let json = """
        {
          "schema_version":4,"revision":1,"run_id":"run","account_uuid":"account","network":"test",
          "consensus_fingerprint":"\(consensusFingerprint)",
          "mode":"private_scheduled","phase":"broadcast_scheduled","state":{"InProgress":{
            "completed_transfers":0,"total_transfers":1,"remaining_orchard":1,"next_transfer_ready_at_height":1
          }},
          "counts":{
            "prepared_locked":1,"prepared_spent_migration":0,"prepared_spent_external":0,"prepared_released":0,
            "intents_planned":0,"intents_materializing":0,"intents_staged":0,
            "intents_awaiting_signature":0,"intents_rejected":0,"intents_invalidated":0,
            "intents_submitting":0,"intents_outcome_unknown":0,"intents_broadcasted":0,"intents_confirmed":0,
            "intents_fee_reapproval_required":0,
            "intents_plan_reapproval_required":0,
            "transfers_scheduled":1,"transfers_submitting":0,"transfers_broadcasted":0,
            "transfers_confirmed":0,"transfers_total":1
          },
          "intents":[{
            "id":"run-0","sequence_index":0,"amount":1,"fee":20000,"required_fee":null,"not_before_height":1,
            "target_window_end_height":2,"materialized_expiry_height":null,
            "status":"future_engine_state"
          }],
          "next_due_height":1,"next_expiry_height":null,"failure_code":null,"recovery_action":null,
          "next_action":"wait_for_due_height","external_signer":false,"ordinary_spends_blocked":true,
          "schema_provenance":"compatible",
          "submission_policy":{"policy":{"transport":"direct","endpoint_identity":"https://test.example:443","consensus_fingerprint":"\(consensusFingerprint)"},"policy_fingerprint":"\(String(repeating: "1", count: 64))","revision":1}
        }
        """

        XCTAssertThrowsError(try decode(MigrationSnapshot.self, json))
    }

    func testNewerSnapshotSchemaBecomesExplicitFailClosedUpdateState() throws {
        // Deliberately contains future enum values and omits the v4 body. The stable envelope is
        // enough to replace cached UI with an explicit non-actionable update-required state.
        let snapshot = try decode(
            MigrationSnapshot.self,
            "{\"schema_version\":5,\"account_uuid\":\"account-5\",\"network\":\"test\",\"next_action\":\"future_action\"}"
        )

        XCTAssertEqual(snapshot.schemaVersion, 5)
        XCTAssertEqual(snapshot.accountUuid, "account-5")
        XCTAssertEqual(snapshot.network, "test")
        XCTAssertEqual(snapshot.state, .requiresAttention(.appUpdateRequired))
        XCTAssertEqual(snapshot.failureCode, .appUpdateRequired)
        XCTAssertEqual(snapshot.recoveryAction, .updateApp)
        XCTAssertEqual(snapshot.nextAction, .none)
        XCTAssertTrue(snapshot.ordinarySpendsBlocked)
        XCTAssertEqual(snapshot.schemaProvenance, .engineSchemaNewer)
        XCTAssertTrue(snapshot.intents.isEmpty)
    }

    func testSnapshotIdentityValidationFailsClosedAcrossAccountOrNetwork() throws {
        let snapshot = MigrationSnapshot.appUpdateRequired(
            foundSchemaVersion: 5,
            accountUuid: "account-a",
            network: "test"
        )

        let projected = try snapshot.validated(
            accountUuid: "00000000-0000-4000-8000-00000000000a",
            network: "test",
            consensusFingerprint: consensusFingerprint
        )
        XCTAssertEqual(projected.accountUuid, "00000000-0000-4000-8000-00000000000a")
        XCTAssertEqual(projected.network, "test")
        XCTAssertTrue(projected.ordinarySpendsBlocked)
    }

    func testStructurallyValidV4SnapshotPassesDefensiveValidation() throws {
        let snapshot = makeReadyToPrepareSnapshot()

        XCTAssertEqual(
            try snapshot.validated(
                accountUuid: snapshot.accountUuid,
                network: "test",
                consensusFingerprint: consensusFingerprint
            ),
            snapshot
        )
    }

    func testUnavailableSnapshotProjectionIsIdentityPreservingAndNonOperational() throws {
        let account = "00000000-0000-4000-8000-000000000007"
        let snapshot = MigrationSnapshot.unavailable(
            accountUuid: account,
            network: "test",
            consensusFingerprint: consensusFingerprint
        )

        XCTAssertEqual(try validate(snapshot), snapshot)
        XCTAssertEqual(snapshot.accountUuid, account)
        XCTAssertEqual(snapshot.schemaProvenance, .walletSchemaUnavailable)
        XCTAssertEqual(snapshot.state, .requiresAttention(.recoveryRequired))
        XCTAssertEqual(snapshot.failureCode, .persistenceFailure)
        XCTAssertEqual(snapshot.nextAction, .none)
        XCTAssertTrue(snapshot.ordinarySpendsBlocked)
        XCTAssertNil(snapshot.runId)
    }

    func testSnapshotValidationRejectsNonCanonicalRunIdentity() throws {
        let snapshot = makeReadyToPrepareSnapshot(runId: "not-a-run-id")

        XCTAssertThrowsError(try validate(snapshot)) { error in
            XCTAssertEqual(error as? MigrationSnapshotValidationError, .invariantViolation("run_identity"))
        }
    }

    func testSnapshotValidationRejectsExactIntentCountCorruption() throws {
        let runId = "00000000-0000-4000-8000-000000000001"
        let intent = MigrationIntentSummary(
            id: "\(runId)-0",
            sequenceIndex: 0,
            amount: 1,
            fee: 10_000,
            requiredFee: nil,
            notBeforeHeight: 100,
            targetWindowEndHeight: 120,
            materializedExpiryHeight: nil,
            status: .planned
        )
        let snapshot = makeReadyToPrepareSnapshot(intents: [intent])

        XCTAssertThrowsError(try validate(snapshot)) { error in
            XCTAssertEqual(
                error as? MigrationSnapshotValidationError,
                .invariantViolation("intent_status_counts_exact")
            )
        }
    }

    func testSnapshotValidationAcceptsEngineRunScopedIntentNamespace() throws {
        let runId = "00000000-0000-4000-8000-000000000001"
        func snapshot(intentId: String, fee: UInt64 = 10_000) -> MigrationSnapshot {
            let intent = MigrationIntentSummary(
                id: intentId,
                sequenceIndex: 0,
                amount: 1,
                fee: fee,
                requiredFee: nil,
                notBeforeHeight: 100,
                targetWindowEndHeight: 120,
                materializedExpiryHeight: nil,
                status: .planned
            )
            return MigrationSnapshot(
                schemaVersion: MigrationSnapshot.supportedSchemaVersion,
                revision: 1,
                runId: runId,
                accountUuid: "00000000-0000-4000-8000-000000000007",
                network: "test",
                mode: .privateScheduled,
                phase: .readyToPrepare,
                state: .notStarted,
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
                    transfersScheduled: 0,
                    transfersSubmitting: 0,
                    transfersBroadcasted: 0,
                    transfersConfirmed: 0,
                    transfersTotal: 1
                ),
                intents: [intent],
                nextDueHeight: 100,
                nextExpiryHeight: nil,
                failureCode: nil,
                recoveryAction: nil,
                nextAction: .preparePrivateSplit,
                externalSigner: false,
                ordinarySpendsBlocked: true,
                schemaProvenance: .compatible,
                consensusFingerprint: consensusFingerprint,
                submissionPolicy: nil
            )
        }

        let upgraded = snapshot(intentId: "\(runId)-legacy-expired-42")
        XCTAssertEqual(try validate(upgraded), upgraded)
        let engineExtension = snapshot(intentId: "\(runId)-future-engine-namespace")
        XCTAssertEqual(try validate(engineExtension), engineExtension)

        XCTAssertThrowsError(try validate(snapshot(intentId: "\(runId)-"))) { error in
            XCTAssertEqual(error as? MigrationSnapshotValidationError, .invariantViolation("intent_structure"))
        }
        XCTAssertThrowsError(try validate(snapshot(intentId: "different-run-legacy-expired-42"))) { error in
            XCTAssertEqual(error as? MigrationSnapshotValidationError, .invariantViolation("intent_structure"))
        }
        XCTAssertThrowsError(try validate(snapshot(intentId: "\(runId)-zero-fee", fee: 0))) { error in
            XCTAssertEqual(error as? MigrationSnapshotValidationError, .invariantViolation("intent_structure"))
        }
    }

    func testSnapshotValidationRejectsUnpairedFailureAndRecovery() throws {
        let snapshot = makeReadyToPrepareSnapshot(failureCode: .networkUnavailable, recoveryAction: nil)

        XCTAssertThrowsError(try validate(snapshot)) { error in
            XCTAssertEqual(error as? MigrationSnapshotValidationError, .invariantViolation("failure_recovery_pair"))
        }
    }

    func testSnapshotValidationRejectsForgedSubmissionPolicyFingerprint() throws {
        let snapshot = makeReadyToPrepareSnapshot(submissionPolicy: boundPolicy)

        XCTAssertThrowsError(try validate(snapshot)) { error in
            XCTAssertEqual(error as? MigrationSnapshotValidationError, .invariantViolation("submission_policy_binding"))
        }
    }

    func testSnapshotValidationRejectsArtifactPhaseWithoutBoundPolicy() throws {
        let base = makeReadyToPrepareSnapshot()
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
            intents: [],
            nextDueHeight: nil,
            nextExpiryHeight: nil,
            failureCode: nil,
            recoveryAction: nil,
            nextAction: .claimDueTransaction,
            externalSigner: false,
            ordinarySpendsBlocked: true,
            schemaProvenance: .compatible,
            consensusFingerprint: consensusFingerprint,
            submissionPolicy: nil
        )

        XCTAssertThrowsError(try validate(snapshot)) { error in
            XCTAssertEqual(
                error as? MigrationSnapshotValidationError,
                .invariantViolation("artifact_requires_submission_policy")
            )
        }
    }

    func testSnapshotValidationTreatsRejectedAndInvalidatedIntentsAsPolicyBoundArtifacts() throws {
        let base = makeReadyToPrepareSnapshot()
        let runId = try XCTUnwrap(base.runId)

        for status in [MigrationIntentStatus.rejected, .invalidated] {
            let intent = MigrationIntentSummary(
                id: "\(runId)-artifact-0",
                sequenceIndex: 0,
                amount: 1,
                fee: 10_000,
                requiredFee: nil,
                notBeforeHeight: 100,
                targetWindowEndHeight: 120,
                materializedExpiryHeight: 140,
                status: status
            )
            let snapshot = MigrationSnapshot(
                schemaVersion: base.schemaVersion,
                revision: base.revision,
                runId: runId,
                accountUuid: base.accountUuid,
                network: base.network,
                mode: .privateScheduled,
                phase: .paused,
                state: .inProgress(
                    MigrationProgress(
                        completedTransfers: 0,
                        totalTransfers: 1,
                        remainingOrchard: 1,
                        nextTransferReadyAtHeight: nil
                    )
                ),
                counts: MigrationCounts(
                    preparedLocked: 0,
                    preparedSpentMigration: 0,
                    preparedSpentExternal: 0,
                    preparedReleased: 0,
                    intentsPlanned: 0,
                    intentsMaterializing: 0,
                    intentsStaged: 0,
                    intentsAwaitingSignature: 0,
                    intentsRejected: status == .rejected ? 1 : 0,
                    intentsInvalidated: status == .invalidated ? 1 : 0,
                    intentsFeeReapprovalRequired: 0,
                    intentsPlanReapprovalRequired: 0,
                    transfersScheduled: 0,
                    transfersSubmitting: 0,
                    transfersBroadcasted: 0,
                    transfersConfirmed: 0,
                    transfersTotal: 1
                ),
                intents: [intent],
                nextDueHeight: nil,
                nextExpiryHeight: 140,
                failureCode: nil,
                recoveryAction: nil,
                nextAction: .resumeMigration,
                externalSigner: false,
                ordinarySpendsBlocked: true,
                schemaProvenance: .compatible,
                consensusFingerprint: consensusFingerprint,
                submissionPolicy: nil
            )

            XCTAssertThrowsError(try validate(snapshot), "status \(status) must require policy") { error in
                XCTAssertEqual(
                    error as? MigrationSnapshotValidationError,
                    .invariantViolation("artifact_requires_submission_policy")
                )
            }
        }
    }

    func testSnapshotValidationAcceptsStagedExternalNoteSplitRelaunchProjection() throws {
        let base = makeReadyToPrepareSnapshot()
        let validPolicy = BoundSubmissionPolicy(
            policy: SubmissionPolicy(
                transport: .direct,
                endpointIdentity: "https://test.example:443",
                consensusFingerprint: consensusFingerprint
            ),
            policyFingerprint: "eb56d124d6f6a1320d89249a1c7fdf1175e8200af9e65ec58ce37a7876f0f5dc",
            revision: 1
        )
        let snapshot = MigrationSnapshot(
            schemaVersion: base.schemaVersion,
            revision: 2,
            runId: base.runId,
            accountUuid: base.accountUuid,
            network: base.network,
            mode: .privateScheduled,
            phase: .preparingDenominations,
            state: .splitPendingConfirmation,
            counts: base.counts,
            intents: [],
            nextDueHeight: nil,
            nextExpiryHeight: nil,
            failureCode: nil,
            recoveryAction: nil,
            nextAction: .awaitExternalSignature,
            externalSigner: true,
            ordinarySpendsBlocked: true,
            schemaProvenance: .compatible,
            consensusFingerprint: consensusFingerprint,
            submissionPolicy: validPolicy
        )

        XCTAssertEqual(try validate(snapshot), snapshot)
    }

    func testSnapshotValidationAcceptsLiveNoteSplitSubmissionProjectionWithoutIntentCounts() throws {
        let base = makeReadyToPrepareSnapshot()
        let validPolicy = BoundSubmissionPolicy(
            policy: SubmissionPolicy(
                transport: .direct,
                endpointIdentity: "https://test.example:443",
                consensusFingerprint: consensusFingerprint
            ),
            policyFingerprint: "eb56d124d6f6a1320d89249a1c7fdf1175e8200af9e65ec58ce37a7876f0f5dc",
            revision: 1
        )
        let snapshot = MigrationSnapshot(
            schemaVersion: base.schemaVersion,
            revision: 2,
            runId: base.runId,
            accountUuid: base.accountUuid,
            network: base.network,
            mode: .privateScheduled,
            phase: .preparingDenominations,
            state: .splitPendingConfirmation,
            counts: base.counts,
            intents: [],
            nextDueHeight: nil,
            nextExpiryHeight: nil,
            failureCode: nil,
            recoveryAction: nil,
            nextAction: .waitForSubmissionResolution,
            externalSigner: false,
            ordinarySpendsBlocked: true,
            schemaProvenance: .compatible,
            consensusFingerprint: consensusFingerprint,
            submissionPolicy: validPolicy
        )

        XCTAssertEqual(try validate(snapshot), snapshot)
    }

    func testSnapshotValidationRejectsGenericRecoverForSpecializedRecoveryActions() throws {
        let base = makeReadyToPrepareSnapshot()

        for specializedRecovery in [RecoveryAction.waitForSync, .waitForSubmissionResolution] {
            let snapshot = MigrationSnapshot(
                schemaVersion: base.schemaVersion,
                revision: base.revision,
                runId: base.runId,
                accountUuid: base.accountUuid,
                network: base.network,
                mode: base.mode,
                phase: base.phase,
                state: base.state,
                counts: base.counts,
                intents: base.intents,
                nextDueHeight: base.nextDueHeight,
                nextExpiryHeight: base.nextExpiryHeight,
                failureCode: .networkUnavailable,
                recoveryAction: specializedRecovery,
                nextAction: .recover,
                externalSigner: base.externalSigner,
                ordinarySpendsBlocked: base.ordinarySpendsBlocked,
                schemaProvenance: base.schemaProvenance,
                consensusFingerprint: base.consensusFingerprint,
                submissionPolicy: base.submissionPolicy
            )

            XCTAssertThrowsError(try validate(snapshot)) { error in
                XCTAssertEqual(
                    error as? MigrationSnapshotValidationError,
                    .invariantViolation("phase_next_action")
                )
            }
        }
    }

    func testSnapshotValidationAcceptsGenericRecoverForRecreateTransaction() throws {
        let base = makeReadyToPrepareSnapshot()
        let snapshot = MigrationSnapshot(
            schemaVersion: base.schemaVersion,
            revision: base.revision,
            runId: base.runId,
            accountUuid: base.accountUuid,
            network: base.network,
            mode: base.mode,
            phase: base.phase,
            state: base.state,
            counts: base.counts,
            intents: base.intents,
            nextDueHeight: base.nextDueHeight,
            nextExpiryHeight: base.nextExpiryHeight,
            failureCode: .transferExpired,
            recoveryAction: .recreateTransaction,
            nextAction: .recover,
            externalSigner: base.externalSigner,
            ordinarySpendsBlocked: base.ordinarySpendsBlocked,
            schemaProvenance: base.schemaProvenance,
            consensusFingerprint: base.consensusFingerprint,
            submissionPolicy: base.submissionPolicy
        )

        XCTAssertEqual(try validate(snapshot), snapshot)
    }

    func testSnapshotValidationAllowsExactLegacyPolicylessArtifactRepairProjections() throws {
        let base = makeReadyToPrepareSnapshot()
        let counts = MigrationCounts(
            preparedLocked: 0,
            preparedSpentMigration: 0,
            preparedSpentExternal: 0,
            preparedReleased: 0,
            intentsPlanned: 0,
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
        )
        let repair = MigrationSnapshot(
            schemaVersion: base.schemaVersion,
            revision: 3,
            runId: base.runId,
            accountUuid: base.accountUuid,
            network: base.network,
            mode: .privateScheduled,
            phase: .failedRecoverable,
            state: .requiresAttention(.recoveryRequired),
            counts: counts,
            intents: [],
            nextDueHeight: 100,
            nextExpiryHeight: 300,
            failureCode: .submissionPolicyMismatch,
            recoveryAction: .waitForSubmissionResolution,
            nextAction: .waitForSubmissionResolution,
            externalSigner: false,
            ordinarySpendsBlocked: true,
            schemaProvenance: .compatible,
            consensusFingerprint: consensusFingerprint,
            submissionPolicy: nil
        )

        XCTAssertEqual(try validate(repair), repair)

        let firstBindSafe = MigrationSnapshot(
            schemaVersion: repair.schemaVersion,
            revision: repair.revision,
            runId: repair.runId,
            accountUuid: repair.accountUuid,
            network: repair.network,
            mode: repair.mode,
            phase: .broadcastScheduled,
            state: .inProgress(
                MigrationProgress(
                    completedTransfers: 0,
                    totalTransfers: 1,
                    remainingOrchard: 1,
                    nextTransferReadyAtHeight: 100
                )
            ),
            counts: repair.counts,
            intents: repair.intents,
            nextDueHeight: repair.nextDueHeight,
            nextExpiryHeight: repair.nextExpiryHeight,
            failureCode: .submissionPolicyMismatch,
            recoveryAction: .requireUserReapproval,
            nextAction: .recover,
            externalSigner: repair.externalSigner,
            ordinarySpendsBlocked: true,
            schemaProvenance: repair.schemaProvenance,
            consensusFingerprint: repair.consensusFingerprint,
            submissionPolicy: nil
        )
        XCTAssertEqual(try validate(firstBindSafe), firstBindSafe)

        let forgedAction = MigrationSnapshot(
            schemaVersion: repair.schemaVersion,
            revision: repair.revision,
            runId: repair.runId,
            accountUuid: repair.accountUuid,
            network: repair.network,
            mode: repair.mode,
            phase: repair.phase,
            state: repair.state,
            counts: repair.counts,
            intents: repair.intents,
            nextDueHeight: repair.nextDueHeight,
            nextExpiryHeight: repair.nextExpiryHeight,
            failureCode: repair.failureCode,
            recoveryAction: repair.recoveryAction,
            nextAction: .recover,
            externalSigner: repair.externalSigner,
            ordinarySpendsBlocked: repair.ordinarySpendsBlocked,
            schemaProvenance: repair.schemaProvenance,
            consensusFingerprint: repair.consensusFingerprint,
            submissionPolicy: nil
        )
        XCTAssertThrowsError(try validate(forgedAction))
    }

    func testSnapshotValidationAllowsPolicylessLegacyTerminalRuns() throws {
        let base = makeReadyToPrepareSnapshot()
        let terminalCounts = MigrationCounts(
            preparedLocked: 0,
            preparedSpentMigration: 0,
            preparedSpentExternal: 0,
            preparedReleased: 0,
            intentsPlanned: 0,
            intentsMaterializing: 0,
            intentsStaged: 0,
            intentsAwaitingSignature: 0,
            intentsRejected: 0,
            intentsInvalidated: 0,
            intentsFeeReapprovalRequired: 0,
            intentsPlanReapprovalRequired: 0,
            transfersScheduled: 0,
            transfersSubmitting: 0,
            transfersBroadcasted: 0,
            transfersConfirmed: 1,
            transfersTotal: 1
        )
        let complete = MigrationSnapshot(
            schemaVersion: base.schemaVersion,
            revision: 4,
            runId: base.runId,
            accountUuid: base.accountUuid,
            network: base.network,
            mode: .privateScheduled,
            phase: .complete,
            state: .complete,
            counts: terminalCounts,
            intents: [],
            nextDueHeight: nil,
            nextExpiryHeight: nil,
            failureCode: nil,
            recoveryAction: nil,
            nextAction: .none,
            externalSigner: false,
            ordinarySpendsBlocked: false,
            schemaProvenance: .compatible,
            consensusFingerprint: consensusFingerprint,
            submissionPolicy: nil
        )
        XCTAssertEqual(try validate(complete), complete)

        let abandoned = MigrationSnapshot(
            schemaVersion: base.schemaVersion,
            revision: 4,
            runId: base.runId,
            accountUuid: base.accountUuid,
            network: base.network,
            mode: .privateScheduled,
            phase: .abandoned,
            state: .notStarted,
            counts: MigrationCounts(
                preparedLocked: 0,
                preparedSpentMigration: 0,
                preparedSpentExternal: 0,
                preparedReleased: 0,
                intentsPlanned: 0,
                intentsMaterializing: 0,
                intentsStaged: 0,
                intentsAwaitingSignature: 0,
                intentsRejected: 0,
                intentsInvalidated: 0,
                intentsFeeReapprovalRequired: 0,
                intentsPlanReapprovalRequired: 0,
                transfersScheduled: 0,
                transfersSubmitting: 0,
                transfersBroadcasted: 0,
                transfersConfirmed: 0,
                transfersTotal: 0
            ),
            intents: [],
            nextDueHeight: nil,
            nextExpiryHeight: nil,
            failureCode: nil,
            recoveryAction: nil,
            nextAction: .awaitUserChoice,
            externalSigner: false,
            ordinarySpendsBlocked: false,
            schemaProvenance: .compatible,
            consensusFingerprint: consensusFingerprint,
            submissionPolicy: nil
        )
        XCTAssertEqual(try validate(abandoned), abandoned)
    }

    func testSnapshotValidationRejectsCompleteWithoutFullPositiveCrossingEvidence() throws {
        let runId = "00000000-0000-4000-8000-000000000001"
        func complete(counts: MigrationCounts, intents: [MigrationIntentSummary] = []) -> MigrationSnapshot {
            MigrationSnapshot(
                schemaVersion: MigrationSnapshot.supportedSchemaVersion,
                revision: 4,
                runId: runId,
                accountUuid: "00000000-0000-4000-8000-000000000007",
                network: "test",
                mode: .privateScheduled,
                phase: .complete,
                state: .complete,
                counts: counts,
                intents: intents,
                nextDueHeight: nil,
                nextExpiryHeight: nil,
                failureCode: nil,
                recoveryAction: nil,
                nextAction: .none,
                externalSigner: false,
                ordinarySpendsBlocked: false,
                schemaProvenance: .compatible,
                consensusFingerprint: consensusFingerprint,
                submissionPolicy: nil
            )
        }
        func counts(
            confirmed: UInt32,
            total: UInt32,
            invalidated: UInt32 = 0,
            preparedSpentExternal: UInt32 = 0
        ) -> MigrationCounts {
            MigrationCounts(
                preparedLocked: 0,
                preparedSpentMigration: 0,
                preparedSpentExternal: preparedSpentExternal,
                preparedReleased: 0,
                intentsPlanned: 0,
                intentsMaterializing: 0,
                intentsStaged: 0,
                intentsAwaitingSignature: 0,
                intentsRejected: 0,
                intentsInvalidated: invalidated,
                intentsFeeReapprovalRequired: 0,
                intentsPlanReapprovalRequired: 0,
                transfersScheduled: 0,
                transfersSubmitting: 0,
                transfersBroadcasted: 0,
                transfersConfirmed: confirmed,
                transfersTotal: total
            )
        }

        XCTAssertThrowsError(try validate(complete(counts: counts(confirmed: 0, total: 0)))) { error in
            XCTAssertEqual(
                error as? MigrationSnapshotValidationError,
                .invariantViolation("complete_has_full_positive_crossing_evidence")
            )
        }

        let invalidated = MigrationIntentSummary(
            id: "\(runId)-legacy-expired-42",
            sequenceIndex: 0,
            amount: 1,
            fee: 10_000,
            requiredFee: nil,
            notBeforeHeight: 100,
            targetWindowEndHeight: 120,
            materializedExpiryHeight: nil,
            status: .invalidated
        )
        XCTAssertThrowsError(
            try validate(complete(counts: counts(confirmed: 1, total: 1, invalidated: 1), intents: [invalidated]))
        ) { error in
            XCTAssertEqual(
                error as? MigrationSnapshotValidationError,
                .invariantViolation("complete_has_full_positive_crossing_evidence")
            )
        }

        XCTAssertThrowsError(
            try validate(complete(counts: counts(confirmed: 1, total: 1, preparedSpentExternal: 1)))
        ) { error in
            XCTAssertEqual(
                error as? MigrationSnapshotValidationError,
                .invariantViolation("complete_has_full_positive_crossing_evidence")
            )
        }
    }

    func testAbandonedExternalInvalidationDoesNotInventNextExpiry() throws {
        let runId = "00000000-0000-4000-8000-000000000001"
        let external = MigrationIntentSummary(
            id: "\(runId)-legacy-expired-42",
            sequenceIndex: 0,
            amount: 1,
            fee: 10_000,
            requiredFee: nil,
            notBeforeHeight: 100,
            targetWindowEndHeight: 120,
            materializedExpiryHeight: 140,
            status: .invalidatedExternal
        )
        let snapshot = MigrationSnapshot(
            schemaVersion: MigrationSnapshot.supportedSchemaVersion,
            revision: 5,
            runId: runId,
            accountUuid: "00000000-0000-4000-8000-000000000007",
            network: "test",
            mode: .privateScheduled,
            phase: .abandoned,
            state: .notStarted,
            counts: MigrationCounts(
                preparedLocked: 0,
                preparedSpentMigration: 0,
                preparedSpentExternal: 1,
                preparedReleased: 0,
                intentsPlanned: 0,
                intentsMaterializing: 0,
                intentsStaged: 0,
                intentsAwaitingSignature: 0,
                intentsRejected: 0,
                intentsInvalidated: 1,
                intentsFeeReapprovalRequired: 0,
                intentsPlanReapprovalRequired: 0,
                transfersScheduled: 0,
                transfersSubmitting: 0,
                transfersBroadcasted: 0,
                transfersConfirmed: 1,
                transfersTotal: 2
            ),
            intents: [external],
            nextDueHeight: nil,
            nextExpiryHeight: nil,
            failureCode: nil,
            recoveryAction: nil,
            nextAction: .awaitUserChoice,
            externalSigner: false,
            ordinarySpendsBlocked: false,
            schemaProvenance: .compatible,
            consensusFingerprint: consensusFingerprint,
            submissionPolicy: nil
        )

        XCTAssertEqual(try validate(snapshot), snapshot)
    }

    func testClaimModelsPreserveLeaseAndExactBytes() throws {
        let policyFingerprint = String(repeating: "1", count: 64)
        let claimed = try decode(
            ClaimedTx.self,
            """
            {"id":"intent-1","txid":"deadbeef","raw_pczt":[0,128,255],"attempt_token":"lease-1","lease_expires_at_ms":9007199254740991,"expiry_height":2881152,"submission_policy":{"policy":{"transport":"direct","endpoint_identity":"https://test.example:443","consensus_fingerprint":"\(consensusFingerprint)"},"policy_fingerprint":"\(policyFingerprint)","revision":1}}
            """
        )
        XCTAssertEqual(
            claimed,
            ClaimedTx(
                id: "intent-1",
                txid: "deadbeef",
                rawPczt: [0, 128, 255],
                attemptToken: "lease-1",
                leaseExpiresAtMs: 9_007_199_254_740_991,
                expiryHeight: 2_881_152,
                submissionPolicy: boundPolicy
            )
        )
        XCTAssertEqual(try roundTrip(claimed), claimed)

        XCTAssertThrowsError(try decode(
            ClaimedTx.self,
            "{\"id\":\"legacy\",\"txid\":\"deadbeef\",\"raw_pczt\":[1],\"attempt_token\":\"lease-old\",\"lease_expires_at_ms\":1234,\"expiry_height\":null}"
        ))

        let external = try decode(
            ClaimedTransferPCZT.self,
            """
            {"intent_id":"intent-2","raw_pczt":[80,67,90,84],"signer_token":"lease-2","lease_expires_at_ms":1234,"expiry_height":2881152,"submission_policy":{"policy":{"transport":"direct","endpoint_identity":"https://test.example:443","consensus_fingerprint":"\(consensusFingerprint)"},"policy_fingerprint":"\(policyFingerprint)","revision":1}}
            """
        )
        XCTAssertEqual(external.intentId, "intent-2")
        XCTAssertEqual(external.pczt, Pczt([80, 67, 90, 84]))
        XCTAssertEqual(external.signerToken, "lease-2")
        XCTAssertEqual(external.leaseExpiresAtMs, 1_234)
        XCTAssertEqual(external.expiryHeight, 2_881_152)
        XCTAssertEqual(try roundTrip(external), external)
    }

    func testExtractedTransactionCarriesRustComputedTxIDAndExactBytes() throws {
        let extracted = try decode(
            ExtractedTx.self,
            "{\"txid\":\"computed-id\",\"raw_tx\":[0,127,255],\"consensus_branch_id\":3268858036,\"expiry_height\":2881152}"
        )

        XCTAssertEqual(
            extracted,
            ExtractedTx(
                txid: "computed-id",
                rawTx: [0, 127, 255],
                consensusBranchId: 3_268_858_036,
                expiryHeight: 2_881_152
            )
        )
        XCTAssertEqual(try roundTrip(extracted), extracted)
    }

    func testMigrationProgressNullableHeight() throws {
        let decoded = try decode(
            MigrationProgress.self,
            "{\"completed_transfers\":0,\"total_transfers\":0,\"remaining_orchard\":0,\"next_transfer_ready_at_height\":null}"
        )
        XCTAssertNil(decoded.nextTransferReadyAtHeight)
    }

    func testNetworkPrivacyOptions() throws {
        XCTAssertEqual(
            try decode(NetworkPrivacyOptions.self, "{\"use_tor\":true,\"submission_endpoint\":null}"),
            NetworkPrivacyOptions(useTor: true, submissionEndpoint: nil)
        )
        XCTAssertEqual(
            try decode(NetworkPrivacyOptions.self, "{\"use_tor\":false,\"submission_endpoint\":\"https://lwd.example:9067\"}"),
            NetworkPrivacyOptions(useTor: false, submissionEndpoint: "https://lwd.example:9067")
        )
    }

    private func validate(_ snapshot: MigrationSnapshot) throws -> MigrationSnapshot {
        try snapshot.validated(
            accountUuid: snapshot.accountUuid,
            network: "test",
            consensusFingerprint: consensusFingerprint
        )
    }

    private func makeReadyToPrepareSnapshot(
        runId: String = "00000000-0000-4000-8000-000000000001",
        intents: [MigrationIntentSummary] = [],
        failureCode: MigrationFailureCode? = nil,
        recoveryAction: RecoveryAction? = nil,
        submissionPolicy: BoundSubmissionPolicy? = nil
    ) -> MigrationSnapshot {
        MigrationSnapshot(
            schemaVersion: MigrationSnapshot.supportedSchemaVersion,
            revision: 1,
            runId: runId,
            accountUuid: "00000000-0000-4000-8000-000000000007",
            network: "test",
            mode: .privateScheduled,
            phase: .readyToPrepare,
            state: .notStarted,
            counts: MigrationCounts(
                preparedLocked: 0,
                preparedSpentMigration: 0,
                preparedSpentExternal: 0,
                preparedReleased: 0,
                intentsPlanned: 0,
                intentsMaterializing: 0,
                intentsStaged: 0,
                intentsAwaitingSignature: 0,
                intentsRejected: 0,
                intentsInvalidated: 0,
                intentsFeeReapprovalRequired: 0,
                intentsPlanReapprovalRequired: 0,
                transfersScheduled: 0,
                transfersSubmitting: 0,
                transfersBroadcasted: 0,
                transfersConfirmed: 0,
                transfersTotal: 0
            ),
            intents: intents,
            nextDueHeight: nil,
            nextExpiryHeight: nil,
            failureCode: failureCode,
            recoveryAction: recoveryAction,
            nextAction: .preparePrivateSplit,
            externalSigner: false,
            ordinarySpendsBlocked: true,
            schemaProvenance: .compatible,
            consensusFingerprint: consensusFingerprint,
            submissionPolicy: submissionPolicy
        )
    }
}
