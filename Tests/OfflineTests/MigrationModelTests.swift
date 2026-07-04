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
    }

    func testTransferResultVariants() throws {
        XCTAssertEqual(try decode(TransferResult.self, "{\"Success\":{\"txid\":\"abc\"}}"), .success(txid: "abc"))
        XCTAssertEqual(try decode(TransferResult.self, "{\"NetworkError\":{\"retryable\":true}}"), .networkError(retryable: true))
        XCTAssertEqual(try decode(TransferResult.self, "\"InvalidNote\""), .invalidNote)
        XCTAssertEqual(try decode(TransferResult.self, "\"Expired\""), .expired)
        for value in [TransferResult.success(txid: "z"), .networkError(retryable: false), .invalidNote, .expired] {
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
}
