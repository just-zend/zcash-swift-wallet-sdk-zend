//
//  OrchardMigrationCompositionTests.swift
//  OfflineTests
//
//  Actor-composition tests for `OrchardMigration`, driven through its internal injecting
//  initializer against `ZcashRustBackendWeldingMock` and a real, temp-file-backed
//  `MigrationSyncGate`. Claim-backed delivery composition lives in the runtime-model and
//  transaction-submitter suites; this file pins the actor's non-throwing sync-gate fallback.
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class OrchardMigrationCompositionTests: ZcashTestCase {
    private let accountA = AccountUUID(id: [UInt8](repeating: 0x33, count: 16))
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let buffer: TimeInterval = 600

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

    // MARK: - isSyncBlocked degrade path

    /// When the engine's overdue query throws, `isSyncBlocked` must degrade to the persisted
    /// gate-file (privacy-buffer) state rather than crash or propagate -- checked both with no gate
    /// file (unblocked) and with an active buffer (blocked), so the fallback is proven to actually
    /// read the file, not just swallow the error into a hardcoded answer.
    func testIsSyncBlockedDegradesToGateFileStateWhenWeldingHasOverdueThrows() async throws {
        welding.migrationHasOverdueTransfersForThrowableError = StubEngineError()
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        let blockedWithNoGateFile = await migration.isSyncBlocked()
        XCTAssertFalse(blockedWithNoGateFile)

        gate.markBroadcast()

        let blockedWithGateFile = await migration.isSyncBlocked()
        XCTAssertTrue(blockedWithGateFile)
    }

    // MARK: - Helpers

    private func makeMigration(broadcaster: any MigrationBroadcasting) -> OrchardMigration {
        OrchardMigration(
            welding: welding,
            accountUUID: accountA,
            broadcaster: broadcaster,
            syncGate: gate,
            logger: logger
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
            overdueProvider: { false },
            logger: logger
        )
    }

}
/// A generic, non-`ZcashError` failure for stubbing welding calls that must fail for reasons
/// unrelated to what a given test is actually asserting (e.g. an engine call the test never expects
/// to succeed but also never inspects the error from).
private struct StubEngineError: Error {}
