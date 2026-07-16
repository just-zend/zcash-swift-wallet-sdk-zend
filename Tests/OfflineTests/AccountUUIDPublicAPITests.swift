//
//  AccountUUIDPublicAPITests.swift
//  OfflineTests
//

import XCTest
import ZcashLightClientKit

final class AccountUUIDPublicAPITests: XCTestCase {
    func testPublicInitializerPreservesCanonicalDatabaseBytes() {
        let databaseBytes = Array(UInt8(0)..<UInt8(16))

        XCTAssertEqual(AccountUUID(id: databaseBytes).id, databaseBytes)
    }
}
