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
}
