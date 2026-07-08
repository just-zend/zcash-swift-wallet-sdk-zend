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
        latestBlocksDataProvider.underlyingLatestBlockHeight = .zero

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
        latestBlocksDataProvider.underlyingLatestBlockHeight = .zero

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

    /// IRONWOOD_FIELD_LEARNINGS §3: a stale load-balanced replica answering below the wallet's
    /// known tip must NOT reach `rustBackend.updateChainTip` — repeated regressions grind the
    /// wallet DB into its safe-rewind floor and wedge it permanently.
    func testUpdateChainTipAction_TipRegressionKeepsKnownTip() async throws {
        let loggerMock = LoggerMock()
        let blockDownloaderMock = BlockDownloaderMock()
        let latestBlocksDataProvider = LatestBlocksDataProviderMock()

        loggerMock.debugFileFunctionLineClosure = { _, _, _, _ in }
        loggerMock.warnFileFunctionLineClosure = { _, _, _, _ in }
        loggerMock.errorFileFunctionLineClosure = { _, _, _, _ in }
        blockDownloaderMock.stopDownloadClosure = { }
        latestBlocksDataProvider.updateClosure = { _ in
            XCTFail("latestBlocksDataProvider.update is not expected to be called for a regressed tip.")
        }
        latestBlocksDataProvider.underlyingLatestBlockHeight = 1000

        let updateChainTipAction = await setupAction(loggerMock, blockDownloaderMock, latestBlocksDataProvider)
        // Every replica in the pool answers stale.
        (updateChainTipAction.service as? LightWalletServiceMock)?.latestBlockHeightModeReturnValue = 900
        (updateChainTipAction.rustBackend as? ZcashRustBackendWeldingMock)?.updateChainTipHeightClosure = { _ in
            XCTFail("rustBackend.updateChainTip is not expected to be called for a regressed tip.")
        }

        do {
            let context = ActionContextMock.default()
            context.prevState = .updateSubtreeRoots
            context.underlyingLastChainTipUpdateTime = 0.0
            context.updateLastChainTipUpdateTimeClosure = { _ in }

            let nextContext = try await updateChainTipAction.run(with: context) { _ in }

            XCTAssertTrue(loggerMock.errorFileFunctionLineCalled, "the kept-known-tip decision is expected to be logged as an error.")
            // The flow itself continues on the previous tip — no failure state.
            let acResult = nextContext.checkStateIs(.clearCache)
            XCTAssertTrue(acResult == .true, "Check of state failed with '\(acResult)'")
        } catch {
            XCTFail("testUpdateChainTipAction_TipRegressionKeepsKnownTip is not expected to fail. \(error)")
        }
    }

    /// A stale first answer followed by a fresh replica on retry proceeds with the fresh tip.
    func testUpdateChainTipAction_TipRegressionRecoversOnRetry() async throws {
        let loggerMock = LoggerMock()
        let blockDownloaderMock = BlockDownloaderMock()
        let latestBlocksDataProvider = LatestBlocksDataProviderMock()

        var updatedTip: BlockHeight?
        loggerMock.debugFileFunctionLineClosure = { _, _, _, _ in }
        loggerMock.warnFileFunctionLineClosure = { _, _, _, _ in }
        blockDownloaderMock.stopDownloadClosure = { }
        latestBlocksDataProvider.updateClosure = { updatedTip = $0 }
        latestBlocksDataProvider.underlyingLatestBlockHeight = 1000

        let updateChainTipAction = await setupAction(loggerMock, blockDownloaderMock, latestBlocksDataProvider)
        var tipAnswers: [BlockHeight] = [900, 1005]
        (updateChainTipAction.service as? LightWalletServiceMock)?.latestBlockHeightModeClosure = { _ in
            tipAnswers.isEmpty ? 1005 : tipAnswers.removeFirst()
        }
        var rustTip: Int32?
        (updateChainTipAction.rustBackend as? ZcashRustBackendWeldingMock)?.updateChainTipHeightClosure = { rustTip = $0 }

        do {
            let context = ActionContextMock.default()
            context.prevState = .updateSubtreeRoots
            context.underlyingLastChainTipUpdateTime = 0.0
            context.updateLastChainTipUpdateTimeClosure = { _ in }

            _ = try await updateChainTipAction.run(with: context) { _ in }

            XCTAssertTrue(loggerMock.warnFileFunctionLineCalled, "the stale first answer is expected to be logged as a warning.")
            XCTAssertEqual(rustTip, 1005, "rustBackend.updateChainTip is expected to receive the fresh retry tip.")
            XCTAssertEqual(updatedTip, 1005, "latestBlocksDataProvider is expected to be updated with the fresh retry tip.")
        } catch {
            XCTFail("testUpdateChainTipAction_TipRegressionRecoversOnRetry is not expected to fail. \(error)")
        }
    }

    private func setupAction(
        _ loggerMock: LoggerMock = LoggerMock(),
        _ blockDownloaderMock: BlockDownloaderMock = BlockDownloaderMock(),
        _ latestBlocksDataProvider: LatestBlocksDataProvider = LatestBlocksDataProviderMock()
    ) async -> UpdateChainTipAction {
        let config: CompactBlockProcessor.Configuration = .standard(
            for: ZcashNetworkBuilder.network(for: underlyingNetworkType), walletBirthday: 0
        )

        let rustBackendMock = ZcashRustBackendWeldingMock()

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

        let serviceMock = LightWalletServiceMock()
        serviceMock.getInfoModeReturnValue = lightWalletdInfoMock
        serviceMock.latestBlockHeightModeReturnValue = 1

        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackendMock }
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in serviceMock }
        mockContainer.mock(type: Logger.self, isSingleton: true) { _ in loggerMock }
        mockContainer.mock(type: BlockDownloader.self, isSingleton: true) { _ in blockDownloaderMock }
        mockContainer.mock(type: LatestBlocksDataProvider.self, isSingleton: true) { _ in latestBlocksDataProvider }
        mockContainer.mock(type: SDKFlags.self, isSingleton: true) { _ in SDKFlags(torEnabled: false, exchangeRateEnabled: false) }

        return UpdateChainTipAction(container: mockContainer)
    }
}
