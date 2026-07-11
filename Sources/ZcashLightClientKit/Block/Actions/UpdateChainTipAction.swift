//
//  UpdateChainTipAction.swift
//
//
//  Created by Lukáš Korba on 01.08.2023.
//

import Foundation

final class UpdateChainTipAction {
    private static let chainTipSampleCount = 3

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

    func updateChainTip(_ context: ActionContext, time: TimeInterval) async throws {
        // called each sync, right after getInfo in ValidateServerAction
        let mode = await sdkFlags.ifTor(.defaultTor)
        let latestBlockHeight = try await sampledLatestBlockHeight(mode: mode)
        let localFloor = try await durableLocalFloor()
        guard latestBlockHeight >= localFloor else {
            throw ZcashError.compactBlockProcessorServerTipBehind(
                localFloor,
                latestBlockHeight,
                Self.chainTipSampleCount
            )
        }

        logger.debug("Latest block height is \(latestBlockHeight), local floor is \(localFloor)")
        try await rustBackend.updateChainTip(height: Int32(latestBlockHeight))
        await context.update(lastChainTipUpdateTime: time)
        await latestBlocksDataProvider.update(latestBlockHeight)
    }

    private func sampledLatestBlockHeight(mode: ServiceMode) async throws -> BlockHeight {
        var highestObserved: BlockHeight?
        var lastError: Error?

        for _ in 0 ..< Self.chainTipSampleCount {
            do {
                let height = try await service.latestBlockHeight(mode: mode)
                highestObserved = max(highestObserved ?? height, height)
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }

        if let highestObserved {
            return highestObserved
        }
        if let lastError {
            throw lastError
        }
        throw ZcashError.serviceLatestBlockHeightFailed(.unknown)
    }

    private func durableLocalFloor() async throws -> BlockHeight {
        let providerHeight = await latestBlocksDataProvider.latestBlockHeight
        let summaryHeight = try await rustBackend.getWalletSummary()?.chainTipHeight ?? .zero
        let maxScannedHeight = try await rustBackend.maxScannedHeight() ?? .zero
        return max(providerHeight, max(summaryHeight, maxScannedHeight))
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
