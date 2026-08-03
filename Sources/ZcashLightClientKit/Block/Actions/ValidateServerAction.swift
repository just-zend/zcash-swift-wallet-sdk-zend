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
    /// The consensus branch ID of NU6.3 ("Ironwood"). When the chain is on this branch, the
    /// connected server must serve Ironwood data — see the tree-state check in `run` below.
    static let nu63ConsensusBranchID: ConsensusBranchID = 0x37a5_165b

    var removeBlocksCacheWhenFailed: Bool { false }

    func run(with context: ActionContext, didUpdate: @escaping (CompactBlockProcessor.Event) async -> Void) async throws -> ActionContext {
        let config = await configProvider.config
        // called each sync, an action in a state machine diagram
        let info = try await service.getInfo(mode: await sdkFlags.ifTor(.defaultTor))
        let localNetwork = config.network
        let saplingActivation = config.saplingActivation

        // check network types
        guard let remoteNetworkType = NetworkType.forChainName(info.chainName) else {
            throw ZcashError.compactBlockProcessorChainName(info.chainName)
        }

        guard remoteNetworkType == localNetwork.networkType else {
            throw ZcashError.compactBlockProcessorNetworkMismatch(localNetwork.networkType, remoteNetworkType)
        }

        guard saplingActivation == info.saplingActivationHeight else {
            throw ZcashError.compactBlockProcessorSaplingActivationMismatch(saplingActivation, BlockHeight(info.saplingActivationHeight))
        }

        // check branch id
        let localBranch = try rustBackend.consensusBranchIdFor(height: Int32(info.blockHeight))

        guard let remoteBranchID = ConsensusBranchID.fromString(info.consensusBranchID) else {
            throw ZcashError.compactBlockProcessorConsensusBranchID
        }

        guard remoteBranchID == localBranch else {
            throw ZcashError.compactBlockProcessorWrongConsensusBranchId(localBranch, remoteBranchID)
        }

        // Past the Ironwood (NU6.3) activation, compact-block scanning is what detects the
        // wallet's shielded transactions; status requests by transaction id are scoped to
        // fully-transparent transactions, which scanning cannot detect, so they are no help
        // here. A server that omits Ironwood data would let scanning pass silently (absent
        // Ironwood chain metadata reads as zero, satisfying the tree-size consistency check) while
        // never detecting anything in that pool, so its absence must fail loudly. The tree state at
        // the server's tip is the discriminating block-level signal: an Ironwood-capable server
        // always serves a non-empty `ironwoodTree` frontier once the pool exists.
        if remoteBranchID == Self.nu63ConsensusBranchID {
            var tipBlock = BlockID()
            tipBlock.height = info.blockHeight
            let treeState = try await service.getTreeState(tipBlock, mode: await sdkFlags.ifTor(.defaultTor))
            guard !treeState.ironwoodTree.isEmpty else {
                throw ZcashError.compactBlockProcessorServerMissingIronwoodSupport
            }
        }

        await context.update(state: .fetchUTXO)
        return context
    }

    func stop() async { }
}
