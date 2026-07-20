//
//  MigrationFFITests.swift
//  OfflineTests
//
//  Exercises the Orchard -> Ironwood migration FFI marshaling and the empty-DB state machine
//  through the real ZcashRustBackend welding, against a freshly initialized, never-synced wallet
//  database (no network, no scanning). Complements MigrationLogicTests.swift (pure logic, mocked
//  welding) and OrchardMigrationCompositionTests.swift (actor composition, mocked welding): this is
//  the one place the SDK's committed migration FFI (rust/src/migration.rs, welded in
//  ZcashRustBackend) is exercised through the real libzcashlc, so a marshaling regression (wrong
//  sentinel, wrong error mapping, wrong tag) shows up here rather than only downstream.
//
//  Ports Tests/OfflineTests/MigrationFFITests.swift from the michal/MOB-1455-ironwood-migration-
//  prototype-ffi branch (commit 86450d54) to the committed API: method names/signatures changed
//  (ZcashRustBackendWelding.migrationState(for:) etc.), MigrationTransferResult.success now takes
//  `txId:` (display-hex) rather than `txid:`, and there is no `migrationInitializePostUpgrade` in
//  the committed surface -- account creation now goes through the standard `createAccount` fixture
//  pattern instead.
//
//  The balance-bearing paths (note splitting, proposing/signing transfers) need a seeded, synced
//  wallet with a real Orchard balance -- a documented integration gap, consistent with every other
//  file under OfflineTests (no network, no lightwalletd) -- so they are not covered here.
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class MigrationFFITests: XCTestCase {
    var dbData: URL!
    var rustBackend: ZcashRustBackendWelding!
    var account: AccountUUID!
    var usk: UnifiedSpendingKey!

    override func setUp() async throws {
        try await super.setUp()

        dbData = try __dataDbURL()
        rustBackend = ZcashRustBackend.makeForTests(
            dbData: dbData,
            fsBlockDbRoot: Environment.uniqueTestTempDirectory,
            networkType: .testnet
        )

        let dbInit = try await rustBackend.initDataDb(seed: nil)
        guard case .success = dbInit else {
            XCTFail("Failed to initDataDb. Expected `.success`, got \(String(describing: dbInit))")
            return
        }

        // A real, created account -- mirroring ZcashRustBackendTests/IronwoodFFITests -- rather than
        // a bare, never-registered AccountUUID: some migration welding calls read the wallet schema
        // (via the engine's `open_wallet`), so the fixture needs an actual `accounts` row to be
        // representative of real usage, even though this specific empty-DB state machine happens not
        // to depend on it for most of the assertions below (see the throwing tests further down).
        let checkpointSource = CheckpointSourceFactory.fromBundle(for: .testnet)
        let treeState = checkpointSource.latestKnownCheckpoint().treeState()
        usk = try await rustBackend.createAccount(
            seed: Environment.seedBytes,
            treeState: treeState,
            recoverUntil: nil,
            name: "",
            keySource: nil
        )
        let accounts = try await rustBackend.listAccounts()
        account = try XCTUnwrap(accounts.first?.id)
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: dbData!)
        rustBackend = nil
        account = nil
        usk = nil
    }

    // MARK: - Empty-DB state machine

    func testFreshWalletMigrationStateIsNotStarted() async throws {
        let state = try await rustBackend.migrationState(for: account)
        XCTAssertEqual(state, MigrationState.notStarted)
    }

    func testFreshWalletMigrationProgressIsNil() async throws {
        let progress = try await rustBackend.migrationProgress(for: account)
        XCTAssertNil(progress)
    }

    func testFreshWalletHasNoOverdueTransfers() async throws {
        let hasOverdue = try await rustBackend.migrationHasOverdueTransfers(for: account)
        XCTAssertFalse(hasOverdue)
    }

    func testFreshWalletHasNoInvalidTransfers() async throws {
        let hasInvalid = try await rustBackend.migrationHasInvalidTransfers(for: account)
        XCTAssertFalse(hasInvalid)
    }

    func testFreshWalletHasNoNextDueTransfer() async throws {
        let nextDue = try await rustBackend.migrationNextDueTransfer(for: account)
        XCTAssertNil(nextDue)
    }

    /// Unlike `isNoteSplitNeeded`/`residualAfterMigration` (which read the spendable Orchard balance
    /// and so throw `NotSynced` on this never-synced fixture), `pendingTransferProposal` short-
    /// circuits to `Ok(None)` as soon as it sees no active migration run -- it never reaches the
    /// target-height read. So on a fresh db it marshals as a benign `nil` (a NULL pointer with no
    /// recorded last-error), not a throw: the pointer-sentinel analog of `nextDueTransfer`'s nil.
    func testFreshWalletHasNoPendingTransferProposal() async throws {
        let pending = try await rustBackend.migrationPendingTransferProposal(for: account)
        XCTAssertNil(pending)
    }

    /// `isNoteSplitNeeded` ultimately reads the spendable Orchard balance (the engine's
    /// `orchard_spendable` -> `pool_balances` -> `get_wallet_summary`), which requires a known chain
    /// tip (`scan_queue` populated by `updateChainTip`/scanning). This fixture never syncs, so
    /// `get_wallet_summary` returns `None` and the crate reports `MigrationError::NotSynced` rather
    /// than a legitimate "no split needed". Per t2-report's documented last-error-gated `bool`
    /// contract (a plain `false` overloads "no" and "error"), that surfaces on the Swift side as a
    /// thrown `rustMigrationIsNoteSplitNeeded`, not a benign `false` -- asserting the case (not the
    /// message), matching the brief's "false-or-throws" contract by nailing down which one it
    /// actually is for this fixture.
    func testFreshUnsyncedWalletIsNoteSplitNeededThrowsNotFalse() async throws {
        do {
            _ = try await rustBackend.migrationIsNoteSplitNeeded(for: account)
            XCTFail("Expected migrationIsNoteSplitNeeded to throw on an unsynced wallet (no chain tip)")
        } catch ZcashError.rustMigrationIsNoteSplitNeeded {
            // expected
        } catch {
            XCTFail("Expected rustMigrationIsNoteSplitNeeded but got \(error)")
        }
    }

    /// Same `NotSynced` root cause as `isNoteSplitNeeded` above: `residualAfterMigration` always
    /// reads the spendable Orchard balance, so on this never-synced fixture it throws rather than
    /// returning `nil`. This is the actual contract for a truly fresh (never-scanned) wallet; a
    /// wallet that has synced to its birthday with a zero balance would instead resolve `nil`, but
    /// establishing that state needs a real sync pipeline, out of scope for OfflineTests.
    func testFreshUnsyncedWalletResidualAfterMigrationThrows() async throws {
        do {
            _ = try await rustBackend.migrationResidualAfterMigration(for: account)
            XCTFail("Expected migrationResidualAfterMigration to throw on an unsynced wallet (no chain tip)")
        } catch ZcashError.rustMigrationResidualAfterMigration {
            // expected
        } catch {
            XCTFail("Expected rustMigrationResidualAfterMigration but got \(error)")
        }
    }

    // MARK: - Invalid-state transitions

    /// The crate refuses an empty schedule outright (before touching any wallet state), so this is a
    /// deterministic, sync-independent throw -- signing/storing "nothing" would advance the run into
    /// a post-schedule phase with no queued transfers, which the engine treats as invalid input.
    func testSignAndStoreEmptyScheduleThrows() async throws {
        let emptySchedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0)
        do {
            try await rustBackend.migrationSignAndStoreSchedule(emptySchedule, usk: usk, for: account)
            XCTFail("Expected signing an empty schedule to throw")
        } catch ZcashError.rustMigrationSignAndStoreSchedule {
            // expected
        } catch {
            XCTFail("Expected rustMigrationSignAndStoreSchedule but got \(error)")
        }
    }

    /// Ported from the prototype's `testRecordTransferResultWithNoActiveRunThrows`: recording a
    /// result against a transfer id with no active migration run throws
    /// `MigrationError::InvalidState(NoActiveRun)` -- a deterministic, sync-independent throw (this
    /// path never touches the wallet schema at all). Uses `.networkError` rather than `.success` to
    /// keep the test focused on the "no active run" contract, sidestepping the unrelated txid-hex
    /// validation `.success` carries (see `TxIdTests.testTxIdStringRoundTripsThroughRawBytesForAnAsymmetricFixture`
    /// / `testTxIdRawBytesRoundTripThroughDisplayHexStringForAnAsymmetricFixture` for the conversion
    /// helpers themselves, and
    /// `OrchardMigrationCompositionTests.testExecuteNextPendingTransferRecordsTheDocumentedByteOrderForAnAsymmetricTxId`
    /// for that validation exercised through this same welding record path).
    func testRecordTransferResultWithNoActiveRunThrows() async throws {
        do {
            try await rustBackend.migrationRecordTransferResult(
                transferId: "does-not-exist",
                result: MigrationTransferResult.networkError(retryable: true),
                for: account
            )
            XCTFail("Expected recording a result with no active migration run to throw")
        } catch ZcashError.rustMigrationRecordTransferResult {
            // expected
        } catch {
            XCTFail("Expected rustMigrationRecordTransferResult but got \(error)")
        }
    }

    /// Ported from the prototype's `testExtractBroadcastTxWithInvalidPcztThrows`: garbage PCZT bytes
    /// fail the crate's deserialization before any wallet-state check, so this is deterministic
    /// regardless of sync state.
    func testExtractBroadcastTxWithInvalidPcztThrows() async throws {
        do {
            _ = try await rustBackend.migrationExtractBroadcastTx(pczt: Data([0, 1, 2, 3]), for: account)
            XCTFail("Expected extracting a tx from invalid PCZT bytes to throw")
        } catch ZcashError.rustMigrationExtractBroadcastTx {
            // expected
        } catch {
            XCTFail("Expected rustMigrationExtractBroadcastTx but got \(error)")
        }
    }

    // MARK: - Marshaling determinism

    func testMigrationProgressNilIsStableAcrossRepeatedCalls() async throws {
        let first = try await rustBackend.migrationProgress(for: account)
        let second = try await rustBackend.migrationProgress(for: account)
        XCTAssertNil(first)
        XCTAssertEqual(first, second)
    }

    func testMigrationNextDueTransferNilIsStableAcrossRepeatedCalls() async throws {
        let first = try await rustBackend.migrationNextDueTransfer(for: account)
        let second = try await rustBackend.migrationNextDueTransfer(for: account)
        XCTAssertNil(first)
        XCTAssertEqual(first, second)
    }

    func testMigrationPendingTransferProposalNilIsStableAcrossRepeatedCalls() async throws {
        let first = try await rustBackend.migrationPendingTransferProposal(for: account)
        let second = try await rustBackend.migrationPendingTransferProposal(for: account)
        XCTAssertNil(first)
        XCTAssertEqual(first, second)
    }

    func testMigrationResidualAfterMigrationThrowIsStableAcrossRepeatedCalls() async throws {
        for _ in 0..<2 {
            do {
                _ = try await rustBackend.migrationResidualAfterMigration(for: account)
                XCTFail("Expected migrationResidualAfterMigration to throw on an unsynced wallet")
            } catch ZcashError.rustMigrationResidualAfterMigration {
                // expected, both times
            } catch {
                XCTFail("Expected rustMigrationResidualAfterMigration but got \(error)")
            }
        }
    }

    /// Guards against last-error-channel pollution across calls: a throwing ambiguous-bool-sentinel
    /// call (`isNoteSplitNeeded`, gated on `zcashlc_last_error_length()`) must not corrupt the next
    /// legitimate `false` answer from a DIFFERENT ambiguous-bool-sentinel call
    /// (`hasOverdueTransfers`, which never touches the wallet at all on a fresh db) sandwiched around
    /// it.
    func testHasOverdueTransfersIsUnaffectedByAPrecedingThrowFromIsNoteSplitNeeded() async throws {
        let before = try await rustBackend.migrationHasOverdueTransfers(for: account)
        XCTAssertFalse(before)

        do {
            _ = try await rustBackend.migrationIsNoteSplitNeeded(for: account)
            XCTFail("Expected migrationIsNoteSplitNeeded to throw on an unsynced wallet")
        } catch {
            // Expected; the specific case is asserted by
            // testFreshUnsyncedWalletIsNoteSplitNeededThrowsNotFalse above.
        }

        let after = try await rustBackend.migrationHasOverdueTransfers(for: account)
        XCTAssertFalse(after)
        XCTAssertEqual(before, after)
    }

    /// Complements the hygiene test above: that one covers a predecessor that itself throws (and so
    /// consumes/clears the FFI's last-error via `lastErrorMessage` on its own throw path). This one
    /// covers a predecessor that sets a last-error and returns *without ever throwing* --
    /// `ironwoodActivationHeight` mapping the FFI's `-1` sentinel to `nil` for a network id outside
    /// `{testnet, mainnet}` (`.regtest`) leaves that error unconsumed in the (thread-local) FFI error
    /// channel, pre-fix. A bool-sentinel migration call on a healthy, freshly initialized db must not
    /// misfire on it merely because it happens to run on the same thread afterward.
    func testABoolSentinelMigrationCallIsUnaffectedByAPrecedingUnconsumedIronwoodActivationHeightError() async throws {
        let staleProducerResult = ZcashRustBackend.ironwoodActivationHeight(networkType: .regtest)
        XCTAssertNil(staleProducerResult, "regtest has no fixed NU6.3 height; `-1` must still map to nil")

        let hasOverdue = try await rustBackend.migrationHasOverdueTransfers(for: account)
        XCTAssertFalse(hasOverdue)
    }
}
