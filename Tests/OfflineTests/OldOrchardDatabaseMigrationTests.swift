//
//  OldOrchardDatabaseMigrationTests.swift
//  OfflineTests
//
//  End-to-end regression for the production upgrade path from Zend's pre-Ironwood SDK baseline.
//

import Foundation
import SQLite
@testable import TestUtils
import XCTest
@testable import ZcashLightClientKit

final class OldOrchardDatabaseMigrationTests: ZcashTestCase {
    private static let expectedAccount = AccountUUID(id: [
        0x67, 0x3a, 0x4e, 0x0e, 0xc2, 0x27, 0x46, 0x42,
        0x98, 0x64, 0x5e, 0xaf, 0x42, 0x5b, 0xe4, 0x2e
    ])
    private static let fixtureSeed = [UInt8](repeating: 0, count: 32)
    private static let orchardValue = Zatoshi(123_456_789)
    private static let ironwoodActivation = 4_134_000

    func testPrepareUpgradesCanonicalOldOrchardWalletWithoutLosingState() async throws {
        let fixtureURL = try XCTUnwrap(TestDbBuilder.zend260Alpha6OrchardDataDbURL())
        let dataDbURL = testTempDirectory.appendingPathComponent("old-orchard-wallet.sqlite")
        try FileManager.default.copyItem(at: fixtureURL, to: dataDbURL)

        let before = try Self.captureDurableState(at: dataDbURL)
        XCTAssertEqual(before.accountCount, 1)
        XCTAssertEqual(before.orchardNoteCount, 1)
        XCTAssertEqual(before.scanQueue, "100000:4133990:0,4133990:4134011:10")
        XCTAssertEqual(try Self.schemaObjectCount(containing: "ironwood", at: dataDbURL), 0)
        XCTAssertEqual(try Self.schemaObjectCount(prefix: "ext_ironwood_migration_", at: dataDbURL), 0)
        XCTAssertEqual(try Self.rawTransactionCount(at: dataDbURL), 0)

        let initializer = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory.appendingPathComponent("blocks"),
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: dataDbURL,
            torDirURL: testTempDirectory.appendingPathComponent("tor"),
            endpoint: LightWalletEndpointBuilder.default,
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: .tests,
            loggingPolicy: .noLogging,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )
        let synchronizer = SDKSynchronizer(initializer: initializer)

        let prepareResult = try await synchronizer.prepare(
            with: Self.fixtureSeed,
            walletBirthday: Self.ironwoodActivation - 10,
            for: .restoreWallet,
            name: "",
            keySource: nil
        )
        guard case .success = prepareResult else {
            return XCTFail("the exact old-wallet seed must satisfy current SDK prepare migrations")
        }

        let accounts = try await synchronizer.listAccounts()
        XCTAssertEqual(accounts.map(\.id), [Self.expectedAccount])

        let afterPrepare = try Self.captureDurableState(at: dataDbURL)
        XCTAssertEqual(afterPrepare.accountCount, 1)
        XCTAssertEqual(afterPrepare.accountPayload, before.accountPayload)
        XCTAssertEqual(afterPrepare.orchardNoteCount, 1)
        XCTAssertEqual(afterPrepare.orchardNotePayload, before.orchardNotePayload)
        XCTAssertEqual(
            afterPrepare.scanQueue,
            "100000:4133990:0,4133990:4134000:10,4134000:4134011:20"
        )

        XCTAssertEqual(try Self.schemaObjectCount(named: "ironwood_received_notes", at: dataDbURL), 1)
        XCTAssertEqual(try Self.schemaObjectCount(named: "ironwood_tree_shards", at: dataDbURL), 1)
        XCTAssertEqual(try Self.columnDefault(named: "note_version", in: "orchard_received_notes", at: dataDbURL), "2")
        XCTAssertEqual(try Self.noteVersion(at: dataDbURL), 2)
        try Self.assertCanonicalOrchardUniqueness(at: dataDbURL)

        let suggested = try await initializer.rustBackend.suggestScanRanges()
        XCTAssertEqual(suggested.count, 1)
        XCTAssertEqual(suggested.first?.range, Self.ironwoodActivation ..< 4_134_011)
        XCTAssertEqual(suggested.first?.priority, .historic)
        let fullyScannedHeight = try await initializer.rustBackend.fullyScannedHeight()
        let maxScannedHeight = try await initializer.rustBackend.maxScannedHeight()
        XCTAssertEqual(fullyScannedHeight, Self.ironwoodActivation - 1)
        XCTAssertEqual(maxScannedHeight, 4_134_010)

        let walletSummary = try await initializer.rustBackend.getWalletSummary()
        let summary = try XCTUnwrap(walletSummary)
        let accountBalance = try XCTUnwrap(summary.accountBalances[Self.expectedAccount])
        XCTAssertEqual(accountBalance.orchardBalance.total(), Self.orchardValue)
        XCTAssertEqual(accountBalance.ironwoodBalance.total(), .zero)

        try await synchronizer.initializePostUpgrade(for: Self.expectedAccount)
        let snapshot = try await synchronizer.migrationSnapshot(for: Self.expectedAccount)
        XCTAssertEqual(snapshot.schemaVersion, MigrationSnapshot.supportedSchemaVersion)
        XCTAssertEqual(snapshot.schemaProvenance, .compatible)
        XCTAssertEqual(snapshot.state, .notStarted)
        XCTAssertFalse(snapshot.ordinarySpendsBlocked)
        XCTAssertEqual(try Self.schemaObjectCount(prefix: "ext_ironwood_migration_", at: dataDbURL), 10)
        XCTAssertEqual(try Self.engineSchemaVersion(at: dataDbURL), MigrationSnapshot.supportedSchemaVersion)

        let orchardSpendable = try XCTUnwrap(UInt64(exactly: accountBalance.orchardBalance.spendableValue.amount))
        let engineRowsBeforePreview = try Self.engineRowCount(at: dataDbURL)
        let preview = try await synchronizer.previewImmediateMigration(for: Self.expectedAccount)
        switch preview {
        case let .actionable(spendableBalance, migrationAmount, fee):
            XCTAssertEqual(spendableBalance, orchardSpendable)
            XCTAssertEqual(migrationAmount + fee, spendableBalance)
            XCTAssertGreaterThan(migrationAmount, 0)
        case let .positiveBalanceAtOrBelowFee(spendableBalance, fee):
            XCTAssertEqual(spendableBalance, orchardSpendable)
            XCTAssertGreaterThan(spendableBalance, 0)
            XCTAssertLessThanOrEqual(spendableBalance, fee)
        case .noSpendableFunds:
            XCTAssertEqual(orchardSpendable, 0)
        }
        XCTAssertEqual(try Self.captureDurableState(at: dataDbURL), afterPrepare)
        XCTAssertEqual(try Self.engineRowCount(at: dataDbURL), engineRowsBeforePreview)
        let snapshotAfterPreview = try await synchronizer.migrationSnapshot(for: Self.expectedAccount)
        XCTAssertEqual(snapshotAfterPreview, snapshot)

        // Both migration layers are restart-safe. A launch interrupted after either step can
        // repeat them without duplicating an account, note, scan range, or engine marker.
        let repeatedInit = try await initializer.rustBackend.initDataDb(seed: Self.fixtureSeed)
        XCTAssertEqual(repeatedInit, .success)
        try await synchronizer.initializePostUpgrade(for: Self.expectedAccount)
        XCTAssertEqual(try Self.captureDurableState(at: dataDbURL), afterPrepare)
        XCTAssertEqual(try Self.engineMetaRowCount(at: dataDbURL), 1)
    }

    private struct DurableState: Equatable {
        let accountCount: Int64
        let accountPayload: String
        let orchardNoteCount: Int64
        let orchardNotePayload: String
        let scanQueue: String
    }

    private static func captureDurableState(at url: URL) throws -> DurableState {
        let db = try Connection(url.path)
        return DurableState(
            accountCount: try scalarInt("SELECT COUNT(*) FROM accounts", in: db),
            accountPayload: try scalarString(
                """
                SELECT printf(
                    '%s|%d|%d|%s|%s|%d',
                    hex(uuid), account_kind, hd_account_index, ufvk, uivk, birthday_height
                ) FROM accounts
                """,
                in: db
            ),
            orchardNoteCount: try scalarInt("SELECT COUNT(*) FROM orchard_received_notes", in: db),
            orchardNotePayload: try scalarString(
                """
                SELECT printf(
                    '%d|%d|%d|%s|%s|%s|%s|%d|%d',
                    transaction_id, action_index, value, hex(diversifier), hex(rho),
                    hex(rseed), hex(nf), is_change, commitment_tree_position
                ) FROM orchard_received_notes
                """,
                in: db
            ),
            scanQueue: try scalarString(
                """
                SELECT group_concat(entry, ',') FROM (
                    SELECT block_range_start || ':' || block_range_end || ':' || priority AS entry
                    FROM scan_queue ORDER BY block_range_start
                )
                """,
                in: db
            )
        )
    }

    private static func schemaObjectCount(named name: String, at url: URL) throws -> Int64 {
        let db = try Connection(url.path)
        return try scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE name = '\(name)'",
            in: db
        )
    }

    private static func schemaObjectCount(prefix: String, at url: URL) throws -> Int64 {
        let db = try Connection(url.path)
        return try scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name LIKE '\(prefix)%'",
            in: db
        )
    }

    private static func schemaObjectCount(containing fragment: String, at url: URL) throws -> Int64 {
        let db = try Connection(url.path)
        return try scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE '%\(fragment)%'",
            in: db
        )
    }

    private static func columnDefault(named column: String, in table: String, at url: URL) throws -> String {
        let db = try Connection(url.path)
        return try scalarString(
            "SELECT dflt_value FROM pragma_table_info('\(table)') WHERE name = '\(column)'",
            in: db
        )
    }

    private static func noteVersion(at url: URL) throws -> Int64 {
        let db = try Connection(url.path)
        return try scalarInt("SELECT note_version FROM orchard_received_notes", in: db)
    }

    private static func engineSchemaVersion(at url: URL) throws -> UInt32 {
        let db = try Connection(url.path)
        return UInt32(try scalarInt(
            "SELECT schema_version FROM ext_ironwood_migration_meta WHERE singleton = 1",
            in: db
        ))
    }

    private static func engineMetaRowCount(at url: URL) throws -> Int64 {
        let db = try Connection(url.path)
        return try scalarInt("SELECT COUNT(*) FROM ext_ironwood_migration_meta", in: db)
    }

    private static func engineRowCount(at url: URL) throws -> Int64 {
        let db = try Connection(url.path)
        return try scalarInt(
            """
            SELECT SUM(row_count) FROM (
                SELECT COUNT(*) AS row_count FROM ext_ironwood_migration_meta
                UNION ALL SELECT COUNT(*) FROM ext_ironwood_migration_runs
                UNION ALL SELECT COUNT(*) FROM ext_ironwood_migration_submission_policies
                UNION ALL SELECT COUNT(*) FROM ext_ironwood_migration_intent_drafts
                UNION ALL SELECT COUNT(*) FROM ext_ironwood_migration_intents
                UNION ALL SELECT COUNT(*) FROM ext_ironwood_migration_prepared_notes
                UNION ALL SELECT COUNT(*) FROM ext_ironwood_migration_prep_tx
                UNION ALL SELECT COUNT(*) FROM ext_ironwood_migration_pending_txs
                UNION ALL SELECT COUNT(*) FROM ext_ironwood_migration_staged_pczts
                UNION ALL SELECT COUNT(*) FROM ext_ironwood_migration_reorg_queue
            )
            """,
            in: db
        )
    }

    private static func rawTransactionCount(at url: URL) throws -> Int64 {
        let db = try Connection(url.path)
        return try scalarInt("SELECT COUNT(*) FROM transactions WHERE raw IS NOT NULL", in: db)
    }

    private static func assertCanonicalOrchardUniqueness(at url: URL) throws {
        let db = try Connection(url.path)
        XCTAssertThrowsError(try db.run(
            """
            INSERT INTO orchard_received_notes (
                transaction_id, action_index, account_id, diversifier, value,
                rho, rseed, nf, is_change, note_version
            ) SELECT
                transaction_id, action_index, account_id, X'00', 1,
                X'01', X'02', X'03', 0, 3
            FROM orchard_received_notes LIMIT 1
            """
        ))
    }

    private static func scalarInt(_ query: String, in db: Connection) throws -> Int64 {
        try XCTUnwrap(db.scalar(query) as? Int64)
    }

    private static func scalarString(_ query: String, in db: Connection) throws -> String {
        try XCTUnwrap(db.scalar(query) as? String)
    }
}
