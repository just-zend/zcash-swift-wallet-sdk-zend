//
//  ValidateServerAction.swift
//
//
//  Created by Michal Fousek on 05.05.2023.
//

import Foundation

final class ValidateServerAction {
    let configProvider: CompactBlockProcessor.ConfigProvider
    let rustBackend: ZcashRustBackendWelding
    var service: LightWalletService
    let sdkFlags: SDKFlags

    init(container: DIContainer, configProvider: CompactBlockProcessor.ConfigProvider) {
        self.configProvider = configProvider
        rustBackend = container.resolve(ZcashRustBackendWelding.self)
        service = container.resolve(LightWalletService.self)
        sdkFlags = container.resolve(SDKFlags.self)
    }
}

extension ValidateServerAction: Action {
    var removeBlocksCacheWhenFailed: Bool { false }

    func run(with context: ActionContext, didUpdate: @escaping (CompactBlockProcessor.Event) async -> Void) async throws -> ActionContext {
        let config = await configProvider.config
        // called each sync, an action in a state machine diagram
        let info = try await service.getInfo(mode: await sdkFlags.ifTor(.defaultTor))
        let localNetwork = config.network
        let saplingActivation = config.saplingActivation

        guard let remoteChainName = ConsensusChainName.canonicalize(info.chainName) else {
            throw ZcashError.compactBlockProcessorChainName(info.chainName)
        }
        guard remoteChainName == localNetwork.chainName else {
            if localNetwork.customActivationHeights == nil,
               let remoteNetworkType = NetworkType.forChainName(remoteChainName) {
                throw ZcashError.compactBlockProcessorNetworkMismatch(localNetwork.networkType, remoteNetworkType)
            }
            throw ZcashError.compactBlockProcessorChainName(info.chainName)
        }

        guard saplingActivation == info.saplingActivationHeight else {
            throw ZcashError.compactBlockProcessorSaplingActivationMismatch(saplingActivation, BlockHeight(info.saplingActivationHeight))
        }

        guard info.blockHeight < UInt64(Int32.max),
              let nextBlockHeight = Int32(exactly: info.blockHeight + 1) else {
            throw ZcashError.compactBlockProcessorConsensusBranchID
        }
        let localBranch = try rustBackend.consensusBranchIdFor(height: nextBlockHeight)
        guard let remoteBranchID = ConsensusBranchID.fromString(info.consensusBranchID) else {
            throw ZcashError.compactBlockProcessorConsensusBranchID
        }
        guard remoteBranchID == localBranch else {
            throw ZcashError.compactBlockProcessorWrongConsensusBranchId(localBranch, remoteBranchID)
        }

        await context.update(state: .fetchUTXO)
        return context
    }

    func stop() async { }
}
