//
//  ChainTipEstimatorTests.swift
//  OfflineTests
//
//  Pure-math tests for `ChainTipEstimator`: the measured-block-rate wall-clock chain-tip
//  projection behind `Synchronizer.estimatedMigrationChainTip()` /
//  `.estimatedMigrationSecondsPerBlock()` and every `useEstimatedTip: true` call site.
//  No network, no FFI, no wallet database -- `ChainTipEstimator` is constructed directly from
//  hand-built `MigrationBlockRateSample` fixtures.
//

import XCTest
@testable import ZcashLightClientKit

final class ChainTipEstimatorTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Android-parity constants

    /// Pins the exact constants the type doc claims mirror the Android SDK's estimator -- a
    /// regression here is a silent behavior change, not just a cosmetic one.
    func testConstantsMatchAndroidParity() {
        XCTAssertEqual(ChainTipEstimator.sampleWindow, 100)
        XCTAssertEqual(ChainTipEstimator.minSecondsPerBlock, 5)
        XCTAssertEqual(ChainTipEstimator.maxSecondsPerBlock, 150)
        XCTAssertEqual(ChainTipEstimator.fallbackSecondsPerBlock, 75)
    }

    // MARK: - secondsPerBlock(): fallback

    func testSecondsPerBlockFallsBackWithNoSamples() {
        let estimator = ChainTipEstimator(samples: [])
        XCTAssertEqual(estimator.secondsPerBlock(), 75)
    }

    func testSecondsPerBlockFallsBackWithExactlyOneSample() {
        let estimator = ChainTipEstimator(samples: [
            MigrationBlockRateSample(height: 1_000_000, unixTime: 1_700_000_000)
        ])
        XCTAssertEqual(estimator.secondsPerBlock(), 75)
    }

    /// The boundary: exactly two samples is enough to stop falling back and compute a real mean.
    func testSecondsPerBlockComputesAMeanWithExactlyTwoSamples() {
        let estimator = ChainTipEstimator(samples: [
            MigrationBlockRateSample(height: 1_000_000, unixTime: 1_700_000_000),
            MigrationBlockRateSample(height: 1_000_001, unixTime: 1_700_000_060)
        ])
        XCTAssertEqual(estimator.secondsPerBlock(), 60)
    }

    // MARK: - secondsPerBlock(): mean of deltas

    /// Three samples, two deltas (60 s, 70 s, 80 s), neither clamp engaged: the mean is the plain
    /// arithmetic mean of the consecutive header-time deltas.
    func testSecondsPerBlockIsTheMeanOfConsecutiveDeltas() {
        let estimator = ChainTipEstimator(samples: [
            MigrationBlockRateSample(height: 1_000_000, unixTime: 1_700_000_000),
            MigrationBlockRateSample(height: 1_000_001, unixTime: 1_700_000_060),
            MigrationBlockRateSample(height: 1_000_002, unixTime: 1_700_000_130),
            MigrationBlockRateSample(height: 1_000_003, unixTime: 1_700_000_210)
        ])
        // Deltas: 60, 70, 80 -- mean 70.
        XCTAssertEqual(estimator.secondsPerBlock(), 70)
    }

    /// Only the last `sampleWindow` (100) samples participate: a 101-sample fixture whose single
    /// OLDEST delta is a wild outlier must compute the same mean as the same fixture with that
    /// oldest sample removed -- proving the window, not just "some" bound, is enforced.
    func testSecondsPerBlockOnlyConsidersTheLastSampleWindowSamples() {
        var samples: [MigrationBlockRateSample] = [
            // The outlier: a 100_000 s gap to the next sample -- would drag the mean far above 150
            // (even after per-delta clamping to 150) if it were included.
            MigrationBlockRateSample(height: 0, unixTime: 0)
        ]
        var time: Int64 = 100_000
        var height = 1
        // 100 more samples (101 total), each 60 s apart -- exactly `sampleWindow` deltas among the
        // last 100 samples once the outlier at index 0 is excluded.
        for _ in 0..<100 {
            samples.append(MigrationBlockRateSample(height: height, unixTime: time))
            time += 60
            height += 1
        }

        let estimator = ChainTipEstimator(samples: samples)
        let estimatorWithoutOutlier = ChainTipEstimator(samples: Array(samples.dropFirst()))

        XCTAssertEqual(estimator.secondsPerBlock(), 60, "the outlier at index 0 must fall outside the last-100-sample window")
        XCTAssertEqual(estimator.secondsPerBlock(), estimatorWithoutOutlier.secondsPerBlock())
    }

    // MARK: - secondsPerBlock(): per-delta and result clamps

    /// A delta below `minSecondsPerBlock` is clamped to 5 BEFORE averaging, not just at the end:
    /// paired with a delta above `maxSecondsPerBlock` (clamped to 150), the mean of the CLAMPED
    /// values is 77.5 -- the raw (unclamped) mean of 2 and 500 would be 251, so this fixture
    /// distinguishes "clamp every delta, then average" from "average, then clamp the result".
    func testSecondsPerBlockClampsEachDeltaBeforeAveraging() {
        let estimator = ChainTipEstimator(samples: [
            MigrationBlockRateSample(height: 1_000_000, unixTime: 0),
            // A 2 s delta: clamped up to 5.
            MigrationBlockRateSample(height: 1_000_001, unixTime: 2),
            // A 500 s delta: clamped down to 150.
            MigrationBlockRateSample(height: 1_000_002, unixTime: 502)
        ])
        XCTAssertEqual(estimator.secondsPerBlock(), 77.5, "(5 + 150) / 2, the clamped deltas' mean")
    }

    /// The final mean is itself clamped too: every delta identically 5 (already at the floor)
    /// leaves the mean at exactly the floor, never below it.
    func testSecondsPerBlockResultNeverGoesBelowTheFloor() {
        let estimator = ChainTipEstimator(samples: [
            MigrationBlockRateSample(height: 1_000_000, unixTime: 0),
            MigrationBlockRateSample(height: 1_000_001, unixTime: 5),
            MigrationBlockRateSample(height: 1_000_002, unixTime: 10)
        ])
        XCTAssertEqual(estimator.secondsPerBlock(), 5)
    }

    /// Symmetric case at the ceiling: every delta identically 150 leaves the mean at exactly the
    /// ceiling, never above it.
    func testSecondsPerBlockResultNeverGoesAboveTheCeiling() {
        let estimator = ChainTipEstimator(samples: [
            MigrationBlockRateSample(height: 1_000_000, unixTime: 0),
            MigrationBlockRateSample(height: 1_000_001, unixTime: 150),
            MigrationBlockRateSample(height: 1_000_002, unixTime: 300)
        ])
        XCTAssertEqual(estimator.secondsPerBlock(), 150)
    }

    // MARK: - estimatedTip(now:): nil with no samples

    func testEstimatedTipIsNilWithNoSamples() {
        let estimator = ChainTipEstimator(samples: [])
        XCTAssertNil(estimator.estimatedTip(now: referenceDate))
    }

    // MARK: - estimatedTip(now:): floor math

    /// `elapsed / secondsPerBlock()` is FLOORED, not rounded: 200 s elapsed at 75 s/block
    /// (fallback, one sample) is 2.66\u{2026} blocks -- floor gives 2, whereas rounding would give 3.
    func testEstimatedTipFloorsThePartialBlockRatherThanRounding() {
        let latest = MigrationBlockRateSample(height: 2_000_000, unixTime: Int64(referenceDate.timeIntervalSince1970))
        let estimator = ChainTipEstimator(samples: [latest])

        let tip = estimator.estimatedTip(now: referenceDate.addingTimeInterval(200))

        XCTAssertEqual(tip, 2_000_002, "floor(200 / 75) == 2, not round(200 / 75) == 3")
    }

    /// An elapsed duration that divides the block rate exactly still floors correctly (no
    /// off-by-one from floating-point wobble at an exact boundary).
    func testEstimatedTipAtAnExactBlockBoundary() {
        let latest = MigrationBlockRateSample(height: 2_000_000, unixTime: Int64(referenceDate.timeIntervalSince1970))
        let estimator = ChainTipEstimator(samples: [latest])

        let tip = estimator.estimatedTip(now: referenceDate.addingTimeInterval(150))

        XCTAssertEqual(tip, 2_000_002, "exactly 2 whole blocks at the 75 s fallback rate")
    }

    // MARK: - estimatedTip(now:): negative elapsed clamps to zero

    /// `now` at or before the latest sample's header time (clock skew, or a caller re-evaluating
    /// against a stale `now`) must never project BACKWARD past the latest known height.
    func testEstimatedTipClampsNegativeElapsedToTheLatestSampleHeight() {
        let latest = MigrationBlockRateSample(height: 2_000_000, unixTime: Int64(referenceDate.timeIntervalSince1970))
        let estimator = ChainTipEstimator(samples: [latest])

        let tipBeforeLatest = estimator.estimatedTip(now: referenceDate.addingTimeInterval(-1_000))
        let tipExactlyAtLatest = estimator.estimatedTip(now: referenceDate)

        XCTAssertEqual(tipBeforeLatest, 2_000_000, "a header time in the future of `now` must add zero blocks, never go negative")
        XCTAssertEqual(tipExactlyAtLatest, 2_000_000)
    }

    /// The latest (last) sample's height is always the projection's floor, regardless of how many
    /// earlier samples exist.
    func testEstimatedTipProjectsFromTheLatestSampleNotTheFirst() {
        let estimator = ChainTipEstimator(samples: [
            MigrationBlockRateSample(height: 1_000_000, unixTime: 0),
            MigrationBlockRateSample(height: 1_000_010, unixTime: 600)
        ])

        let tip = estimator.estimatedTip(now: Date(timeIntervalSince1970: 600))

        XCTAssertEqual(tip, 1_000_010, "with zero elapsed time past the latest sample, the tip is exactly its height")
    }
}
