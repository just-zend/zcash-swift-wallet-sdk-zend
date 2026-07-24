//
//  MigrationTransactionSubmitter.swift
//  ZcashLightClientKit
//

import Foundation

enum MigrationBroadcastError: Error, Equatable {
    case invalidSubmissionEndpoint
    case selectedEndpointChainMismatch
    case selectedEndpointConsensusBranchMismatch
    case transactionConsensusBranchMismatch
    case selectedEndpointInfoBehindSampledTip(infoTip: BlockHeight, sampledTip: BlockHeight)
    case selectedTransportTipWithinExpirySafetyMargin(
        tip: BlockHeight,
        expiry: BlockHeight,
        minimumRemainingBlocks: BlockHeight
    )
}

struct MigrationTransport {
    let service: LightWalletService
    let mode: ServiceMode
}

/// Creates exactly the transport sealed into a Rust-owned migration run. Tor is deliberately
/// independent of the SDK-wide Tor flag and never falls back to a clear channel.
protocol MigrationTransportCreating {
    func makeTransport(endpoint: LightWalletEndpoint, useTor: Bool) async throws -> MigrationTransport
}

final class LiveMigrationTransportFactory: MigrationTransportCreating {
    private let torClient: TorClient

    init(torClient: TorClient) {
        self.torClient = torClient
    }

    func makeTransport(endpoint: LightWalletEndpoint, useTor: Bool) async throws -> MigrationTransport {
        if useTor {
            let isolatedTorClient = try await torClient.isolatedClient()
            return MigrationTransport(
                service: LightWalletGRPCServiceOverTor(endpoint: endpoint, tor: isolatedTorClient),
                mode: .defaultTor
            )
        }

        return MigrationTransport(
            service: LightWalletGRPCService(endpoint: endpoint),
            mode: .direct
        )
    }
}

/// Network-only submission of exact bytes held by a Rust claim. Policy validation, endpoint
/// normalization, revision binding, and claim authority stay in Rust; Swift receives only the
/// normalized target required to construct the transport.
protocol MigrationTransactionSubmitting {
    // swiftlint:disable:next function_parameter_count
    func submit(
        transaction: EncodedTransaction,
        expiryHeight: BlockHeight,
        target: MigrationBoundSubmissionTarget,
        expectedChainName: String,
        transactionConsensusBranchId: UInt32,
        branchIdForHeight: @escaping (Int32) throws -> Int32,
        renewLease: @escaping () async throws -> Void
    ) async throws -> MigrationSubmissionOutcome
}

/// Fail-closed fallback used only by injected test compositions whose legacy broadcaster cannot
/// create a claim-bound transport. Production always installs ``LiveMigrationTransactionSubmitter``.
final class UnavailableMigrationTransactionSubmitter: MigrationTransactionSubmitting {
    // swiftlint:disable:next function_parameter_count
    func submit(
        transaction: EncodedTransaction,
        expiryHeight: BlockHeight,
        target: MigrationBoundSubmissionTarget,
        expectedChainName: String,
        transactionConsensusBranchId: UInt32,
        branchIdForHeight: @escaping (Int32) throws -> Int32,
        renewLease: @escaping () async throws -> Void
    ) async throws -> MigrationSubmissionOutcome {
        throw MigrationDeliveryError.submissionTransportUnavailable
    }
}

final class LiveMigrationTransactionSubmitter: MigrationTransactionSubmitting {
    private static let preflightTipSampleCount = 3
    /// zcashd accepts when `nextBlockHeight + 3 <= expiry`; with tip H this requires
    /// `expiry - H >= 4`.
    private static let expirySafetyMargin: BlockHeight = 4

    private let transportFactory: MigrationTransportCreating
    private let logger: Logger

    init(transportFactory: MigrationTransportCreating, logger: Logger) {
        self.transportFactory = transportFactory
        self.logger = logger
    }

    convenience init(torClient: TorClient, logger: Logger) {
        self.init(
            transportFactory: LiveMigrationTransportFactory(torClient: torClient),
            logger: logger
        )
    }

    /// Converts app input into raw intent only. Rust remains responsible for validating and
    /// binding this endpoint to the wallet's network and consensus fingerprint.
    static func submissionIntent(
        options: MigrationNetworkPrivacyOptions,
        networkType: NetworkType
    ) -> MigrationSubmissionIntent {
        let transport: MigrationSubmissionTransport
        if options.useTor {
            transport = .torOnion
        } else if !options.submissionEndpoint.secure && networkType == .regtest {
            transport = .loopbackDevelopment
        } else {
            transport = .directTLS
        }
        return MigrationSubmissionIntent(
            transport: transport,
            endpoint: endpointIdentity(options.submissionEndpoint)
        )
    }

    // swiftlint:disable:next function_parameter_count
    func submit(
        transaction: EncodedTransaction,
        expiryHeight: BlockHeight,
        target: MigrationBoundSubmissionTarget,
        expectedChainName: String,
        transactionConsensusBranchId: UInt32,
        branchIdForHeight: @escaping (Int32) throws -> Int32,
        renewLease: @escaping () async throws -> Void
    ) async throws -> MigrationSubmissionOutcome {
        let endpoint = try Self.endpoint(for: target)
        let useTor = target.transport == .torOnion

        // Transport construction and every preflight operation occur before submit begins. A
        // failure here is known-unsent and is reported to Rust by the claim-owning caller.
        let transport = try await transportFactory.makeTransport(endpoint: endpoint, useTor: useTor)
        do {
            try await renewLease()
            try Task.checkCancellation()
            let selectedTransportTip = try await validateSelectedEndpoint(
                transport: transport,
                expectedChainName: expectedChainName,
                expectedTransactionBranchId: transactionConsensusBranchId,
                branchIdForHeight: branchIdForHeight,
                renewLease: renewLease
            )
            guard expiryHeight > selectedTransportTip,
                  expiryHeight - selectedTransportTip >= Self.expirySafetyMargin else {
                throw MigrationBroadcastError.selectedTransportTipWithinExpirySafetyMargin(
                    tip: selectedTransportTip,
                    expiry: expiryHeight,
                    minimumRemainingBlocks: Self.expirySafetyMargin
                )
            }
            try await renewLease()
            try Task.checkCancellation()
        } catch {
            await transport.service.closeConnections()
            throw error
        }

        let outcome: MigrationSubmissionOutcome
        do {
            let response = try await transport.service.submit(
                spendTransaction: transaction.raw,
                mode: transport.mode
            )
            if response.errorCode == 0 {
                outcome = .accepted
            } else {
                outcome = await reconcileRejectedSubmission(
                    response: response,
                    transaction: transaction,
                    transport: transport
                )
            }
        } catch {
            // Once submit starts, timeout, cancellation, and disconnect are all ambiguous. The
            // exact claim remains durable for Rust-owned chain reconciliation.
            logger.error("migration_submit outcome=unknown code=transport_exception")
            outcome = .unknown
        }

        await transport.service.closeConnections()
        return outcome
    }

    private func sampledTip(
        transport: MigrationTransport,
        renewLease: (() async throws -> Void)? = nil
    ) async throws -> BlockHeight {
        var highestObserved: BlockHeight?
        var lastError: Error?

        for _ in 0 ..< Self.preflightTipSampleCount {
            do {
                let height = try await transport.service.latestBlockHeight(mode: transport.mode)
                try await renewLease?()
                try Task.checkCancellation()
                highestObserved = max(highestObserved ?? height, height)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
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

    private func validateSelectedEndpoint(
        transport: MigrationTransport,
        expectedChainName: String,
        expectedTransactionBranchId: UInt32?,
        branchIdForHeight: (Int32) throws -> Int32,
        renewLease: (() async throws -> Void)? = nil
    ) async throws -> BlockHeight {
        let sampledTip = try await sampledTip(transport: transport, renewLease: renewLease)
        let info = try await transport.service.getInfo(mode: transport.mode)
        try await renewLease?()
        try Task.checkCancellation()
        guard let remoteChainName = ConsensusChainName.canonicalize(info.chainName),
              remoteChainName == expectedChainName else {
            throw MigrationBroadcastError.selectedEndpointChainMismatch
        }
        guard let infoTip = BlockHeight(exactly: info.blockHeight), infoTip >= sampledTip else {
            throw MigrationBroadcastError.selectedEndpointInfoBehindSampledTip(
                infoTip: BlockHeight(clamping: info.blockHeight),
                sampledTip: sampledTip
            )
        }
        guard infoTip < BlockHeight(Int32.max),
              let reportedHeight = Int32(exactly: infoTip),
              let nextHeight = Int32(exactly: infoTip + 1),
              let remoteBranch = ConsensusBranchID.fromString(info.consensusBranchID) else {
            throw MigrationBroadcastError.selectedEndpointConsensusBranchMismatch
        }
        let localReportedBranch = try branchIdForHeight(reportedHeight)
        guard remoteBranch == localReportedBranch else {
            throw MigrationBroadcastError.selectedEndpointConsensusBranchMismatch
        }
        let localNextBranch = try branchIdForHeight(nextHeight)
        guard expectedTransactionBranchId.map({ UInt32(bitPattern: localNextBranch) == $0 }) ?? true else {
            throw MigrationBroadcastError.transactionConsensusBranchMismatch
        }
        return infoTip
    }

    private func reconcileRejectedSubmission(
        response: LightWalletServiceResponse,
        transaction: EncodedTransaction,
        transport: MigrationTransport
    ) async -> MigrationSubmissionOutcome {
        do {
            let fetched = try await transport.service.fetchTransaction(
                txId: transaction.transactionId,
                mode: transport.mode
            )
            if fetched.status != .txidNotRecognized {
                return .accepted
            }

            logger.error("migration_submit outcome=known_unsent code=server_rejected_\(response.errorCode)")
            return .knownUnsent
        } catch {
            logger.error("migration_submit outcome=unknown code=reconciliation_failed")
            return .unknown
        }
    }

    /// Rehydrates only a Rust-validated target. This parser cannot create policy or authority.
    static func endpoint(for target: MigrationBoundSubmissionTarget) throws -> LightWalletEndpoint {
        guard let components = URLComponents(string: target.endpoint),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw MigrationBroadcastError.invalidSubmissionEndpoint
        }

        let secure: Bool
        switch target.transport {
        case .directTLS:
            guard scheme == "https" else {
                throw MigrationBroadcastError.invalidSubmissionEndpoint
            }
            secure = true
        case .torOnion:
            guard (scheme == "http" || scheme == "https"), host.hasSuffix(".onion") else {
                throw MigrationBroadcastError.invalidSubmissionEndpoint
            }
            secure = scheme == "https"
        case .loopbackDevelopment:
            guard scheme == "http", Self.isExplicitLoopback(host) else {
                throw MigrationBroadcastError.invalidSubmissionEndpoint
            }
            secure = false
        }

        let port = components.port ?? (secure ? 443 : 80)
        guard (1 ... Int(UInt16.max)).contains(port) else {
            throw MigrationBroadcastError.invalidSubmissionEndpoint
        }
        return LightWalletEndpoint(address: host, port: port, secure: secure)
    }

    private static func isExplicitLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    static func endpointIdentity(_ endpoint: LightWalletEndpoint) -> String {
        let host = endpoint.host.lowercased()
        let renderedHost = host.contains(":") ? "[\(host)]" : host
        return "\(endpoint.secure ? "https" : "http")://\(renderedHost):\(endpoint.port)"
    }
}
