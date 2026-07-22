//
//  IronwoodFFITests.swift
//  OfflineTests
//
//  Exercises the Ironwood (Orchard note-version V3 / NU6.3) receive/sync welding through the real
//  ZcashRustBackend: the `putIronwoodSubtreeRoots` FFI and the `AccountBalance.ironwoodBalance` model
//  field. Detecting actual Ironwood notes / non-zero balances needs a lightwalletd that serves Ironwood
//  compact blocks and an activated NU6.3 network (a documented integration gap), so that is not covered.
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class IronwoodFFITests: XCTestCase {
    var dbData: URL!
    var rustBackend: ZcashRustBackendWelding!

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

    /// `putIronwoodSubtreeRoots` with an empty root set is a no-op that exercises the new
    /// `zcashlc_put_ironwood_subtree_roots` symbol end-to-end through the welding without needing a
    /// populated Ironwood commitment tree.
    func testPutIronwoodSubtreeRootsWithEmptyRootsSucceeds() async throws {
        _ = try await rustBackend.initDataDb(seed: nil)
        try await rustBackend.putIronwoodSubtreeRoots(startIndex: 0, roots: [])
    }

    /// The public `AccountBalance.ironwoodBalance` field holds and totals an Ironwood pool balance, and
    /// is `.zero` on the zero balance.
    func testAccountBalanceExposesIronwoodBalance() {
        let ironwood = PoolBalance(
            spendableValue: Zatoshi(5),
            changePendingConfirmation: Zatoshi(2),
            valuePendingSpendability: Zatoshi(1)
        )
        let balance = AccountBalance(
            saplingBalance: .zero,
            orchardBalance: .zero,
            ironwoodBalance: ironwood,
            unshielded: .zero
        )

        XCTAssertEqual(balance.ironwoodBalance, ironwood)
        XCTAssertEqual(balance.ironwoodBalance.total(), Zatoshi(8))
        XCTAssertEqual(AccountBalance.zero.ironwoodBalance, .zero)
    }

    /// `PoolBalance.lockedValue` participates in `total()` — the FFI balance contract is that the
    /// sum of the fields is the account's total, and locked value (e.g. the Orchard migration
    /// residual locked via `lockMigrationResidual`) leaves `spendableValue` without leaving the
    /// account. Fixtures that predate locking default it to `.zero`.
    func testPoolBalanceTotalIncludesLockedValue() {
        let balance = PoolBalance(
            spendableValue: Zatoshi(5),
            changePendingConfirmation: Zatoshi(2),
            valuePendingSpendability: Zatoshi(1),
            lockedValue: Zatoshi(7)
        )

        XCTAssertEqual(balance.lockedValue, Zatoshi(7))
        XCTAssertEqual(balance.total(), Zatoshi(15))
        XCTAssertEqual(PoolBalance.zero.lockedValue, .zero)
    }
}
