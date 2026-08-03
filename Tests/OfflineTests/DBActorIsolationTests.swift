//
//  DBActorIsolationTests.swift
//  OfflineTests
//
//  Pins the read/write split's one invariant that type-checking cannot: a read-only call
//  completes while `DBActor` is HELD. If someone re-adds `@DBActor` to a converted read, the
//  read queues behind the held actor and the expectation below times out — a deterministic
//  failure, not a flake. The holder BLOCKS ITS THREAD inside the actor on a semaphore the
//  test controls. The block being synchronous is the point: an `await` inside the actor is a
//  suspension point that RELEASES the actor (reentrancy, SE-0306) and would hold nothing.
//

import XCTest
import libzcashlc
@testable import TestUtils
@testable import ZcashLightClientKit

final class DBActorIsolationTests: XCTestCase {
    var dbData: URL!
    var rustBackend: ZcashRustBackendWelding!

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
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: dbData!)
        rustBackend = nil
    }

    func testBlockRateSamplesReadCompletesWhileDBActorIsHeld() async throws {
        // Deterministically occupy DBActor: the holder signals `entered` from INSIDE the
        // actor, then synchronously blocks its thread until the test signals release. From
        // `entered` until `release.signal()`, the actor is executing this one job and every
        // other `@DBActor` call queues behind it.
        let entered = XCTestExpectation(description: "holder entered DBActor")
        let release = DispatchSemaphore(value: 0)
        let holder = Task { @DBActor in
            entered.fulfill()
            release.wait()
        }
        await fulfillment(of: [entered], timeout: 5.0)

        // The read under test: must complete (value or throw — either proves it ran) while
        // the actor is still parked. Before the split lands this times out: the read is
        // `@DBActor` and queues behind the holder.
        let readCompleted = XCTestExpectation(description: "read completed while actor held")
        let backend = rustBackend!
        let reader = Task {
            _ = try? await backend.migrationBlockRateSamples(window: 100)
            readCompleted.fulfill()
        }

        await fulfillment(of: [readCompleted], timeout: 5.0)

        // Cleanup: release the actor, then settle both tasks so nothing outlives the test.
        release.signal()
        _ = await holder.value
        _ = await reader.value
    }
}
