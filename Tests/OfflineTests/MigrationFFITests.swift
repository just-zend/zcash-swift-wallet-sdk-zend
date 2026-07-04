//
//  MigrationFFITests.swift
//  OfflineTests
//
//  Exercises the migration FFI marshalling + the empty-DB state machine through the real
//  ZcashRustBackend welding. The balance/signing paths need a seeded, synced wallet DB (a
//  documented integration gap), so they are not covered here.
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class MigrationFFITests: XCTestCase {
    var dbData: URL!
    var rustBackend: ZcashRustBackendWelding!
    let account = AccountUUID(id: [UInt8](repeating: 7, count: 16))

    override func setUp() {
        super.setUp()
        dbData = try! __dataDbURL()
        rustBackend = ZcashRustBackend.makeForTests(
            dbData: dbData,
            fsBlockDbRoot: Environment.uniqueTestTempDirectory,
            networkType: .testnet
        )
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: dbData!)
        rustBackend = nil
    }

    func testMigrationStateOnFreshWalletIsNotStarted() async throws {
        let state = try await rustBackend.migrationState(for: account)
        XCTAssertEqual(state, .notStarted)
    }

    func testMigrationProgressIsNilWhenNotStarted() async throws {
        let progress = try await rustBackend.migrationProgress(for: account)
        XCTAssertNil(progress)
    }

    func testInitializePostUpgradeSucceeds() async throws {
        try await rustBackend.migrationInitializePostUpgrade(for: account)
    }

    func testRecordTransferResultWithNoActiveRunThrows() async throws {
        do {
            try await rustBackend.migrationRecordTransferResult(
                transferId: "does-not-exist",
                result: .success(txid: "abc"),
                for: account
            )
            XCTFail("expected recording a result with no active migration run to throw")
        } catch {
            // The crate returns MigrationError::InvalidState -> null ptr -> rustMigrationRecordTransferResult.
        }
    }

    func testExtractBroadcastTxWithInvalidPcztThrows() async throws {
        do {
            _ = try await rustBackend.migrationExtractBroadcastTx(pczt: [0, 1, 2, 3], for: account)
            XCTFail("expected extracting a tx from invalid PCZT bytes to throw")
        } catch {
            // Invalid PCZT bytes -> crate deserialization error -> null ptr -> rustMigrationExtractBroadcastTx.
        }
    }

    func testStoreSignedNoteSplitPCZTWithNothingStagedThrows() async throws {
        do {
            _ = try await rustBackend.migrationStoreSignedNoteSplitPCZT(pczt: Pczt([0, 1, 2]), for: account)
            XCTFail("expected storing a signed split with nothing staged to throw")
        } catch {
            // No staged note-split PCZT -> MigrationError::InvalidState -> null ptr ->
            // rustMigrationStoreSignedNoteSplitPCZT.
        }
    }

    func testStoreSignedSchedulePCZTsWithNothingStagedThrows() async throws {
        do {
            try await rustBackend.migrationStoreSignedSchedulePCZTs(
                pczts: [MigrationTransferPCZT(id: "run-0", pczt: Pczt([1, 2, 3]))],
                for: account
            )
            XCTFail("expected storing signed transfers with nothing staged to throw")
        } catch {
            // No staged transfer PCZTs -> MigrationError::InvalidState -> null ptr ->
            // rustMigrationStoreSignedSchedulePCZTs.
        }
    }

    func testStoreSignedSchedulePCZTsWithEmptySetThrows() async throws {
        do {
            try await rustBackend.migrationStoreSignedSchedulePCZTs(pczts: [], for: account)
            XCTFail("expected storing an empty signed-transfer set to throw")
        } catch {
            // Empty set -> MigrationError::InvalidState -> null ptr -> rustMigrationStoreSignedSchedulePCZTs.
        }
    }

    func testCreateUnsignedTransferPCZTsWithEmptyScheduleThrows() async throws {
        // Round-trips the caller-provided schedule through the FFI's JSON marshalling into the
        // crate, which rejects an empty schedule before any PCZT work.
        do {
            _ = try await rustBackend.migrationCreateUnsignedTransferPCZTs(
                schedule: MigrationSchedule(transfers: [], estimatedDurationHours: 0),
                for: account
            )
            XCTFail("expected building PCZTs for an empty schedule to throw")
        } catch {
            // Empty schedule -> MigrationError::InvalidState -> null ptr ->
            // rustMigrationCreateUnsignedTransferPCZTs.
        }
    }
}
