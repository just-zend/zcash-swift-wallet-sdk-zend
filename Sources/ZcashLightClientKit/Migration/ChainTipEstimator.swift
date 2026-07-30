//
//  ChainTipEstimator.swift
//  ZcashLightClientKit
//

import Foundation

/// A pure, measured-block-rate chain-tip estimator: projects a wall-clock ESTIMATED chain tip
/// from the most recently scanned blocks' `(height, header time)` samples
/// (`ZcashRustBackendWelding.migrationBlockRateSamples(window:)`).
///
/// The projection feeds the migration delivery lane's `estimatedTip` inputs
/// (`migrationHasOverdueTransfers(for:estimatedTip:)` / `migrationNextDueTransfer(for:estimatedTip:)`),
/// where it may only ACCELERATE scheduled-height due-ness — the rust side takes
/// `max(scanned, estimated)` and always evaluates expiry against the SCANNED tip — so an
/// over-estimate here costs nothing worse than an early "due" answer, and an under-estimate
/// degrades to the scanned-tip behavior.
///
/// The constants mirror the Android SDK's estimator exactly: a window of up to the last
/// ``sampleWindow`` samples, every per-delta and the final mean clamped to
/// [``minSecondsPerBlock``, ``maxSecondsPerBlock``] seconds, and ``fallbackSecondsPerBlock``
/// when fewer than two samples exist. Deltas are the raw header-time differences of consecutive
/// samples — the samples are the most recently scanned blocks, so consecutive rows are adjacent
/// heights and a delta IS one block's spacing; the clamp bounds the damage of any gapped or
/// out-of-order header times.
struct ChainTipEstimator {
    /// How many of the latest samples participate, at most (Android parity: 100).
    static let sampleWindow = 100
    /// The lower clamp on any per-delta and on the final mean, in seconds (Android parity: 5).
    static let minSecondsPerBlock: Double = 5
    /// The upper clamp on any per-delta and on the final mean, in seconds (Android parity: 150).
    static let maxSecondsPerBlock: Double = 150
    /// The seconds-per-block assumed when fewer than two samples exist (Android parity: 75 — the
    /// Zcash target block spacing).
    static let fallbackSecondsPerBlock: Double = 75

    /// The `(height, header time)` samples, ascending by height (the order the welding returns).
    private let samples: [MigrationBlockRateSample]

    /// Creates an estimator over `samples` (ascending by height; may be empty).
    init(samples: [MigrationBlockRateSample]) {
        self.samples = samples
    }

    /// The measured seconds-per-block: the mean of the consecutive header-time deltas over up to
    /// the last ``sampleWindow`` samples, each delta and the result clamped to
    /// [``minSecondsPerBlock``, ``maxSecondsPerBlock``]; ``fallbackSecondsPerBlock`` when fewer
    /// than two samples exist.
    func secondsPerBlock() -> Double {
        let window = samples.suffix(Self.sampleWindow)
        guard window.count >= 2 else {
            return Self.fallbackSecondsPerBlock
        }

        var deltaSum: Double = 0
        var deltaCount = 0
        for (previous, next) in zip(window, window.dropFirst()) {
            let delta = Double(next.unixTime - previous.unixTime)
            deltaSum += min(max(delta, Self.minSecondsPerBlock), Self.maxSecondsPerBlock)
            deltaCount += 1
        }

        let mean = deltaSum / Double(deltaCount)
        return min(max(mean, Self.minSecondsPerBlock), Self.maxSecondsPerBlock)
    }

    /// The estimated chain tip at `now`: the latest sample's height plus the whole blocks that
    /// fit into the wall-clock time elapsed since its header time at ``secondsPerBlock()``,
    /// never below the latest sample's height (a header time in the future adds zero). `nil`
    /// when there are no samples at all — the wallet has never scanned, so there is nothing to
    /// project from.
    func estimatedTip(now: Date) -> BlockHeight? {
        guard let latest = samples.last else {
            return nil
        }

        let elapsed = now.timeIntervalSince1970 - Double(latest.unixTime)
        let advancedBlocks = max(0, Int(floor(elapsed / secondsPerBlock())))
        return latest.height + advancedBlocks
    }
}
