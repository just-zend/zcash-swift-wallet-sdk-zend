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
    private static let immediateFee: UInt64 = 20_000

    func testRestoreUpgradesCanonicalOldOrchardTestnetWalletWithoutLosingState() async throws {
        let fixtureURL = try XCTUnwrap(TestDbBuilder.zend260Alpha6OrchardDataDbURL())
        try await assertCanonicalUpgrade(
            fixtureURL: fixtureURL,
            compactBlocks: try TestDbBuilder.zend260Alpha6OrchardCompactBlocks(),
            identifier: "testnet-restore",
            networkType: .testnet,
            saplingActivation: 280_000,
            ironwoodActivation: 4_134_000,
            walletMode: .restoreWallet
        )
    }

    func testExistingWalletUpgradesCanonicalOldOrchardMainnetWalletWithoutLosingState() async throws {
        let fixtureURL = try XCTUnwrap(TestDbBuilder.zend260Alpha6OrchardMainnetDataDbURL())
        try await assertCanonicalUpgrade(
            fixtureURL: fixtureURL,
            compactBlocks: try TestDbBuilder.zend260Alpha6OrchardMainnetCompactBlocks(),
            identifier: "mainnet-existing",
            networkType: .mainnet,
            saplingActivation: 419_200,
            ironwoodActivation: 3_428_143,
            walletMode: .existingWallet
        )
    }

    private func assertCanonicalUpgrade(
        fixtureURL: URL,
        compactBlocks: [ZcashCompactBlock],
        identifier: String,
        networkType: NetworkType,
        saplingActivation: BlockHeight,
        ironwoodActivation: BlockHeight,
        walletMode: WalletInitMode
    ) async throws {
        let fixtureStart = ironwoodActivation - 10
        let fixtureEndExclusive = ironwoodActivation + 11
        let dataDbURL = testTempDirectory.appendingPathComponent("old-orchard-wallet-\(identifier).sqlite")
        try FileManager.default.copyItem(at: fixtureURL, to: dataDbURL)

        let before = try Self.captureDurableState(at: dataDbURL)
        XCTAssertEqual(before.accountCount, 1)
        XCTAssertGreaterThan(before.addressCount, 0)
        XCTAssertEqual(before.orchardNoteCount, 1)
        XCTAssertEqual(
            before.scanQueue,
            "\(saplingActivation):\(fixtureStart):0,\(fixtureStart):\(fixtureEndExclusive):10"
        )
        try Self.assertCanonicalAddressNetwork(before.addressPayload, networkType: networkType)
        XCTAssertEqual(try Self.schemaObjectCount(containing: "ironwood", at: dataDbURL), 0)
        XCTAssertEqual(try Self.schemaObjectCount(prefix: "ext_ironwood_migration_", at: dataDbURL), 0)
        XCTAssertEqual(try Self.rawTransactionCount(at: dataDbURL), 0)

        let initializer = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory.appendingPathComponent("blocks-\(identifier)"),
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: dataDbURL,
            torDirURL: testTempDirectory.appendingPathComponent("tor-\(identifier)"),
            endpoint: LightWalletEndpointBuilder.default,
            network: ZcashNetworkBuilder.network(for: networkType),
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
            walletBirthday: fixtureStart,
            for: walletMode,
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
        XCTAssertEqual(afterPrepare.addressCount, before.addressCount)
        XCTAssertEqual(afterPrepare.addressPayload, before.addressPayload)
        XCTAssertEqual(afterPrepare.orchardNoteCount, 1)
        XCTAssertEqual(afterPrepare.orchardNotePayload, before.orchardNotePayload)
        let expectedScanQueue = [
            "\(saplingActivation):\(fixtureStart):0",
            "\(fixtureStart):\(ironwoodActivation):10",
            "\(ironwoodActivation):\(fixtureEndExclusive):20"
        ].joined(separator: ",")
        XCTAssertEqual(
            afterPrepare.scanQueue,
            expectedScanQueue
        )
        try Self.assertCanonicalAddressNetwork(afterPrepare.addressPayload, networkType: networkType)

        let currentAddress = try await synchronizer.getUnifiedAddress(accountUUID: Self.expectedAccount)
        XCTAssertNoThrow(try UnifiedAddress(encoding: currentAddress.stringEncoded, network: networkType))
        let otherNetwork: NetworkType = networkType == .mainnet ? .testnet : .mainnet
        XCTAssertThrowsError(try UnifiedAddress(encoding: currentAddress.stringEncoded, network: otherNetwork))

        XCTAssertEqual(try Self.schemaObjectCount(named: "ironwood_received_notes", at: dataDbURL), 1)
        XCTAssertEqual(try Self.schemaObjectCount(named: "ironwood_tree_shards", at: dataDbURL), 1)
        XCTAssertEqual(try Self.columnDefault(named: "note_version", in: "orchard_received_notes", at: dataDbURL), "2")
        XCTAssertEqual(try Self.noteVersion(at: dataDbURL), 2)
        try Self.assertCanonicalOrchardUniqueness(at: dataDbURL)

        let suggested = try await initializer.rustBackend.suggestScanRanges()
        XCTAssertEqual(suggested.count, 1)
        XCTAssertEqual(suggested.first?.range, ironwoodActivation ..< fixtureEndExclusive)
        XCTAssertEqual(suggested.first?.priority, .historic)
        let fullyScannedHeight = try await initializer.rustBackend.fullyScannedHeight()
        let maxScannedHeight = try await initializer.rustBackend.maxScannedHeight()
        XCTAssertEqual(fullyScannedHeight, ironwoodActivation - 1)
        XCTAssertEqual(maxScannedHeight, fixtureEndExclusive - 1)

        // Isolate librustzcash's witness eligibility from the SDK's separate startup guard,
        // which deliberately masks every spendable balance until a live chain tip is observed.
        await initializer.container.resolve(SDKFlags.self).markChainTipAsUpdated()
        let walletSummary = try await initializer.rustBackend.getWalletSummary()
        let summary = try XCTUnwrap(walletSummary)
        let accountBalance = try XCTUnwrap(summary.accountBalances[Self.expectedAccount])
        XCTAssertEqual(accountBalance.orchardBalance.total(), Self.orchardValue)
        // The schema migration introduces a historic Ironwood activation range. Until the next
        // synchronization scans that range, the open Orchard shard is not witness-complete under
        // current librustzcash rules. Total value must survive, but presenting it as immediately
        // spendable would race the required rescan.
        XCTAssertEqual(accountBalance.orchardBalance.spendableValue, .zero)
        XCTAssertEqual(accountBalance.ironwoodBalance.total(), .zero)

        try await synchronizer.initializePostUpgrade(for: Self.expectedAccount)
        let snapshot = try await synchronizer.migrationSnapshot(for: Self.expectedAccount)
        XCTAssertEqual(snapshot.schemaVersion, MigrationSnapshot.supportedSchemaVersion)
        XCTAssertEqual(snapshot.schemaProvenance, .compatible)
        XCTAssertEqual(snapshot.state, .notStarted)
        XCTAssertFalse(snapshot.ordinarySpendsBlocked)
        XCTAssertEqual(try Self.schemaObjectCount(prefix: "ext_ironwood_migration_", at: dataDbURL), 10)
        XCTAssertEqual(try Self.engineSchemaVersion(at: dataDbURL), MigrationSnapshot.supportedSchemaVersion)

        let engineRowsBeforePreview = try Self.engineRowCount(at: dataDbURL)
        let preview = try await synchronizer.previewImmediateMigration(for: Self.expectedAccount)
        XCTAssertEqual(preview, .noSpendableFunds)
        XCTAssertEqual(try Self.captureDurableState(at: dataDbURL), afterPrepare)
        XCTAssertEqual(try Self.engineRowCount(at: dataDbURL), engineRowsBeforePreview)
        let snapshotAfterPreview = try await synchronizer.migrationSnapshot(for: Self.expectedAccount)
        XCTAssertEqual(snapshotAfterPreview, snapshot)

        // A production synchronizer self-heals this expected waiting state by downloading and
        // scanning the Historic range. Replay the exact compact blocks that created the old
        // database through the real filesystem cache and current Rust scanner, without a server.
        XCTAssertEqual(compactBlocks.map(\.height), Array(fixtureStart ..< fixtureEndExclusive))
        try await initializer.storage.create()
        try await initializer.storage.write(blocks: compactBlocks)

        var priorTreeState = TreeState()
        priorTreeState.network = networkType == .mainnet ? "main" : "test"
        priorTreeState.height = UInt64(fixtureStart - 1)
        priorTreeState.hash = String(repeating: "0", count: 64)
        let scanSummary = try await initializer.rustBackend.scanBlocks(
            fromHeight: Int32(fixtureStart),
            fromState: priorTreeState,
            limit: UInt32(compactBlocks.count)
        )
        XCTAssertEqual(scanSummary.scannedRange, fixtureStart ..< fixtureEndExclusive)
        let healedSuggestedRanges = try await initializer.rustBackend.suggestScanRanges()
        let healedFullyScannedHeight = try await initializer.rustBackend.fullyScannedHeight()
        let healedMaxScannedHeight = try await initializer.rustBackend.maxScannedHeight()
        XCTAssertTrue(healedSuggestedRanges.isEmpty)
        XCTAssertEqual(healedFullyScannedHeight, fixtureEndExclusive - 1)
        XCTAssertEqual(healedMaxScannedHeight, fixtureEndExclusive - 1)
        XCTAssertEqual(try Self.captureDurableState(at: dataDbURL), before)

        let healedWalletSummary = try await initializer.rustBackend.getWalletSummary()
        let healedSummary = try XCTUnwrap(healedWalletSummary)
        let healedBalance = try XCTUnwrap(healedSummary.accountBalances[Self.expectedAccount])
        XCTAssertEqual(healedBalance.orchardBalance.total(), Self.orchardValue)
        XCTAssertEqual(healedBalance.orchardBalance.spendableValue, Self.orchardValue)
        XCTAssertEqual(healedBalance.orchardBalance.valuePendingSpendability, .zero)

        let healedPreview = try await synchronizer.previewImmediateMigration(for: Self.expectedAccount)
        guard case let .actionable(spendableBalance, migrationAmount, fee) = healedPreview else {
            return XCTFail("the canonical Orchard note must become actionable after its queued rescan")
        }
        let orchardSpendable = try XCTUnwrap(UInt64(exactly: Self.orchardValue.amount))
        XCTAssertEqual(spendableBalance, orchardSpendable)
        XCTAssertEqual(fee, Self.immediateFee)
        XCTAssertEqual(migrationAmount, orchardSpendable - Self.immediateFee)
        XCTAssertEqual(try Self.engineRowCount(at: dataDbURL), engineRowsBeforePreview)
        let healedSnapshot = try await synchronizer.migrationSnapshot(for: Self.expectedAccount)
        XCTAssertEqual(healedSnapshot, snapshot)

        // Both migration layers are restart-safe. A launch interrupted after either step can
        // repeat them without duplicating an account, note, scan range, or engine marker.
        let repeatedInit = try await initializer.rustBackend.initDataDb(seed: Self.fixtureSeed)
        XCTAssertEqual(repeatedInit, .success)
        try await synchronizer.initializePostUpgrade(for: Self.expectedAccount)
        XCTAssertEqual(try Self.captureDurableState(at: dataDbURL), before)
        XCTAssertEqual(try Self.engineMetaRowCount(at: dataDbURL), 1)
    }

    private struct DurableState: Equatable {
        let accountCount: Int64
        let accountPayload: String
        let addressCount: Int64
        let addressPayload: String
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
            addressCount: try scalarInt("SELECT COUNT(*) FROM addresses", in: db),
            addressPayload: try scalarString(
                """
                SELECT group_concat(entry, ';') FROM (
                    SELECT printf(
                        '%d|%d|%s|%s|%s|%d',
                        id, key_scope, coalesce(hex(diversifier_index_be), ''), address,
                        coalesce(cached_transparent_receiver_address, ''), receiver_flags
                    ) AS entry
                    FROM addresses ORDER BY id
                )
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

    private static func assertCanonicalAddressNetwork(
        _ payload: String,
        networkType: NetworkType
    ) throws {
        let otherNetwork: NetworkType = networkType == .mainnet ? .testnet : .mainnet
        for entry in payload.split(separator: ";") {
            let fields = entry.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 6 else {
                XCTFail("unexpected persisted address payload shape")
                continue
            }

            let address = String(fields[3])
            if address.hasPrefix("u") {
                XCTAssertNoThrow(try UnifiedAddress(encoding: address, network: networkType))
                XCTAssertThrowsError(try UnifiedAddress(encoding: address, network: otherNetwork))
            } else {
                XCTAssertNoThrow(try TransparentAddress(encoding: address, network: networkType))
                XCTAssertThrowsError(try TransparentAddress(encoding: address, network: otherNetwork))
            }

            let cachedTransparent = String(fields[4])
            if !cachedTransparent.isEmpty {
                XCTAssertNoThrow(
                    try TransparentAddress(encoding: cachedTransparent, network: networkType)
                )
                XCTAssertThrowsError(
                    try TransparentAddress(encoding: cachedTransparent, network: otherNetwork)
                )
            }
        }
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
