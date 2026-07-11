//
//  MigrationTransactionSubmitter.swift
//  ZcashLightClientKit
//

import Foundation

enum MigrationBroadcastError: Error, Equatable {
    case migrationSnapshotChanged
    case invalidTransactionID
    case transactionIDMismatch
    case invalidSubmissionEndpoint
    case submissionPolicyMismatch
    case selectedEndpointChainMismatch
    case selectedEndpointConsensusBranchMismatch
    case transactionConsensusBranchMismatch
    case selectedEndpointInfoBehindSampledTip(infoTip: BlockHeight, sampledTip: BlockHeight)
    case missingExpiryHeight
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

/// Creates exactly the transport requested for one migration broadcast. Tor is deliberately
/// independent of the SDK-wide Tor flag: a migration privacy choice is authoritative per call.
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
            // The isolated client owns this migration attempt even when global Tor is disabled.
            // Failure to create it propagates; privacy requests never fall back to a clear channel.
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

protocol MigrationTransactionSubmitting {
    func validateSubmissionPolicy(
        options: NetworkPrivacyOptions,
        defaultEndpoint: LightWalletEndpoint,
        networkType: NetworkType,
        expectedChainName: String,
        consensusFingerprint: String,
        branchIdForHeight: @escaping (Int32) throws -> Int32
    ) async throws -> SubmissionPolicy

    // Engine claim, immutable policy, and lease renewal are one atomic submission contract.
    // swiftlint:disable:next function_parameter_count
    func submit(
        transaction: EncodedTransaction,
        displayTransactionID: String,
        expiryHeight: BlockHeight,
        options: NetworkPrivacyOptions,
        defaultEndpoint: LightWalletEndpoint,
        networkType: NetworkType,
        expectedChainName: String,
        boundPolicy: BoundSubmissionPolicy,
        transactionConsensusBranchId: UInt32,
        branchIdForHeight: @escaping (Int32) throws -> Int32,
        renewLease: @escaping () async throws -> Void
    ) async throws -> TransferResult
}

/// One-shot migration submission with explicit transport selection and exact-tx reconciliation.
final class LiveMigrationTransactionSubmitter: MigrationTransactionSubmitting {
    private static let preflightTipSampleCount = 3
    /// zcashd accepts when `nextBlockHeight + 3 <= expiry`; with tip H this requires
    /// `expiry - H >= 4`. Apply that exact boundary before submission.
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

    func validateSubmissionPolicy(
        options: NetworkPrivacyOptions,
        defaultEndpoint: LightWalletEndpoint,
        networkType: NetworkType,
        expectedChainName: String,
        consensusFingerprint: String,
        branchIdForHeight: @escaping (Int32) throws -> Int32
    ) async throws -> SubmissionPolicy {
        let endpoint = try Self.resolveEndpoint(
            options.submissionEndpoint,
            fallback: defaultEndpoint,
            networkType: networkType
        )
        let transport = try await transportFactory.makeTransport(endpoint: endpoint, useTor: options.useTor)
        do {
            _ = try await validateSelectedEndpoint(
                transport: transport,
                expectedChainName: expectedChainName,
                expectedTransactionBranchId: nil,
                branchIdForHeight: branchIdForHeight
            )
            await transport.service.closeConnections()
            return SubmissionPolicy(
                transport: options.useTor ? .tor : .direct,
                endpointIdentity: Self.endpointIdentity(endpoint),
                consensusFingerprint: consensusFingerprint
            )
        } catch {
            await transport.service.closeConnections()
            throw error
        }
    }

    /// Compatibility overload retained for focused submitter tests and internal callers that do
    /// not own an engine claim. Production migration execution uses the policy-bound overload.
    func submit(
        transaction: EncodedTransaction,
        displayTransactionID: String,
        expiryHeight: BlockHeight,
        options: NetworkPrivacyOptions,
        defaultEndpoint: LightWalletEndpoint,
        networkType: NetworkType = .testnet
    ) async throws -> TransferResult {
        let endpoint = try Self.resolveEndpoint(
            options.submissionEndpoint,
            fallback: defaultEndpoint,
            networkType: networkType
        )
        let policy = SubmissionPolicy(
            transport: options.useTor ? .tor : .direct,
            endpointIdentity: Self.endpointIdentity(endpoint),
            consensusFingerprint: String(repeating: "0", count: 64)
        )
        let branch = UInt32(bitPattern: Int32(bitPattern: 0xc2d6d0b4))
        return try await submit(
            transaction: transaction,
            displayTransactionID: displayTransactionID,
            expiryHeight: expiryHeight,
            options: options,
            defaultEndpoint: defaultEndpoint,
            networkType: networkType,
            expectedChainName: networkType.chainName,
            boundPolicy: BoundSubmissionPolicy(
                policy: policy,
                policyFingerprint: String(repeating: "0", count: 64),
                revision: 1
            ),
            transactionConsensusBranchId: branch,
            branchIdForHeight: { _ in Int32(bitPattern: branch) },
            renewLease: {}
        )
    }

    // Mirrors the atomic protocol contract above; grouping these values would obscure ownership.
    // swiftlint:disable:next function_parameter_count
    func submit(
        transaction: EncodedTransaction,
        displayTransactionID: String,
        expiryHeight: BlockHeight,
        options: NetworkPrivacyOptions,
        defaultEndpoint: LightWalletEndpoint,
        networkType: NetworkType,
        expectedChainName: String,
        boundPolicy: BoundSubmissionPolicy,
        transactionConsensusBranchId: UInt32,
        branchIdForHeight: @escaping (Int32) throws -> Int32,
        renewLease: @escaping () async throws -> Void
    ) async throws -> TransferResult {
        let endpoint = try Self.resolveEndpoint(
            options.submissionEndpoint,
            fallback: defaultEndpoint,
            networkType: networkType
        )
        let requestedPolicy = SubmissionPolicy(
            transport: options.useTor ? .tor : .direct,
            endpointIdentity: Self.endpointIdentity(endpoint),
            consensusFingerprint: boundPolicy.policy.consensusFingerprint
        )
        guard requestedPolicy == boundPolicy.policy else {
            throw MigrationBroadcastError.submissionPolicyMismatch
        }
        // Transport creation happens before submission. A setup failure is known not to have
        // broadcast anything, so it propagates instead of being mislabeled outcome-unknown.
        let transport = try await transportFactory.makeTransport(endpoint: endpoint, useTor: options.useTor)
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
            // This is the last known-unsent boundary. Cancellation after `submit` begins is
            // outcome-unknown and must retain the exact engine claim.
            try await renewLease()
            try Task.checkCancellation()
        } catch {
            await transport.service.closeConnections()
            throw error
        }

        let result: TransferResult
        do {
            let response = try await transport.service.submit(
                spendTransaction: transaction.raw,
                mode: transport.mode
            )

            if response.errorCode == 0 {
                result = .success(txid: displayTransactionID)
            } else {
                result = await reconcileRejectedSubmission(
                    response: response,
                    transaction: transaction,
                    displayTransactionID: displayTransactionID,
                    transport: transport
                )
            }
        } catch {
            // Once submit has started, a timeout/disconnect cannot prove that the server did not
            // receive the transaction. Retain the engine claim instead of immediately retrying.
            logger.error("migration_submit outcome=unknown code=transport_exception")
            result = .outcomeUnknown
        }

        await transport.service.closeConnections()
        return result
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
        displayTransactionID: String,
        transport: MigrationTransport
    ) async -> TransferResult {
        do {
            let fetched = try await transport.service.fetchTransaction(
                txId: transaction.transactionId,
                mode: transport.mode
            )
            if fetched.status != .txidNotRecognized {
                // A rejection such as "already in mempool" is acceptance when this exact txid is
                // present at the selected endpoint.
                return .success(txid: displayTransactionID)
            }

            logger.error("migration_submit outcome=rejected code=server_rejected")
            return .networkError(retryable: false)
        } catch {
            // The submit response was negative but reconciliation itself failed. We cannot tell
            // whether this was an already-known response, so preserve the lease and reconcile later.
            logger.error("migration_submit outcome=unknown code=reconciliation_failed")
            return .outcomeUnknown
        }
    }

    static func resolveEndpoint(
        _ submissionEndpoint: String?,
        fallback: LightWalletEndpoint,
        networkType: NetworkType
    ) throws -> LightWalletEndpoint {
        guard let submissionEndpoint else {
            try validateTransportSecurity(fallback, networkType: networkType)
            return fallback
        }
        guard
            let components = URLComponents(string: submissionEndpoint),
            let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.isEmpty || components.path == "/"
        else {
            throw MigrationBroadcastError.invalidSubmissionEndpoint
        }

        let secure = scheme == "https"
        let port = components.port ?? (secure ? 443 : 80)
        guard (1 ... 65_535).contains(port) else {
            throw MigrationBroadcastError.invalidSubmissionEndpoint
        }
        let endpoint = LightWalletEndpoint(
            address: host,
            port: port,
            secure: secure,
            singleCallTimeoutInMillis: fallback.singleCallTimeoutInMillis,
            streamingCallTimeoutInMillis: fallback.streamingCallTimeoutInMillis
        )
        try validateTransportSecurity(endpoint, networkType: networkType)
        return endpoint
    }

    private static func validateTransportSecurity(
        _ endpoint: LightWalletEndpoint,
        networkType: NetworkType
    ) throws {
        guard endpoint.secure || (networkType == .regtest && isLoopback(endpoint.host)) else {
            throw MigrationBroadcastError.invalidSubmissionEndpoint
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        let lowercased = host.lowercased()
        let normalized = lowercased.hasPrefix("[") && lowercased.hasSuffix("]")
            ? String(lowercased.dropFirst().dropLast())
            : lowercased
        if normalized == "localhost" || normalized == "::1" {
            return true
        }
        let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.first == "127",
              octets.allSatisfy({ octet in
                  guard !octet.isEmpty,
                        octet.utf8.allSatisfy({ (48 ... 57).contains($0) }),
                        let value = UInt8(octet) else {
                      return false
                  }
                  return String(value) == String(octet)
              }) else {
            return false
        }
        return true
    }

    static func endpointIdentity(_ endpoint: LightWalletEndpoint) -> String {
        let host = endpoint.host.lowercased()
        let renderedHost = host.contains(":") ? "[\(host)]" : host
        return "\(endpoint.secure ? "https" : "http")://\(renderedHost):\(endpoint.port)"
    }
}
