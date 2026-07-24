//
//  MigrationLogicTests.swift
//  ZcashLightClientKitTests
//

import Combine
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// Pure-logic tests for the app-facing migration layer: sync-gate math and file round-trip,
/// endpoint resolution, broadcast-result mapping, and the reschedule accessor's delegation to the
/// migration welding. No network, no dataDb — every collaborator here is exercised in isolation.
final class MigrationLogicTests: ZcashTestCase {
    private let accountA = AccountUUID(id: [UInt8](repeating: 0x11, count: 16))
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let buffer: TimeInterval = 600
    private static let immediateMaximumGrossAmount = Zatoshi(100_000_000)
    private struct UnsafeImmediateFailureCase {
        let name: String
        let activeClaimKind: MigrationDeliveryClaimKind?
        let externallyExposed: Bool
        let hasSignedPCZT: Bool
        let hasExactTransaction: Bool
        let txid: Data?
        let lastError: MigrationDeliveryFailureReason?
    }
    private static let immediateOptions = MigrationNetworkPrivacyOptions(
        useTor: false,
        submissionEndpoint: LightWalletEndpoint(
            address: "submit.example",
            port: 9067,
            secure: true
        )
    )
    private static let uaString = """
    u1l9f0l4348negsncgr9pxd9d3qaxagmqv3lnexcplmufpq7muffvfaue6ksevfvd7wrz7xrvn95rc5zjtn7ugkmgh5rnxswmcj30y0pw52pn0zjvy38rn2esfgve64rj5pcmazxgpyuj
    """

    // MARK: - Gate math

    func testGateBlockedImmediatelyAfterMark() {
        // The +600 s buffer starts at `now`, so `now` itself is inside the blocked window.
        let resumeAt = referenceDate.addingTimeInterval(buffer)
        XCTAssertTrue(MigrationSyncGate.isBlocked(now: referenceDate, hasOverdue: false, resumeAt: resumeAt))
    }

    func testGateUnblocksAtExactlyBufferBoundary() {
        // At exactly `resumeAt` the buffer has elapsed: `now < resumeAt` is false.
        let resumeAt = referenceDate.addingTimeInterval(buffer)
        XCTAssertFalse(MigrationSyncGate.isBlocked(now: resumeAt, hasOverdue: false, resumeAt: resumeAt))
    }

    func testGateOverdueForcesBlockedEvenAfterBufferElapsed() {
        let resumeAt = referenceDate.addingTimeInterval(buffer)
        let afterBuffer = resumeAt.addingTimeInterval(1)
        XCTAssertTrue(MigrationSyncGate.isBlocked(now: afterBuffer, hasOverdue: true, resumeAt: resumeAt))
    }

    func testGateOverdueForcesBlockedWithoutAnyBuffer() {
        XCTAssertTrue(MigrationSyncGate.isBlocked(now: referenceDate, hasOverdue: true, resumeAt: nil))
    }

    func testGateCorruptOrMissingFileUnblockedWhenNoOverdue() {
        // Corrupt/missing file resolves to `resumeAt == nil`, which is "no gate".
        XCTAssertFalse(MigrationSyncGate.isBlocked(now: referenceDate, hasOverdue: false, resumeAt: nil))
    }

    // MARK: - Gate file round-trip

    func testGateFileRoundTripPersistsResumeAt() {
        let clock = TestClock(referenceDate)
        let gate = makeGate(account: accountA, clock: clock)

        gate.markBroadcast()

        XCTAssertEqual(gate.currentResumeAt(), referenceDate.addingTimeInterval(buffer))
        XCTAssertTrue(gate.currentlyBlocked(hasOverdue: false))
    }

    func testGateUnblocksOnceRealTimePassesTheBuffer() {
        let clock = TestClock(referenceDate)
        let gate = makeGate(account: accountA, clock: clock)

        gate.markBroadcast()
        // Advance the injected clock past the buffer; the persisted resumeAt is unchanged.
        clock.now = referenceDate.addingTimeInterval(buffer + 1)

        XCTAssertFalse(gate.currentlyBlocked(hasOverdue: false))
        XCTAssertTrue(gate.currentlyBlocked(hasOverdue: true))
    }

    func testCorruptFileAtInitReadsAsNoGate() throws {
        // Written BEFORE construction: finding 14's in-memory `resumeAt` cache is loaded from the
        // file exactly once, at init, so this is the only point at which corrupt content is parsed.
        let fileURL = testGeneralStorageDirectory.appendingPathComponent(MigrationSyncGate.fileName(accountUUID: accountA))
        try Data("not json at all".utf8).write(to: fileURL)

        let gate = makeGate(account: accountA, clock: TestClock(referenceDate))

        XCTAssertNil(gate.currentResumeAt())
        XCTAssertFalse(gate.currentlyBlocked(hasOverdue: false))
    }

    /// Finding 14: `currentResumeAt()`/`currentlyBlocked` read the in-memory `resumeAt` cache, not a
    /// fresh file read every call -- a write to the gate file from something other than this gate
    /// instance must not change what THIS instance reports until its OWN `markBroadcast()` updates
    /// the cache. Stands the violation up with a second `MigrationSyncGate` over the SAME file
    /// (deliberately breaking the documented single-writer assumption) so the write is genuinely
    /// out-of-band and genuinely observable if reads went to disk: a "read fresh every call"
    /// implementation would pick it up, a cached one will not. Was
    /// `testGateCorruptFileReadsAsNoGate` pre-finding-14, when every read re-parsed the file fresh;
    /// the corrupt-JSON coverage that test used to provide now lives in
    /// `testCorruptFileAtInitReadsAsNoGate` above (corrupt content is only ever parsed at init).
    func testCurrentResumeAtIgnoresAnOutOfBandFileChangeAfterInit() throws {
        let gate = makeGate(account: accountA, clock: TestClock(referenceDate))
        XCTAssertNil(gate.currentResumeAt(), "precondition: no buffer yet")

        // A second gate instance over the same account/directory (hence the same file) marks a fresh
        // broadcast -- a valid, non-nil resumeAt written out-of-band from the first gate's viewpoint.
        let otherProcessGate = makeGate(account: accountA, clock: TestClock(referenceDate))
        otherProcessGate.markBroadcast()

        XCTAssertNil(gate.currentResumeAt(), "an out-of-band file write after init must not change the cached answer")
        XCTAssertFalse(gate.currentlyBlocked(hasOverdue: false))
    }

    /// Finding 14: the in-memory `resumeAt` cache is loaded from the gate file once, at init -- a
    /// value persisted by an earlier gate instance (standing in for a previous process launch) must
    /// be honored by a fresh instance over the same file, before that fresh instance's own
    /// `markBroadcast()` ever runs.
    func testMemoryCacheHonorsAPreExistingFileValueAtInit() throws {
        let clock = TestClock(referenceDate)
        let firstLaunchGate = makeGate(account: accountA, clock: clock)
        firstLaunchGate.markBroadcast()
        let persistedResumeAt = try XCTUnwrap(firstLaunchGate.currentResumeAt())

        let secondLaunchGate = makeGate(account: accountA, clock: clock)

        XCTAssertEqual(secondLaunchGate.currentResumeAt(), persistedResumeAt)
        XCTAssertTrue(secondLaunchGate.currentlyBlocked(hasOverdue: false))
    }

    // MARK: - Storage provisioning (backup exclusion)

    /// Finding 15: the gate's storage directory must be excluded from backup, mirroring
    /// `SubmitPlanStore.connection()`'s handling of the same general-storage directory (schedule
    /// timing/heights must never leave the device via an iCloud/iTunes backup). The directory is
    /// created fresh (but NOT yet excluded) by `ZcashTestCase.setUp()`, so this also exercises the
    /// "directory already exists" re-provisioning path, not just first creation.
    func testGateInitExcludesItsStorageDirectoryFromBackup() throws {
        let resourceValuesBefore = try testGeneralStorageDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertNotEqual(resourceValuesBefore.isExcludedFromBackup, true, "precondition: not yet excluded")

        _ = makeGate(account: accountA, clock: TestClock(referenceDate))

        let resourceValuesAfter = try testGeneralStorageDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resourceValuesAfter.isExcludedFromBackup, true)
    }

    // MARK: - Ticker gated on subscribers

    /// Finding 14: the ticker must do zero periodic work with no subscriber attached, start
    /// evaluating on the first subscriber (0 -> 1), and stop again once the last one detaches (1 -> 0)
    /// -- the `overdueProvider` invocation count freezes rather than merely slowing down. A very
    /// short `tickInterval` keeps the "prove nothing fires" waits fast; unlike `now`, the ticker's
    /// inter-tick delay is real wall-clock sleep, not injected, so those two waits are real-time
    /// (mirrors the inverted-expectation style already used by
    /// `testStaleRecomputeIsDroppedInFavorOfAFresherPublishedValue` above).
    func testTickerTicksOnlyWhileSubscribed() async throws {
        let counter = CallCountingOverdueProvider()
        let tickedAtLeastTwice = expectation(description: "ticker evaluates at least twice while subscribed")
        let gate = MigrationSyncGate(
            directory: testGeneralStorageDirectory,
            accountUUID: accountA,
            bufferDuration: buffer,
            tickInterval: 0.02,
            overdueProvider: {
                let count = await counter.increment()
                if count == 2 { tickedAtLeastTwice.fulfill() }
                return false
            },
            logger: logger
        )

        // No subscriber yet: several tick intervals' worth of real time must produce zero calls.
        try await Task.sleep(nanoseconds: 200_000_000)
        let countBeforeSubscribing = await counter.count
        XCTAssertEqual(countBeforeSubscribing, 0, "the ticker must not run with no subscriber attached")

        // Attaching a subscriber starts evaluation.
        let cancellable = gate.blockedStream.sink { _ in }
        await fulfillment(of: [tickedAtLeastTwice], timeout: 2)

        // Detaching stops it: the invocation count must stop growing across a further quiet period.
        cancellable.cancel()
        // A tick may already be in flight at the moment of cancellation; let it settle before
        // snapshotting the count both sides of the quiet period.
        try await Task.sleep(nanoseconds: 50_000_000)
        let countAfterCancel = await counter.count
        try await Task.sleep(nanoseconds: 200_000_000)
        let countAfterQuietPeriod = await counter.count
        XCTAssertEqual(countAfterQuietPeriod, countAfterCancel, "the ticker must stop once the last subscriber detaches")
    }

    // MARK: - Blocked stream behavior (finding 13)

    /// Subscribe-time value, "unblocked" half: a fresh gate -- no gate file yet -- seeds `false` on
    /// the very first (synchronous, subscribe-time) emission. Complements
    /// `testBlockedStreamSubscribeTimeSeedIsTrueWhenAlreadyLiveInTheGateFileAtInit` below (the "blocked"
    /// half of the same behavior). Synchronous (not `async`): the assertion runs before the ticker
    /// (started by this very subscription) gets a chance to schedule its first recompute, so there is
    /// no race with the seed being the only value observed.
    func testBlockedStreamSubscribeTimeSeedIsFalseForAFreshGateWithNoBuffer() {
        let gate = makeGate(account: accountA, clock: TestClock(referenceDate))

        var received: [Bool] = []
        let cancellable = gate.blockedStream.sink { received.append($0) }
        defer { cancellable.cancel() }

        XCTAssertEqual(received, [false])
    }

    /// Subscribe-time value, "blocked" half: when the gate file already carries a live privacy buffer
    /// at init -- a second gate instance over a file a prior instance already wrote via
    /// `markBroadcast()`, standing in for a relaunch mid-buffer -- the very first (synchronous)
    /// emission is `true`, without waiting for any tick. Exercises `MigrationSyncGate`'s documented
    /// init-time seed (loads `cachedResumeAt` from the file once, then seeds `blockedSubject` from it)
    /// through the public `blockedStream`, complementing `testMemoryCacheHonorsAPreExistingFileValueAtInit`
    /// above (which checks the same init-time load via `currentResumeAt()`/`currentlyBlocked(hasOverdue:)`
    /// rather than the stream).
    func testBlockedStreamSubscribeTimeSeedIsTrueWhenAlreadyLiveInTheGateFileAtInit() {
        let clock = TestClock(referenceDate)
        let firstLaunchGate = makeGate(account: accountA, clock: clock)
        firstLaunchGate.markBroadcast()

        let secondLaunchGate = makeGate(account: accountA, clock: clock)
        var received: [Bool] = []
        let cancellable = secondLaunchGate.blockedStream.sink { received.append($0) }
        defer { cancellable.cancel() }

        XCTAssertEqual(received, [true])
    }

    /// Emission after `markBroadcast()`: a subscriber already attached before a broadcast must
    /// receive the fresh `true` value promptly, without waiting for the periodic ticker -- pinned by
    /// using a `tickInterval` far longer than the test's timeout, so only `markBroadcast()`'s own
    /// `recomputeAsync()` call (never a coincidental tick) can possibly deliver it.
    ///
    /// Canary (R3-D report): commenting out `recomputeAsync()` inside `markBroadcast()` makes this
    /// test time out and fail red, since with that line gone nothing would ever publish a fresh value
    /// before the next tick 3600 s away.
    func testBlockedStreamEmitsTrueAfterMarkBroadcastWithoutWaitingForATick() async throws {
        let clock = TestClock(referenceDate)
        let gate = MigrationSyncGate(
            directory: testGeneralStorageDirectory,
            accountUUID: accountA,
            bufferDuration: buffer,
            // Long enough that no real tick can plausibly fire during this test's timeout below.
            tickInterval: 3600,
            now: { clock.now },
            overdueProvider: { false },
            logger: logger
        )

        var received: [Bool] = []
        let trueReceivedWithNoTick = expectation(description: "true received promptly after markBroadcast, with no tick possible")
        let cancellable = gate.blockedStream.sink { value in
            received.append(value)
            if value { trueReceivedWithNoTick.fulfill() }
        }
        defer { cancellable.cancel() }
        XCTAssertEqual(received, [false], "precondition: fresh gate seeds false")

        gate.markBroadcast()

        await fulfillment(of: [trueReceivedWithNoTick], timeout: 5)
        XCTAssertEqual(received, [false, true])
    }

    /// Tick re-evaluation, "overdue flips on" half: the ticker's OWN periodic re-evaluation -- not a
    /// `markBroadcast()` -- must pick up an `overdueProvider` answer that flips from `false` to `true`
    /// between ticks. `GatedOverdueProvider` (already used by
    /// `testStaleRecomputeIsDroppedInFavorOfAFresherPublishedValue` above) pre-queues both ticks'
    /// answers so each `next()` call resolves immediately -- no suspension, no `Task.sleep` in this
    /// test -- while the real (short) `tickInterval` is what actually paces the two ticks.
    func testBlockedStreamTickEmitsTrueAfterOverdueProviderFlipsFromFalseToTrue() async throws {
        let provider = GatedOverdueProvider()
        await provider.queue(false) // generation 1 (the ticker's startup recompute): agrees with the seed
        await provider.queue(true) // generation 2 (the next tick): the flip
        let fixedNow = referenceDate
        let gate = MigrationSyncGate(
            directory: testGeneralStorageDirectory,
            accountUUID: accountA,
            bufferDuration: buffer,
            tickInterval: 0.02,
            now: { fixedNow },
            overdueProvider: { await provider.next() },
            logger: logger
        )

        var received: [Bool] = []
        let trueReceived = expectation(description: "a tick observed the overdueProvider flip to true")
        let cancellable = gate.blockedStream.sink { value in
            received.append(value)
            if value { trueReceived.fulfill() }
        }
        defer { cancellable.cancel() }

        await fulfillment(of: [trueReceived], timeout: 5)
        XCTAssertEqual(received, [false, true])
    }

    /// Tick re-evaluation, "buffer expires" half: with a live buffer already seeded at subscribe time
    /// (so the gate reads `true`) and nothing ever overdue, advancing the INJECTED clock past the
    /// persisted `resumeAt` must have the next tick re-evaluate to `false`. Uses a fresh gate over a
    /// file a prior instance already wrote via `markBroadcast()` (rather than calling
    /// `markBroadcast()` on the gate under test) precisely so the `true` -> `false` transition
    /// observed here is unambiguously a TICK's doing, not another `markBroadcast()`-triggered
    /// recompute -- that path is `testBlockedStreamEmitsTrueAfterMarkBroadcastWithoutWaitingForATick`
    /// above.
    func testBlockedStreamTickEmitsFalseOnceTheInjectedClockPassesBufferExpiry() async throws {
        let clock = TestClock(referenceDate)
        let firstLaunchGate = makeGate(account: accountA, clock: clock)
        firstLaunchGate.markBroadcast()

        let gate = MigrationSyncGate(
            directory: testGeneralStorageDirectory,
            accountUUID: accountA,
            bufferDuration: buffer,
            tickInterval: 0.02,
            now: { clock.now },
            overdueProvider: { false },
            logger: logger
        )

        var received: [Bool] = []
        let falseAfterExpiry = expectation(description: "a tick re-evaluates false once the buffer has expired")
        let cancellable = gate.blockedStream.sink { value in
            received.append(value)
            if value == false { falseAfterExpiry.fulfill() }
        }
        defer { cancellable.cancel() }
        XCTAssertEqual(received, [true], "precondition: the live buffer seeds true at subscribe time")

        // Advance the injected clock past the persisted resumeAt; nothing is overdue, so the next
        // tick must re-evaluate to false.
        clock.now = referenceDate.addingTimeInterval(buffer + 1)

        await fulfillment(of: [falseAfterExpiry], timeout: 5)
        XCTAssertEqual(received, [true, false])
    }

    /// Duplicate collapse: several ticks that all agree with the already-published value must not
    /// produce any additional emissions -- pins `.removeDuplicates()` in `blockedStream`'s pipeline.
    /// Reuses `CallCountingOverdueProvider` (already used by `testTickerTicksOnlyWhileSubscribed`
    /// above) to prove multiple recomputes actually ran, rather than merely that nothing arrived
    /// because nothing ticked.
    func testBlockedStreamCollapsesConsecutiveIdenticalTickEvaluationsIntoNoExtraEmissions() async throws {
        let counter = CallCountingOverdueProvider()
        let tickedAtLeastThreeTimes = expectation(description: "the ticker evaluates at least three times")
        let fixedNow = referenceDate
        let gate = MigrationSyncGate(
            directory: testGeneralStorageDirectory,
            accountUUID: accountA,
            bufferDuration: buffer,
            tickInterval: 0.02,
            now: { fixedNow },
            overdueProvider: {
                let count = await counter.increment()
                if count == 3 { tickedAtLeastThreeTimes.fulfill() }
                // No buffer, never overdue: every tick agrees with the fresh-gate seed.
                return false
            },
            logger: logger
        )

        var received: [Bool] = []
        let cancellable = gate.blockedStream.sink { received.append($0) }
        defer { cancellable.cancel() }
        XCTAssertEqual(received, [false], "precondition: fresh gate seeds false")

        await fulfillment(of: [tickedAtLeastThreeTimes], timeout: 5)

        XCTAssertEqual(received, [false], "three ticks agreeing with the seed must not add any emissions")
    }

    // MARK: - Concurrent send serialization

    /// Reproduces finding 7's race directly: the ticker's very first recompute -- generation 1,
    /// started by subscribing below (finding 14 gates the ticker on the first subscriber; it no
    /// longer starts at construction) -- is held suspended in `overdueProvider`, standing in for "a
    /// tick suspended when a broadcast lands", while a second, later-started `markBroadcast()`-
    /// triggered recompute resolves immediately and publishes a fresher value. Releasing the stale
    /// first recompute (with an answer engineered to compute a *different* `blocked` value, so
    /// `removeDuplicates()` can't accidentally be the thing hiding the bug) must not publish a third,
    /// stale emission: latest-wins, and a recompute that started earlier but finishes later is
    /// dropped.
    func testStaleRecomputeIsDroppedInFavorOfAFresherPublishedValue() async throws {
        let clock = TestClock(referenceDate)
        let provider = GatedOverdueProvider()
        let gate = MigrationSyncGate(
            directory: testGeneralStorageDirectory,
            accountUUID: accountA,
            bufferDuration: buffer,
            // Long enough that only the ticker's own startup recompute fires during this test.
            tickInterval: 3600,
            now: { clock.now },
            overdueProvider: { await provider.next() },
            logger: logger
        )

        var received: [Bool] = []
        let freshValuePublished = expectation(description: "fresher value published")
        let noStaleValuePublished = expectation(description: "a stale third value must not publish")
        noStaleValuePublished.isInverted = true
        // Subscribing is what starts the ticker (finding 14): this kicks off generation 1, which
        // immediately suspends in `overdueProvider` below.
        let cancellable = gate.blockedStream.sink { value in
            received.append(value)
            if received.count == 2 { freshValuePublished.fulfill() }
            if received.count >= 3 { noStaleValuePublished.fulfill() }
        }
        defer { cancellable.cancel() }

        // Generation 1 is now in flight (started by the subscription above): wait for it to be
        // suspended in `overdueProvider`, unresolved, until we explicitly release it below.
        await provider.waitUntilWaiting()

        // Generation 2: queued ahead of time, so `next()` returns immediately (no suspension) and
        // this recompute -- started AFTER generation 1 -- finishes and publishes FIRST.
        await provider.queue(true)
        gate.markBroadcast()

        await fulfillment(of: [freshValuePublished], timeout: 5)
        XCTAssertEqual(received, [false, true])

        // Advance the clock past the buffer `markBroadcast()` just started, so generation 1's
        // eventual answer (`hasOverdue: false`) computes to `false` -- different from generation 2's
        // published `true` -- rather than being incidentally deduplicated to the same value.
        clock.now = referenceDate.addingTimeInterval(buffer + 1)

        // Release the stale generation-1 call. Pre-fix this publishes a third, stale `false`;
        // post-fix it is dropped (generation 1 < the already-published generation 2).
        await provider.resolveOldestWaiting(false)

        await fulfillment(of: [noStaleValuePublished], timeout: 0.5)
        XCTAssertEqual(received, [false, true])
    }

    // MARK: - Lock split regression (deadlock on synchronous cancel during publish)

    /// Regression for the reviewer's Important finding on the sync-gate lock split: a `blockedStream`
    /// subscriber that cancels *synchronously*, from inside its own `receiveValue` handler, in
    /// response to a value delivered through `publish(_:generation:)` (a `markBroadcast()`-triggered
    /// emission -- NOT the synchronous subscribe-time seed, which bypasses `publish(_:generation:)`
    /// entirely) drives Combine's `receiveCancel` synchronously on the SAME thread, still inside
    /// `publish`'s lock critical section around `blockedSubject.send(_:)`. Before the lock split this
    /// was a single `sendLock`: `subscriberDetached()`'s re-entrant `lock()` on that same,
    /// already-held, non-recursive `NSLock` deadlocked the thread and left the lock forever held,
    /// wedging the whole gate -- every later `currentResumeAt()` / `currentlyBlocked()` /
    /// `markBroadcast()` / subscribe would hang too. After the split, `subscriberDetached()` only
    /// ever touches `subscriptionLock`, a separate, uncontended lock, so the re-entrant call during
    /// `send` no longer contends anything `publish()` holds.
    ///
    /// The risky calls run on a background `Task`, gated by expectations fulfilled from inside the
    /// relevant closures, with the outer `fulfillment` below as the single bound on the whole
    /// scenario: pre-fix, the synchronous `cancel()` deadlocks that Task's thread permanently, so
    /// nothing after it -- including the second `markBroadcast()`, which needs the very same
    /// still-held lock -- ever runs. The outer wait still times out cleanly rather than hanging the
    /// test itself, because it only watches an `XCTestExpectation` object, independent of whether the
    /// Task that would fulfill it is stuck. No wall sleeps anywhere.
    func testSubscriberCancellingSynchronouslyDuringAPublishDoesNotWedgeTheGate() async throws {
        let gate = makeGate(account: accountA, clock: TestClock(referenceDate))

        var cancellable: AnyCancellable?
        var received: [Bool] = []
        let publishedValueCancelledSynchronously = expectation(
            description: "the markBroadcast-triggered value was received and its synchronous cancel completed"
        )
        cancellable = gate.blockedStream.sink { value in
            received.append(value)
            // The seed (subscribe-time) value is delivered outside `publish(_:generation:)` and is
            // deterministically `false` here (fresh gate, no resumeAt yet) -- only a `true` value can
            // be the `markBroadcast()`-triggered publish this test targets.
            if value {
                cancellable?.cancel()
                publishedValueCancelledSynchronously.fulfill()
            }
        }
        XCTAssertEqual(received, [false], "precondition: the synchronous seed must be the unblocked value")

        let secondSubscriberReceivedAValue = expectation(description: "a new subscriber after the scenario still receives a value")
        let scenarioCompleted = expectation(description: "gate remains usable after the cancel-during-publish scenario")

        Task {
            // Triggers a recompute that publishes `true` (a live resumeAt now exists); the
            // synchronous cancel above fires from inside that publish's `send`.
            gate.markBroadcast()

            // Pre-fix this never fires: the sink's `receiveValue` is stuck inside
            // `cancellable?.cancel()` -> `subscriberDetached()` re-locking the same lock `publish()`
            // is still holding.
            await self.fulfillment(of: [publishedValueCancelledSynchronously], timeout: 5)
            XCTAssertEqual(received, [false, true])

            // The gate must not be wedged: a fresh `markBroadcast()` plus a brand-new subscriber must
            // still work. Pre-fix, the lock is left permanently held by the deadlocked cancel above,
            // so this direct, synchronous call would hang right here too.
            gate.markBroadcast()
            _ = gate.blockedStream.sink { _ in secondSubscriberReceivedAValue.fulfill() }
            await self.fulfillment(of: [secondSubscriberReceivedAValue], timeout: 5)

            scenarioCompleted.fulfill()
        }

        await fulfillment(of: [scenarioCompleted], timeout: 15)
    }

    // MARK: - Tor client bootstrap caching

    /// Reproduces finding 8 directly: two concurrent `useTor` bootstraps must await the SAME cached
    /// `Task` rather than each racing an independent `TorClient` construction against the shared
    /// `migration_tor` directory. A gated factory pins it deterministically: held suspended until
    /// both callers have reached `dedicatedTorClient()`, then released once -- if the cache were
    /// bypassed, the second caller would have driven a second, independent factory invocation
    /// before the first could even resolve. Drives the internal `dedicatedTorClient()` seam directly
    /// (rather than the full `broadcast()`) so this stays an offline test: once the factory resolves
    /// successfully, a real `TorClient` would need actual FFI/network I/O for anything beyond this
    /// bootstrap step.
    func testConcurrentTorBootstrapsShareASingleFactoryInvocation() async throws {
        let factory = GatedTorClientFactory()
        let broadcaster = MigrationBroadcaster(
            torDirURL: testGeneralStorageDirectory,
            logger: logger,
            torClientFactory: factory.make
        )

        let first = Task { try await broadcaster.dedicatedTorClient() }
        await factory.awaitCallsStarted(1)
        let second = Task { try await broadcaster.dedicatedTorClient() }
        // Scheduling aid only (correctness must not depend on it): give the second caller ample
        // opportunity to reach the actor while the first bootstrap is still in flight.
        for _ in 0..<50 {
            await Task.yield()
        }
        await factory.resolve()

        _ = try await first.value
        _ = try await second.value

        let callCount = await factory.callCount
        XCTAssertEqual(callCount, 1, "two concurrent useTor bootstraps must await the same cached Task")
    }

    /// The failure half: a bootstrap failure is observed by every concurrent caller of that SAME
    /// attempt -- both throw `migrationTorUnavailable`, driven through the public `broadcast` entry
    /// point so the fail-closed wrapping is exercised too -- but clears the cache so a LATER,
    /// non-concurrent broadcast retries with a fresh bootstrap instead of replaying the same cached
    /// failure forever.
    func testTorBootstrapFailureIsSharedByConcurrentCallersThenClearsForALaterRetry() async throws {
        let factory = GatedTorClientFactory()
        let broadcaster = MigrationBroadcaster(
            torDirURL: testGeneralStorageDirectory,
            logger: logger,
            torClientFactory: factory.make
        )
        let endpoint = LightWalletEndpoint(address: "default.example", port: 9067)

        let first = Task {
            try await broadcaster.broadcast(rawTransaction: Data([0x01]), to: endpoint, useTor: true)
        }
        await factory.awaitCallsStarted(1)
        let second = Task {
            try await broadcaster.broadcast(rawTransaction: Data([0x02]), to: endpoint, useTor: true)
        }
        for _ in 0..<50 {
            await Task.yield()
        }
        await factory.resolve(throwing: StubTorBootstrapError())

        await assertThrowsMigrationTorUnavailable(first)
        await assertThrowsMigrationTorUnavailable(second)

        let callCountAfterFailure = await factory.callCount
        XCTAssertEqual(callCountAfterFailure, 1, "the failing bootstrap must be shared by both concurrent callers")

        do {
            _ = try await broadcaster.broadcast(rawTransaction: Data([0x03]), to: endpoint, useTor: true)
            XCTFail("Expected migrationTorUnavailable to be thrown")
        } catch ZcashError.migrationTorUnavailable {
            // expected
        } catch {
            XCTFail("Expected migrationTorUnavailable but got \(error)")
        }

        let callCountAfterRetry = await factory.callCount
        XCTAssertEqual(callCountAfterRetry, 2, "a later broadcast must retry with a fresh bootstrap, not replay the cached failure")
    }

    private func assertThrowsMigrationTorUnavailable(_ task: Task<MigrationBroadcastOutcome, Error>) async {
        do {
            _ = try await task.value
            XCTFail("Expected migrationTorUnavailable to be thrown")
        } catch ZcashError.migrationTorUnavailable {
            // expected
        } catch {
            XCTFail("Expected migrationTorUnavailable but got \(error)")
        }
    }

    // MARK: - Result mapping table

    func testMapTransportErrorIsRetryableNetworkError() {
        XCTAssertEqual(
            MigrationBroadcaster.map(outcome: .transportError, successTxId: "unused"),
            MigrationTransferResult.networkError(retryable: true)
        )
    }

    func testMapGenericRejectionIsInvalidNote() {
        XCTAssertEqual(
            MigrationBroadcaster.map(outcome: .rejected(errorCode: -25, message: "missing inputs"), successTxId: "unused"),
            MigrationTransferResult.invalidNote
        )
    }

    func testMapExpiringSoonRejectionIsExpired() {
        XCTAssertEqual(
            MigrationBroadcaster.map(outcome: .rejected(errorCode: -26, message: "tx-expiring-soon"), successTxId: "unused"),
            MigrationTransferResult.expired
        )
    }

    func testMapExpiredRejectionIsCaseInsensitive() {
        XCTAssertEqual(
            MigrationBroadcaster.map(outcome: .rejected(errorCode: -1, message: "Transaction has EXPIRED"), successTxId: "unused"),
            MigrationTransferResult.expired
        )
    }

    func testMapSuccessCarriesProvidedTxId() {
        XCTAssertEqual(
            MigrationBroadcaster.map(outcome: .submitted, successTxId: "aabbccdd"),
            MigrationTransferResult.success(txId: "aabbccdd")
        )
    }

    // MARK: - Result mapping table: duplicate re-submissions

    /// A rejection carrying zcashd's "already known" RPC code means the transaction landed on a
    /// previous attempt: it must map to success (with the prepared transfer's txid), not to a dead-end
    /// `invalidNote`, regardless of the message text.
    func testMapDuplicateRejectionByErrorCodeIsSuccessWithTxId() {
        XCTAssertEqual(
            MigrationBroadcaster.map(
                outcome: .rejected(errorCode: -27, message: "transaction verification failed"),
                successTxId: "feedface"
            ),
            MigrationTransferResult.success(txId: "feedface")
        )
    }

    /// Every known duplicate-rejection message variant maps to success, independently of the error
    /// code (here a non-duplicate code, so only the message can classify).
    func testMapDuplicateRejectionByEachKnownMessageIsSuccessWithTxId() {
        let duplicateMessages = [
            "transaction already in block chain",
            "already in blockchain",
            "18: txn-already-in-mempool",
            "transaction is already in mempool",
            "257: txn-already-known"
        ]

        for message in duplicateMessages {
            XCTAssertEqual(
                MigrationBroadcaster.map(outcome: .rejected(errorCode: -26, message: message), successTxId: "aabbccdd"),
                MigrationTransferResult.success(txId: "aabbccdd"),
                "expected duplicate message \"\(message)\" to map to success"
            )
        }
    }

    func testMapDuplicateRejectionMessageMatchIsCaseInsensitive() {
        XCTAssertEqual(
            MigrationBroadcaster.map(
                outcome: .rejected(errorCode: -26, message: "Transaction ALREADY In Block Chain"),
                successTxId: "aabbccdd"
            ),
            MigrationTransferResult.success(txId: "aabbccdd")
        )
    }

    /// The duplicate check runs before the expiry sniffing: the "already known" RPC code identifies
    /// a duplicate even when the message alone would read as an expiry.
    func testMapDuplicateDetectionWinsOverExpirySniffing() {
        XCTAssertEqual(
            MigrationBroadcaster.map(
                outcome: .rejected(errorCode: -27, message: "transaction has expired"),
                successTxId: "aabbccdd"
            ),
            MigrationTransferResult.success(txId: "aabbccdd")
        )
    }

    /// Fragment specificity: a message merely containing "already" (an already-spent input) is not a
    /// duplicate re-submission and stays on the invalidNote path.
    func testMapNonDuplicateRejectionMentioningAlreadyStaysInvalidNote() {
        XCTAssertEqual(
            MigrationBroadcaster.map(
                outcome: .rejected(errorCode: -25, message: "input already spent"),
                successTxId: "unused"
            ),
            MigrationTransferResult.invalidNote
        )
    }

    // MARK: - Reschedule delegation

    /// `rescheduleOverdueTransfer()` is now a straight delegation to the engine-backed welding
    /// accessor: the proposal the welding returns is passed through untouched (no local
    /// time-shifting of `nextExecutableAfterHeight`), the bound account is forwarded, and a `nil`
    /// answer becomes `nil` out.
    func testRescheduleOverdueTransferReturnsWeldingProposalUntouched() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let proposal = Self.makeSchedule(count: 3).transfers[1]
        welding.migrationPendingTransferProposalForReturnValue = proposal
        let migration = makeMigration(welding: welding, account: accountA)

        let rescheduled = try await migration.rescheduleOverdueTransfer()

        XCTAssertEqual(rescheduled, proposal)
        XCTAssertEqual(welding.migrationPendingTransferProposalForReceivedAccount, accountA)
    }

    func testRescheduleOverdueTransferReturnsNilWhenWeldingReturnsNil() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationPendingTransferProposalForReturnValue = nil
        let migration = makeMigration(welding: welding, account: accountA)

        let rescheduled = try await migration.rescheduleOverdueTransfer()

        XCTAssertNil(rescheduled)
    }

    func testRescheduleOverdueTransferRethrowsWhenWeldingThrows() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationPendingTransferProposalForThrowableError =
            ZcashError.rustMigrationPendingTransferProposal("boom")
        let migration = makeMigration(welding: welding, account: accountA)

        do {
            _ = try await migration.rescheduleOverdueTransfer()
            XCTFail("Expected rescheduleOverdueTransfer to rethrow the welding error")
        } catch ZcashError.rustMigrationPendingTransferProposal {
            // expected
        } catch {
            XCTFail("Expected rustMigrationPendingTransferProposal but got \(error)")
        }
    }

    // MARK: - Immediate migration (opaque claim lane)

    func testSubmitImmediateMigrationUsesOnlyRustOwnedExactBytesAndRecordsOutcome() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let reserved = Self.makeClaimHandle(1)
        let staged = Self.makeClaimHandle(2)
        welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForReturnValue = reserved
        welding.migrationMaterializeImmediateSDKClaimUskForReturnValue = staged
        Self.configureImmediateSubmission(welding, identity: 10)
        welding.migrationRenewClaimClaimForReturnValue = Self.makeClaimHandle(20)

        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .accepted
        submitter.renewBeforeReturning = true
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )
        let usk = TestsData(networkType: .testnet).spendingKey
        let options = Self.immediateOptions

        let outcome = try await migration.submitImmediateMigration(
            usk: usk,
            maximumGrossAmount: Self.immediateMaximumGrossAmount,
            options: options
        )

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(
            welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForReceivedArguments?.signer,
            .sdk
        )
        XCTAssertEqual(
            welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForReceivedArguments?.maximumGrossAmount,
            Self.immediateMaximumGrossAmount
        )
        XCTAssertEqual(
            welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForReceivedArguments?.submission,
            MigrationSubmissionIntent(transport: .directTLS, endpoint: "https://submit.example:9067")
        )
        XCTAssertEqual(welding.migrationMaterializeImmediateSDKClaimUskForCallsCount, 1)
        XCTAssertEqual(submitter.receivedArguments?.transaction.raw, Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(submitter.receivedArguments?.transaction.transactionId, Data(repeating: 0x44, count: 32))
        XCTAssertEqual(submitter.receivedArguments?.expiryHeight, 2_000_040)
        XCTAssertEqual(submitter.receivedArguments?.transactionConsensusBranchId, 0xC8E71055)
        XCTAssertEqual(submitter.receivedArguments?.expectedChainName, "test")
        XCTAssertEqual(submitter.renewalCallsCount, 1)
        XCTAssertEqual(
            welding.migrationRecordSubmissionOutcomeClaimForReceivedArguments?.outcome,
            .accepted
        )
        let isBlocked = await migration.isSyncBlocked()
        XCTAssertTrue(isBlocked)
        XCTAssertFalse(welding.proposeSendMaxTransferAccountUUIDRecipientMemoOrchardOnlyCalled)
    }

    func testImmediatePreSubmitFailureReleasesKnownUnsentClaimWithoutStartingPrivacyGate() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForReturnValue = Self.makeClaimHandle(30)
        welding.migrationMaterializeImmediateSDKClaimUskForReturnValue = Self.makeClaimHandle(31)
        Self.configureImmediateSubmission(welding, identity: 32)
        welding.migrationReleaseKnownUnsentClaimClaimFailureForReturnValue = Self.makeClaimHandle(40)

        let submitter = MigrationTransactionSubmitterMock()
        submitter.throwableError = ZcashError.migrationTorUnavailable
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )

        do {
            _ = try await migration.submitImmediateMigration(
                usk: TestsData(networkType: .testnet).spendingKey,
                maximumGrossAmount: Self.immediateMaximumGrossAmount,
                options: Self.immediateOptions
            )
            XCTFail("Expected the pre-submit transport failure")
        } catch ZcashError.migrationTorUnavailable {
            // expected
        }

        XCTAssertEqual(
            welding.migrationReleaseKnownUnsentClaimClaimFailureForReceivedArguments?.failure,
            .transportDidNotBegin
        )
        XCTAssertFalse(welding.migrationRecordSubmissionOutcomeClaimForCalled)
        let isBlocked = await migration.isSyncBlocked()
        XCTAssertFalse(isBlocked)
    }

    func testExternalImmediateSigningRoundTripConsumesTheOpaqueRequestClaim() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForReturnValue = Self.makeClaimHandle(50)
        welding.migrationPrepareImmediateExternalSigningClaimForReturnValue = Self.makeClaimHandle(51)
        let unsignedPCZT = Data("SECRET-PCZT".utf8)
        welding.migrationClaimExternalSigningPCZTReturnValue = unsignedPCZT

        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .unknown
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )
        let request = try await migration.prepareImmediateMigrationForExternalSigning(
            maximumGrossAmount: Self.immediateMaximumGrossAmount,
            options: Self.immediateOptions
        )

        XCTAssertEqual(request.pczt, unsignedPCZT)
        XCTAssertFalse(String(reflecting: request).contains("SECRET-PCZT"))
        XCTAssertEqual(
            welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForReceivedArguments?.signer,
            .external
        )
        XCTAssertEqual(
            welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForReceivedArguments?.maximumGrossAmount,
            Self.immediateMaximumGrossAmount
        )

        welding.migrationRuntimeSnapshotForReturnValue = Self.makeImmediateExternalRuntime(
            account: accountA,
            runIdentity: 52,
            claim: Self.makeClaimHandle(52)
        )
        welding.migrationResumeClaimClaimForReturnValue = Self.makeClaimHandle(52)
        welding.migrationStageSignedPCZTClaimForReturnValue = Self.makeClaimHandle(53)
        welding.migrationFinalizeImmediateExternalSigningClaimForReturnValue = Self.makeClaimHandle(54)
        Self.configureImmediateSubmission(welding, identity: 55)
        let signedPCZT = Data("SIGNED-PCZT".utf8)

        let outcome = try await migration.submitExternallySignedImmediateMigration(
            request: request,
            signedPCZT: signedPCZT
        )

        XCTAssertEqual(outcome, .unknown)
        XCTAssertEqual(
            welding.migrationStageSignedPCZTClaimForReceivedArguments?.signedPCZT,
            signedPCZT
        )
        XCTAssertEqual(welding.migrationFinalizeImmediateExternalSigningClaimForCallsCount, 1)
        XCTAssertFalse(welding.migrationReacquireExternalSigningClaimForCalled)
        XCTAssertEqual(
            welding.migrationRecordSubmissionOutcomeClaimForReceivedArguments?.outcome,
            .unknown
        )
        let isBlocked = await migration.isSyncBlocked()
        XCTAssertTrue(isBlocked)
    }

    func testPrepareExternalImmediateSigningAfterRelaunchRecoversExactRustStagedPCZT() async throws {
        let firstLaunchWelding = ZcashRustBackendWeldingMock()
        firstLaunchWelding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForReturnValue = Self.makeClaimHandle(60)
        firstLaunchWelding.migrationPrepareImmediateExternalSigningClaimForReturnValue = Self.makeClaimHandle(61)
        let stagedPCZT = Data("EXACT-STAGED-PCZT".utf8)
        firstLaunchWelding.migrationClaimExternalSigningPCZTReturnValue = stagedPCZT
        let firstLaunch = makeMigration(welding: firstLaunchWelding, account: accountA)

        let originalRequest = try await firstLaunch.prepareImmediateMigrationForExternalSigning(
            maximumGrossAmount: Self.immediateMaximumGrossAmount,
            options: Self.immediateOptions
        )

        // Simulate a process relaunch: the second OrchardMigration has no retained request and its
        // welding projects a newly allocated opaque handle from the durable Rust runtime snapshot.
        let runtimeClaim = Self.makeClaimHandle(62)
        let secondLaunchWelding = ZcashRustBackendWeldingMock()
        secondLaunchWelding.migrationRuntimeSnapshotForReturnValue = Self.makeImmediateExternalRuntime(
            account: accountA,
            runIdentity: 63,
            claim: runtimeClaim
        )
        secondLaunchWelding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        secondLaunchWelding.migrationResumeClaimClaimForReturnValue = nil
        let reacquiredClaim = Self.makeClaimHandle(64)
        secondLaunchWelding.migrationReacquireExternalSigningClaimForReturnValue = reacquiredClaim
        secondLaunchWelding.migrationClaimExternalSigningPCZTReturnValue = stagedPCZT
        let secondLaunch = makeMigration(welding: secondLaunchWelding, account: accountA)
        let loweredRecoveryCeiling = Zatoshi(1)

        let recoveredRequest = try await secondLaunch.prepareImmediateMigrationForExternalSigning(
            maximumGrossAmount: loweredRecoveryCeiling,
            options: Self.immediateOptions
        )

        XCTAssertEqual(recoveredRequest.pczt, originalRequest.pczt)
        XCTAssertEqual(recoveredRequest.claim.pointer, reacquiredClaim.pointer)
        XCTAssertNotEqual(recoveredRequest.claim.pointer, originalRequest.claim.pointer)
        XCTAssertEqual(secondLaunchWelding.migrationRuntimeSnapshotForCallsCount, 1)
        XCTAssertEqual(secondLaunchWelding.migrationBoundSubmissionTargetForCallsCount, 1)
        XCTAssertEqual(
            secondLaunchWelding.migrationResumeClaimClaimForReceivedArguments?.claim.pointer,
            runtimeClaim.pointer
        )
        XCTAssertEqual(
            secondLaunchWelding.migrationReacquireExternalSigningClaimForReceivedArguments?.claim.pointer,
            runtimeClaim.pointer
        )
        XCTAssertEqual(
            secondLaunchWelding.migrationClaimExternalSigningPCZTReceivedClaim?.pointer,
            reacquiredClaim.pointer
        )
        XCTAssertFalse(secondLaunchWelding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
        XCTAssertFalse(
            secondLaunchWelding
                .migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForCalled
        )
        XCTAssertFalse(secondLaunchWelding.migrationPrepareImmediateExternalSigningClaimForCalled)
    }

    func testPrepareExternalImmediateSigningReusesLiveRuntimeClaimWithoutReacquiring() async throws {
        let runtimeClaim = Self.makeClaimHandle(65)
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = Self.makeImmediateExternalRuntime(
            account: accountA,
            runIdentity: 66,
            claim: runtimeClaim
        )
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        let resumedClaim = Self.makeClaimHandle(67)
        welding.migrationResumeClaimClaimForReturnValue = resumedClaim
        let stagedPCZT = Data("STILL-LIVE-STAGED-PCZT".utf8)
        welding.migrationClaimExternalSigningPCZTReturnValue = stagedPCZT
        let migration = makeMigration(welding: welding, account: accountA)

        let request = try await migration.prepareImmediateMigrationForExternalSigning(
            maximumGrossAmount: Self.immediateMaximumGrossAmount,
            options: Self.immediateOptions
        )

        XCTAssertEqual(request.pczt, stagedPCZT)
        XCTAssertEqual(request.claim.pointer, resumedClaim.pointer)
        XCTAssertEqual(
            welding.migrationResumeClaimClaimForReceivedArguments?.claim.pointer,
            runtimeClaim.pointer
        )
        XCTAssertFalse(welding.migrationReacquireExternalSigningClaimForCalled)
        XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
    }

    func testPrepareExternalImmediateSigningAfterRelaunchRejectsDifferentSubmissionPolicy() async throws {
        let runtimeClaim = Self.makeClaimHandle(70)
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = Self.makeImmediateExternalRuntime(
            account: accountA,
            runIdentity: 71,
            claim: runtimeClaim
        )
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        let migration = makeMigration(welding: welding, account: accountA)
        let differentOptions = MigrationNetworkPrivacyOptions(
            useTor: false,
            submissionEndpoint: LightWalletEndpoint(
                address: "other.example",
                port: 9067,
                secure: true
            )
        )

        do {
            _ = try await migration.prepareImmediateMigrationForExternalSigning(
                maximumGrossAmount: Self.immediateMaximumGrossAmount,
                options: differentOptions
            )
            XCTFail("Expected the Rust-bound submission policy to reject different relaunch options")
        } catch MigrationDeliveryError.runtimeUnavailable(.submissionPolicyMismatch) {
            // expected
        } catch {
            XCTFail("Expected submissionPolicyMismatch but got \(error)")
        }

        XCTAssertFalse(welding.migrationResumeClaimClaimForCalled)
        XCTAssertFalse(welding.migrationReacquireExternalSigningClaimForCalled)
        XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
    }

    func testImmediateSDKRelaunchSubmitsTheDurablyStagedExactArtifact() async throws {
        let runtimeClaim = Self.makeClaimHandle(72)
        let welding = ZcashRustBackendWeldingMock()
        let runtime = Self.makeImmediateSDKRuntime(
            account: accountA,
            runIdentity: 73,
            claim: runtimeClaim,
            status: .staged
        )
        welding.migrationRuntimeSnapshotForReturnValue = runtime
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        Self.configureImmediateSubmission(welding, identity: 74)
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .accepted
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )

        let loweredRecoveryCeiling = Zatoshi(1)
        let outcome = try await migration.submitImmediateMigration(
            usk: TestsData(networkType: .testnet).spendingKey,
            maximumGrossAmount: loweredRecoveryCeiling,
            options: Self.immediateOptions
        )

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(
            welding.migrationClaimSubmissionClaimForReceivedArguments?.claim.pointer,
            runtimeClaim.pointer
        )
        XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
        XCTAssertFalse(
            welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForCalled
        )
        XCTAssertFalse(welding.migrationMaterializeImmediateSDKClaimUskForCalled)
        XCTAssertEqual(submitter.callsCount, 1)
    }

    func testImmediateSDKRelaunchResumesSnapshotRefreshedMaterializationToken() async throws {
        let snapshotClaim = Self.makeClaimHandle(171)
        let resumedClaim = Self.makeClaimHandle(172)
        let welding = ZcashRustBackendWeldingMock()
        let runtime = Self.makeImmediateSDKRuntime(
            account: accountA,
            runIdentity: 173,
            claim: snapshotClaim,
            status: .materializing,
            activeClaimKind: .materialization
        )
        welding.migrationRuntimeSnapshotForReturnValue = runtime
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        welding.migrationResumeClaimClaimForReturnValue = resumedClaim
        welding.migrationMaterializeImmediateSDKClaimUskForReturnValue = Self.makeClaimHandle(174)
        Self.configureImmediateSubmission(welding, identity: 175)
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .accepted
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )

        let outcome = try await migration.submitImmediateMigration(
            usk: TestsData(networkType: .testnet).spendingKey,
            maximumGrossAmount: Self.immediateMaximumGrossAmount,
            options: Self.immediateOptions
        )

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(
            welding.migrationResumeClaimClaimForReceivedArguments?.claim.pointer,
            snapshotClaim.pointer
        )
        XCTAssertEqual(
            welding.migrationMaterializeImmediateSDKClaimUskForReceivedArguments?.claim.pointer,
            resumedClaim.pointer
        )
        XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
        XCTAssertEqual(submitter.callsCount, 1)
    }

    func testImmediateSDKRelaunchReacquiresSafeFailedMaterializationAndSubmits() async throws {
        let failedClaim = Self.makeClaimHandle(176)
        let reacquiredClaim = Self.makeClaimHandle(177)
        let stagedClaim = Self.makeClaimHandle(178)
        let welding = ZcashRustBackendWeldingMock()
        let runtime = Self.makeImmediateSDKRuntime(
            account: accountA,
            runIdentity: 179,
            claim: failedClaim,
            status: .materializationFailed,
            availability: .unavailable(.missingSpendAuthorization)
        )
        welding.migrationRuntimeSnapshotForReturnValue = runtime
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForReturnValue =
            reacquiredClaim
        welding.migrationMaterializeImmediateSDKClaimUskForReturnValue = stagedClaim
        Self.configureImmediateSubmission(welding, identity: 180)
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .accepted
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )

        let outcome = try await migration.recoverFailedImmediateMigration(
            recoveryCapability: try XCTUnwrap(runtime.immediateMigrationRecoveryCapability),
            usk: TestsData(networkType: .testnet).spendingKey,
            maximumGrossAmount: Self.immediateMaximumGrossAmount,
            options: Self.immediateOptions
        )

        XCTAssertEqual(outcome, .accepted)
        let arguments = welding
            .migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForReceivedArguments
        XCTAssertEqual(arguments?.claim.pointer, failedClaim.pointer)
        XCTAssertEqual(arguments?.signer, .sdk)
        XCTAssertEqual(arguments?.maximumGrossAmount, Self.immediateMaximumGrossAmount)
        XCTAssertEqual(arguments?.account, accountA)
        XCTAssertEqual(
            welding.migrationMaterializeImmediateSDKClaimUskForReceivedArguments?.claim.pointer,
            reacquiredClaim.pointer
        )
        XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
        XCTAssertEqual(submitter.callsCount, 1)
    }

    func testRecoveryOnlySDKReacquiresAvailableSafeFailedMaterializationWithoutReserving() async throws {
        let failedClaim = Self.makeClaimHandle(0x17A)
        let reacquiredClaim = Self.makeClaimHandle(0x17B)
        let welding = ZcashRustBackendWeldingMock()
        let runtime = Self.makeImmediateSDKRuntime(
            account: accountA,
            runIdentity: 0x17C,
            claim: failedClaim,
            status: .materializationFailed,
            availability: .available
        )
        welding.migrationRuntimeSnapshotForReturnValue = runtime
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForReturnValue =
            reacquiredClaim
        welding.migrationMaterializeImmediateSDKClaimUskForReturnValue = Self.makeClaimHandle(0x17D)
        Self.configureImmediateSubmission(welding, identity: 0x17E)
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .accepted
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )

        let outcome = try await migration.recoverFailedImmediateMigration(
            recoveryCapability: try XCTUnwrap(runtime.immediateMigrationRecoveryCapability),
            usk: TestsData(networkType: .testnet).spendingKey,
            maximumGrossAmount: Self.immediateMaximumGrossAmount,
            options: Self.immediateOptions
        )

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(
            welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForReceivedArguments?
                .claim.pointer,
            failedClaim.pointer
        )
        XCTAssertEqual(
            welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForReceivedArguments?
                .maximumGrossAmount,
            Self.immediateMaximumGrossAmount
        )
        XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
        XCTAssertEqual(submitter.callsCount, 1)
    }

    func testRecoveryCapabilityEqualityUsesHiddenSealAcrossDistinctHandleClones() throws {
        let first = Self.makeImmediateSDKRuntime(
            account: accountA,
            runIdentity: 0x176,
            claim: Self.makeClaimHandle(0x177),
            status: .materializationFailed,
            artifactIdentityByte: 0x61,
            deliveryRevision: 44
        )
        let sameSealFreshClone = Self.makeImmediateSDKRuntime(
            account: accountA,
            runIdentity: 0x178,
            claim: Self.makeClaimHandle(0x179),
            status: .materializationFailed,
            artifactIdentityByte: 0x61,
            deliveryRevision: 44
        )
        let changedRevision = Self.makeImmediateSDKRuntime(
            account: accountA,
            runIdentity: 0x17A,
            claim: Self.makeClaimHandle(0x17B),
            status: .materializationFailed,
            artifactIdentityByte: 0x61,
            deliveryRevision: 45
        )

        XCTAssertEqual(
            try XCTUnwrap(first.immediateMigrationRecoveryCapability),
            try XCTUnwrap(sameSealFreshClone.immediateMigrationRecoveryCapability)
        )
        XCTAssertNotEqual(
            try XCTUnwrap(first.immediateMigrationRecoveryCapability),
            try XCTUnwrap(changedRevision.immediateMigrationRecoveryCapability)
        )
    }

    func testRecoveryUsesCallerHandleAfterFreshSameSealClone() async throws {
        let renderedClaim = Self.makeClaimHandle(0x17C)
        let renderedRuntime = Self.makeImmediateSDKRuntime(
            account: accountA,
            runIdentity: 0x17D,
            claim: renderedClaim,
            status: .materializationFailed,
            artifactIdentityByte: 0x62,
            deliveryRevision: 46
        )
        let freshCloneClaim = Self.makeClaimHandle(0x17E)
        let freshRuntime = Self.makeImmediateSDKRuntime(
            account: accountA,
            runIdentity: 0x17F,
            claim: freshCloneClaim,
            status: .materializationFailed,
            artifactIdentityByte: 0x62,
            deliveryRevision: 46
        )
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = freshRuntime
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForReturnValue =
            Self.makeClaimHandle(0x180)
        welding.migrationMaterializeImmediateSDKClaimUskForReturnValue = Self.makeClaimHandle(0x181)
        Self.configureImmediateSubmission(welding, identity: 0x182)
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .accepted
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )

        _ = try await migration.recoverFailedImmediateMigration(
            recoveryCapability: try XCTUnwrap(
                renderedRuntime.immediateMigrationRecoveryCapability
            ),
            usk: TestsData(networkType: .testnet).spendingKey,
            maximumGrossAmount: Self.immediateMaximumGrossAmount,
            options: Self.immediateOptions
        )

        XCTAssertEqual(
            welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForReceivedArguments?
                .claim.pointer,
            renderedClaim.pointer
        )
        XCTAssertNotEqual(
            welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForReceivedArguments?
                .claim.pointer,
            freshCloneClaim.pointer
        )
        XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
    }

    func testRecoveryOnlySDKRejectsSameSignerReplacementBeforeReacquisition() async throws {
        let renderedRuntime = Self.makeImmediateSDKRuntime(
            account: accountA,
            runIdentity: 0x17F,
            claim: Self.makeClaimHandle(0x180),
            status: .materializationFailed,
            artifactIdentityByte: 0x71,
            deliveryRevision: 71
        )
        let renderedCapability = try XCTUnwrap(
            renderedRuntime.immediateMigrationRecoveryCapability
        )
        let replacementClaim = Self.makeClaimHandle(0x181)
        let replacementRuntime = Self.makeImmediateSDKRuntime(
            account: accountA,
            runIdentity: 0x182,
            claim: replacementClaim,
            status: .materializationFailed,
            artifactIdentityByte: 0x72,
            deliveryRevision: 72
        )
        XCTAssertNotEqual(
            renderedCapability,
            try XCTUnwrap(replacementRuntime.immediateMigrationRecoveryCapability)
        )

        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = replacementRuntime
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        let migration = makeMigration(welding: welding, account: accountA)

        do {
            _ = try await migration.recoverFailedImmediateMigration(
                recoveryCapability: renderedCapability,
                usk: TestsData(networkType: .testnet).spendingKey,
                maximumGrossAmount: Self.immediateMaximumGrossAmount,
                options: Self.immediateOptions
            )
            XCTFail("Expected the stale rendered capability to reject the replacement")
        } catch MigrationDeliveryError.immediateRecoveryStateChanged {
            // expected
        } catch {
            XCTFail("Expected immediateRecoveryStateChanged but got \(error)")
        }

        XCTAssertFalse(
            welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForCalled
        )
        XCTAssertFalse(welding.migrationMaterializeImmediateSDKClaimUskForCalled)
        XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
    }

    func testGenericImmediateEntryPointsCannotRecoverMissingSpendAuthorization() async throws {
        let sdkWelding = ZcashRustBackendWeldingMock()
        sdkWelding.migrationRuntimeSnapshotForReturnValue = Self.makeImmediateSDKRuntime(
            account: accountA,
            runIdentity: 0x180,
            claim: Self.makeClaimHandle(0x181),
            status: .materializationFailed,
            availability: .unavailable(.missingSpendAuthorization)
        )
        sdkWelding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        let sdkMigration = makeMigration(welding: sdkWelding, account: accountA)

        do {
            _ = try await sdkMigration.submitImmediateMigration(
                usk: TestsData(networkType: .testnet).spendingKey,
                maximumGrossAmount: Self.immediateMaximumGrossAmount,
                options: Self.immediateOptions
            )
            XCTFail("Expected generic SDK submission to reject legacy recovery")
        } catch MigrationDeliveryError.runtimeUnavailable(.missingSpendAuthorization) {
            // expected
        } catch {
            XCTFail("Expected missingSpendAuthorization but got \(error)")
        }
        XCTAssertFalse(sdkWelding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
        XCTAssertFalse(
            sdkWelding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForCalled
        )

        let externalWelding = ZcashRustBackendWeldingMock()
        externalWelding.migrationRuntimeSnapshotForReturnValue = Self.makeImmediateExternalRuntime(
            account: accountA,
            runIdentity: 0x182,
            claim: Self.makeClaimHandle(0x183),
            status: .materializationFailed,
            activeClaimKind: nil,
            externallyExposed: false,
            availability: .unavailable(.missingSpendAuthorization)
        )
        let externalMigration = makeMigration(welding: externalWelding, account: accountA)

        do {
            _ = try await externalMigration.prepareImmediateMigrationForExternalSigning(
                maximumGrossAmount: Self.immediateMaximumGrossAmount,
                options: Self.immediateOptions
            )
            XCTFail("Expected generic external preparation to reject legacy recovery")
        } catch MigrationDeliveryError.runtimeUnavailable(.missingSpendAuthorization) {
            // expected
        } catch {
            XCTFail("Expected missingSpendAuthorization but got \(error)")
        }
        XCTAssertFalse(externalWelding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
        XCTAssertFalse(
            externalWelding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForCalled
        )
    }

    func testGenericImmediateEntryPointsCannotRecoverAvailableMaterializationFailure() async throws {
        let sdkWelding = ZcashRustBackendWeldingMock()
        sdkWelding.migrationRuntimeSnapshotForReturnValue = Self.makeImmediateSDKRuntime(
            account: accountA,
            runIdentity: 0x1E0,
            claim: Self.makeClaimHandle(0x1E1),
            status: .materializationFailed,
            availability: .available
        )
        sdkWelding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        let sdkMigration = makeMigration(welding: sdkWelding, account: accountA)
        do {
            _ = try await sdkMigration.submitImmediateMigration(
                usk: TestsData(networkType: .testnet).spendingKey,
                maximumGrossAmount: Self.immediateMaximumGrossAmount,
                options: Self.immediateOptions
            )
            XCTFail("Expected generic SDK submission to reject failed materialization")
        } catch MigrationDeliveryError.claimUnavailable {
            // expected
        } catch {
            XCTFail("Expected claimUnavailable but got \(error)")
        }
        XCTAssertFalse(sdkWelding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
        XCTAssertFalse(
            sdkWelding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForCalled
        )

        let externalWelding = ZcashRustBackendWeldingMock()
        externalWelding.migrationRuntimeSnapshotForReturnValue = Self.makeImmediateExternalRuntime(
            account: accountA,
            runIdentity: 0x1E2,
            claim: Self.makeClaimHandle(0x1E3),
            status: .materializationFailed,
            activeClaimKind: nil,
            externallyExposed: false,
            availability: .available
        )
        externalWelding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        let externalMigration = makeMigration(welding: externalWelding, account: accountA)
        do {
            _ = try await externalMigration.prepareImmediateMigrationForExternalSigning(
                maximumGrossAmount: Self.immediateMaximumGrossAmount,
                options: Self.immediateOptions
            )
            XCTFail("Expected generic external preparation to reject failed materialization")
        } catch MigrationDeliveryError.externalSigningClaimUnavailable {
            // expected
        } catch {
            XCTFail("Expected externalSigningClaimUnavailable but got \(error)")
        }
        XCTAssertFalse(externalWelding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
        XCTAssertFalse(
            externalWelding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForCalled
        )
    }

    func testRecoveryOnlySoftwareNeverReservesForAbsentAdvancedReplacementOrOtherUnavailableState() async throws {
        let staleCapability = Self.makeRecoveryCapability(0x183, signer: .sdk)
        var cases: [(String, MigrationRuntimeSnapshot)] = [
            ("absent", Self.makeNoRunRuntime(account: accountA)),
            (
                "same-signer staged replacement",
                Self.makeImmediateSDKRuntime(
                    account: accountA,
                    runIdentity: 0x184,
                    claim: Self.makeClaimHandle(0x185),
                    status: .staged,
                    availability: .available
                )
            )
        ]
        let advancedStates: [(String, MigrationDeliveryClaimStatus, MigrationDeliveryClaimKind?)] = [
            ("materializing", .materializing, .materialization),
            ("staged", .staged, nil),
            ("submitting", .submitting, .submission),
            ("outcome unknown", .outcomeUnknown, .outcomeResolution),
            ("broadcasted", .broadcasted, nil),
            ("confirmed", .confirmed, nil),
            ("expired unmined", .expiredUnmined, nil)
        ]
        for (index, state) in advancedStates.enumerated() {
            cases.append((
                state.0,
                Self.makeImmediateSDKRuntime(
                    account: accountA,
                    runIdentity: 0x190 + index * 2,
                    claim: Self.makeClaimHandle(0x191 + index * 2),
                    status: state.1,
                    activeClaimKind: state.2
                )
            ))
        }
        let unavailableReasons: [(String, MigrationRuntimeUnavailableReason)] = [
            ("schema unavailable", .schemaUnavailable),
            ("future schema", .futureSchema(version: 3)),
            ("corrupt schema", .corruptDeliveryState),
            ("legacy cutover", .legacyCutoverRecovery(objects: 1)),
            ("delivery inconsistent", .deliveryInconsistent),
            ("finality recovery", .finalityRecovery(.rewoundBeyondFinalityHorizon))
        ]
        for (index, unavailable) in unavailableReasons.enumerated() {
            cases.append((
                unavailable.0,
                Self.makeImmediateSDKRuntime(
                    account: accountA,
                    runIdentity: 0x1A0 + index * 2,
                    claim: Self.makeClaimHandle(0x1A1 + index * 2),
                    status: .materializationFailed,
                    availability: .unavailable(unavailable.1)
                )
            ))
        }

        for (name, runtime) in cases {
            let welding = ZcashRustBackendWeldingMock()
            welding.migrationRuntimeSnapshotForReturnValue = runtime
            let migration = makeMigration(welding: welding, account: accountA)
            do {
                _ = try await migration.recoverFailedImmediateMigration(
                    recoveryCapability: staleCapability,
                    usk: TestsData(networkType: .testnet).spendingKey,
                    maximumGrossAmount: Self.immediateMaximumGrossAmount,
                    options: Self.immediateOptions
                )
                XCTFail("Expected \(name) recovery state to fail closed")
            } catch MigrationDeliveryError.immediateRecoveryStateChanged {
                // expected
            } catch {
                XCTFail("Expected immediateRecoveryStateChanged for \(name), got \(error)")
            }
            XCTAssertFalse(
                welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForCalled,
                name
            )
            XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled, name)
        }
    }

    func testRecoveryOnlyExternalNeverReservesForAbsentOrAdvancedState() async throws {
        let staleCapability = Self.makeRecoveryCapability(0x1AF, signer: .external)
        var cases: [(String, MigrationRuntimeSnapshot)] = [
            ("absent", Self.makeNoRunRuntime(account: accountA)),
            (
                "same-signer exposed replacement",
                Self.makeImmediateExternalRuntime(
                    account: accountA,
                    runIdentity: 0x1B0,
                    claim: Self.makeClaimHandle(0x1B1),
                    status: .awaitingExternalSignature,
                    availability: .available
                )
            )
        ]
        let advancedStates: [MigrationDeliveryClaimStatus] = [
            .materializing,
            .awaitingExternalSignature,
            .staged,
            .submitting,
            .outcomeUnknown,
            .broadcasted,
            .confirmed,
            .expiredUnmined,
            .externalSigningExpiredUnmined
        ]
        for (index, status) in advancedStates.enumerated() {
            cases.append((
                status.rawValue,
                Self.makeImmediateExternalRuntime(
                    account: accountA,
                    runIdentity: 0x1B2 + index * 2,
                    claim: Self.makeClaimHandle(0x1B3 + index * 2),
                    status: status
                )
            ))
        }
        let unavailableReasons: [(String, MigrationRuntimeUnavailableReason)] = [
            ("schema unavailable", .schemaUnavailable),
            ("future schema", .futureSchema(version: 3)),
            ("corrupt schema", .corruptDeliveryState),
            ("legacy cutover", .legacyCutoverRecovery(objects: 1)),
            ("finality recovery", .finalityRecovery(.externalSigningExposureUnresolved))
        ]
        for (index, unavailable) in unavailableReasons.enumerated() {
            cases.append((
                unavailable.0,
                Self.makeImmediateExternalRuntime(
                    account: accountA,
                    runIdentity: 0x1D0 + index * 2,
                    claim: Self.makeClaimHandle(0x1D1 + index * 2),
                    status: .materializationFailed,
                    activeClaimKind: nil,
                    externallyExposed: false,
                    availability: .unavailable(unavailable.1)
                )
            ))
        }

        for (name, runtime) in cases {
            let welding = ZcashRustBackendWeldingMock()
            welding.migrationRuntimeSnapshotForReturnValue = runtime
            let migration = makeMigration(welding: welding, account: accountA)
            do {
                _ = try await migration
                    .recoverFailedImmediateMigrationForExternalSigning(
                        recoveryCapability: staleCapability,
                        maximumGrossAmount: Self.immediateMaximumGrossAmount,
                        options: Self.immediateOptions
                    )
                XCTFail("Expected \(name) external recovery state to fail closed")
            } catch MigrationDeliveryError.immediateRecoveryStateChanged {
                // expected
            } catch {
                XCTFail("Expected immediateRecoveryStateChanged for \(name), got \(error)")
            }
            XCTAssertFalse(
                welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForCalled,
                name
            )
            XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled, name)
        }
    }

    func testRecoveryOnlySoftwareRejectsSubmissionPolicyMismatchBeforeReacquiring() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let runtime = Self.makeImmediateSDKRuntime(
            account: accountA,
            runIdentity: 0x18C,
            claim: Self.makeClaimHandle(0x18D),
            status: .materializationFailed,
            availability: .unavailable(.missingSpendAuthorization)
        )
        welding.migrationRuntimeSnapshotForReturnValue = runtime
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://different.example:9067"
        )
        let migration = makeMigration(welding: welding, account: accountA)

        do {
            _ = try await migration.recoverFailedImmediateMigration(
                recoveryCapability: try XCTUnwrap(runtime.immediateMigrationRecoveryCapability),
                usk: TestsData(networkType: .testnet).spendingKey,
                maximumGrossAmount: Self.immediateMaximumGrossAmount,
                options: Self.immediateOptions
            )
            XCTFail("Expected policy mismatch")
        } catch MigrationDeliveryError.runtimeUnavailable(.submissionPolicyMismatch) {
            // expected
        } catch {
            XCTFail("Expected submissionPolicyMismatch but got \(error)")
        }

        XCTAssertFalse(
            welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForCalled
        )
        XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
    }

    func testRecoveryOnlyPropagatesCapAndRevisionCASFailuresWithoutReserving() async throws {
        let failures: [(String, Zatoshi)] = [
            ("gross authorization rejected", .zero),
            ("delivery revision changed", Self.immediateMaximumGrossAmount)
        ]
        for (message, cap) in failures {
            let welding = ZcashRustBackendWeldingMock()
            let runtime = Self.makeImmediateSDKRuntime(
                account: accountA,
                runIdentity: 0x18E,
                claim: Self.makeClaimHandle(0x18F),
                status: .materializationFailed,
                availability: .unavailable(.missingSpendAuthorization)
            )
            welding.migrationRuntimeSnapshotForReturnValue = runtime
            welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
                transport: .directTLS,
                endpoint: "https://submit.example:9067"
            )
            welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForThrowableError =
                ZcashError.rustMigrationDelivery(message)
            let migration = makeMigration(welding: welding, account: accountA)

            do {
                _ = try await migration.recoverFailedImmediateMigration(
                    recoveryCapability: try XCTUnwrap(runtime.immediateMigrationRecoveryCapability),
                    usk: TestsData(networkType: .testnet).spendingKey,
                    maximumGrossAmount: cap,
                    options: Self.immediateOptions
                )
                XCTFail("Expected Rust CAS failure")
            } catch ZcashError.rustMigrationDelivery(let actual) {
                XCTAssertEqual(actual, message)
            } catch {
                XCTFail("Expected rustMigrationDelivery but got \(error)")
            }

            XCTAssertEqual(
                welding
                    .migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForReceivedArguments?
                    .maximumGrossAmount,
                cap
            )
            XCTAssertFalse(welding.migrationMaterializeImmediateSDKClaimUskForCalled)
            XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
        }
    }

    func testMissingLegacySpendAuthorizationCannotSubmitAlreadyStagedBytes() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = Self.makeImmediateSDKRuntime(
            account: accountA,
            runIdentity: 180,
            claim: Self.makeClaimHandle(181),
            status: .staged,
            availability: .unavailable(.missingSpendAuthorization)
        )
        let migration = makeMigration(welding: welding, account: accountA)

        do {
            _ = try await migration.submitImmediateMigration(
                usk: TestsData(networkType: .testnet).spendingKey,
                maximumGrossAmount: Self.immediateMaximumGrossAmount,
                options: Self.immediateOptions
            )
            XCTFail("Expected legacy staged bytes to remain recovery-only")
        } catch MigrationDeliveryError.runtimeUnavailable(.missingSpendAuthorization) {
            // expected
        } catch {
            XCTFail("Expected missingSpendAuthorization but got \(error)")
        }

        XCTAssertFalse(welding.migrationClaimSubmissionClaimForCalled)
        XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
    }

    func testPrepareExternalImmediateSigningReacquiresSafeFailedMaterialization() async throws {
        let failedClaim = Self.makeClaimHandle(181)
        let reacquiredClaim = Self.makeClaimHandle(182)
        let stagedClaim = Self.makeClaimHandle(183)
        let welding = ZcashRustBackendWeldingMock()
        let runtime = Self.makeImmediateExternalRuntime(
            account: accountA,
            runIdentity: 184,
            claim: failedClaim,
            status: .materializationFailed,
            activeClaimKind: nil,
            externallyExposed: false,
            availability: .unavailable(.missingSpendAuthorization)
        )
        welding.migrationRuntimeSnapshotForReturnValue = runtime
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForReturnValue =
            reacquiredClaim
        welding.migrationPrepareImmediateExternalSigningClaimForReturnValue = stagedClaim
        let expectedPCZT = Data("REACQUIRED-EXTERNAL-PCZT".utf8)
        welding.migrationClaimExternalSigningPCZTReturnValue = expectedPCZT
        let migration = makeMigration(welding: welding, account: accountA)

        let request = try await migration.recoverFailedImmediateMigrationForExternalSigning(
            recoveryCapability: try XCTUnwrap(runtime.immediateMigrationRecoveryCapability),
            maximumGrossAmount: Self.immediateMaximumGrossAmount,
            options: Self.immediateOptions
        )

        XCTAssertEqual(request.pczt, expectedPCZT)
        XCTAssertEqual(request.claim.pointer, stagedClaim.pointer)
        let arguments = welding
            .migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForReceivedArguments
        XCTAssertEqual(arguments?.claim.pointer, failedClaim.pointer)
        XCTAssertEqual(arguments?.signer, .external)
        XCTAssertEqual(arguments?.maximumGrossAmount, Self.immediateMaximumGrossAmount)
        XCTAssertEqual(arguments?.account, accountA)
        XCTAssertEqual(
            welding.migrationPrepareImmediateExternalSigningClaimForReceivedArguments?.claim.pointer,
            reacquiredClaim.pointer
        )
        XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
    }

    func testRecoveryOnlyExternalReacquiresAvailableSafeFailedMaterializationWithoutReserving() async throws {
        let failedClaim = Self.makeClaimHandle(0x18A)
        let reacquiredClaim = Self.makeClaimHandle(0x18B)
        let stagedClaim = Self.makeClaimHandle(0x18C)
        let welding = ZcashRustBackendWeldingMock()
        let runtime = Self.makeImmediateExternalRuntime(
            account: accountA,
            runIdentity: 0x18D,
            claim: failedClaim,
            status: .materializationFailed,
            activeClaimKind: nil,
            externallyExposed: false,
            availability: .available
        )
        welding.migrationRuntimeSnapshotForReturnValue = runtime
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForReturnValue =
            reacquiredClaim
        welding.migrationPrepareImmediateExternalSigningClaimForReturnValue = stagedClaim
        welding.migrationClaimExternalSigningPCZTReturnValue = Data("AVAILABLE-RECOVERY-PCZT".utf8)
        let migration = makeMigration(welding: welding, account: accountA)

        let request = try await migration.recoverFailedImmediateMigrationForExternalSigning(
            recoveryCapability: try XCTUnwrap(runtime.immediateMigrationRecoveryCapability),
            maximumGrossAmount: Self.immediateMaximumGrossAmount,
            options: Self.immediateOptions
        )

        XCTAssertEqual(request.claim.pointer, stagedClaim.pointer)
        XCTAssertEqual(
            welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForReceivedArguments?
                .claim.pointer,
            failedClaim.pointer
        )
        XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
    }

    func testRecoveryOnlyExternalRejectsSameSignerReplacementBeforeReacquisition() async throws {
        let renderedRuntime = Self.makeImmediateExternalRuntime(
            account: accountA,
            runIdentity: 0x18E,
            claim: Self.makeClaimHandle(0x18F),
            status: .materializationFailed,
            activeClaimKind: nil,
            externallyExposed: false,
            artifactIdentityByte: 0x81,
            deliveryRevision: 81
        )
        let renderedCapability = try XCTUnwrap(
            renderedRuntime.immediateMigrationRecoveryCapability
        )
        let replacementClaim = Self.makeClaimHandle(0x190)
        let replacementRuntime = Self.makeImmediateExternalRuntime(
            account: accountA,
            runIdentity: 0x191,
            claim: replacementClaim,
            status: .materializationFailed,
            activeClaimKind: nil,
            externallyExposed: false,
            artifactIdentityByte: 0x82,
            deliveryRevision: 82
        )

        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = replacementRuntime
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        let migration = makeMigration(welding: welding, account: accountA)

        do {
            _ = try await migration.recoverFailedImmediateMigrationForExternalSigning(
                recoveryCapability: renderedCapability,
                maximumGrossAmount: Self.immediateMaximumGrossAmount,
                options: Self.immediateOptions
            )
            XCTFail("Expected the stale rendered external capability to reject the replacement")
        } catch MigrationDeliveryError.immediateRecoveryStateChanged {
            // expected
        } catch {
            XCTFail("Expected immediateRecoveryStateChanged but got \(error)")
        }

        XCTAssertFalse(
            welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForCalled
        )
        XCTAssertFalse(welding.migrationPrepareImmediateExternalSigningClaimForCalled)
        XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
    }

    func testFailedExternalImmediateMaterializationWithExposureEvidenceStaysFailClosed() async throws {
        let staleCapability = Self.makeRecoveryCapability(0x18E, signer: .external)
        let cases = [
            UnsafeImmediateFailureCase(
                name: "live claim",
                activeClaimKind: .materialization,
                externallyExposed: false,
                hasSignedPCZT: false,
                hasExactTransaction: false,
                txid: nil,
                lastError: .materializationFailed
            ),
            UnsafeImmediateFailureCase(
                name: "external exposure",
                activeClaimKind: nil,
                externallyExposed: true,
                hasSignedPCZT: false,
                hasExactTransaction: false,
                txid: nil,
                lastError: .materializationFailed
            ),
            UnsafeImmediateFailureCase(
                name: "signed PCZT",
                activeClaimKind: nil,
                externallyExposed: false,
                hasSignedPCZT: true,
                hasExactTransaction: false,
                txid: nil,
                lastError: .materializationFailed
            ),
            UnsafeImmediateFailureCase(
                name: "exact transaction",
                activeClaimKind: nil,
                externallyExposed: false,
                hasSignedPCZT: false,
                hasExactTransaction: true,
                txid: nil,
                lastError: .materializationFailed
            ),
            UnsafeImmediateFailureCase(
                name: "transaction id",
                activeClaimKind: nil,
                externallyExposed: false,
                hasSignedPCZT: false,
                hasExactTransaction: false,
                txid: Data(repeating: 0x44, count: 32),
                lastError: .materializationFailed
            ),
            UnsafeImmediateFailureCase(
                name: "transport failure reason",
                activeClaimKind: nil,
                externallyExposed: false,
                hasSignedPCZT: false,
                hasExactTransaction: false,
                txid: nil,
                lastError: .transportDidNotBegin
            )
        ]

        for testCase in cases {
            let welding = ZcashRustBackendWeldingMock()
            welding.migrationRuntimeSnapshotForReturnValue = Self.makeImmediateExternalRuntime(
                account: accountA,
                runIdentity: 185,
                claim: Self.makeClaimHandle(186),
                status: .materializationFailed,
                activeClaimKind: testCase.activeClaimKind,
                externallyExposed: testCase.externallyExposed,
                hasSignedPCZT: testCase.hasSignedPCZT,
                hasExactTransaction: testCase.hasExactTransaction,
                txid: testCase.txid,
                lastError: testCase.lastError,
                availability: .unavailable(.missingSpendAuthorization)
            )
            welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
                transport: .directTLS,
                endpoint: "https://submit.example:9067"
            )
            let migration = makeMigration(welding: welding, account: accountA)

            do {
                _ = try await migration.recoverFailedImmediateMigrationForExternalSigning(
                    recoveryCapability: staleCapability,
                    maximumGrossAmount: Self.immediateMaximumGrossAmount,
                    options: Self.immediateOptions
                )
                XCTFail("Expected \(testCase.name) to prevent reacquisition")
            } catch MigrationDeliveryError.externalSigningClaimUnavailable {
                // expected
            } catch {
                XCTFail("Expected externalSigningClaimUnavailable for \(testCase.name), got \(error)")
            }

            XCTAssertFalse(
                welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForCalled,
                testCase.name
            )
            XCTAssertFalse(welding.migrationPrepareImmediateExternalSigningClaimForCalled, testCase.name)
            XCTAssertFalse(
                welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled,
                testCase.name
            )
        }
    }

    func testImmediateSDKRetryRejectsFailedArtifactOwnedByExternalSigner() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let runtime = Self.makeImmediateExternalRuntime(
            account: accountA,
            runIdentity: 187,
            claim: Self.makeClaimHandle(188),
            status: .materializationFailed,
            activeClaimKind: nil,
            externallyExposed: false,
            availability: .unavailable(.missingSpendAuthorization)
        )
        welding.migrationRuntimeSnapshotForReturnValue = runtime
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        let migration = makeMigration(welding: welding, account: accountA)

        do {
            _ = try await migration.recoverFailedImmediateMigration(
                recoveryCapability: try XCTUnwrap(runtime.immediateMigrationRecoveryCapability),
                usk: TestsData(networkType: .testnet).spendingKey,
                maximumGrossAmount: Self.immediateMaximumGrossAmount,
                options: Self.immediateOptions
            )
            XCTFail("Expected the signer mismatch to stay fail-closed")
        } catch MigrationDeliveryError.claimUnavailable {
            // expected
        } catch {
            XCTFail("Expected claimUnavailable but got \(error)")
        }

        XCTAssertFalse(
            welding.migrationReacquireFailedImmediateMaterializationClaimSignerMaximumGrossAmountForCalled
        )
        XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
    }

    func testImmediateSDKRelaunchReconcilesUnknownOutcomeWithoutResubmitting() async throws {
        let runtimeClaim = Self.makeClaimHandle(75)
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = Self.makeImmediateSDKRuntime(
            account: accountA,
            runIdentity: 76,
            claim: runtimeClaim,
            status: .outcomeUnknown,
            activeClaimKind: .outcomeResolution
        )
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        welding.migrationClaimOutcomeResolutionClaimForReturnValue = Self.makeClaimHandle(77)
        welding.migrationReconcileSubmissionClaimForReturnValue = Self.makeClaimHandle(78)
        let submitter = MigrationTransactionSubmitterMock()
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )

        let outcome = try await migration.submitImmediateMigration(
            usk: TestsData(networkType: .testnet).spendingKey,
            maximumGrossAmount: Self.immediateMaximumGrossAmount,
            options: Self.immediateOptions
        )

        XCTAssertEqual(outcome, .unknown)
        XCTAssertEqual(welding.migrationClaimOutcomeResolutionClaimForCallsCount, 1)
        XCTAssertEqual(welding.migrationReconcileSubmissionClaimForCallsCount, 1)
        XCTAssertFalse(welding.migrationClaimSubmissionClaimForCalled)
        XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
        XCTAssertEqual(submitter.callsCount, 0)
    }

    func testImmediateExternalRelaunchAfterFinalizationSubmitsWithoutRestagingSignerBytes() async throws {
        let runtimeClaim = Self.makeClaimHandle(79)
        let stagedPCZT = Data("DURABLE-EXTERNAL-PCZT".utf8)
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = Self.makeImmediateExternalRuntime(
            account: accountA,
            runIdentity: 80,
            claim: runtimeClaim,
            status: .staged,
            activeClaimKind: nil,
            hasSignedPCZT: true,
            hasExactTransaction: true,
            txid: Data(repeating: 0x44, count: 32)
        )
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        welding.migrationClaimExternalSigningPCZTReturnValue = stagedPCZT
        Self.configureImmediateSubmission(welding, identity: 81)
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .accepted
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )

        let recovered = try await migration.prepareImmediateMigrationForExternalSigning(
            maximumGrossAmount: Self.immediateMaximumGrossAmount,
            options: Self.immediateOptions
        )
        let outcome = try await migration.submitExternallySignedImmediateMigration(
            request: recovered,
            signedPCZT: Data("RETRIED-SIGNER-RESPONSE".utf8)
        )

        XCTAssertEqual(recovered.pczt, stagedPCZT)
        XCTAssertEqual(outcome, .accepted)
        XCTAssertFalse(welding.migrationResumeClaimClaimForCalled)
        XCTAssertFalse(welding.migrationReacquireExternalSigningClaimForCalled)
        XCTAssertFalse(welding.migrationStageSignedPCZTClaimForCalled)
        XCTAssertFalse(welding.migrationFinalizeImmediateExternalSigningClaimForCalled)
        XCTAssertEqual(
            welding.migrationClaimSubmissionClaimForReceivedArguments?.claim.pointer,
            runtimeClaim.pointer
        )
        XCTAssertEqual(submitter.callsCount, 1)
    }

    func testNoResignImmediateResumeSubmitsOnlyTheDurablyStagedExactTransaction() async throws {
        let runtimeClaim = Self.makeClaimHandle(0x2C0)
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = Self.makeImmediateExternalRuntime(
            account: accountA,
            runIdentity: 0x2C1,
            claim: runtimeClaim,
            status: .staged,
            activeClaimKind: nil,
            externallyExposed: true,
            hasSignedPCZT: true,
            hasExactTransaction: true,
            txid: Data(repeating: 0x44, count: 32),
            deliveryRevision: 0x2C2
        )
        Self.configureImmediateSubmission(welding, identity: 0x2C3)
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .knownUnsent
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )

        let outcome = try await migration.resumeStagedImmediateExternalSubmission()

        XCTAssertEqual(outcome, .knownUnsent)
        XCTAssertEqual(
            welding.migrationClaimSubmissionClaimForReceivedArguments?.claim.pointer,
            runtimeClaim.pointer
        )
        XCTAssertFalse(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCalled)
        XCTAssertFalse(welding.migrationPrepareImmediateExternalSigningClaimForCalled)
        XCTAssertFalse(welding.migrationClaimExternalSigningPCZTCalled)
        XCTAssertFalse(welding.migrationStageSignedPCZTClaimForCalled)
        XCTAssertFalse(welding.migrationFinalizeImmediateExternalSigningClaimForCalled)
        XCTAssertEqual(submitter.callsCount, 1)
    }

    func testNoResignScheduledResumeSubmitsOnlyTheSelectedDurablyStagedTransaction() async throws {
        let runtimeClaimIdentity = 0x2D0
        let transactionID: UInt32 = 37
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .staged,
            hasExactTransaction: true,
            runIdentity: 0x2D1,
            claimIdentity: runtimeClaimIdentity,
            transactionID: transactionID,
            signerOwnership: .external,
            externallyExposed: true,
            hasSignedPCZT: true
        )
        Self.configureImmediateSubmission(welding, identity: 0x2D2)
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .knownUnsent
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )

        let result = try await migration.resumeStagedScheduledExternalSubmission(
            transactionID: transactionID
        )

        XCTAssertEqual(result, .networkError(retryable: true))
        XCTAssertEqual(
            welding.migrationClaimSubmissionClaimForReceivedArguments?.claim.pointer,
            OpaquePointer(bitPattern: runtimeClaimIdentity)
        )
        XCTAssertFalse(welding.migrationClaimExternalSigningPCZTCalled)
        XCTAssertFalse(welding.migrationStageSignedPCZTClaimForCalled)
        XCTAssertFalse(welding.migrationAdvanceExternalSignatureClaimForCalled)
        XCTAssertFalse(welding.migrationProveClaimClaimForCalled)
        XCTAssertEqual(submitter.callsCount, 1)
    }

    // MARK: - Scheduled migration (opaque claim lane)

    func testPublicStateProgressAndStatusReadsReconcileThroughTheOpaqueRunFirst() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let runtime = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .broadcasted,
            hasExactTransaction: true,
            runIdentity: 90,
            claimIdentity: 91
        )
        welding.migrationRuntimeSnapshotForReturnValue = runtime
        welding.migrationReconcileCanonicalChainRunForReturnValue = Self.makeRunHandle(92)
        welding.migrationStateForClosure = { _ in
            XCTAssertEqual(welding.migrationReconcileCanonicalChainRunForCallsCount, 1)
            return .inProgress(
                MigrationProgress(
                    completedTransfers: 0,
                    totalTransfers: 1,
                    remainingOrchard: Zatoshi(1),
                    nextTransferReadyAtHeight: 2_000_040
                )
            )
        }
        welding.migrationProgressForClosure = { _ in
            XCTAssertEqual(welding.migrationReconcileCanonicalChainRunForCallsCount, 2)
            return MigrationProgress(
                completedTransfers: 0,
                totalTransfers: 1,
                remainingOrchard: Zatoshi(1),
                nextTransferReadyAtHeight: 2_000_040
            )
        }
        welding.migrationTransactionStatusesForClosure = { _ in
            XCTAssertEqual(welding.migrationReconcileCanonicalChainRunForCallsCount, 3)
            return []
        }
        let migration = makeMigration(welding: welding, account: accountA)

        _ = try await migration.migrationState()
        _ = try await migration.migrationProgress()
        _ = try await migration.transactionStatuses()

        XCTAssertEqual(welding.migrationRuntimeSnapshotForCallsCount, 6)
        XCTAssertEqual(welding.migrationReconcileCanonicalChainRunForCallsCount, 3)
        XCTAssertEqual(
            welding.migrationReconcileCanonicalChainRunForReceivedArguments?.run.pointer,
            runtime.delivery?.runHandle.pointer
        )
        XCTAssertEqual(welding.migrationReconcileCanonicalChainRunForReceivedArguments?.account, accountA)
    }

    func testPublicRuntimeSnapshotReturnsThePostReconciliationProjection() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let stale = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .broadcasted,
            hasExactTransaction: true,
            runIdentity: 86,
            claimIdentity: 87
        )
        let current = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .confirmed,
            hasExactTransaction: true,
            runIdentity: 88,
            claimIdentity: 89,
            canonicalStatus: .complete
        )
        var reads = 0
        welding.migrationRuntimeSnapshotForClosure = { _ in
            defer { reads += 1 }
            return reads == 0 ? stale : current
        }
        let migration = makeMigration(welding: welding, account: accountA)

        let snapshot = try await migration.runtimeSnapshot()

        XCTAssertEqual(snapshot.canonical.status, .complete)
        XCTAssertEqual(snapshot.delivery?.claims.first?.status, .confirmed)
        XCTAssertEqual(welding.migrationRuntimeSnapshotForCallsCount, 2)
        XCTAssertEqual(welding.migrationReconcileCanonicalChainRunForCallsCount, 1)
        XCTAssertEqual(
            welding.migrationReconcileCanonicalChainRunForReceivedArguments?.run.pointer,
            stale.delivery?.runHandle.pointer
        )
    }

    func testTerminalScheduleUsesOpaqueInternalRollover() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let staleRuntime = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .broadcasted,
            hasExactTransaction: true,
            runIdentity: 90,
            claimIdentity: 91
        )
        let reconciledRuntime = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .confirmed,
            hasExactTransaction: true,
            runIdentity: 92,
            claimIdentity: 93,
            canonicalStatus: .complete
        )
        var reads = 0
        welding.migrationRuntimeSnapshotForClosure = { _ in
            defer { reads += 1 }
            return reads == 0 ? staleRuntime : reconciledRuntime
        }
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        welding.migrationRolloverInternalSchedulePredecessorUskForReturnValue = Self.makeRunHandle(94)
        let migration = makeMigration(welding: welding, account: accountA)
        let schedule = Self.makeSchedule(count: 1)

        try await migration.signAndStoreMigrationSchedule(
            schedule,
            usk: TestsData(networkType: .testnet).spendingKey,
            options: Self.immediateOptions
        )

        XCTAssertEqual(welding.migrationRolloverInternalSchedulePredecessorUskForCallsCount, 1)
        XCTAssertEqual(
            welding.migrationRolloverInternalSchedulePredecessorUskForReceivedArguments?.schedule,
            schedule
        )
        XCTAssertEqual(
            welding.migrationRolloverInternalSchedulePredecessorUskForReceivedArguments?.predecessor.pointer,
            reconciledRuntime.delivery?.runHandle.pointer
        )
        XCTAssertEqual(welding.migrationRuntimeSnapshotForCallsCount, 2)
        XCTAssertEqual(welding.migrationReconcileCanonicalChainRunForCallsCount, 1)
        XCTAssertFalse(welding.migrationSignAndStoreScheduleUskForCalled)
    }

    func testInitialSDKScheduleRejectsPersistedPolicyValidationFailure() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let missingPolicy = Self.makeScheduledRuntime(
            account: accountA,
            availability: .unavailable(.submissionPolicyMissing),
            claimStatus: .materializationFailed,
            hasExactTransaction: false,
            runIdentity: 194,
            claimIdentity: 195
        )
        var reads = 0
        welding.migrationRuntimeSnapshotForClosure = { _ in
            defer { reads += 1 }
            return reads == 0 ? Self.makeNoRunRuntime(account: self.accountA) : missingPolicy
        }
        welding.migrationSignAndStoreScheduleUskForClosure = { _, _, _ in }
        welding.migrationReconcileCanonicalChainRunForReturnValue = Self.makeRunHandle(196)
        welding.migrationBindSubmissionPolicyRunForReturnValue = Self.makeRunHandle(197)
        // A validation failure is represented by a fresh Rust run handle with no bound target.
        welding.migrationBoundSubmissionTargetForReturnValue = nil
        let migration = makeMigration(welding: welding, account: accountA)

        do {
            try await migration.signAndStoreMigrationSchedule(
                Self.makeSchedule(count: 1),
                usk: TestsData(networkType: .testnet).spendingKey,
                options: Self.immediateOptions
            )
            XCTFail("Expected persisted policy validation failure")
        } catch MigrationDeliveryError.runtimeUnavailable(.submissionPolicyMismatch) {
            // expected
        } catch {
            XCTFail("Expected submissionPolicyMismatch but got \(error)")
        }

        XCTAssertEqual(welding.migrationSignAndStoreScheduleUskForCallsCount, 1)
        XCTAssertEqual(welding.migrationBindSubmissionPolicyRunForCallsCount, 1)
        XCTAssertEqual(welding.migrationBoundSubmissionTargetForCallsCount, 1)
    }

    func testInitialSDKScheduleAcceptsOnlyTheTargetProjectedByTheBoundHandle() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let missingPolicy = Self.makeScheduledRuntime(
            account: accountA,
            availability: .unavailable(.submissionPolicyMissing),
            claimStatus: .materializationFailed,
            hasExactTransaction: false,
            runIdentity: 198,
            claimIdentity: 199
        )
        var reads = 0
        welding.migrationRuntimeSnapshotForClosure = { _ in
            defer { reads += 1 }
            return reads == 0 ? Self.makeNoRunRuntime(account: self.accountA) : missingPolicy
        }
        welding.migrationSignAndStoreScheduleUskForClosure = { _, _, _ in }
        welding.migrationReconcileCanonicalChainRunForReturnValue = Self.makeRunHandle(200)
        welding.migrationBindSubmissionPolicyRunForReturnValue = Self.makeRunHandle(201)
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://SUBMIT.EXAMPLE:9067/"
        )
        let migration = makeMigration(welding: welding, account: accountA)

        try await migration.signAndStoreMigrationSchedule(
            Self.makeSchedule(count: 1),
            usk: TestsData(networkType: .testnet).spendingKey,
            options: Self.immediateOptions
        )

        XCTAssertEqual(welding.migrationBoundSubmissionTargetForCallsCount, 1)
    }

    func testTerminalSDKScheduleRejectsDifferentPolicyBeforeAtomicRollover() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .confirmed,
            hasExactTransaction: true,
            runIdentity: 95,
            claimIdentity: 96,
            canonicalStatus: .complete
        )
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://different.example:9067"
        )
        let migration = makeMigration(welding: welding, account: accountA)

        do {
            try await migration.signAndStoreMigrationSchedule(
                Self.makeSchedule(count: 1),
                usk: TestsData(networkType: .testnet).spendingKey,
                options: Self.immediateOptions
            )
            XCTFail("Expected inherited submission policy mismatch")
        } catch MigrationDeliveryError.runtimeUnavailable(.submissionPolicyMismatch) {
            // expected
        } catch {
            XCTFail("Expected submissionPolicyMismatch but got \(error)")
        }

        XCTAssertFalse(welding.migrationRolloverInternalSchedulePredecessorUskForCalled)
        XCTAssertFalse(welding.migrationSignAndStoreScheduleUskForCalled)
        XCTAssertFalse(welding.migrationBindSubmissionPolicyRunForCalled)
    }

    func testTerminalExternalScheduleUsesOpaqueRolloverWithAtomicallyInheritedPolicy() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let runtime = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .confirmed,
            hasExactTransaction: true,
            runIdentity: 93,
            claimIdentity: 94,
            canonicalStatus: .complete
        )
        welding.migrationRuntimeSnapshotForReturnValue = runtime
        welding.migrationRolloverExternalSchedulePredecessorForReturnValue = Self.makeRunHandle(95)
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        let migration = makeMigration(welding: welding, account: accountA)
        let schedule = Self.makeSchedule(count: 1)

        _ = try await migration.commitMigrationScheduleForExternalSigning(
            schedule,
            options: Self.immediateOptions
        )

        XCTAssertEqual(welding.migrationRolloverExternalSchedulePredecessorForCallsCount, 1)
        XCTAssertFalse(welding.migrationCommitExternalScheduleForCalled)
        XCTAssertFalse(welding.migrationBindSubmissionPolicyRunForCalled)
        XCTAssertEqual(welding.migrationBoundSubmissionTargetForCallsCount, 1)
    }

    func testTerminalExternalScheduleRejectsDifferentPolicyBeforeAtomicRollover() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .confirmed,
            hasExactTransaction: true,
            runIdentity: 96,
            claimIdentity: 97,
            canonicalStatus: .complete
        )
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://different.example:9067"
        )
        let migration = makeMigration(welding: welding, account: accountA)

        do {
            _ = try await migration.commitMigrationScheduleForExternalSigning(
                Self.makeSchedule(count: 1),
                options: Self.immediateOptions
            )
            XCTFail("Expected inherited submission policy mismatch")
        } catch MigrationDeliveryError.runtimeUnavailable(.submissionPolicyMismatch) {
            // expected
        } catch {
            XCTFail("Expected submissionPolicyMismatch but got \(error)")
        }

        XCTAssertFalse(welding.migrationRolloverExternalSchedulePredecessorForCalled)
        XCTAssertFalse(welding.migrationBindSubmissionPolicyRunForCalled)
        XCTAssertFalse(welding.migrationCommitExternalScheduleForCalled)
    }

    func testPrepareExternalSigningRecoversExposedClaimBeforeMintingAnother() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let runtime = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .awaitingExternalSignature,
            activeClaimKind: .materialization,
            hasExactTransaction: false,
            runIdentity: 97,
            claimIdentity: 98,
            signerOwnership: .external,
            externallyExposed: true,
            hasSignedPCZT: false
        )
        let reacquired = Self.makeClaimHandle(99)
        let canonicalPCZT = Data("CANONICAL-PCZT".utf8)
        welding.migrationRuntimeSnapshotForReturnValue = runtime
        welding.migrationResumeClaimClaimForReturnValue = nil
        welding.migrationReacquireExternalSigningClaimForReturnValue = reacquired
        welding.migrationClaimExternalSigningPCZTReturnValue = canonicalPCZT
        let migration = makeMigration(welding: welding, account: accountA)

        let request = try await migration.prepareNextMigrationTransactionForExternalSigning()

        XCTAssertEqual(request?.transactionID, 7)
        XCTAssertEqual(request?.pczt, canonicalPCZT)
        XCTAssertEqual(request?.claim.pointer, reacquired.pointer)
        XCTAssertEqual(welding.migrationResumeClaimClaimForCallsCount, 1)
        XCTAssertEqual(welding.migrationReacquireExternalSigningClaimForCallsCount, 1)
        XCTAssertFalse(welding.migrationClaimMaterializationTransactionIDSignerRunForCalled)
        XCTAssertFalse(welding.migrationStageExternalSigningPCZTClaimForCalled)
    }

    func testPrepareExternalSigningReacquiresExactKnownUnsentMaterializationFailure() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let runtime = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .materializationFailed,
            hasExactTransaction: false,
            runIdentity: 100,
            claimIdentity: 101,
            signerOwnership: .external,
            externallyExposed: false,
            hasSignedPCZT: false
        )
        let reacquired = Self.makeClaimHandle(102)
        let staged = Self.makeClaimHandle(103)
        let canonicalPCZT = Data("REACQUIRED-CANONICAL-PCZT".utf8)
        welding.migrationRuntimeSnapshotForReturnValue = runtime
        welding.migrationResumeClaimClaimForReturnValue = nil
        welding.migrationClaimMaterializationTransactionIDSignerRunForReturnValue = reacquired
        welding.migrationStageExternalSigningPCZTClaimForReturnValue = staged
        welding.migrationClaimExternalSigningPCZTReturnValue = canonicalPCZT
        let migration = makeMigration(welding: welding, account: accountA)

        let request = try await migration.prepareNextMigrationTransactionForExternalSigning()

        XCTAssertEqual(request?.transactionID, 7)
        XCTAssertEqual(request?.pczt, canonicalPCZT)
        XCTAssertEqual(request?.claim.pointer, staged.pointer)
        XCTAssertEqual(welding.migrationResumeClaimClaimForCallsCount, 1)
        XCTAssertEqual(welding.migrationClaimMaterializationTransactionIDSignerRunForCallsCount, 1)
        XCTAssertEqual(
            welding.migrationClaimMaterializationTransactionIDSignerRunForReceivedArguments?.transactionID,
            7
        )
        XCTAssertEqual(
            welding.migrationClaimMaterializationTransactionIDSignerRunForReceivedArguments?.signer,
            .external
        )
        XCTAssertEqual(
            welding.migrationClaimMaterializationTransactionIDSignerRunForReceivedArguments?.run.pointer,
            runtime.delivery?.runHandle.pointer
        )
        XCTAssertEqual(welding.migrationStageExternalSigningPCZTClaimForCallsCount, 1)
        XCTAssertEqual(
            welding.migrationStageExternalSigningPCZTClaimForReceivedArguments?.claim.pointer,
            reacquired.pointer
        )
    }

    func testScheduledExternalSigningRelaunchAfterCanonicalSignedResumesProofWithoutReapplyingSignature() async throws {
        let runtime = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .awaitingExternalSignature,
            activeClaimKind: .materialization,
            hasExactTransaction: false,
            runIdentity: 111,
            claimIdentity: 110,
            signerOwnership: .external,
            externallyExposed: true,
            hasSignedPCZT: true
        )
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = runtime
        let active = Self.makeClaimHandle(112)
        welding.migrationResumeClaimClaimForReturnValue = active
        let canonicalPCZT = Data("SIGNED-BOUND-CANONICAL-PCZT".utf8)
        welding.migrationClaimExternalSigningPCZTReturnValue = canonicalPCZT
        welding.migrationTransactionStatusesForReturnValue = [
            MigrationTransactionStatus(
                id: 7,
                kind: .transfer(crossing: 0),
                state: .signed,
                scheduledHeight: 2_000_010,
                expiryHeight: 2_000_040,
                isReady: true,
                nextAction: .prove,
                blockedOn: nil
            )
        ]
        welding.migrationProveClaimClaimForReturnValue = Self.makeClaimHandle(113)
        Self.configureImmediateSubmission(welding, identity: 114)
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .accepted
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )

        let recovered = try await migration.prepareNextMigrationTransactionForExternalSigning()
        let request = try XCTUnwrap(recovered)
        let result = try await migration.submitExternallySignedMigrationTransaction(
            request: request,
            signedPCZT: Data("CALLER-RETRY-MUST-BE-IGNORED".utf8)
        )

        XCTAssertEqual(result, .success(txId: Data(repeating: 0x44, count: 32).toHexStringTxId()))
        XCTAssertFalse(welding.migrationStageSignedPCZTClaimForCalled)
        XCTAssertFalse(welding.migrationAdvanceExternalSignatureClaimForCalled)
        XCTAssertEqual(welding.migrationProveClaimClaimForReceivedArguments?.claim.pointer, active.pointer)
        XCTAssertEqual(submitter.callsCount, 1)
    }

    func testRebuildExpiredSDKTransferUsesExactRuntimeClaim() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let runtime = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .expiredUnmined,
            hasExactTransaction: true,
            runIdentity: 130,
            claimIdentity: 131
        )
        welding.migrationRuntimeSnapshotForReturnValue = runtime
        welding.migrationRebuildExpiredTransferClaimSignerUskForReturnValue = Self.makeClaimHandle(132)
        let migration = makeMigration(welding: welding, account: accountA)

        let result = try await migration.rebuildExpiredTransfer(
            transactionID: 7,
            usk: TestsData(networkType: .testnet).spendingKey
        )

        XCTAssertEqual(result, runtime)
        XCTAssertEqual(welding.migrationRebuildExpiredTransferClaimSignerUskForCallsCount, 1)
        XCTAssertEqual(
            welding.migrationRebuildExpiredTransferClaimSignerUskForReceivedArguments?.claim.pointer,
            runtime.delivery?.claims.first?.claimHandle.pointer
        )
        XCTAssertEqual(
            welding.migrationRebuildExpiredTransferClaimSignerUskForReceivedArguments?.signer,
            .sdk
        )
        XCTAssertEqual(
            welding.migrationRebuildExpiredTransferClaimSignerUskForReceivedArguments?.account,
            accountA
        )
    }

    func testPauseResumeAndAbandonmentForwardTheOpaqueRun() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let runtime = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .materializationFailed,
            hasExactTransaction: false,
            runIdentity: 140,
            claimIdentity: 141
        )
        welding.migrationRuntimeSnapshotForReturnValue = runtime
        welding.migrationPauseDeliveryRunForReturnValue = Self.makeRunHandle(142)
        welding.migrationResumeDeliveryRunForReturnValue = Self.makeRunHandle(143)
        welding.migrationBeginAbandonmentRunForReturnValue = Self.makeRunHandle(144)
        welding.migrationFinishAbandonmentRunForReturnValue = Self.makeRunHandle(145)
        let migration = makeMigration(welding: welding, account: accountA)

        _ = try await migration.pauseDelivery()
        _ = try await migration.resumeDelivery()
        _ = try await migration.beginAbandonment()
        _ = try await migration.finishAbandonment()

        let expected = runtime.delivery?.runHandle.pointer
        XCTAssertEqual(welding.migrationPauseDeliveryRunForReceivedArguments?.run.pointer, expected)
        XCTAssertEqual(welding.migrationResumeDeliveryRunForReceivedArguments?.run.pointer, expected)
        XCTAssertEqual(welding.migrationBeginAbandonmentRunForReceivedArguments?.run.pointer, expected)
        XCTAssertEqual(welding.migrationFinishAbandonmentRunForReceivedArguments?.run.pointer, expected)
    }

    func testExecuteNextPendingTransferBindsPolicyClaimsProvesAndSubmitsExactRustBytes() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let initial = Self.makeScheduledRuntime(
            account: accountA,
            availability: .unavailable(.submissionPolicyMissing),
            claimStatus: .materializationFailed,
            hasExactTransaction: false,
            runIdentity: 100,
            claimIdentity: 101
        )
        let bound = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .materializationFailed,
            hasExactTransaction: false,
            runIdentity: 102,
            claimIdentity: 103
        )
        var snapshotReads = 0
        welding.migrationRuntimeSnapshotForClosure = { _ in
            defer { snapshotReads += 1 }
            return snapshotReads == 0 ? initial : bound
        }
        welding.migrationBindSubmissionPolicyRunForReturnValue = Self.makeRunHandle(104)
        welding.migrationReconcileCanonicalChainRunForReturnValue = Self.makeRunHandle(105)
        welding.migrationClaimMaterializationTransactionIDSignerRunForReturnValue = Self.makeClaimHandle(106)
        welding.migrationProveClaimClaimForReturnValue = Self.makeClaimHandle(107)
        Self.configureImmediateSubmission(welding, identity: 108)

        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .accepted
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )

        let result = try await migration.executeNextPendingTransfer(options: Self.immediateOptions)

        XCTAssertEqual(result, .success(txId: Data(repeating: 0x44, count: 32).toHexStringTxId()))
        XCTAssertEqual(welding.migrationRuntimeSnapshotForCallsCount, 2)
        XCTAssertEqual(
            welding.migrationBindSubmissionPolicyRunForReceivedArguments?.intent,
            MigrationSubmissionIntent(transport: .directTLS, endpoint: "https://submit.example:9067")
        )
        XCTAssertEqual(
            welding.migrationClaimMaterializationTransactionIDSignerRunForReceivedArguments?.transactionID,
            7
        )
        XCTAssertEqual(
            welding.migrationClaimMaterializationTransactionIDSignerRunForReceivedArguments?.signer,
            .sdk
        )
        XCTAssertEqual(welding.migrationProveClaimClaimForCallsCount, 1)
        XCTAssertEqual(submitter.receivedArguments?.transaction.raw, Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(welding.migrationRecordSubmissionOutcomeClaimForReceivedArguments?.outcome, .accepted)
        let isBlocked = await migration.isSyncBlocked()
        XCTAssertTrue(isBlocked)
    }

    func testExecuteNextPendingTransferRejectsEveryNonBindableUnavailableRuntimeBeforeMutation() async throws {
        let reasons: [MigrationRuntimeUnavailableReason] = [
            .schemaUnavailable,
            .futureSchema(version: 2),
            .corruptDeliveryState,
            .legacyCutoverRecovery(objects: 1),
            .submissionPolicyMismatch,
            .deliveryInconsistent,
            .finalityRecovery(.transferEvidenceLost)
        ]

        for reason in reasons {
            let welding = ZcashRustBackendWeldingMock()
            welding.migrationRuntimeSnapshotForReturnValue = Self.makeScheduledRuntime(
                account: accountA,
                availability: .unavailable(reason),
                claimStatus: .staged,
                hasExactTransaction: true,
                runIdentity: 150,
                claimIdentity: 151
            )
            let submitter = MigrationTransactionSubmitterMock()
            let migration = makeMigration(
                welding: welding,
                account: accountA,
                transactionSubmitter: submitter
            )

            do {
                _ = try await migration.executeNextPendingTransfer(options: Self.immediateOptions)
                XCTFail("Expected the unavailable runtime to fail closed: \(reason)")
            } catch MigrationDeliveryError.runtimeUnavailable(let actualReason) {
                XCTAssertEqual(actualReason, reason)
            } catch {
                XCTFail("Expected runtimeUnavailable(\(reason)) but got \(error)")
            }

            XCTAssertFalse(welding.migrationBindSubmissionPolicyRunForCalled)
            XCTAssertFalse(welding.migrationReconcileCanonicalChainRunForCalled)
            XCTAssertFalse(welding.migrationClaimMaterializationTransactionIDSignerRunForCalled)
            XCTAssertFalse(welding.migrationProveClaimClaimForCalled)
            XCTAssertFalse(welding.migrationClaimSubmissionClaimForCalled)
            XCTAssertEqual(submitter.callsCount, 0)
        }
    }

    func testExecuteNextPendingTransferAfterRelaunchUsesThePersistedStagedClaimWithoutRematerializing() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let runtime = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .staged,
            hasExactTransaction: true,
            runIdentity: 160,
            claimIdentity: 161
        )
        welding.migrationRuntimeSnapshotForReturnValue = runtime
        welding.migrationBindSubmissionPolicyRunForReturnValue = Self.makeRunHandle(162)
        welding.migrationReconcileCanonicalChainRunForReturnValue = Self.makeRunHandle(163)
        Self.configureImmediateSubmission(welding, identity: 164)
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .accepted

        // A newly created actor has no Swift-retained claim. Its only authority is the staged claim
        // projected from durable Rust state above, exactly as after process relaunch.
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )
        let result = try await migration.executeNextPendingTransfer(options: Self.immediateOptions)

        XCTAssertEqual(result, .success(txId: Data(repeating: 0x44, count: 32).toHexStringTxId()))
        XCTAssertEqual(
            welding.migrationClaimSubmissionClaimForReceivedArguments?.claim.pointer,
            runtime.delivery?.claims.first?.claimHandle.pointer
        )
        XCTAssertEqual(welding.migrationClaimSubmissionClaimForReceivedArguments?.account, accountA)
        XCTAssertFalse(welding.migrationClaimMaterializationTransactionIDSignerRunForCalled)
        XCTAssertFalse(welding.migrationProveClaimClaimForCalled)
        XCTAssertFalse(welding.migrationResumeClaimClaimForCalled)
        XCTAssertEqual(submitter.callsCount, 1)
        XCTAssertEqual(welding.migrationRecordSubmissionOutcomeClaimForReceivedArguments?.outcome, .accepted)
    }

    func testExecuteNextPendingTransferNeverSubmitsAnExternalSignerStagedClaim() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationRuntimeSnapshotForReturnValue = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .staged,
            hasExactTransaction: true,
            runIdentity: 0x2C0,
            claimIdentity: 0x2C1,
            signerOwnership: .external,
            externallyExposed: true
        )
        welding.migrationBindSubmissionPolicyRunForReturnValue = Self.makeRunHandle(0x2C2)
        welding.migrationReconcileCanonicalChainRunForReturnValue = Self.makeRunHandle(0x2C3)
        let submitter = MigrationTransactionSubmitterMock()
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )

        let result = try await migration.executeNextPendingTransfer(options: Self.immediateOptions)

        XCTAssertNil(result)
        XCTAssertFalse(welding.migrationClaimSubmissionClaimForCalled)
        XCTAssertFalse(welding.migrationResumeClaimClaimForCalled)
        XCTAssertFalse(welding.migrationClaimMaterializationTransactionIDSignerRunForCalled)
        XCTAssertEqual(submitter.callsCount, 0)
    }

    func testExecuteNextPendingTransferReconcilesUnknownClaimWithoutResubmitting() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let initial = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .outcomeUnknown,
            activeClaimKind: .outcomeResolution,
            hasExactTransaction: true,
            runIdentity: 120,
            claimIdentity: 121
        )
        welding.migrationRuntimeSnapshotForReturnValue = initial
        welding.migrationBindSubmissionPolicyRunForReturnValue = Self.makeRunHandle(122)
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        welding.migrationReconcileCanonicalChainRunForReturnValue = Self.makeRunHandle(123)
        welding.migrationClaimOutcomeResolutionClaimForReturnValue = Self.makeClaimHandle(124)
        welding.migrationReconcileSubmissionClaimForReturnValue = Self.makeClaimHandle(125)
        let submitter = MigrationTransactionSubmitterMock()
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )

        let result = try await migration.executeNextPendingTransfer(options: Self.immediateOptions)

        XCTAssertNil(result)
        XCTAssertEqual(welding.migrationClaimOutcomeResolutionClaimForCallsCount, 1)
        XCTAssertEqual(welding.migrationReconcileSubmissionClaimForCallsCount, 1)
        XCTAssertEqual(submitter.callsCount, 0)
        XCTAssertFalse(welding.migrationClaimSubmissionClaimForCalled)
        let isBlocked = await migration.isSyncBlocked()
        XCTAssertFalse(isBlocked)
    }

    func testTwoAccountActorsKeepOpaqueClaimsAndSubmissionOutcomesAccountScoped() async throws {
        let accountA = self.accountA
        let accountB = AccountUUID(id: [UInt8](repeating: 0x22, count: 16))
        let runtimeA = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .staged,
            hasExactTransaction: true,
            runIdentity: 170,
            claimIdentity: 171
        )
        let runtimeB = Self.makeScheduledRuntime(
            account: accountB,
            availability: .available,
            claimStatus: .staged,
            hasExactTransaction: true,
            runIdentity: 180,
            claimIdentity: 181
        )
        let stagedA = try XCTUnwrap(runtimeA.delivery?.claims.first?.claimHandle)
        let stagedB = try XCTUnwrap(runtimeB.delivery?.claims.first?.claimHandle)
        let runtimeRunA = try XCTUnwrap(runtimeA.delivery?.runHandle)
        let runtimeRunB = try XCTUnwrap(runtimeB.delivery?.runHandle)
        let boundRunA = Self.makeRunHandle(172)
        let boundRunB = Self.makeRunHandle(182)
        let activeA = Self.makeClaimHandle(173)
        let activeB = Self.makeClaimHandle(183)
        let txidA = Data(repeating: 0xA1, count: 32)
        let txidB = Data(repeating: 0xB2, count: 32)
        let welding = ZcashRustBackendWeldingMock()

        welding.migrationRuntimeSnapshotForClosure = { account in
            if account == accountA { return runtimeA }
            if account == accountB { return runtimeB }
            throw MigrationDeliveryError.claimUnavailable
        }
        welding.migrationBindSubmissionPolicyRunForClosure = { _, run, account in
            if account == accountA, run.pointer == runtimeRunA.pointer { return boundRunA }
            if account == accountB, run.pointer == runtimeRunB.pointer { return boundRunB }
            throw MigrationDeliveryError.claimUnavailable
        }
        welding.migrationReconcileCanonicalChainRunForClosure = { run, account in
            if account == accountA, run.pointer == boundRunA.pointer { return run }
            if account == accountB, run.pointer == boundRunB.pointer { return run }
            throw MigrationDeliveryError.claimUnavailable
        }
        welding.migrationClaimSubmissionClaimForClosure = { claim, account in
            if account == accountA, claim.pointer == stagedA.pointer { return activeA }
            if account == accountB, claim.pointer == stagedB.pointer { return activeB }
            throw MigrationDeliveryError.claimUnavailable
        }
        welding.migrationClaimRunClosure = { claim in
            if claim.pointer == activeA.pointer { return boundRunA }
            if claim.pointer == activeB.pointer { return boundRunB }
            throw MigrationDeliveryError.claimUnavailable
        }
        welding.migrationBoundSubmissionTargetForClosure = { run in
            guard run.pointer == boundRunA.pointer || run.pointer == boundRunB.pointer else {
                throw MigrationDeliveryError.claimUnavailable
            }
            return MigrationBoundSubmissionTarget(
                transport: .directTLS,
                endpoint: "https://submit.example:9067"
            )
        }
        welding.migrationClaimExactTransactionClosure = { claim in
            if claim.pointer == activeA.pointer { return Data([0xAA]) }
            if claim.pointer == activeB.pointer { return Data([0xBB]) }
            throw MigrationDeliveryError.claimUnavailable
        }
        welding.migrationClaimTransactionIDClosure = { claim in
            if claim.pointer == activeA.pointer { return txidA }
            if claim.pointer == activeB.pointer { return txidB }
            throw MigrationDeliveryError.claimUnavailable
        }
        welding.migrationClaimExpiryHeightReturnValue = 2_000_040
        welding.migrationClaimConsensusBranchIDReturnValue = 0xC8E71055
        welding.migrationRecordSubmissionOutcomeClaimForClosure = { outcome, claim, account in
            guard outcome == .accepted else { throw MigrationDeliveryError.claimUnavailable }
            if account == accountA, claim.pointer == activeA.pointer { return Self.makeClaimHandle(174) }
            if account == accountB, claim.pointer == activeB.pointer { return Self.makeClaimHandle(184) }
            throw MigrationDeliveryError.claimUnavailable
        }
        let submitter = MigrationTransactionSubmitterMock()
        submitter.result = .accepted
        let migrationA = makeMigration(welding: welding, account: accountA, transactionSubmitter: submitter)
        let migrationB = makeMigration(welding: welding, account: accountB, transactionSubmitter: submitter)

        let resultA = try await migrationA.executeNextPendingTransfer(options: Self.immediateOptions)
        let resultB = try await migrationB.executeNextPendingTransfer(options: Self.immediateOptions)

        XCTAssertEqual(resultA, .success(txId: txidA.toHexStringTxId()))
        XCTAssertEqual(resultB, .success(txId: txidB.toHexStringTxId()))
        XCTAssertEqual(welding.migrationClaimSubmissionClaimForCallsCount, 2)
        XCTAssertEqual(welding.migrationRecordSubmissionOutcomeClaimForCallsCount, 2)
        XCTAssertEqual(welding.migrationRecordSubmissionOutcomeClaimForReceivedArguments?.account, accountB)
    }

    func testSerializedBroadcastFlowLetsOnlyOneConcurrentCallerSubmitTheStagedClaim() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let stagedRuntime = Self.makeScheduledRuntime(
            account: accountA,
            availability: .available,
            claimStatus: .staged,
            hasExactTransaction: true,
            runIdentity: 190,
            claimIdentity: 191
        )
        let runtimeState = SingleFlightMigrationRuntimeState(
            initial: stagedRuntime,
            terminal: Self.makeNoRunRuntime(account: accountA)
        )
        welding.migrationRuntimeSnapshotForClosure = { _ in await runtimeState.snapshot() }
        welding.migrationBindSubmissionPolicyRunForReturnValue = Self.makeRunHandle(192)
        welding.migrationReconcileCanonicalChainRunForReturnValue = Self.makeRunHandle(193)
        Self.configureImmediateSubmission(welding, identity: 194)
        welding.migrationRecordSubmissionOutcomeClaimForClosure = { _, _, _ in
            await runtimeState.markTerminal()
            return Self.makeClaimHandle(197)
        }
        let submitter = GatedMigrationTransactionSubmitter()
        let migration = makeMigration(
            welding: welding,
            account: accountA,
            transactionSubmitter: submitter
        )

        let first = Task {
            try await migration.executeNextPendingTransfer(options: Self.immediateOptions)
        }
        await submitter.waitUntilCallCount(1)

        let secondStarted = expectation(description: "the concurrent caller started")
        let second = Task {
            secondStarted.fulfill()
            return try await migration.executeNextPendingTransfer(options: Self.immediateOptions)
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        for _ in 0 ..< 20 { await Task.yield() }

        let callsWhileFirstIsSuspended = await submitter.currentCallCount()
        XCTAssertEqual(callsWhileFirstIsSuspended, 1)
        await submitter.release()

        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, .success(txId: Data(repeating: 0x44, count: 32).toHexStringTxId()))
        XCTAssertNil(secondResult)
        let finalCallCount = await submitter.currentCallCount()
        XCTAssertEqual(finalCallCount, 1)
        XCTAssertEqual(welding.migrationRecordSubmissionOutcomeClaimForCallsCount, 1)
    }

    func testSerializedBroadcastFlowLetsOnlyOneConcurrentCallerPrepareImmediateExternalSigning() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let reservedClaim = Self.makeClaimHandle(0x2A0)
        let stagedClaim = Self.makeClaimHandle(0x2A1)
        let resumedClaim = Self.makeClaimHandle(0x2A2)
        let stagedPCZT = Data("SINGLE-FLIGHT-EXTERNAL-PCZT".utf8)
        let stagedRuntime = Self.makeImmediateExternalRuntime(
            account: accountA,
            runIdentity: 0x2A3,
            claim: stagedClaim,
            deliveryRevision: 0x2A4
        )
        let runtimeState = SingleFlightMigrationRuntimeState(
            initial: Self.makeNoRunRuntime(account: accountA),
            terminal: stagedRuntime
        )
        let preparationGate = GatedAsyncOperation()

        welding.migrationRuntimeSnapshotForClosure = { _ in await runtimeState.snapshot() }
        welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForReturnValue = reservedClaim
        welding.migrationPrepareImmediateExternalSigningClaimForClosure = { claim, account in
            XCTAssertEqual(claim.pointer, reservedClaim.pointer)
            XCTAssertEqual(account, self.accountA)
            await preparationGate.suspend()
            await runtimeState.markTerminal()
            return stagedClaim
        }
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        welding.migrationResumeClaimClaimForReturnValue = resumedClaim
        welding.migrationClaimExternalSigningPCZTReturnValue = stagedPCZT
        let migration = makeMigration(welding: welding, account: accountA)

        let first = Task {
            try await migration.prepareImmediateMigrationForExternalSigning(
                maximumGrossAmount: Self.immediateMaximumGrossAmount,
                options: Self.immediateOptions
            )
        }
        await preparationGate.waitUntilSuspended()

        let secondStarted = expectation(description: "the concurrent external preparation started")
        let second = Task {
            secondStarted.fulfill()
            return try await migration.prepareImmediateMigrationForExternalSigning(
                maximumGrossAmount: Self.immediateMaximumGrossAmount,
                options: Self.immediateOptions
            )
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        for _ in 0 ..< 20 { await Task.yield() }

        XCTAssertEqual(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCallsCount, 1)
        XCTAssertEqual(welding.migrationPrepareImmediateExternalSigningClaimForCallsCount, 1)
        XCTAssertEqual(welding.migrationRuntimeSnapshotForCallsCount, 1)

        await preparationGate.release()
        let firstRequest = try await first.value
        let secondRequest = try await second.value

        XCTAssertEqual(firstRequest.pczt, stagedPCZT)
        XCTAssertEqual(secondRequest.pczt, stagedPCZT)
        XCTAssertEqual(firstRequest.claim.pointer, stagedClaim.pointer)
        XCTAssertEqual(secondRequest.claim.pointer, resumedClaim.pointer)
        XCTAssertEqual(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCallsCount, 1)
        XCTAssertEqual(welding.migrationPrepareImmediateExternalSigningClaimForCallsCount, 1)
        XCTAssertEqual(welding.migrationRuntimeSnapshotForCallsCount, 2)
        XCTAssertEqual(welding.migrationResumeClaimClaimForCallsCount, 1)
    }

    func testCancelledQueuedExternalPreparationNeverReachesAWeldingMutation() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let reservedClaim = Self.makeClaimHandle(0x2B0)
        let stagedClaim = Self.makeClaimHandle(0x2B1)
        let stagedPCZT = Data("CANCELLED-WAITER-MUST-NOT-PREPARE".utf8)
        let preparationGate = GatedAsyncOperation()

        welding.migrationRuntimeSnapshotForReturnValue = Self.makeNoRunRuntime(account: accountA)
        welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForReturnValue = reservedClaim
        welding.migrationPrepareImmediateExternalSigningClaimForClosure = { _, _ in
            await preparationGate.suspend()
            return stagedClaim
        }
        welding.migrationClaimExternalSigningPCZTReturnValue = stagedPCZT
        let migration = makeMigration(welding: welding, account: accountA)

        let first = Task {
            try await migration.prepareImmediateMigrationForExternalSigning(
                maximumGrossAmount: Self.immediateMaximumGrossAmount,
                options: Self.immediateOptions
            )
        }
        await preparationGate.waitUntilSuspended()

        let secondStarted = expectation(description: "the cancellable waiter started")
        let second = Task {
            secondStarted.fulfill()
            return try await migration.prepareImmediateMigrationForExternalSigning(
                maximumGrossAmount: Self.immediateMaximumGrossAmount,
                options: Self.immediateOptions
            )
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        for _ in 0 ..< 20 { await Task.yield() }
        second.cancel()

        await preparationGate.release()
        let firstRequest = try await first.value
        XCTAssertEqual(firstRequest.pczt, stagedPCZT)
        do {
            _ = try await second.value
            XCTFail("Expected the queued caller to observe cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Expected CancellationError but got \(error)")
        }

        XCTAssertEqual(welding.migrationRuntimeSnapshotForCallsCount, 1)
        XCTAssertEqual(welding.migrationReserveImmediateSignerMaximumGrossAmountSubmissionForCallsCount, 1)
        XCTAssertEqual(welding.migrationPrepareImmediateExternalSigningClaimForCallsCount, 1)
        XCTAssertEqual(welding.migrationClaimExternalSigningPCZTCallsCount, 1)
    }

    // MARK: - Residual locking and the run-count estimate (delegation)

    /// `lockMigrationResidual()` is a straight delegation to the welding lock call, bound to this
    /// actor's own account: the total the welding reports comes back untouched.
    func testLockMigrationResidualForwardsTotalAndAccount() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.lockMigrationResidualAccountUUIDReturnValue = Zatoshi(38_000)
        let migration = makeMigration(welding: welding, account: accountA)

        let locked = try await migration.lockMigrationResidual()

        XCTAssertEqual(locked, Zatoshi(38_000))
        XCTAssertEqual(welding.lockMigrationResidualAccountUUIDReceivedAccountUUID, accountA)
    }

    /// A zero locked total is a legitimate outcome (nothing was spendable, or everything spendable
    /// was already locked), not an error: it passes through unchanged.
    func testLockMigrationResidualZeroTotalPassesThrough() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.lockMigrationResidualAccountUUIDReturnValue = Zatoshi.zero
        let migration = makeMigration(welding: welding, account: accountA)

        let locked = try await migration.lockMigrationResidual()

        XCTAssertEqual(locked, Zatoshi.zero)
    }

    /// The concurrent-lock race (and any other engine failure) surfaces as the welding's own
    /// `rustMigrationLockResidual`, rethrown untouched so the caller can retry.
    func testLockMigrationResidualRethrowsWhenWeldingThrows() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.lockMigrationResidualAccountUUIDThrowableError = ZcashError.rustMigrationLockResidual("boom")
        let migration = makeMigration(welding: welding, account: accountA)

        do {
            _ = try await migration.lockMigrationResidual()
            XCTFail("Expected lockMigrationResidual to rethrow the welding error")
        } catch ZcashError.rustMigrationLockResidual {
            // expected
        } catch {
            XCTFail("Expected rustMigrationLockResidual but got \(error)")
        }
    }

    /// `unlockMigrationResidual()` is the release half: a straight delegation returning the
    /// welding's cleared-lock count, bound to this actor's own account.
    func testUnlockMigrationResidualForwardsCountAndAccount() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.unlockMigrationResidualAccountUUIDReturnValue = 4
        let migration = makeMigration(welding: welding, account: accountA)

        let cleared = try await migration.unlockMigrationResidual()

        XCTAssertEqual(cleared, 4)
        XCTAssertEqual(welding.unlockMigrationResidualAccountUUIDReceivedAccountUUID, accountA)
    }

    func testUnlockMigrationResidualRethrowsWhenWeldingThrows() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.unlockMigrationResidualAccountUUIDThrowableError = ZcashError.rustMigrationUnlockResidual("boom")
        let migration = makeMigration(welding: welding, account: accountA)

        do {
            _ = try await migration.unlockMigrationResidual()
            XCTFail("Expected unlockMigrationResidual to rethrow the welding error")
        } catch ZcashError.rustMigrationUnlockResidual {
            // expected
        } catch {
            XCTFail("Expected rustMigrationUnlockResidual but got \(error)")
        }
    }

    /// `estimateMigrationRuns()` returns the welding's estimate untouched: every per-run field
    /// (crossings, preparation layers/transactions, migratable value) and the final residual flow
    /// through, so the model's derived queries answer over exactly what the engine reported.
    func testEstimateMigrationRunsReturnsWeldingEstimateUntouched() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let estimate = Self.makeRunEstimate()
        welding.estimateMigrationRunsAccountUUIDReturnValue = estimate
        let migration = makeMigration(welding: welding, account: accountA)

        let returned = try await migration.estimateMigrationRuns()

        XCTAssertEqual(returned, estimate)
        XCTAssertEqual(welding.estimateMigrationRunsAccountUUIDReceivedAccountUUID, accountA)
    }

    func testEstimateMigrationRunsRethrowsWhenWeldingThrows() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.estimateMigrationRunsAccountUUIDThrowableError = ZcashError.rustMigrationEstimateRuns("boom")
        let migration = makeMigration(welding: welding, account: accountA)

        do {
            _ = try await migration.estimateMigrationRuns()
            XCTFail("Expected estimateMigrationRuns to rethrow the welding error")
        } catch ZcashError.rustMigrationEstimateRuns {
            // expected
        } catch {
            XCTFail("Expected rustMigrationEstimateRuns but got \(error)")
        }
    }

    // MARK: - Helpers

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

    /// Builds a real `OrchardMigration` around the given welding mock, wired with a real,
    /// temp-file-backed sync gate and a broadcaster that is never reached by the reschedule path.
    private func makeMigration(
        welding: ZcashRustBackendWeldingMock,
        account: AccountUUID,
        transactionSubmitter: (any MigrationTransactionSubmitting)? = nil
    ) -> OrchardMigration {
        // `isSyncBlocked()` is asserted by several delivery tests after the transaction path
        // completes. Keep that independent engine query deterministic instead of relying on the
        // generated mock's implicitly-unwrapped default.
        welding.migrationHasOverdueTransfersForReturnValue = false
        if welding.migrationRuntimeSnapshotForReturnValue == nil,
           welding.migrationRuntimeSnapshotForClosure == nil {
            welding.migrationRuntimeSnapshotForReturnValue = Self.makeNoRunRuntime(account: account)
        }
        if welding.migrationReconcileCanonicalChainRunForReturnValue == nil {
            welding.migrationReconcileCanonicalChainRunForReturnValue = Self.makeRunHandle(0x7FFF)
        }
        return OrchardMigration(
            welding: welding,
            accountUUID: account,
            broadcaster: ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable)),
            syncGate: makeGate(account: account, clock: TestClock(referenceDate)),
            logger: logger,
            networkType: .testnet,
            expectedChainName: "test",
            transactionSubmitter: transactionSubmitter
        )
    }

    private static func makeClaimHandle(_ identity: Int) -> MigrationClaimHandle {
        MigrationClaimHandle(
            storage: MigrationOpaqueHandleStorage(
                pointer: OpaquePointer(bitPattern: identity)!,
                release: { _ in }
            )
        )
    }

    private static func makeRecoveryCapability(
        _ identity: Int,
        signer: MigrationSignerOwnership
    ) -> ImmediateMigrationRecoveryCapability {
        ImmediateMigrationRecoveryCapability(
            claimHandle: makeClaimHandle(identity),
            account: AccountUUID(id: [UInt8](repeating: 0x11, count: 16)),
            artifact: .immediate(identity: Data(repeating: UInt8(truncatingIfNeeded: identity), count: 32)),
            signerOwnership: signer,
            deliveryRevision: UInt64(identity)
        )
    }

    private static func makeRunHandle(_ identity: Int) -> MigrationRunHandle {
        MigrationRunHandle(
            storage: MigrationOpaqueHandleStorage(
                pointer: OpaquePointer(bitPattern: identity)!,
                release: { _ in }
            )
        )
    }

    private static func configureImmediateSubmission(
        _ welding: ZcashRustBackendWeldingMock,
        identity: Int
    ) {
        welding.migrationClaimSubmissionClaimForReturnValue = makeClaimHandle(identity)
        welding.migrationClaimRunReturnValue = makeRunHandle(identity + 1)
        welding.migrationBoundSubmissionTargetForReturnValue = MigrationBoundSubmissionTarget(
            transport: .directTLS,
            endpoint: "https://submit.example:9067"
        )
        welding.migrationClaimExactTransactionReturnValue = Data([0xAA, 0xBB, 0xCC])
        welding.migrationClaimTransactionIDReturnValue = Data(repeating: 0x44, count: 32)
        welding.migrationClaimExpiryHeightReturnValue = 2_000_040
        welding.migrationClaimConsensusBranchIDReturnValue = 0xC8E71055
        welding.migrationRecordSubmissionOutcomeClaimForReturnValue = makeClaimHandle(identity + 2)
    }

    private static func makeNoRunRuntime(account: AccountUUID) -> MigrationRuntimeSnapshot {
        MigrationRuntimeSnapshot(
            account: account,
            canonical: MigrationCanonicalSummary(status: nil, transactionCount: 0),
            schemaProvenance: .compatible(version: 1),
            legacyCutover: .fresh,
            destinationSpendability: .notApplicable,
            availability: .available,
            ordinarySpendAuthorization: .unrestricted,
            accountDeletionAuthorization: .allowed,
            canonicalMutationAuthorization: .allowed,
            aggregateStorageFinality: .noRun,
            delivery: nil,
            retainedRuns: []
        )
    }

    private static func makeImmediateExternalRuntime(
        account: AccountUUID,
        runIdentity: Int,
        claim: MigrationClaimHandle,
        status: MigrationDeliveryClaimStatus = .awaitingExternalSignature,
        activeClaimKind: MigrationDeliveryClaimKind? = .materialization,
        externallyExposed: Bool = true,
        hasSignedPCZT: Bool = false,
        hasExactTransaction: Bool = false,
        txid: Data? = nil,
        lastError: MigrationDeliveryFailureReason? = nil,
        availability: MigrationRuntimeAvailability = .available,
        artifactIdentityByte: UInt8 = 0xA5,
        deliveryRevision: UInt64 = 1
    ) -> MigrationRuntimeSnapshot {
        let effectiveLastError = status == .materializationFailed
            ? (lastError ?? .materializationFailed)
            : (status == .outcomeUnknown ? .transportOutcomeUnknown : lastError)
        let summary = MigrationDeliveryClaimSummary(
            artifact: .immediate(identity: Data(repeating: artifactIdentityByte, count: 32)),
            signerOwnership: .external,
            status: status,
            activeClaimKind: activeClaimKind,
            externallyExposed: externallyExposed,
            hasSignedPCZT: hasSignedPCZT,
            hasExactTransaction: hasExactTransaction,
            expiryHeight: 2_000_040,
            txid: txid,
            lastError: effectiveLastError,
            claimHandle: claim
        )
        let delivery = MigrationDeliverySnapshot(
            lane: .immediate,
            phase: .active,
            storageFinality: .active,
            activeSourceReservationCount: 1,
            hasSubmissionPolicy: true,
            policyValidationFailure: nil,
            safeToCancel: false,
            claims: [summary],
            runHandle: makeRunHandle(runIdentity),
            revision: deliveryRevision
        )
        return MigrationRuntimeSnapshot(
            account: account,
            canonical: MigrationCanonicalSummary(status: .inProgress, transactionCount: 1),
            schemaProvenance: .compatible(version: 1),
            legacyCutover: .fresh,
            destinationSpendability: .notSpendable,
            availability: availability,
            ordinarySpendAuthorization: .excludingMigrationSources(releaseAtHeight: 2_000_040),
            accountDeletionAuthorization: .blocked(.unresolvedDelivery),
            canonicalMutationAuthorization: .blocked(.deliveryOwned),
            aggregateStorageFinality: .active,
            delivery: delivery,
            retainedRuns: []
        )
    }

    private static func makeImmediateSDKRuntime(
        account: AccountUUID,
        runIdentity: Int,
        claim: MigrationClaimHandle,
        status: MigrationDeliveryClaimStatus,
        activeClaimKind: MigrationDeliveryClaimKind? = nil,
        externallyExposed: Bool = false,
        hasSignedPCZT: Bool = false,
        hasExactTransaction: Bool? = nil,
        txid: Data? = nil,
        lastError: MigrationDeliveryFailureReason? = nil,
        availability: MigrationRuntimeAvailability = .available,
        artifactIdentityByte: UInt8 = 0x5A,
        deliveryRevision: UInt64 = 1
    ) -> MigrationRuntimeSnapshot {
        let inferredExact = status == .staged || status == .submitting || status == .outcomeUnknown ||
            status == .broadcasted || status == .confirmed || status == .expiredUnmined
        let exact = hasExactTransaction ?? inferredExact
        let effectiveLastError = status == .materializationFailed
            ? (lastError ?? .materializationFailed)
            : (status == .outcomeUnknown ? .transportOutcomeUnknown : lastError)
        let summary = MigrationDeliveryClaimSummary(
            artifact: .immediate(identity: Data(repeating: artifactIdentityByte, count: 32)),
            signerOwnership: .sdk,
            status: status,
            activeClaimKind: activeClaimKind,
            externallyExposed: externallyExposed,
            hasSignedPCZT: hasSignedPCZT,
            hasExactTransaction: exact,
            expiryHeight: 2_000_040,
            txid: txid ?? (exact ? Data(repeating: 0x44, count: 32) : nil),
            lastError: effectiveLastError,
            claimHandle: claim
        )
        let delivery = MigrationDeliverySnapshot(
            lane: .immediate,
            phase: .active,
            storageFinality: .active,
            activeSourceReservationCount: 1,
            hasSubmissionPolicy: true,
            policyValidationFailure: nil,
            safeToCancel: false,
            claims: [summary],
            runHandle: makeRunHandle(runIdentity),
            revision: deliveryRevision
        )
        return MigrationRuntimeSnapshot(
            account: account,
            canonical: MigrationCanonicalSummary(status: .inProgress, transactionCount: 1),
            schemaProvenance: .compatible(version: 1),
            legacyCutover: .fresh,
            destinationSpendability: .notSpendable,
            availability: availability,
            ordinarySpendAuthorization: .excludingMigrationSources(releaseAtHeight: 2_000_040),
            accountDeletionAuthorization: .blocked(.unresolvedDelivery),
            canonicalMutationAuthorization: .blocked(.deliveryOwned),
            aggregateStorageFinality: .active,
            delivery: delivery,
            retainedRuns: []
        )
    }

    private static func makeScheduledRuntime(
        account: AccountUUID,
        availability: MigrationRuntimeAvailability,
        claimStatus: MigrationDeliveryClaimStatus,
        activeClaimKind: MigrationDeliveryClaimKind? = nil,
        hasExactTransaction: Bool,
        runIdentity: Int,
        claimIdentity: Int,
        transactionID: UInt32 = 7,
        signerOwnership: MigrationSignerOwnership = .sdk,
        externallyExposed: Bool = false,
        hasSignedPCZT: Bool? = nil,
        canonicalStatus: MigrationCanonicalStatus = .inProgress,
        phase: MigrationDeliveryPhase = .active,
        storageFinality: MigrationStorageFinality = .active
    ) -> MigrationRuntimeSnapshot {
        let durableSignedPCZT = hasSignedPCZT ?? (signerOwnership == .external && hasExactTransaction)
        let lastError: MigrationDeliveryFailureReason?
        switch claimStatus {
        case .materializationFailed:
            lastError = .materializationFailed
        case .outcomeUnknown:
            lastError = .transportOutcomeUnknown
        default:
            lastError = nil
        }
        let claim = MigrationDeliveryClaimSummary(
            artifact: .scheduled(transactionID: transactionID),
            signerOwnership: signerOwnership,
            status: claimStatus,
            activeClaimKind: activeClaimKind,
            externallyExposed: externallyExposed,
            hasSignedPCZT: durableSignedPCZT,
            hasExactTransaction: hasExactTransaction,
            expiryHeight: 2_000_040,
            txid: hasExactTransaction ? Data(repeating: 0x44, count: 32) : nil,
            lastError: lastError,
            claimHandle: makeClaimHandle(claimIdentity)
        )
        let delivery = MigrationDeliverySnapshot(
            lane: .scheduled,
            phase: phase,
            storageFinality: storageFinality,
            activeSourceReservationCount: 1,
            hasSubmissionPolicy: availability == .available,
            policyValidationFailure: nil,
            safeToCancel: false,
            claims: [claim],
            runHandle: makeRunHandle(runIdentity),
            revision: UInt64(runIdentity)
        )
        return MigrationRuntimeSnapshot(
            account: account,
            canonical: MigrationCanonicalSummary(status: canonicalStatus, transactionCount: 1),
            schemaProvenance: .compatible(version: 1),
            legacyCutover: .fresh,
            destinationSpendability: .notSpendable,
            availability: availability,
            ordinarySpendAuthorization: .excludingMigrationSources(releaseAtHeight: 2_000_040),
            accountDeletionAuthorization: .blocked(.unresolvedDelivery),
            canonicalMutationAuthorization: .blocked(.deliveryOwned),
            aggregateStorageFinality: storageFinality,
            delivery: delivery,
            retainedRuns: []
        )
    }

    static func makeSchedule(count: Int) -> MigrationSchedule {
        // An explicit accumulator rather than `(0..<count).map { ... }`: CI's Xcode 16.0 compiler
        // times out type-checking the closure-wrapped multi-argument literal expression ("unable to
        // type-check this expression in reasonable time"); newer local toolchains accept either form.
        var transfers: [MigrationTransferProposal] = []
        for index in 0..<count {
            let amount = Zatoshi(Int64((index + 1) * 100_000))
            let transfer = MigrationTransferProposal(
                id: "transfer-\(index)",
                amount: amount,
                anchorHeight: 2_000_000 + index,
                nextExecutableAfterHeight: 2_000_100 + index,
                expiryHeight: 2_010_000 + index
            )
            transfers.append(transfer)
        }
        return MigrationSchedule(
            transfers: transfers,
            estimatedDurationHours: count * 6,
            proposalHandle: 0xA11C_E
        )
    }

    /// Builds a deliberately non-trivial `MigrationRunEstimate` fixture: two runs whose fields are
    /// all distinct (so any cross-wiring of a field in the pass-through would break equality) plus
    /// a non-zero final residual.
    static func makeRunEstimate() -> MigrationRunEstimate {
        MigrationRunEstimate(
            runs: [
                MigrationRunEstimate.Run(
                    migratable: Zatoshi(75_000_000),
                    crossings: 15,
                    preparationLayers: 2,
                    preparationTransactions: 5
                ),
                MigrationRunEstimate.Run(
                    migratable: Zatoshi(1_200_000),
                    crossings: 3,
                    preparationLayers: 1,
                    preparationTransactions: 1
                )
            ],
            finalResidual: Zatoshi(42_000)
        )
    }
}

/// Mutable durable-state projection used to model the runtime changing underneath two serialized
/// calls after the first call records its submission outcome.
private actor SingleFlightMigrationRuntimeState {
    private var current: MigrationRuntimeSnapshot
    private let terminal: MigrationRuntimeSnapshot

    init(initial: MigrationRuntimeSnapshot, terminal: MigrationRuntimeSnapshot) {
        current = initial
        self.terminal = terminal
    }

    func snapshot() -> MigrationRuntimeSnapshot {
        current
    }

    func markTerminal() {
        current = terminal
    }
}

/// Suspends one async operation until explicitly released, while letting the test observe the
/// suspension without sleeps. Used to prove that a second external-preparation caller remains
/// outside the serialized flow until the first caller publishes its durable staged runtime.
private actor GatedAsyncOperation {
    private var isSuspended = false
    private var isReleased = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    func waitUntilSuspended() async {
        if isSuspended { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = operationWaiters
        operationWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// Suspends the first transaction submission until the test releases it, allowing a second caller
/// to contend with the actor's serialized broadcast flow without relying on wall-clock sleeps.
private actor GatedMigrationTransactionSubmitter: MigrationTransactionSubmitting {
    private var callCount = 0
    private var isReleased = false
    private var submitWaiters: [CheckedContinuation<Void, Never>] = []
    private var callCountWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    // swiftlint:disable:next function_parameter_count
    func submit(
        transaction: EncodedTransaction,
        expiryHeight: BlockHeight,
        target: MigrationBoundSubmissionTarget,
        expectedChainName: String,
        transactionConsensusBranchId: UInt32,
        branchIdForHeight: @escaping (Int32) throws -> Int32,
        renewLease: @escaping () async throws -> Void
    ) async throws -> MigrationSubmissionOutcome {
        callCount += 1
        var remainingCallCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in callCountWaiters {
            if callCount >= waiter.threshold {
                waiter.continuation.resume()
            } else {
                remainingCallCountWaiters.append(waiter)
            }
        }
        callCountWaiters = remainingCallCountWaiters

        if !isReleased {
            await withCheckedContinuation { continuation in
                submitWaiters.append(continuation)
            }
        }
        return .accepted
    }

    func waitUntilCallCount(_ threshold: Int) async {
        if callCount >= threshold { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((threshold, continuation))
        }
    }

    func release() {
        isReleased = true
        let waiters = submitWaiters
        submitWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func currentCallCount() -> Int {
        callCount
    }
}

/// A controllable test double for `MigrationSyncGate`'s `overdueProvider` seam: each call to
/// `next()` either returns an already-queued answer immediately, or suspends until `resolveOldestWaiting`
/// releases the oldest still-waiting call. Lets a test pin the exact interleaving of two concurrent
/// recomputes deterministically -- no `Task.sleep`, no polling -- by controlling which of two
/// `overdueProvider` calls resolves first.
private actor GatedOverdueProvider {
    private var queuedAnswers: [Bool] = []
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var suspensionSignals: [CheckedContinuation<Void, Never>] = []

    func next() async -> Bool {
        if !queuedAnswers.isEmpty {
            return queuedAnswers.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            let signals = suspensionSignals
            suspensionSignals = []
            for signal in signals {
                signal.resume()
            }
        }
    }

    /// Queues `answer` for the next call to `next()` that is not already suspended, so that call
    /// returns immediately instead of waiting on `resolveOldestWaiting`.
    func queue(_ answer: Bool) {
        queuedAnswers.append(answer)
    }

    /// Resolves the oldest currently-suspended `next()` call with `answer`.
    func resolveOldestWaiting(_ answer: Bool) {
        guard !waiters.isEmpty else {
            XCTFail("GatedOverdueProvider: no suspended `next()` call to resolve")
            return
        }
        waiters.removeFirst().resume(returning: answer)
    }

    /// Suspends until at least one call to `next()` is itself suspended awaiting resolution.
    func waitUntilWaiting() async {
        if !waiters.isEmpty { return }
        await withCheckedContinuation { continuation in
            suspensionSignals.append(continuation)
        }
    }
}

/// A trivial, always-immediately-resolving `overdueProvider` double that just counts calls -- used
/// to pin finding 14's subscription-gated ticker (``MigrationLogicTests/testTickerTicksOnlyWhileSubscribed()``):
/// unlike `GatedOverdueProvider`, nothing here ever suspends, so the count only grows when the
/// ticker itself actually decides to tick.
private actor CallCountingOverdueProvider {
    private(set) var count = 0

    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }
}

// `GatedTorClientFactory` and `StubTorBootstrapError` were promoted to
// `Tests/TestUtils/MigrationTestDoubles.swift` so `OrchardMigrationHostTests` can reuse them for the
// shared-broadcaster single-bootstrap canary.
