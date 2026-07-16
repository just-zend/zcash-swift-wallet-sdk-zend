//
//  UpdateChainTipActionTests.swift
//
//
//  Created by Lukáš Korba on 25.08.2023.
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class UpdateChainTipActionTests: ZcashTestCase {
    var underlyingChainName = ""
    var underlyingNetworkType = NetworkType.testnet
    var underlyingSaplingActivationHeight: BlockHeight?
    var underlyingConsensusBranchID = ""

    override func setUp() {
        super.setUp()

        underlyingChainName = "test"
        underlyingNetworkType = .testnet
        underlyingSaplingActivationHeight = nil
        underlyingConsensusBranchID = "c2d6d0b4"
    }

    func testUpdateChainTipAction_UpdateChainTipTimeTriggered() async throws {
        let loggerMock = LoggerMock()
        let blockDownloaderMock = BlockDownloaderMock()
        let latestBlocksDataProvider = LatestBlocksDataProviderMock()

        loggerMock.debugFileFunctionLineClosure = { _, _, _, _ in }
        blockDownloaderMock.stopDownloadClosure = { }
        latestBlocksDataProvider.updateClosure = { _ in }

        let updateChainTipAction = await setupAction(loggerMock, blockDownloaderMock, latestBlocksDataProvider)

        do {
            let context = ActionContextMock.default()
            context.prevState = .idle
            context.underlyingLastChainTipUpdateTime = 0.0
            context.updateLastChainTipUpdateTimeClosure = { _ in }

            let nextContext = try await updateChainTipAction.run(with: context) { _ in }

            XCTAssertTrue(blockDownloaderMock.stopDownloadCallsCount == 1, "downloader.stopDownload() is expected to be called exactly once.")

            let acResult = nextContext.checkStateIs(.clearCache)
            XCTAssertTrue(acResult == .true, "Check of state failed with '\(acResult)'")
        } catch {
            XCTFail("testUpdateChainTipAction_UpdateChainTipTimeTriggered is not expected to fail. \(error)")
        }
    }

    func testUpdateChainTipAction_UpdateChainTipPrevActionTriggered() async throws {
        let loggerMock = LoggerMock()
        let blockDownloaderMock = BlockDownloaderMock()
        let latestBlocksDataProvider = LatestBlocksDataProviderMock()

        loggerMock.debugFileFunctionLineClosure = { _, _, _, _ in }
        blockDownloaderMock.stopDownloadClosure = { }
        latestBlocksDataProvider.updateClosure = { _ in }

        let updateChainTipAction = await setupAction(loggerMock, blockDownloaderMock, latestBlocksDataProvider)

        do {
            let context = ActionContextMock.default()
            context.prevState = .updateSubtreeRoots
            context.underlyingLastChainTipUpdateTime = Date().timeIntervalSince1970
            context.updateLastChainTipUpdateTimeClosure = { _ in }

            let nextContext = try await updateChainTipAction.run(with: context) { _ in }

            XCTAssertTrue(blockDownloaderMock.stopDownloadCallsCount == 1, "downloader.stopDownload() is expected to be called exactly once.")

            let acResult = nextContext.checkStateIs(.clearCache)
            XCTAssertTrue(acResult == .true, "Check of state failed with '\(acResult)'")
        } catch {
            XCTFail("testUpdateChainTipAction_UpdateChainTipPrevActionTriggered is not expected to fail. \(error)")
        }
    }

    func testUpdateChainTipAction_UpdateChainTipSkipped() async throws {
        let loggerMock = LoggerMock()
        let blockDownloaderMock = BlockDownloaderMock()

        loggerMock.infoFileFunctionLineClosure = { _, _, _, _ in }
        blockDownloaderMock.stopDownloadClosure = { }

        let updateChainTipAction = await setupAction(loggerMock, blockDownloaderMock)

        do {
            let context = ActionContextMock.default()
            context.prevState = .txResubmission
            context.underlyingLastChainTipUpdateTime = Date().timeIntervalSince1970
            context.updateLastChainTipUpdateTimeClosure = { _ in }

            let nextContext = try await updateChainTipAction.run(with: context) { _ in }

            XCTAssertFalse(blockDownloaderMock.stopDownloadCalled, "downloader.stopDownload() is not expected to be called.")

            let acResult = nextContext.checkStateIs(.download)
            XCTAssertTrue(acResult == .true, "Check of state failed with '\(acResult)'")
        } catch {
            XCTFail("testUpdateChainTipAction_UpdateChainTipSkipped is not expected to fail. \(error)")
        }
    }

    func testUpdateChainTipSamplesLoadBalancerAndCommitsOnlyHighestTipAtOrAboveLocalFloor() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.maxScannedHeightReturnValue = 105
        rustBackend.updateChainTipHeightClosure = { _ in }
        let service = LightWalletServiceMock()
        var sampledHeights = [104, 110, 106]
        service.latestBlockHeightModeClosure = { _ in sampledHeights.removeFirst() }
        let provider = LatestBlocksDataProviderMock()
        provider.underlyingLatestBlockHeight = 107
        provider.updateClosure = { _ in }
        let logger = LoggerMock()
        logger.debugFileFunctionLineClosure = { _, _, _, _ in }
        let context = ActionContextMock.default()
        context.updateLastChainTipUpdateTimeClosure = { _ in }
        let action = await setupAction(
            logger,
            BlockDownloaderMock(),
            provider,
            rustBackend,
            service
        )

        try await action.updateChainTip(context, time: 123)

        XCTAssertEqual(service.latestBlockHeightModeCallsCount, 3)
        XCTAssertEqual(rustBackend.updateChainTipHeightReceivedHeight, 110)
        XCTAssertEqual(provider.updateReceivedLatestBlockHeight, 110)
        XCTAssertEqual(context.updateLastChainTipUpdateTimeReceivedLastChainTipUpdateTime, 123)
    }

    func testUpdateChainTipRejectsAllStaleReplicasWithoutAnyLowerTipMutation() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.maxScannedHeightReturnValue = 105
        rustBackend.updateChainTipHeightClosure = { _ in }
        let service = LightWalletServiceMock()
        var sampledHeights = [102, 104, 103]
        service.latestBlockHeightModeClosure = { _ in sampledHeights.removeFirst() }
        let provider = LatestBlocksDataProviderMock()
        provider.underlyingLatestBlockHeight = 101
        provider.updateClosure = { _ in }
        let logger = LoggerMock()
        logger.debugFileFunctionLineClosure = { _, _, _, _ in }
        let context = ActionContextMock.default()
        context.updateLastChainTipUpdateTimeClosure = { _ in }
        let action = await setupAction(
            logger,
            BlockDownloaderMock(),
            provider,
            rustBackend,
            service
        )

        do {
            try await action.updateChainTip(context, time: 123)
            XCTFail("Expected every sampled replica below durable state to fail closed")
        } catch let ZcashError.compactBlockProcessorServerTipBehind(floor, observed, attempts) {
            XCTAssertEqual(floor, 105)
            XCTAssertEqual(observed, 104)
            XCTAssertEqual(attempts, 3)
        }

        XCTAssertEqual(service.latestBlockHeightModeCallsCount, 3)
        XCTAssertFalse(rustBackend.updateChainTipHeightCalled)
        XCTAssertFalse(provider.updateCalled)
        XCTAssertFalse(context.updateLastChainTipUpdateTimeCalled)
    }

    private func setupAction(
        _ loggerMock: LoggerMock = LoggerMock(),
        _ blockDownloaderMock: BlockDownloaderMock = BlockDownloaderMock(),
        _ latestBlocksDataProvider: LatestBlocksDataProvider = LatestBlocksDataProviderMock(),
        _ rustBackendMock: ZcashRustBackendWeldingMock = ZcashRustBackendWeldingMock(),
        _ serviceMock: LightWalletServiceMock = LightWalletServiceMock()
    ) async -> UpdateChainTipAction {
        let config: CompactBlockProcessor.Configuration = .standard(
            for: ZcashNetworkBuilder.network(for: underlyingNetworkType), walletBirthday: 0
        )

        rustBackendMock.consensusBranchIdForHeightClosure = { height in
            XCTAssertEqual(height, 2, "")
            return -1026109260
        }

        rustBackendMock.updateChainTipHeightClosure = { _ in }

        let lightWalletdInfoMock = LightWalletdInfoMock()
        lightWalletdInfoMock.underlyingConsensusBranchID = underlyingConsensusBranchID
        lightWalletdInfoMock.underlyingSaplingActivationHeight = UInt64(underlyingSaplingActivationHeight ?? config.saplingActivation)
        lightWalletdInfoMock.underlyingBlockHeight = 2
        lightWalletdInfoMock.underlyingChainName = underlyingChainName

        serviceMock.getInfoModeReturnValue = lightWalletdInfoMock
        if serviceMock.latestBlockHeightModeClosure == nil {
            serviceMock.latestBlockHeightModeReturnValue = 1
        }

        if let provider = latestBlocksDataProvider as? LatestBlocksDataProviderMock {
            provider.underlyingLatestBlockHeight = provider.underlyingLatestBlockHeight ?? .zero
            provider.underlyingMaxScannedHeight = provider.underlyingMaxScannedHeight ?? .zero
            provider.underlyingFullyScannedHeight = provider.underlyingFullyScannedHeight ?? .zero
            provider.underlyingWalletBirthday = provider.underlyingWalletBirthday ?? .zero
        }

        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackendMock }
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in serviceMock }
        mockContainer.mock(type: Logger.self, isSingleton: true) { _ in loggerMock }
        mockContainer.mock(type: BlockDownloader.self, isSingleton: true) { _ in blockDownloaderMock }
        mockContainer.mock(type: LatestBlocksDataProvider.self, isSingleton: true) { _ in latestBlocksDataProvider }
        mockContainer.mock(type: SDKFlags.self, isSingleton: true) { _ in SDKFlags(torEnabled: false, exchangeRateEnabled: false) }

        return UpdateChainTipAction(container: mockContainer)
    }
}
