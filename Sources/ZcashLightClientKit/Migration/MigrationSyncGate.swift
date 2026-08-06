//
//  MigrationSyncGate.swift
//  ZcashLightClientKit
//

import Combine
import Foundation

/// The persisted, per-account gate that decides whether ordinary wallet sync must pause for the
/// benefit of an in-flight migration.
///
/// Two independent reasons block sync — both PAST/PRESENT-looking, never future:
/// 1. **Privacy buffer** — for a fixed window after each broadcast, sync stays paused so the
///    broadcast is not correlated with a fresh sync. This is the `resumeAt` timestamp persisted here.
/// 2. **Broadcast in flight** — from just before a migration submit hits the network until its
///    outcome is recorded, sync must not run: the engine's own in-flight sweep (inside
///    `migrationAdvanceStep`) would otherwise meet a transfer that is neither recorded broadcast
///    nor yet visible on chain. This is the `inFlightUntil` timestamp persisted here; a crash
///    between submit and record leaves the marker behind, and it self-expires
///    ``broadcastInFlightGuardDuration`` (120 s) after it was set.
///
/// A THIRD condition — "ready broadcast": block sync whenever a proved, schedule-due transfer was
/// servable — lived here until 2026-08-05 and was REMOVED on danny + nuttycom's ruling (relayed by
/// Lukas): sync is held only when a broadcast happened recently in the PAST (the buffer, and the
/// submit-to-record marker), never because one is expected in the FUTURE. The forward-looking
/// clause was also field-implicated in a live wedge: it blocked the very sync whose scanned
/// progress the pending broadcast needed, freezing an awake session for 50+ minutes (FIND-5,
/// campaign 7/8a receipts). The broadcast-or-sync session split itself is unaffected — an app
/// open whose `next_step` answers `.broadcast` runs a no-sync delivery session (the consumer's
/// visit classification), which is a statement about THAT session, not a hold on sync in general.
///
/// State is durably persisted to an atomically written JSON file, but every read in this process is
/// served from an in-memory cache (see `cachedResumeAt`/`cachedInFlightUntil`) -- the file exists
/// for durability across launches, not as the read path. The other in-memory mutable state is the
/// subscriber-gated ticker task (see `subscriberAttached()`, guarded by `subscriptionLock`) and the
/// send-generation counters (see `publish(_:generation:)`, guarded by `emissionLock`); all of it is
/// guarded by one lock or the other, so a `final class` is `@unchecked Sendable` without needing an
/// actor hop to read the reactive stream. A corrupt or missing file reads as "no buffer".
final class MigrationSyncGate: @unchecked Sendable {
    /// The persisted envelope: a schema version plus the epoch-seconds instants at which the
    /// privacy buffer elapses and the in-flight broadcast marker expires. Both instants are
    /// OPTIONAL (synthesized `Codable` decodes them via `decodeIfPresent`), and the version int is
    /// unchanged: files persisted before the in-flight marker existed — which always carry
    /// `resumeAtEpochSeconds` and never `inFlightUntilEpochSeconds` — stay readable.
    private struct GateState: Codable {
        let version: Int
        let resumeAtEpochSeconds: Double?
        let inFlightUntilEpochSeconds: Double?
    }

    private static let currentVersion = 1

    /// How long the in-flight broadcast marker set by ``markBroadcastInFlight()`` lives before it
    /// self-expires: long enough to cover a submit's network round-trip plus the result record,
    /// short enough that a crash mid-broadcast does not wedge sync — the marker's whole point is
    /// to be safe to leak.
    static let broadcastInFlightGuardDuration: TimeInterval = 120

    private let fileURL: URL
    private let bufferDuration: TimeInterval
    private let tickInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let logger: Logger
    private let blockedSubject: CurrentValueSubject<Bool, Never>

    /// Guards the send-generation counters (`nextGeneration`, `lastPublishedGeneration`) and the
    /// in-memory `resumeAt` cache (`cachedResumeAt`) -- the funnel that computes and emits values on
    /// `blockedSubject`. `publish(_:generation:)` holds this lock across the actual
    /// `blockedSubject.send(_:)` call (Combine requires sends on a subject to be serialized). Kept
    /// deliberately separate from `subscriptionLock` below -- see that property's doc for why.
    /// `NSLock` rather than `OSAllocatedUnfairLock` (the usual preference for new locking code): this
    /// package's deployment target (`Package.swift`: `.iOS(.v13)` / `.macOS(.v12)`) is below
    /// `OSAllocatedUnfairLock`'s iOS 16 / macOS 13 floor, so this matches the plain-`NSLock`
    /// convention already used elsewhere in this codebase (see `ZcashRustBackend.rustInitLock`).
    private let emissionLock = NSLock()
    /// The generation handed out to the most recently *started* `recompute()`, and the newest
    /// generation `publish(_:generation:)` has actually sent. Both guarded by `emissionLock`.
    private var nextGeneration: UInt64 = 0
    private var lastPublishedGeneration: UInt64 = 0

    /// The in-memory cache of the persisted privacy-buffer expiry, guarded by `emissionLock`. Loaded
    /// once from the gate file at init; `markBroadcast()` is the only writer thereafter (persists to
    /// the file first, then updates this cache -- see `markBroadcast()` for why the file must win
    /// that race). Every read in this process (`currentResumeAt()`, hence `currentlyBlocked()`
    /// and `recompute()`) serves this cache rather than re-reading the file.
    ///
    /// A plain lock-guarded value suffices here, unlike `publish(_:generation:)`'s generation
    /// ordering: the writers (`markBroadcast()`, `markBroadcastInFlight()`,
    /// `clearBroadcastInFlight()`) all run inside `OrchardMigration`'s single-flight broadcast flow
    /// -- and there is one `MigrationSyncGate` instance per account per process (the standing
    /// single-writer assumption) -- so there is never a fresher write for a slower one to clobber.
    private var cachedResumeAt: Date?

    /// The in-memory cache of the persisted in-flight broadcast marker's expiry, guarded by
    /// `emissionLock` exactly like `cachedResumeAt` (same load-at-init, write-file-first
    /// discipline). `nil` when no marker is set; an instant in the past is an expired marker a
    /// crash left behind (equivalent to none for blocking purposes, and overwritten by the next
    /// `markBroadcastInFlight()`/`clearBroadcastInFlight()` write).
    ///
    /// One reader also writes: `currentInFlightUntil()` clamps an implausibly-far-future value
    /// (a backwards clock-step artifact — see ``clampedInFlightUntil(_:now:)``) back into the
    /// plausible window and persists the clamp HERE (cache only, not the file), so the marker
    /// then expires within ``broadcastInFlightGuardDuration`` of the observation instead of
    /// re-deriving a fresh far-future block on every read. The single-writer assumption the
    /// marking calls rely on is unaffected: the clamp only ever SHORTENS the marker, never
    /// extends or revives one.
    private var cachedInFlightUntil: Date?

    /// Guards the subscriber count and the ticker task's start/stop state -- the bookkeeping for
    /// `blockedStream`'s subscription lifecycle. Deliberately a SEPARATE lock from `emissionLock`:
    /// Combine can invoke `receiveCancel` (-> `subscriberDetached()`) *synchronously, on the calling
    /// thread*, when a subscriber cancels from inside its own value-handling closure -- including a
    /// value just delivered by `publish(_:generation:)`, i.e. while that thread is still inside
    /// `publish`'s `emissionLock` critical section around `blockedSubject.send(_:)`. If subscription
    /// bookkeeping shared `emissionLock`, that re-entrant `lock()` would deadlock against itself
    /// (`NSLock` is non-recursive) and wedge the gate permanently -- every later
    /// `currentResumeAt()` / `currentlyBlocked()` / `markBroadcast()` / subscribe would then hang too,
    /// since the thread that deadlocked never releases the lock it holds.
    ///
    /// The ordering rule this buys is one-way, not "never both": `subscriberAttached()`,
    /// `subscriberDetached()`, `startTicking()`, and `stopTicking()` touch only `subscriptionLock`
    /// and must never acquire `emissionLock` -- that is the invariant that actually prevents the
    /// deadlock described above. The reverse nesting is deliberate and safe: `publish(_:generation:)`
    /// legitimately holds `emissionLock` across `blockedSubject.send(_:)`, and that send can
    /// synchronously re-enter this instance via a subscriber's synchronous cancel
    /// (-> `subscriberDetached()`, which acquires `subscriptionLock`) -- so `emissionLock` ->
    /// `subscriptionLock` is a real, one-way nesting this type relies on. What must never happen is
    /// the reverse acquisition order; keep it that way rather than letting subscription-side code
    /// reach back into `emissionLock`. See `publish(_:generation:)`'s doc for the different,
    /// currently-unreachable re-entrancy hazard this same nesting creates for `emissionLock` itself.
    private let subscriptionLock = NSLock()
    /// Live subscriber count of `blockedStream`, guarded by `subscriptionLock`. The ticker task runs
    /// only while this is > 0: `subscriberAttached()` starts it on the 0 -> 1 transition,
    /// `subscriberDetached()` cancels it on the 1 -> 0 transition. With zero subscribers the gate
    /// does zero periodic FFI/sqlite work (finding 14).
    private var subscriberCount = 0
    /// The ticker task itself, guarded by `subscriptionLock` alongside `subscriberCount` -- see
    /// `startTicking()` / `stopTicking()`.
    private var tickerTask: Task<Void, Never>?

    /// Creates a gate rooted at `directory`, scoped to `accountUUID` by file name.
    ///
    /// - Parameters:
    ///   - directory: the general-storage directory the gate file lives in; provisioned via
    ///     ``BackupExcludedStorage`` (created if missing, and excluded from backup either way --
    ///     schedule timing must never leave the device via an iCloud/iTunes backup).
    ///   - accountUUID: the account this gate governs; encoded into the file name.
    ///   - bufferDuration: how long the privacy buffer keeps sync blocked after each broadcast.
    ///   - tickInterval: how often the reactive stream re-evaluates (time passing alone can flip the
    ///     answer even with no data change). Injectable for tests.
    ///   - now: the clock. Injectable for tests.
    ///   - logger: sink for the single warning emitted on a corrupt read or a failed write.
    init(
        directory: URL,
        accountUUID: AccountUUID,
        bufferDuration: TimeInterval,
        tickInterval: TimeInterval = 15,
        now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger
    ) {
        let url = directory.appendingPathComponent(Self.fileName(accountUUID: accountUUID))
        self.fileURL = url
        self.bufferDuration = bufferDuration
        self.tickInterval = tickInterval
        self.now = now
        self.logger = logger

        do {
            try BackupExcludedStorage.provision(directory: directory)
        } catch {
            logger.warn("MigrationSyncGate: failed to provision the storage directory (backup exclusion may be missing): \(error)")
        }

        // Load the in-memory `resumeAt`/`inFlightUntil` caches from the file exactly once, here --
        // every subsequent read in this process serves these caches (see `cachedResumeAt`), never
        // the file again, until a marking call updates them. The in-flight marker is clamped into
        // its plausible window at this load (the A13 backwards-clock-step guard — see
        // `clampedInFlightUntil(_:now:)`), so a marker persisted before a clock step back expires
        // within `broadcastInFlightGuardDuration` of THIS launch rather than wedging sync for the
        // whole displacement. Also seeds the synchronous subscribe-time value, which is EXACT —
        // the gate's inputs are entirely these two persisted instants — so subscribers get an
        // immediate, correct value.
        let loadedAt = now()
        let initialInputs = Self.readGateInputs(fileURL: url, logger: logger)
        self.cachedResumeAt = initialInputs.resumeAt
        let clampedInFlightUntil = Self.clampedInFlightUntil(initialInputs.inFlightUntil, now: loadedAt)
        self.cachedInFlightUntil = clampedInFlightUntil
        let initialBlocked = Self.isBlocked(
            now: loadedAt,
            resumeAt: initialInputs.resumeAt,
            inFlightUntil: clampedInFlightUntil
        )
        self.blockedSubject = CurrentValueSubject(initialBlocked)
        self.tickerTask = nil

        // No `startTicking()` here: the ticker is subscription-gated (finding 14) -- it starts on the
        // first `blockedStream` subscriber (`subscriberAttached()`), not at construction.
    }

    deinit {
        tickerTask?.cancel()
    }

    /// The account-scoped gate file name, e.g. `migration_sync_gate_<account-uuid-hex>.json`.
    static func fileName(accountUUID: AccountUUID) -> String {
        "migration_sync_gate_\(Data(accountUUID.id).hexEncodedString()).json"
    }

    /// The persisted gate inputs for `accountUUID` — the privacy-buffer expiry and the in-flight
    /// broadcast marker's expiry — read directly from its gate file under `directory`, without
    /// constructing a gate instance. A corrupt or missing file reads as `(nil, nil)` ("no buffer,
    /// nothing in flight"), exactly like an instance's init-time load.
    ///
    /// The wallet-scope path a host uses to answer "is any account still inside its gate?" after a
    /// fresh launch, when the per-account gate for a dormant account has not been (and must not
    /// need to be) constructed. Reuses the same envelope-read path (`readGateInputs`) as the
    /// instance's own init so the on-disk format has a single reader. The raw file values are
    /// returned UNCLAMPED — this static read has nowhere to persist a clamp, so an
    /// implausibly-far-future in-flight marker (a backwards clock-step artifact) is instead
    /// neutralized at evaluation time by ``isBlocked(now:resumeAt:inFlightUntil:)``'s
    /// plausible-window rule.
    static func persistedGateInputs(
        directory: URL,
        accountUUID: AccountUUID,
        logger: Logger
    ) -> (resumeAt: Date?, inFlightUntil: Date?) {
        let fileURL = directory.appendingPathComponent(fileName(accountUUID: accountUUID))
        return readGateInputs(fileURL: fileURL, logger: logger)
    }

    /// The in-flight marker expiry clamped into its plausible window: a marker is armed at
    /// exactly `now + broadcastInFlightGuardDuration`, so under a monotone clock its remaining
    /// life can never EXCEED the guard duration — an expiry further out than that proves the
    /// clock has stepped backwards since it was armed (the A13 hazard: without the clamp, the
    /// marker would block sync for the whole displacement). Clamping to `now + guard` preserves
    /// the protective window (the marker still blocks, briefly) while bounding it. `nil` passes
    /// through; a plausible value is returned unchanged.
    static func clampedInFlightUntil(_ inFlightUntil: Date?, now: Date) -> Date? {
        inFlightUntil.map { min($0, now.addingTimeInterval(broadcastInFlightGuardDuration)) }
    }

    /// The gate's core predicate: sync is blocked while the privacy buffer has not yet elapsed,
    /// or while an unexpired in-flight broadcast marker exists — past/present conditions only
    /// (see the type doc for the removed forward-looking third clause). Pure, so it is
    /// exhaustively table-testable.
    ///
    /// The in-flight clause honors the marker only within its PLAUSIBLE window (`inFlightUntil`
    /// at most ``broadcastInFlightGuardDuration`` in the future — see
    /// ``clampedInFlightUntil(_:now:)``): a marker further out than a freshly armed one proves a
    /// backwards clock step, and on the read paths with no cache to persist a clamp into (the
    /// host's dormant-account file reads) it must fail OPEN here, or each re-read would re-derive
    /// a fresh block forever. The marker is designed to be safe to leak, so failing open on clock
    /// weirdness matches its contract; the in-process cache paths additionally clamp (load +
    /// `currentInFlightUntil()`), which keeps the protective window instead.
    static func isBlocked(now: Date, resumeAt: Date?, inFlightUntil: Date?) -> Bool {
        if let inFlightUntil,
            now < inFlightUntil,
            inFlightUntil.timeIntervalSince(now) <= Self.broadcastInFlightGuardDuration {
            return true
        }
        guard let resumeAt else {
            return false
        }
        return now < resumeAt
    }

    /// Starts (or restarts) the privacy buffer: persists `resumeAt = now + bufferDuration` to the
    /// gate file FIRST, then updates the in-memory `resumeAt` cache, then pushes a fresh value to
    /// the reactive stream. Call after every successful migration broadcast. Preserves the
    /// in-flight marker (`markBroadcast()` fires mid-flow, between submit and record).
    ///
    /// The file write must land before the cache update, not after. `OrchardMigrationHost`'s
    /// wallet-scope predicate reads the FILE (`persistedGateInputs`) — alongside, for accounts
    /// with a live actor, this gate's in-memory view (blocked wins; the A8 defense against a
    /// failed write) — while the gate's own recomputes (and therefore `blockedStream`) read the
    /// in-memory cache. If the cache updated first, a recompute could observe the fresh cache and
    /// publish `true` before the file write lands; that emission can trigger a wallet-scope
    /// recompute whose FILE half reads the still-stale file, computes `false`, and publishes it
    /// with a later generation -- the later, correct `true` (once the file does land) then
    /// collapses into that stale `false` as a consecutive duplicate under `removeDuplicates()`,
    /// leaving the wallet-scope stream stuck at `false` until the next periodic tick. Persisting
    /// first closes that window: the file is never observably behind the cache. The same
    /// write-file-before-cache discipline applies to `markBroadcastInFlight()` and
    /// `clearBroadcastInFlight()`.
    ///
    /// A failed write (`write(resumeAt:inFlightUntil:)` only logs, never throws) still updates the
    /// cache afterward, so in-process gating never depends on the write having actually landed on
    /// disk — and the host's live-view consultation (above) keeps even the wallet-scope answer
    /// correct in that case.
    func markBroadcast() {
        let resumeAt = now().addingTimeInterval(bufferDuration)

        write(resumeAt: resumeAt, inFlightUntil: currentInFlightUntil())

        emissionLock.lock()
        cachedResumeAt = resumeAt
        emissionLock.unlock()

        recomputeAsync()
    }

    /// Persists the in-flight broadcast marker (`inFlightUntil = now +`
    /// ``broadcastInFlightGuardDuration``), file first, then cache, then a reactive recompute —
    /// the same write-file-before-cache discipline as ``markBroadcast()``. Call just before a
    /// migration submit hits the network; pair with ``clearBroadcastInFlight()`` once the
    /// outcome is recorded. A crash (or a record failure) between the two leaves the marker
    /// behind, and it self-expires on its own — that leak-safety is the point of the deadline.
    func markBroadcastInFlight() {
        let inFlightUntil = now().addingTimeInterval(Self.broadcastInFlightGuardDuration)

        write(resumeAt: currentResumeAt(), inFlightUntil: inFlightUntil)

        emissionLock.lock()
        cachedInFlightUntil = inFlightUntil
        emissionLock.unlock()

        recomputeAsync()
    }

    /// Clears the in-flight broadcast marker (file first, then cache, then a reactive recompute)
    /// — the release half of ``markBroadcastInFlight()``, called once the broadcast's outcome is
    /// recorded, or when the submit never happened at all (a fail-closed pre-submit throw).
    func clearBroadcastInFlight() {
        write(resumeAt: currentResumeAt(), inFlightUntil: nil)

        emissionLock.lock()
        cachedInFlightUntil = nil
        emissionLock.unlock()

        recomputeAsync()
    }

    /// The in-memory cached privacy-buffer expiry (see `cachedResumeAt`), or `nil` when no buffer is
    /// active. Reflects the gate file's contents as of the last init or `markBroadcast()` in THIS
    /// process, not a fresh file read.
    func currentResumeAt() -> Date? {
        emissionLock.lock()
        defer { emissionLock.unlock() }
        return cachedResumeAt
    }

    /// The in-memory cached in-flight broadcast marker's expiry (see `cachedInFlightUntil`), or
    /// `nil` when none is set. Reflects the gate file's contents as of the last init or
    /// mark/clear in THIS process, not a fresh file read.
    ///
    /// Every read is the A13 evaluation-side clamp: a value more than
    /// ``broadcastInFlightGuardDuration`` in the future (the clock stepped backwards after the
    /// marker was armed) is clamped to `now + guard` and the clamp is written back to the cache,
    /// so the marker keeps its protective window once and then expires — instead of re-deriving a
    /// fresh far-future block on every evaluation. The file is deliberately NOT rewritten: its
    /// stale value is re-clamped at the next launch's load, and the wallet-scope reader's raw
    /// file read is bounded by `isBlocked`'s plausible-window rule instead.
    func currentInFlightUntil() -> Date? {
        emissionLock.lock()
        defer { emissionLock.unlock() }
        guard let inFlightUntil = cachedInFlightUntil else {
            return nil
        }
        let clamped = Self.clampedInFlightUntil(inFlightUntil, now: now())
        cachedInFlightUntil = clamped
        return clamped
    }

    /// Whether the in-flight broadcast marker is currently live: armed
    /// (``markBroadcastInFlight()``) and neither cleared nor self-expired. The submit-to-record
    /// window signal callers use to defer work that must not observe a just-broadcast transfer.
    func isBroadcastInFlight() -> Bool {
        guard let inFlightUntil = currentInFlightUntil() else {
            return false
        }
        return now() < inFlightUntil
    }

    /// Whether sync is currently blocked by the persisted privacy buffer or the in-flight
    /// broadcast marker. Never throws, never suspends — the gate's inputs are entirely local.
    func currentlyBlocked() -> Bool {
        Self.isBlocked(
            now: now(),
            resumeAt: currentResumeAt(),
            inFlightUntil: currentInFlightUntil()
        )
    }

    /// A stream of the blocked flag: emits the current value on subscribe, re-evaluates every
    /// `tickInterval` — waking EARLY at each known gate boundary (`resumeAt`/`inFlightUntil`
    /// expiry, see `nextRecomputeDelay`) — and after every ``markBroadcast()``, and collapses
    /// consecutive duplicates.
    /// Internally synchronized: the ticker loop and every `markBroadcast()`-triggered recompute can
    /// be in flight concurrently, and every send is serialized and generation-ordered -- latest-wins, so a recompute that started earlier
    /// but finishes later after a fresher one already published is dropped rather than emitted as a
    /// stale overwrite. See `publish(_:generation:)`.
    ///
    /// - Important: Subscription-gated (finding 14): the periodic ticker only runs while at least one
    ///   subscriber is attached (`subscriberAttached()`/`subscriberDetached()`, via `handleEvents`
    ///   below), so a `blockedStream` with no subscribers costs nothing beyond the seed already
    ///   computed at init. `markBroadcast()`-triggered recomputes are unaffected by subscriber count.
    var blockedStream: AnyPublisher<Bool, Never> {
        blockedSubject
            .handleEvents(
                receiveSubscription: { [weak self] _ in self?.subscriberAttached() },
                receiveCancel: { [weak self] in self?.subscriberDetached() }
            )
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    // MARK: - Private

    /// Called (via `handleEvents`) whenever a new `blockedStream` subscription is established. On the
    /// 0 -> 1 transition, starts the ticker task -- see `subscriberCount`.
    private func subscriberAttached() {
        subscriptionLock.lock()
        subscriberCount += 1
        if subscriberCount == 1 {
            startTicking()
        }
        subscriptionLock.unlock()
    }

    /// Called (via `handleEvents`) whenever a `blockedStream` subscription is cancelled. On the
    /// 1 -> 0 transition, cancels the ticker task -- see `subscriberCount`.
    private func subscriberDetached() {
        subscriptionLock.lock()
        subscriberCount -= 1
        if subscriberCount == 0 {
            stopTicking()
        }
        subscriptionLock.unlock()
    }

    /// Starts the ticker task. Only called with `subscriptionLock` held, on the 0 -> 1 subscriber
    /// transition (`subscriberAttached()`) -- creating the `Task` here is a cheap, non-suspending
    /// call, so doing it under the lock is safe. No risk of deadlock either way: the task's own body
    /// (`recompute()`) only ever acquires `emissionLock`, never `subscriptionLock`.
    ///
    /// BOUNDARY-AWARE (field-caught 2026-08-02): the gate KNOWS when its persisted inputs flip --
    /// `resumeAt` and `inFlightUntil` are wall-clock deadlines -- yet the flat `tickInterval` sleep
    /// could leave a cleared gate unnoticed for a whole interval. On a foregrounded device that
    /// read as a dead half-minute between "gate expired" and "sync resumed", with the app doing
    /// nothing wrong. Each iteration now sleeps only until the SOONEST future boundary (plus a
    /// small epsilon so the recompute lands strictly after the flip), capped at `tickInterval`.
    private func startTicking() {
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                await self.recompute()
                let delay = Self.nextRecomputeDelay(
                    now: self.now(),
                    resumeAt: self.currentResumeAt(),
                    inFlightUntil: self.currentInFlightUntil(),
                    tickInterval: self.tickInterval
                )
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// The ticker's next sleep: the soonest FUTURE gate boundary (`resumeAt`/`inFlightUntil`,
    /// plus a 0.25 s epsilon so the wake lands strictly after the input flips), capped at
    /// `tickInterval`. Past or absent boundaries fall back to the plain interval. Pure and
    /// static for offline testing.
    static func nextRecomputeDelay(
        now: Date,
        resumeAt: Date?,
        inFlightUntil: Date?,
        tickInterval: TimeInterval
    ) -> TimeInterval {
        let futureBoundaries = [resumeAt, inFlightUntil]
            .compactMap { $0?.timeIntervalSince(now) }
            .filter { $0 > 0 }
        guard let soonest = futureBoundaries.min() else { return tickInterval }
        return min(tickInterval, soonest + 0.25)
    }

    /// Stops the ticker task. Only called with `subscriptionLock` held, on the 1 -> 0 subscriber
    /// transition (`subscriberDetached()`).
    private func stopTicking() {
        tickerTask?.cancel()
        tickerTask = nil
    }

    private func recomputeAsync() {
        Task { [weak self] in
            await self?.recompute()
        }
    }

    private func recompute() async {
        let generation = drawNextGeneration()

        let blocked = Self.isBlocked(
            now: now(),
            resumeAt: currentResumeAt(),
            inFlightUntil: currentInFlightUntil()
        )
        publish(blocked, generation: generation)
    }

    /// Snapshots this recompute's generation, under `emissionLock`, at the moment it *starts*, so
    /// `publish(_:generation:)` can later tell whether a later-started recompute has already
    /// published.
    private func drawNextGeneration() -> UInt64 {
        emissionLock.lock()
        defer { emissionLock.unlock() }

        nextGeneration += 1
        return nextGeneration
    }

    /// The single funnel every `blockedSubject.send` goes through. Atomically (under `emissionLock`)
    /// checks freshness and sends: `generation` was snapshotted when the calling `recompute()`
    /// started, so if a *later*-started recompute has already published (`lastPublishedGeneration` is
    /// newer), this send is stale and is silently dropped instead of overwriting the fresher value.
    /// Serializing the actual `.send()` call here also satisfies Combine's requirement that sends on
    /// a subject not race.
    ///
    /// Holding `emissionLock` across `send(_:)` is safe with respect to `subscriptionLock` even
    /// though `send(_:)` can synchronously re-enter this instance (a subscriber cancelling from
    /// inside its own value handler, see `subscriptionLock`'s doc): the only re-entrant call that path
    /// reaches is `subscriberDetached()`, which acquires `subscriptionLock`, never this lock.
    ///
    /// - Warning: That safety is specific to the cancel path. A subscriber's synchronous
    ///   value-handling callback must never call back into `currentResumeAt()`,
    ///   `currentlyBlocked()`, or `markBroadcast()` from inside its handler for this
    ///   emission: all three acquire `emissionLock`, which -- unlike `subscriptionLock` -- this
    ///   thread is already holding right here, and `NSLock` is non-recursive, so a same-thread
    ///   re-acquisition would deadlock. No shipped subscriber does this today (only cancellation
    ///   reaches back in, and only into `subscriptionLock`), so the hazard is currently unreachable,
    ///   not exercised.
    private func publish(_ blocked: Bool, generation: UInt64) {
        emissionLock.lock()
        defer { emissionLock.unlock() }

        guard generation > lastPublishedGeneration else {
            return
        }
        lastPublishedGeneration = generation
        blockedSubject.send(blocked)
    }

    /// Persists the full gate envelope atomically. Every writer passes BOTH fields — the one it
    /// changes and the other's current cached value — so the file always carries the whole state
    /// (the fields have independent writers: `markBroadcast()` vs the in-flight pair).
    private func write(resumeAt: Date?, inFlightUntil: Date?) {
        do {
            let state = GateState(
                version: Self.currentVersion,
                resumeAtEpochSeconds: resumeAt?.timeIntervalSince1970,
                inFlightUntilEpochSeconds: inFlightUntil?.timeIntervalSince1970
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.warn("MigrationSyncGate: failed to persist sync-gate state: \(error)")
        }
    }

    private static func readGateInputs(fileURL: URL, logger: Logger) -> (resumeAt: Date?, inFlightUntil: Date?) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return (nil, nil)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let state = try JSONDecoder().decode(GateState.self, from: data)
            guard state.version == Self.currentVersion else {
                logger.warn("MigrationSyncGate: ignoring sync-gate file with unknown version \(state.version)")
                return (nil, nil)
            }
            return (
                state.resumeAtEpochSeconds.map { Date(timeIntervalSince1970: $0) },
                state.inFlightUntilEpochSeconds.map { Date(timeIntervalSince1970: $0) }
            )
        } catch {
            logger.warn("MigrationSyncGate: ignoring corrupt sync-gate file: \(error)")
            return (nil, nil)
        }
    }
}
