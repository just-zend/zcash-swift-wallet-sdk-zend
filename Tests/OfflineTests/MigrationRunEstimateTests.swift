//
//  MigrationRunEstimateTests.swift
//  OfflineTests
//
//  Pure model math for `MigrationRunEstimate`: the per-run transaction and signing-session
//  arithmetic, the cross-run totals, and — the semantically load-bearing part — that
//  `totalSigningSessions(maxTransactionsPerSession:)` sums per-run sessions instead of pooling
//  transactions across runs (sessions cannot span runs: a later run's transactions spend notes an
//  earlier run must mine first). Mirrors the upstream `RunEstimate::signing_sessions` /
//  `MigrationRunEstimate::total_signing_sessions` semantics. The FFI decode of the estimate is
//  exercised through the real welding in MigrationFFITests.swift.
//

import XCTest
@testable import ZcashLightClientKit

final class MigrationRunEstimateTests: XCTestCase {
    /// `transactions` is the run's preparation transactions plus one crossing transfer per
    /// funding note.
    func testRunTransactionsIsPreparationPlusCrossings() {
        let run = MigrationRunEstimate.Run(
            migratable: Zatoshi(100),
            crossings: 3,
            preparationLayers: 2,
            preparationTransactions: 4
        )

        XCTAssertEqual(run.transactions, 7)
    }

    /// When the transaction count divides the session capacity exactly, no session is wasted.
    func testRunSigningSessionsOnAnExactMultiple() {
        let run = MigrationRunEstimate.Run(
            migratable: Zatoshi(100),
            crossings: 2,
            preparationLayers: 1,
            preparationTransactions: 4
        )

        // 6 transactions at 3 per session: exactly 2 sessions.
        XCTAssertEqual(run.signingSessions(maxTransactionsPerSession: 3), 2)
    }

    /// A remainder costs one extra (partially filled) session: ceil division, not floor.
    func testRunSigningSessionsWithARemainder() {
        let run = MigrationRunEstimate.Run(
            migratable: Zatoshi(100),
            crossings: 3,
            preparationLayers: 2,
            preparationTransactions: 4
        )

        // 7 transactions at 3 per session: 2 full sessions + 1 for the remainder.
        XCTAssertEqual(run.signingSessions(maxTransactionsPerSession: 3), 3)
    }

    /// A capacity of one transaction per session degenerates to one session per transaction.
    func testRunSigningSessionsAtOnePerSession() {
        let run = MigrationRunEstimate.Run(
            migratable: Zatoshi(100),
            crossings: 2,
            preparationLayers: 1,
            preparationTransactions: 3
        )

        XCTAssertEqual(run.signingSessions(maxTransactionsPerSession: 1), 5)
    }

    /// The totals are plain sums across runs, and `totalTransactions` equals
    /// `totalPreparationTransactions + totalCrossings`.
    func testTotalsSumAcrossRuns() {
        let estimate = MigrationRunEstimate(
            runs: [
                MigrationRunEstimate.Run(
                    migratable: Zatoshi(500),
                    crossings: 2,
                    preparationLayers: 1,
                    preparationTransactions: 3
                ),
                MigrationRunEstimate.Run(
                    migratable: Zatoshi(250),
                    crossings: 3,
                    preparationLayers: 2,
                    preparationTransactions: 2
                )
            ],
            finalResidual: Zatoshi(7)
        )

        XCTAssertEqual(estimate.runCount, 2)
        XCTAssertEqual(estimate.totalMigratable, Zatoshi(750))
        XCTAssertEqual(estimate.totalCrossings, 5)
        XCTAssertEqual(estimate.totalPreparationLayers, 3)
        XCTAssertEqual(estimate.totalPreparationTransactions, 5)
        XCTAssertEqual(estimate.totalTransactions, 10)
        XCTAssertEqual(estimate.finalResidual, Zatoshi(7))
    }

    /// The load-bearing session semantics: `totalSigningSessions` is the SUM of per-run session
    /// counts, NOT `ceil(totalTransactions / max)` — a later run's transactions spend notes an
    /// earlier run must mine first, so the spare capacity in a run's last session cannot be
    /// filled with the next run's transactions. This fixture is chosen so the two answers differ.
    func testTotalSigningSessionsDoNotPoolAcrossRuns() {
        let estimate = MigrationRunEstimate(
            runs: [
                MigrationRunEstimate.Run(
                    migratable: Zatoshi(500),
                    crossings: 2,
                    preparationLayers: 1,
                    preparationTransactions: 3
                ),
                MigrationRunEstimate.Run(
                    migratable: Zatoshi(250),
                    crossings: 3,
                    preparationLayers: 2,
                    preparationTransactions: 2
                )
            ],
            finalResidual: Zatoshi.zero
        )

        // 5 + 5 transactions at 4 per session: per-run ceil gives 2 + 2 = 4 sessions,
        // while the naive pooled ceil(10 / 4) would claim only 3.
        XCTAssertEqual(estimate.totalTransactions, 10)
        XCTAssertEqual(estimate.totalSigningSessions(maxTransactionsPerSession: 4), 4)
        XCTAssertNotEqual(
            estimate.totalSigningSessions(maxTransactionsPerSession: 4),
            (estimate.totalTransactions + 3) / 4,
            "per-run sessions must not collapse into the pooled ceiling"
        )
    }

    /// The zero-run estimate (nothing migrates) has all-zero totals and needs no signing
    /// sessions — a legitimate answer, mirroring the FFI's non-error empty marshaling.
    func testZeroRunEstimateHasAllZeroTotals() {
        let estimate = MigrationRunEstimate(runs: [], finalResidual: Zatoshi.zero)

        XCTAssertEqual(estimate.runCount, 0)
        XCTAssertEqual(estimate.totalMigratable, .zero)
        XCTAssertEqual(estimate.totalCrossings, 0)
        XCTAssertEqual(estimate.totalPreparationLayers, 0)
        XCTAssertEqual(estimate.totalPreparationTransactions, 0)
        XCTAssertEqual(estimate.totalTransactions, 0)
        XCTAssertEqual(estimate.totalSigningSessions(maxTransactionsPerSession: 1), 0)
        XCTAssertEqual(estimate.finalResidual, .zero)
    }
}
