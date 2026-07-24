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
import libzcashlc
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

    /// No stored run marshals as an EMPTY container (`len == 0`), not an error -- see
    /// `zcashlc_migration_transaction_statuses`'s doc.
    func testFreshWalletHasNoTransactionStatuses() async throws {
        let statuses = try await rustBackend.migrationTransactionStatuses(for: account)
        XCTAssertTrue(statuses.isEmpty)
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

    /// `isNoteSplitNeeded` plans fresh against the live balance. On this never-synced fixture the
    /// engine reports "nothing to migrate" (no spendable Orchard notes), which the FFI maps to a
    /// benign `false` — the same answer the platform's "does anything remain" sequential-runs check
    /// consumes. (The v1 crate threw `NotSynced` here; the final engine plans over whatever the
    /// wallet database knows.)
    func testFreshUnsyncedWalletIsNoteSplitNeededIsFalse() async throws {
        let needed = try await rustBackend.migrationIsNoteSplitNeeded(for: account)
        XCTAssertFalse(needed, "a fresh wallet with nothing to migrate needs no note split")
    }

    /// Same root behavior as `isNoteSplitNeeded` above: with nothing to migrate there is no note
    /// split and therefore no residual — `nil`, not a throw. (The v1 crate threw `NotSynced` on
    /// this fixture.)
    func testFreshUnsyncedWalletResidualAfterMigrationIsNil() async throws {
        let residual = try await rustBackend.migrationResidualAfterMigration(for: account)
        XCTAssertNil(residual, "a fresh wallet with nothing to migrate has no residual")
    }

    // MARK: - Residual locking

    /// Residual locking is available only after the strict public migration `Complete` state. A
    /// fresh wallet has no migration at all, so even its empty spendable set must not bypass the
    /// ordering gate and acquire the permanent residual owner.
    func testFreshWalletLockResidualRequiresStrictComplete() async throws {
        do {
            _ = try await rustBackend.lockMigrationResidual(accountUUID: account)
            XCTFail("Expected residual locking before strict Complete to throw")
        } catch ZcashError.rustMigrationLockResidual {
            // expected
        } catch {
            XCTFail("Expected rustMigrationLockResidual but got \(error)")
        }
    }

    /// The release half on a fresh wallet: no locks exist, so the cleared-output count is `0`.
    func testFreshWalletUnlockResidualClearsNothing() async throws {
        let unlocked = try await rustBackend.unlockMigrationResidual(accountUUID: account)
        XCTAssertEqual(unlocked, 0)
    }

    /// A rejected pre-completion lock attempt leaves no residual-owned lock behind.
    func testRejectedResidualLockLeavesNothingToUnlock() async throws {
        do {
            _ = try await rustBackend.lockMigrationResidual(accountUUID: account)
            XCTFail("Expected residual locking before strict Complete to throw")
        } catch ZcashError.rustMigrationLockResidual {
            // expected
        }
        let unlocked = try await rustBackend.unlockMigrationResidual(accountUUID: account)
        XCTAssertEqual(unlocked, 0)
    }

    // MARK: - Run-count estimate

    /// On a fresh wallet with nothing to migrate, the run-count estimate is the ZERO-RUN
    /// estimate — `runCount` 0 and no residual — a legitimate answer decoded from a non-null
    /// FFI struct, not an error: the estimate analog of the empty propose schedule (and of
    /// `isNoteSplitNeeded`'s benign `false` above).
    func testFreshWalletEstimateMigrationRunsIsZeroRuns() async throws {
        let estimate = try await rustBackend.estimateMigrationRuns(accountUUID: account)

        XCTAssertEqual(estimate.runCount, 0)
        XCTAssertTrue(estimate.runs.isEmpty)
        XCTAssertEqual(estimate.finalResidual, .zero)
        XCTAssertEqual(estimate.totalSigningSessions(maxTransactionsPerSession: 1), 0)
    }

    // MARK: - Invalid-state transitions

    /// A commit without a matching previewed plan is the plan-stale contract: the engine signs
    /// exactly the plan the most recent propose call cached (ZIP 318 draws fresh schedule
    /// randomness on every proposal), so committing with nothing cached must surface
    /// `migrationPlanStale` — the actionable "propose again" signal — not a generic failure.
    func testSignAndStoreWithoutAPreviewedPlanThrowsPlanStale() async throws {
        let emptySchedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
        do {
            try await rustBackend.migrationSignAndStoreSchedule(emptySchedule, usk: usk, for: account)
            XCTFail("Expected committing without a previewed plan to throw")
        } catch ZcashError.migrationPlanStale {
            // expected
        } catch {
            XCTFail("Expected migrationPlanStale but got \(error)")
        }
    }

    /// A nonzero handle is not authority by itself: if it does not identify a live Rust-cached
    /// plan (for example after relaunch or supersession), the same re-propose signal is returned.
    func testSignAndStoreWithAStaleNonzeroHandleThrowsPlanStale() async throws {
        let staleSchedule = MigrationSchedule(
            transfers: [],
            estimatedDurationHours: 0,
            proposalHandle: 0xDEAD_BEEF
        )
        do {
            try await rustBackend.migrationSignAndStoreSchedule(staleSchedule, usk: usk, for: account)
            XCTFail("Expected committing with a stale handle to throw")
        } catch ZcashError.migrationPlanStale {
            // expected
        } catch {
            XCTFail("Expected migrationPlanStale but got \(error)")
        }
    }

    /// MOB-1513 R2: the FFI→model mapping (`FfiMigrationProgress.unsafeToMigrationProgress()`) must
    /// copy `is_immediate` straight through, so the immediate lane's quiet-aftermath flag survives
    /// the boundary and the model's defaulted `isImmediate` can never silently swallow it. Both
    /// paths are exercised on the mapping directly (constructing the `#[repr(C)]` struct) because an
    /// engine-tracked InProgress — the only real-FFI `is_immediate == false` source — needs a
    /// seeded, synced Orchard balance this offline suite does not have.
    func testMigrationProgressMappingCarriesIsImmediateBothWays() throws {
        let immediate = FfiMigrationProgress(
            is_present: true,
            completed_transfers: 0,
            total_transfers: 1,
            remaining_orchard_value: 0,
            next_transfer_ready_at_height: -1,
            is_immediate: true
        )
        let immediateProgress = try XCTUnwrap(immediate.unsafeToMigrationProgress())
        XCTAssertTrue(immediateProgress.isImmediate, "an immediate-lane FFI struct must map to isImmediate = true")

        let engine = FfiMigrationProgress(
            is_present: true,
            completed_transfers: 1,
            total_transfers: 3,
            remaining_orchard_value: 12_345,
            next_transfer_ready_at_height: 100,
            is_immediate: false
        )
        let engineProgress = try XCTUnwrap(engine.unsafeToMigrationProgress())
        XCTAssertFalse(engineProgress.isImmediate, "an engine-tracked FFI struct must map to isImmediate = false")
    }

    // MARK: - Ironwood activation height

    /// Verified against the pinned rust source directly: zcash_protocol 0.10.0 @ e0e1277
    /// (components/zcash_protocol/src/consensus.rs), `impl Parameters for MainNetwork` ->
    /// `NetworkUpgrade::Nu6_3 => Some(BlockHeight(3_428_143))`. Also asserts the public
    /// `OrchardMigration.ironwoodActivationHeight(for:)` accessor delegates to the same value, so
    /// the public surface -- not just the internal backend -- is test-covered.
    func testIronwoodActivationHeightMainnet() throws {
        let height = try XCTUnwrap(ZcashRustBackend.ironwoodActivationHeight(networkType: .mainnet))
        XCTAssertEqual(height, 3_428_143)

        let publicHeight = try XCTUnwrap(OrchardMigration.ironwoodActivationHeight(for: .mainnet))
        XCTAssertEqual(publicHeight, height)

        // The public `ZcashNetwork.ironwoodActivationHeight` extension (the app-facing home that
        // replaces hosts' hardcoded NU heights) resolves to the same value.
        let networkHeight = try XCTUnwrap(ZcashNetworkBuilder.network(for: .mainnet).ironwoodActivationHeight)
        XCTAssertEqual(networkHeight, height)
    }

    /// Verified against the pinned rust source directly: zcash_protocol 0.10.0 @ e0e1277
    /// (components/zcash_protocol/src/consensus.rs), `impl Parameters for TestNetwork` ->
    /// `NetworkUpgrade::Nu6_3 => Some(BlockHeight(4_134_000))`. Matches the brief's expectation
    /// exactly; no discrepancy to flag.
    func testIronwoodActivationHeightTestnet() throws {
        let height = try XCTUnwrap(ZcashRustBackend.ironwoodActivationHeight(networkType: .testnet))
        XCTAssertEqual(height, 4_134_000)

        // The public `ZcashNetwork.ironwoodActivationHeight` extension resolves to the same value.
        let networkHeight = try XCTUnwrap(ZcashNetworkBuilder.network(for: .testnet).ironwoodActivationHeight)
        XCTAssertEqual(networkHeight, height)
    }

    /// The public `ZcashNetwork.ironwoodActivationHeight` extension on a custom (regtest-slot)
    /// network resolves through the same FFI path and reports `nil` -- the documented "no known
    /// Ironwood activation for that network" case: the regtest network id carries no fixed NU6.3
    /// height. Registers the same idempotent custom heights as
    /// `testOrchardMigrationRegistersCustomActivationHeightsOnInit` /
    /// `RegtestActivationHeightsTests.testRegtestConsensusBranchIdReflectsCustomActivationHeights`
    /// (`zcashlc_set_custom_network` is process-global and a conflicting re-registration asserts, so
    /// identical values keep every registrant idempotent regardless of run order).
    func testIronwoodActivationHeightForCustomNetworkIsNil() {
        let activationHeights = NetworkActivationHeights(
            overwinter: 1,
            sapling: 1,
            blossom: 1,
            heartwood: 1,
            canopy: 1,
            nu5: 100,
            nu6: 200
        )
        _ = ZcashRustBackend.setCustomNetwork(base: .regtest, activationHeights)
        let network = ZcashNetworkBuilder.custom(base: .mainnet, activationHeights: activationHeights)

        XCTAssertNil(network.ironwoodActivationHeight)
    }

    // MARK: - Marshaling determinism

    func testMigrationProgressNilIsStableAcrossRepeatedCalls() async throws {
        let first = try await rustBackend.migrationProgress(for: account)
        let second = try await rustBackend.migrationProgress(for: account)
        XCTAssertNil(first)
        XCTAssertEqual(first, second)
    }

    func testMigrationTransactionStatusesEmptyIsStableAcrossRepeatedCalls() async throws {
        let first = try await rustBackend.migrationTransactionStatuses(for: account)
        let second = try await rustBackend.migrationTransactionStatuses(for: account)
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(first, second)
    }

    func testMigrationPendingTransferProposalNilIsStableAcrossRepeatedCalls() async throws {
        let first = try await rustBackend.migrationPendingTransferProposal(for: account)
        let second = try await rustBackend.migrationPendingTransferProposal(for: account)
        XCTAssertNil(first)
        XCTAssertEqual(first, second)
    }

    func testMigrationResidualAfterMigrationNilIsStableAcrossRepeatedCalls() async throws {
        let first = try await rustBackend.migrationResidualAfterMigration(for: account)
        let second = try await rustBackend.migrationResidualAfterMigration(for: account)
        XCTAssertNil(first)
        XCTAssertEqual(first, second)
    }

    /// Guards against last-error-channel pollution across calls: a throwing call must not corrupt
    /// the next legitimate `false` answer from an ambiguous-bool-sentinel call
    /// (`hasOverdueTransfers`, which reads only the empty migration store on a fresh db)
    /// sandwiched around it. The throwing predecessor is a supported handle-gated schedule commit
    /// without a cached preview.
    func testHasOverdueTransfersIsUnaffectedByAPrecedingThrowingMigrationCall() async throws {
        let before = try await rustBackend.migrationHasOverdueTransfers(for: account)
        XCTAssertFalse(before)

        do {
            try await rustBackend.migrationSignAndStoreSchedule(
                MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0),
                usk: usk,
                for: account
            )
            XCTFail("Expected committing without a preview to throw")
        } catch {
            // Expected; the specific plan-stale case is asserted above.
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

    // MARK: - Transaction status decode mapping
    //
    // `FfiMigrationTransactionStatus`'s raw C fields fold into `MigrationTransactionStatus`'s
    // enums; these tests construct the `#[repr(C)]` struct directly (mirroring
    // `testMigrationProgressMappingCarriesIsImmediateBothWays` above) and exercise the internal
    // `unsafeToMigrationTransactionStatus()` decode function itself. The balance-bearing engine
    // state a real committed run needs is out of reach for this offline suite (see the file
    // header), so the field-by-field mapping -- including the malformed-discriminant fallback --
    // is exercised here instead of over the real FFI.

    func testDecodeMapsPreparationKind() throws {
        let ffi = makeStatus(isTransfer: false, prepLayer: 2, prepIndex: 1, crossing: -1)
        let decoded = try XCTUnwrap(ffi.unsafeToMigrationTransactionStatus())
        XCTAssertEqual(decoded.kind, .preparation(layer: 2, index: 1))
    }

    func testDecodeMapsTransferKind() throws {
        let ffi = makeStatus(isTransfer: true, prepLayer: -1, prepIndex: -1, crossing: 5)
        let decoded = try XCTUnwrap(ffi.unsafeToMigrationTransactionStatus())
        XCTAssertEqual(decoded.kind, .transfer(crossing: 5))
    }

    func testDecodeMapsAwaitingSignatureSignedAndProvedStates() throws {
        let awaitingSignature = try XCTUnwrap(makeStatus(state: 0).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(awaitingSignature.state, .awaitingSignature)

        let signed = try XCTUnwrap(makeStatus(state: 1).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(signed.state, .signed)

        let proved = try XCTUnwrap(makeStatus(state: 2).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(proved.state, .proved)
    }

    /// `has_txid` is engine-verbatim -- true only while `state == 3` (Broadcast) -- so the folded
    /// `.broadcast` case carries the txid straight through.
    func testDecodeMapsBroadcastStateWithItsTxid() throws {
        let bytes = (0 ..< 32).map { UInt8($0) }
        let ffi = makeStatus(state: 3, txid: Self.tuple32(bytes), hasTxid: true)
        let decoded = try XCTUnwrap(ffi.unsafeToMigrationTransactionStatus())
        XCTAssertEqual(decoded.state, .broadcast(txid: Data(bytes)))
    }

    /// A mined row's txid is NOT carried by the engine's state model (`has_txid` drops back to
    /// `false` once mined) -- `.mined` carries only the height, matching the model's own doc.
    func testDecodeMapsMinedStateWithItsHeight() throws {
        let ffi = makeStatus(state: 4, minedHeight: 3_500_000)
        let decoded = try XCTUnwrap(ffi.unsafeToMigrationTransactionStatus())
        XCTAssertEqual(decoded.state, .mined(height: 3_500_000))
    }

    func testDecodeMapsExpiryHeightZeroSentinelToNil() throws {
        let ffi = makeStatus(expiryHeight: 0)
        let decoded = try XCTUnwrap(ffi.unsafeToMigrationTransactionStatus())
        XCTAssertNil(decoded.expiryHeight, "the engine's 0 sentinel means 'never expires'")
    }

    func testDecodeMapsANonzeroExpiryHeightThrough() throws {
        let ffi = makeStatus(expiryHeight: 3_100_000)
        let decoded = try XCTUnwrap(ffi.unsafeToMigrationTransactionStatus())
        XCTAssertEqual(decoded.expiryHeight, 3_100_000)
    }

    func testDecodeMapsIdScheduledHeightAndReadyStraightThrough() throws {
        let ffi = makeStatus(id: 42, scheduledHeight: 3_050_000, ready: false)
        let decoded = try XCTUnwrap(ffi.unsafeToMigrationTransactionStatus())
        XCTAssertEqual(decoded.id, 42)
        XCTAssertEqual(decoded.scheduledHeight, 3_050_000)
        XCTAssertFalse(decoded.isReady)
    }

    func testDecodeMapsEachNextActionCase() throws {
        let none = try XCTUnwrap(makeStatus(action: 0).unsafeToMigrationTransactionStatus())
        XCTAssertNil(none.nextAction)

        let prove = try XCTUnwrap(makeStatus(action: 1).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(prove.nextAction, .prove)

        let broadcast = try XCTUnwrap(makeStatus(action: 2).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(broadcast.nextAction, .broadcast)
    }

    func testDecodeMapsEachBlockedOnCase() throws {
        let none = try XCTUnwrap(makeStatus(blockedOn: 0).unsafeToMigrationTransactionStatus())
        XCTAssertNil(none.blockedOn)

        let dependencies = try XCTUnwrap(makeStatus(blockedOn: 1).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(dependencies.blockedOn, .dependencies)

        let schedule = try XCTUnwrap(makeStatus(blockedOn: 2).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(schedule.blockedOn, .schedule)

        let anchorBoundary = try XCTUnwrap(makeStatus(blockedOn: 3).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(anchorBoundary.blockedOn, .anchorBoundary)

        let signature = try XCTUnwrap(makeStatus(blockedOn: 4).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(signature.blockedOn, .signature)

        let expired = try XCTUnwrap(makeStatus(blockedOn: 5).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(expired.blockedOn, .expired)
    }

    func testDecodeReturnsNilForAnOutOfRangeState() {
        XCTAssertNil(makeStatus(state: 99).unsafeToMigrationTransactionStatus())
    }

    func testDecodeReturnsNilForAnOutOfRangeNextAction() {
        XCTAssertNil(makeStatus(action: 99).unsafeToMigrationTransactionStatus())
    }

    func testDecodeReturnsNilForAnOutOfRangeBlockedOn() {
        XCTAssertNil(makeStatus(blockedOn: 99).unsafeToMigrationTransactionStatus())
    }

    /// The engine's contract ties `has_txid` to `state == 3` (Broadcast) -- see
    /// `FfiMigrationTransactionStatus`'s doc. A broadcast row without a txid violates that
    /// contract, so decode treats it as malformed rather than silently folding in a fake empty
    /// txid.
    func testDecodeReturnsNilForABroadcastStateWithoutATxid() {
        XCTAssertNil(makeStatus(state: 3, hasTxid: false).unsafeToMigrationTransactionStatus())
    }

    func testDecodeReturnsNilForAMinedStateWithNoMinedHeight() {
        XCTAssertNil(makeStatus(state: 4, minedHeight: -1).unsafeToMigrationTransactionStatus())
    }

    func testDecodeReturnsNilForAPreparationRowWithANegativeLayerOrIndex() {
        XCTAssertNil(makeStatus(isTransfer: false, prepLayer: -1, prepIndex: 0).unsafeToMigrationTransactionStatus())
        XCTAssertNil(makeStatus(isTransfer: false, prepLayer: 0, prepIndex: -1).unsafeToMigrationTransactionStatus())
    }

    func testDecodeReturnsNilForATransferRowWithANegativeCrossing() {
        XCTAssertNil(makeStatus(isTransfer: true, crossing: -1).unsafeToMigrationTransactionStatus())
    }

    /// Exercises `FfiMigrationTransactionStatuses.unsafeToMigrationTransactionStatuses()` (the
    /// container decode) directly: the engine's own `transaction_statuses` order (dependency
    /// order: preparation layers first, then transfers) must survive the marshal untouched.
    func testDecodeContainerMapsMultipleRowsInEngineOrder() throws {
        var rows = [
            makeStatus(id: 1, isTransfer: false, prepLayer: 0, prepIndex: 0, crossing: -1),
            makeStatus(id: 2, isTransfer: true, prepLayer: -1, prepIndex: -1, crossing: 0)
        ]
        let decoded = try rows.withUnsafeMutableBufferPointer { buffer -> [MigrationTransactionStatus] in
            let container = FfiMigrationTransactionStatuses(ptr: buffer.baseAddress, len: UInt(buffer.count))
            return try XCTUnwrap(container.unsafeToMigrationTransactionStatuses())
        }
        XCTAssertEqual(decoded.map(\.id), [1, 2])
    }

    /// A single malformed row anywhere in the container must fail the WHOLE decode -- a partially
    /// decoded array would silently drop the malformed transaction rather than surfacing the
    /// "returned malformed data" error `ZcashRustBackend.migrationTransactionStatuses` maps it to.
    func testDecodeContainerReturnsNilWhenAnyRowIsMalformed() {
        var rows = [
            makeStatus(id: 1),
            makeStatus(id: 2, state: 99)
        ]
        let decoded = rows.withUnsafeMutableBufferPointer { buffer -> [MigrationTransactionStatus]? in
            FfiMigrationTransactionStatuses(ptr: buffer.baseAddress, len: UInt(buffer.count)).unsafeToMigrationTransactionStatuses()
        }
        XCTAssertNil(decoded, "a malformed row anywhere in the array must fail the whole decode")
    }

    // MARK: - Actor integration over real FFI (nil paths)

    /// Constructs a real `OrchardMigration` via the injecting initializer, wired to the SAME
    /// real-FFI-backed welding as the rest of this file (not a mock) plus a real, temp-file-backed
    /// `MigrationSyncGate`. On this fresh wallet the runtime has no delivery run, so
    /// `executeNextPendingTransfer` must short-circuit before ever reaching the submitter
    /// -- proven here with a fake that fails the assertion (via a non-zero call count) rather than
    /// the test itself if that contract regresses. `rescheduleOverdueTransfer` likewise resolves
    /// `nil` (no active run), exercising the engine-backed pending-proposal accessor over real FFI.
    func testFreshWalletActorNextPendingTransferAndRescheduleAreNilOverRealFFI() async throws {
        let storageDirectory = try makeUniqueStorageDirectory()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let broadcaster = ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable))
        let migration = OrchardMigration(
            welding: rustBackend,
            accountUUID: account,
            broadcaster: broadcaster,
            syncGate: MigrationSyncGate(
                directory: storageDirectory,
                accountUUID: account,
                bufferDuration: 600,
                tickInterval: 3600,
                overdueProvider: { false },
                logger: logger
            ),
            logger: logger
        )

        let result = try await migration.executeNextPendingTransfer(
            options: MigrationNetworkPrivacyOptions(
                useTor: false,
                submissionEndpoint: LightWalletEndpoint(address: "default.example", port: 9067)
            )
        )
        XCTAssertNil(result)
        XCTAssertEqual(broadcaster.receivedCalls.count, 0)

        let rescheduled = try await migration.rescheduleOverdueTransfer()
        XCTAssertNil(rescheduled)
    }

    // MARK: - Custom network registration

    /// `OrchardMigration.init(config:)` builds its own `ZcashRustBackend` rather than sharing the
    /// synchronizer's, so it -- like `Initializer.setup` -- must register a custom network's
    /// activation heights with the Rust core itself; nothing else does it on this path. Pre-fix,
    /// every migration FFI call on a `.regtest`/custom network id (2) throws "custom network (id 2)
    /// used before it was configured" (see `rust/src/lib.rs`'s `parse_network`), which
    /// `migrationState()` surfaces as `rustMigrationState`, and which `isSyncBlocked()`/the gate's
    /// `overdueProvider` silently swallow via `try?` instead (finding 5's "migration dead on
    /// .custom/.regtest").
    ///
    /// `NetworkActivationHeights` here intentionally matches
    /// `RegtestActivationHeightsTests.testRegtestConsensusBranchIdReflectsCustomActivationHeights`'s
    /// values exactly: `zcashlc_set_custom_network` is process-global, `swift test` runs the whole
    /// `OfflineTests` bundle in one process, and a conflicting re-registration is a host
    /// configuration bug this code path asserts on (`assertionFailure`, live in a debug/test build).
    /// Identical values make both tests' registrations idempotent regardless of run order.
    ///
    /// The engine's store tables ride the wallet schema migrations (the FFI no longer creates
    /// them on first touch), so the fixture initializes the wallet database first — exactly like
    /// a real caller, whose `Initializer`/`prepare` runs `initDataDb` before any migration read —
    /// and then verifies `migrationState()` reads `NotStarted` over the custom network the
    /// `OrchardMigration` initializer registered.
    ///
    /// `migrationState()` opens the account-scoped migration store, which requires a real `accounts`
    /// row (mirroring this file's class-wide `setUp()` and its own "representative of real usage"
    /// rationale). The FIRST `OrchardMigration.init(config:)` below registers the custom network as
    /// a side effect (the behavior under test; its placeholder `accountUUID` is never queried) --
    /// only once that registration has happened can any other FFI call on this network id succeed,
    /// so `initDataDb`/`createAccount` (which discover the REAL `AccountUUID` the wallet assigns)
    /// must run after it. The SECOND `OrchardMigration.init(config:)`, bound to that real account, is
    /// the instance the assertion below exercises; re-registering the same activation heights is
    /// harmlessly idempotent.
    func testOrchardMigrationRegistersCustomActivationHeightsOnInit() async throws {
        let activationHeights = NetworkActivationHeights(
            overwinter: 1,
            sapling: 1,
            blossom: 1,
            heartwood: 1,
            canopy: 1,
            nu5: 100,
            nu6: 200
        )
        let network = ZcashNetworkBuilder.regtest(activationHeights: activationHeights)

        let storageDirectory = try makeUniqueStorageDirectory()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        func makeConfig(accountUUID: AccountUUID) -> OrchardMigration.Config {
            OrchardMigration.Config(
                dataDbURL: storageDirectory.appendingPathComponent("data.db"),
                fsBlockDbRoot: storageDirectory.appendingPathComponent("fs_cache", isDirectory: true),
                spendParamsURL: storageDirectory.appendingPathComponent("sapling-spend.params"),
                outputParamsURL: storageDirectory.appendingPathComponent("sapling-output.params"),
                network: network,
                accountUUID: accountUUID,
                torDirURL: storageDirectory.appendingPathComponent("tor", isDirectory: true),
                generalStorageURL: storageDirectory,
                loggingPolicy: .noLogging
            )
        }

        // Registers the custom network as a side effect of `init(config:)` -- this placeholder
        // account is never used past this point.
        _ = OrchardMigration(config: makeConfig(accountUUID: AccountUUID(id: [UInt8](repeating: 9, count: 16))))

        let initBackend = ZcashRustBackend.makeForTests(
            dbData: storageDirectory.appendingPathComponent("data.db"),
            fsBlockDbRoot: storageDirectory.appendingPathComponent("fs_cache", isDirectory: true),
            networkType: network.networkType
        )
        let dbInit = try await initBackend.initDataDb(seed: nil)
        guard case .success = dbInit else {
            XCTFail("Failed to initDataDb. Expected `.success`, got \(String(describing: dbInit))")
            return
        }

        let checkpointSource = CheckpointSourceFactory.fromBundle(for: .regtest, regtestActivationHeights: activationHeights)
        let treeState = checkpointSource.latestKnownCheckpoint().treeState()
        _ = try await initBackend.createAccount(
            seed: Environment.seedBytes,
            treeState: treeState,
            recoverUntil: nil,
            name: "",
            keySource: nil
        )
        let accounts = try await initBackend.listAccounts()
        let accountUUID = try XCTUnwrap(accounts.first?.id)

        let migration = OrchardMigration(config: makeConfig(accountUUID: accountUUID))

        do {
            let state = try await migration.migrationState()
            XCTAssertEqual(state, MigrationState.notStarted)
        } catch {
            XCTFail("Expected migrationState() to succeed once the custom network is registered by init(config:); got \(error)")
        }
    }

    // MARK: - Helpers

    private func makeUniqueStorageDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MigrationFFITests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The imported shape of `FfiMigrationTransactionStatus.txid` (`uint8_t[32]`): an unlabeled
    /// 32-`UInt8` tuple, structurally identical to (and freely interchangeable with) that field's
    /// own C-imported type, matching how `FfiTxId.tuple` is used elsewhere in the SDK.
    private typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    private static func tuple32(_ bytes: [UInt8]) -> Bytes32 {
        precondition(bytes.count == 32, "a txid is exactly 32 bytes")
        return bytes.withUnsafeBytes { $0.load(as: Bytes32.self) }
    }

    /// Builds a valid row -- transfer 0, awaiting signature, ready, no next action, not blocked,
    /// no txid -- with every field defaulted; override only the field(s) under test. Mirrors
    /// `FfiMigrationTransactionStatus`'s field-by-field contract (see `rust/src/migration.rs`'s
    /// doc comments).
    private func makeStatus(
        id: UInt32 = 7,
        isTransfer: Bool = true,
        prepLayer: Int64 = -1,
        prepIndex: Int64 = -1,
        crossing: Int64 = 0,
        state: UInt8 = 0,
        scheduledHeight: Int64 = 3_000_000,
        expiryHeight: Int64 = 3_000_100,
        minedHeight: Int64 = -1,
        txid: Bytes32 = MigrationFFITests.tuple32([UInt8](repeating: 0, count: 32)),
        hasTxid: Bool = false,
        ready: Bool = true,
        action: UInt8 = 0,
        blockedOn: UInt8 = 0
    ) -> FfiMigrationTransactionStatus {
        FfiMigrationTransactionStatus(
            id: id,
            is_transfer: isTransfer,
            prep_layer: prepLayer,
            prep_index: prepIndex,
            crossing: crossing,
            state: state,
            scheduled_height: scheduledHeight,
            expiry_height: expiryHeight,
            mined_height: minedHeight,
            txid: txid,
            has_txid: hasTxid,
            ready: ready,
            action: action,
            blocked_on: blockedOn
        )
    }
}
