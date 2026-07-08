//
//  UpdateChainTipAction.swift
//
//
//  Created by Lukáš Korba on 01.08.2023.
//

import Foundation

final class UpdateChainTipAction {
    let rustBackend: ZcashRustBackendWelding
    var downloader: BlockDownloader
    var service: LightWalletService
    var latestBlocksDataProvider: LatestBlocksDataProvider
    let logger: Logger
    let sdkFlags: SDKFlags

    init(container: DIContainer) {
        service = container.resolve(LightWalletService.self)
        downloader = container.resolve(BlockDownloader.self)
        rustBackend = container.resolve(ZcashRustBackendWelding.self)
        latestBlocksDataProvider = container.resolve(LatestBlocksDataProvider.self)
        logger = container.resolve(Logger.self)
        sdkFlags = container.resolve(SDKFlags.self)
    }

    /// How many times a tip below the wallet's known tip is re-fetched (hoping the pool routes
    /// the retry to a fresh replica) before this cycle gives up and keeps the known tip.
    private static let staleTipRetries = 2

    func updateChainTip(_ context: ActionContext, time: TimeInterval) async throws {
        // called each sync, right after getInfo in ValidateServerAction
        var latestBlockHeight = try await service.latestBlockHeight(mode: await sdkFlags.ifTor(.defaultTor))

        // Tip-regression guard: load-balanced lightwalletd pools route per REQUEST, and replicas
        // have been observed 300–700 blocks apart — including serving different chains during a
        // deep testnet reorg (zend-ios docs/IRONWOOD_FIELD_LEARNINGS.md §3). Feeding a stale
        // replica's tip into `rustBackend.updateChainTip` walks the wallet's chain tip BACKWARDS
        // a few blocks per sync until cumulative rewinds exceed the safe-rewind horizon and the
        // wallet DB wedges permanently (`RequestedRewindInvalid`). A lower tip is never
        // actionable here: a healthy chain tip does not regress, and genuine reorg rewinds are
        // the scan continuity-error path's job. So retry for a fresher replica, and if the pool
        // still answers stale, keep the tip we already have — sync continues against the
        // previous tip and self-corrects on a later cycle.
        let knownTip = await latestBlocksDataProvider.latestBlockHeight
        var retriesLeft = Self.staleTipRetries
        while latestBlockHeight < knownTip && retriesLeft > 0 {
            logger.warn("Service tip \(latestBlockHeight) is below the known tip \(knownTip) (stale replica); retrying")
            latestBlockHeight = try await service.latestBlockHeight(mode: await sdkFlags.ifTor(.defaultTor))
            retriesLeft -= 1
        }
        guard latestBlockHeight >= knownTip else {
            logger.error(
                "Service tip \(latestBlockHeight) still below the known tip \(knownTip) after retries — keeping the known tip; the server pool looks unhealthy"
            )
            await context.update(lastChainTipUpdateTime: time)
            return
        }

        logger.debug("Latest block height is \(latestBlockHeight)")
        try await rustBackend.updateChainTip(height: Int32(latestBlockHeight))
        await context.update(lastChainTipUpdateTime: time)
        await latestBlocksDataProvider.update(latestBlockHeight)
    }
}

extension UpdateChainTipAction: Action {
    var removeBlocksCacheWhenFailed: Bool { false }

    func run(with context: ActionContext, didUpdate: @escaping (CompactBlockProcessor.Event) async -> Void) async throws -> ActionContext {
        let lastChainTipUpdateTime = await context.lastChainTipUpdateTime
        let now = Date().timeIntervalSince1970

        // Update chain tip can be called from different contexts
        if await context.prevState == .updateSubtreeRoots || now - lastChainTipUpdateTime > 600 {
            await downloader.stopDownload()
            try await updateChainTip(context, time: now)
            await sdkFlags.markChainTipAsUpdated()
            await context.update(state: .clearCache)
        } else if await context.prevState == .txResubmission {
            await context.update(state: .download)
        }

        return context
    }

    func stop() async { }
}
