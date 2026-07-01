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

        // A custom-parameter network (customActivationHeights != nil, e.g. a regtest wallet pointed at a
        // modified-mainnet Ironwood backend) may reach a server that identifies with a different base
        // chain (chainName "main") and reports a nonstandard consensus branch id. For such networks the
        // strict network-type and branch-id matches are skipped; the Sapling-activation check below still
        // guards against pointing a custom-heights wallet at a real main/test server.
        let isCustomNetwork = localNetwork.customActivationHeights != nil

        // check network types
        guard let remoteNetworkType = NetworkType.forChainName(info.chainName) else {
            throw ZcashError.compactBlockProcessorChainName(info.chainName)
        }

        if !isCustomNetwork {
            guard remoteNetworkType == localNetwork.networkType else {
                throw ZcashError.compactBlockProcessorNetworkMismatch(localNetwork.networkType, remoteNetworkType)
            }
        }

        guard saplingActivation == info.saplingActivationHeight else {
            throw ZcashError.compactBlockProcessorSaplingActivationMismatch(saplingActivation, BlockHeight(info.saplingActivationHeight))
        }

        // check branch id
        if !isCustomNetwork {
            let localBranch = try rustBackend.consensusBranchIdFor(height: Int32(info.blockHeight))

            guard let remoteBranchID = ConsensusBranchID.fromString(info.consensusBranchID) else {
                throw ZcashError.compactBlockProcessorConsensusBranchID
            }

            guard remoteBranchID == localBranch else {
                throw ZcashError.compactBlockProcessorWrongConsensusBranchId(localBranch, remoteBranchID)
            }
        }

        await context.update(state: .fetchUTXO)
        return context
    }

    func stop() async { }
}
