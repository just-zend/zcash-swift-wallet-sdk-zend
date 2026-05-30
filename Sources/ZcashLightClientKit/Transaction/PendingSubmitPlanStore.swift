//
//  PendingSubmitPlanStore.swift
//  ZcashLightClientKit
//
//  Created by Adam Tucker on 2026-05-12.
//

import Foundation
import Security

protocol PendingSubmitPlanPersistence {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func clear() throws
}

struct TransactionSubmitPlan {
    let endpoints: [LightWalletEndpoint]

    init(endpoints: [LightWalletEndpoint]) {
        precondition(!endpoints.isEmpty, "Transaction submit plan must include at least one endpoint.")
        self.endpoints = endpoints
    }
}

/// Tracks submit plans for pending transactions created through `Broadcaster`.
///
/// Transactions start as waiting for submit endpoints, then the store records
/// the endpoints used for submission so resubmission can retry through the same
/// path. Plans are persisted across launches and pruned when their transactions
/// are no longer resubmission candidates.
actor PendingSubmitPlanStore {
    enum StoredSubmitPlan {
        case awaitingPlan
        case ready(TransactionSubmitPlan)
    }

    private struct RetainToken {
        let storeRevision: UInt64
        let activeSubmitPlanCreations: Int
    }

    private struct SubmitPlanCreationToken {
        let clearGeneration: UInt64
    }

    private let persistence: PendingSubmitPlanPersistence?
    private let logger: Logger

    private var plansByTransactionId: [String: [StoredEndpoint]] = [:]
    // In-memory cache only. After restart, raw transaction submissions recover
    // the transaction id through RawTransactionLookup before recording endpoints.
    private var transactionIdsByRawTransaction: [String: String] = [:]
    private var pendingEndpointsByRawTransaction: [String: [StoredEndpoint]] = [:]
    private var loadedFromPersistence = false
    // Actor isolation prevents data races, but actor methods are reentrant
    // across await. Candidate lookup returns a repository snapshot, so pruning
    // only applies if no submit-plan creation was active and the store did not
    // change while that lookup was suspended.
    private var activeSubmitPlanCreations = 0
    private var storeRevision: UInt64 = 0
    // Prevents a creation that started before clear() from recording plans after
    // clear() has removed the in-memory and persisted submit-plan state.
    private var clearGeneration: UInt64 = 0

    init(
        persistence: PendingSubmitPlanPersistence? = nil,
        logger: Logger
    ) {
        self.persistence = persistence
        self.logger = logger
    }

    func createAndMarkAwaitingSubmitPlan(
        createTransactions: () async throws -> [ZcashTransaction.Overview]
    ) async rethrows -> [ZcashTransaction.Overview] {
        loadFromPersistenceIfNeeded()
        let creationToken = beginSubmitPlanCreation()
        defer { endSubmitPlanCreation() }

        let transactions = try await createTransactions()
        if canRecordSubmitPlanCreation(using: creationToken) {
            markAwaitingSubmitPlan(transactions)
        }
        return transactions
    }

    func addSubmitEndpoint(
        rawTransaction: Data,
        endpoint: LightWalletEndpoint
    ) async {
        loadFromPersistenceIfNeeded()

        let rawTransactionKey = rawTransaction.stablePlanKey
        guard let transactionId = transactionIdsByRawTransaction[rawTransactionKey] else {
            if activeSubmitPlanCreations > 0 {
                addPendingSubmitEndpoint(rawTransactionKey: rawTransactionKey, endpoint: endpoint)
            }
            return
        }

        addSubmitEndpoint(transactionId: transactionId, endpoint: endpoint)
    }

    func addSubmitEndpoint(
        transaction: ZcashTransaction.Overview,
        endpoint: LightWalletEndpoint
    ) async {
        loadFromPersistenceIfNeeded()
        if let raw = transaction.raw {
            let transactionId = transaction.rawID.stablePlanKey
            if transactionIdsByRawTransaction[raw.stablePlanKey] != transactionId {
                transactionIdsByRawTransaction[raw.stablePlanKey] = transactionId
                bumpStoreRevision()
            }
        }
        addSubmitEndpoint(transactionId: transaction.rawID.stablePlanKey, endpoint: endpoint)
    }

    func getSubmitPlan(for transactionId: Data) async -> StoredSubmitPlan? {
        loadFromPersistenceIfNeeded()

        switch plansByTransactionId[transactionId.stablePlanKey] {
        case nil:
            return nil
        case let endpoints? where endpoints.isEmpty:
            return .awaitingPlan
        case let endpoints?:
            return .ready(TransactionSubmitPlan(endpoints: endpoints.map(\.endpoint)))
        }
    }

    func loadTransactionsAndRetainSubmitPlans<T>(
        loadTransactions: () async throws -> [T],
        transactionId: (T) -> Data
    ) async rethrows -> [T] {
        loadFromPersistenceIfNeeded()
        let retainToken = makeRetainToken()

        let transactions = try await loadTransactions()
        if canApplyRetain(using: retainToken) {
            retainPlans(for: transactions.map(transactionId))
        }
        return transactions
    }

    func clear() async {
        plansByTransactionId.removeAll()
        transactionIdsByRawTransaction.removeAll()
        pendingEndpointsByRawTransaction.removeAll()
        clearGeneration &+= 1
        bumpStoreRevision()
        do {
            try persistence?.clear()
        } catch {
            logger.warn("Failed to clear pending submit plans: \(error)")
        }
    }
}

private extension PendingSubmitPlanStore {
    private func markAwaitingSubmitPlan(_ transactions: [ZcashTransaction.Overview]) {
        var shouldSave = false
        var didChange = false
        for transaction in transactions {
            let transactionId = transaction.rawID.stablePlanKey
            if let raw = transaction.raw {
                let rawTransactionKey = raw.stablePlanKey
                if transactionIdsByRawTransaction[rawTransactionKey] != transactionId {
                    transactionIdsByRawTransaction[rawTransactionKey] = transactionId
                    didChange = true
                }
                if let pendingEndpoints = pendingEndpointsByRawTransaction.removeValue(forKey: rawTransactionKey) {
                    didChange = true
                    var endpoints = plansByTransactionId[transactionId] ?? []
                    for pendingEndpoint in pendingEndpoints where !endpoints.contains(pendingEndpoint) {
                        endpoints.append(pendingEndpoint)
                        shouldSave = true
                    }
                    plansByTransactionId[transactionId] = endpoints
                }
            }
            if plansByTransactionId[transactionId] == nil {
                plansByTransactionId[transactionId] = []
                shouldSave = true
                didChange = true
            }
        }

        if didChange {
            bumpStoreRevision()
        }
        if shouldSave {
            saveToPersistence()
        }
    }

    private func addSubmitEndpoint(
        transactionId: String,
        endpoint: LightWalletEndpoint
    ) {
        let storedEndpoint = StoredEndpoint(endpoint: endpoint)
        var endpoints = plansByTransactionId[transactionId] ?? []
        guard !endpoints.contains(storedEndpoint) else { return }

        endpoints.append(storedEndpoint)
        plansByTransactionId[transactionId] = endpoints
        bumpStoreRevision()
        saveToPersistence()
    }

    private func addPendingSubmitEndpoint(
        rawTransactionKey: String,
        endpoint: LightWalletEndpoint
    ) {
        let storedEndpoint = StoredEndpoint(endpoint: endpoint)
        var endpoints = pendingEndpointsByRawTransaction[rawTransactionKey] ?? []
        guard !endpoints.contains(storedEndpoint) else { return }

        endpoints.append(storedEndpoint)
        pendingEndpointsByRawTransaction[rawTransactionKey] = endpoints
        bumpStoreRevision()
    }

    private func retainPlans(for transactionIds: [Data]) {
        let retainedTransactionIds = Set(transactionIds.map(\.stablePlanKey))
        let previousPlanCount = plansByTransactionId.count
        let previousRawTransactionCount = transactionIdsByRawTransaction.count
        plansByTransactionId = plansByTransactionId.filter { retainedTransactionIds.contains($0.key) }
        transactionIdsByRawTransaction = transactionIdsByRawTransaction.filter { retainedTransactionIds.contains($0.value) }

        if plansByTransactionId.count != previousPlanCount ||
            transactionIdsByRawTransaction.count != previousRawTransactionCount {
            bumpStoreRevision()
        }

        if plansByTransactionId.count != previousPlanCount {
            saveToPersistence()
        }
    }

    private func beginSubmitPlanCreation() -> SubmitPlanCreationToken {
        activeSubmitPlanCreations += 1
        bumpStoreRevision()
        return SubmitPlanCreationToken(clearGeneration: clearGeneration)
    }

    private func endSubmitPlanCreation() {
        precondition(activeSubmitPlanCreations > 0, "Attempted to end inactive submit-plan creation.")
        activeSubmitPlanCreations -= 1
        if activeSubmitPlanCreations == 0 && !pendingEndpointsByRawTransaction.isEmpty {
            pendingEndpointsByRawTransaction.removeAll()
            bumpStoreRevision()
        }
    }

    private func makeRetainToken() -> RetainToken {
        RetainToken(
            storeRevision: storeRevision,
            activeSubmitPlanCreations: activeSubmitPlanCreations
        )
    }

    private func canApplyRetain(using token: RetainToken) -> Bool {
        token.activeSubmitPlanCreations == 0 &&
            activeSubmitPlanCreations == 0 &&
            storeRevision == token.storeRevision
    }

    private func canRecordSubmitPlanCreation(using token: SubmitPlanCreationToken) -> Bool {
        clearGeneration == token.clearGeneration
    }

    private func bumpStoreRevision() {
        storeRevision &+= 1
    }

    private func loadFromPersistenceIfNeeded() {
        guard !loadedFromPersistence else { return }

        do {
            let shouldSaveAfterLoad: Bool
            if let data = try persistence?.load(), !data.isEmpty {
                let storedPlans = try JSONDecoder().decode(StoredPlans.self, from: data)
                guard storedPlans.version == StoredPlans.currentVersion else {
                    throw PendingSubmitPlanStoreError.unsupportedVersion(storedPlans.version)
                }
                shouldSaveAfterLoad = mergeLoadedPlans(storedPlans.plansByTransactionId)
            } else {
                shouldSaveAfterLoad = !plansByTransactionId.isEmpty
            }

            loadedFromPersistence = true
            if shouldSaveAfterLoad {
                saveToPersistence()
            }
        } catch {
            logger.warn("Failed to load pending submit plans: \(error)")
        }
    }

    private func mergeLoadedPlans(_ loadedPlans: [String: [StoredEndpoint]]) -> Bool {
        let previousPlans = plansByTransactionId
        guard !plansByTransactionId.isEmpty else {
            plansByTransactionId = loadedPlans
            if previousPlans != plansByTransactionId {
                bumpStoreRevision()
            }
            return false
        }

        var mergedPlans = loadedPlans
        for (transactionId, currentEndpoints) in plansByTransactionId {
            var endpoints = mergedPlans[transactionId] ?? []
            currentEndpoints.forEach {
                if !endpoints.contains($0) {
                    endpoints.append($0)
                }
            }
            mergedPlans[transactionId] = endpoints
        }
        plansByTransactionId = mergedPlans
        if previousPlans != plansByTransactionId {
            bumpStoreRevision()
        }
        return loadedPlans != plansByTransactionId
    }

    private func saveToPersistence() {
        guard loadedFromPersistence else {
            logger.warn("Skipping pending submit plan save because persisted plans have not loaded.")
            return
        }

        do {
            let storedPlans = StoredPlans(plansByTransactionId: plansByTransactionId)
            let data = try JSONEncoder().encode(storedPlans)
            try persistence?.save(data)
        } catch {
            logger.warn("Failed to store pending submit plans: \(error)")
        }
    }
}

private struct StoredPlans: Codable {
    let version: Int
    let plansByTransactionId: [String: [StoredEndpoint]]

    static let currentVersion = 1

    init(
        version: Int = Self.currentVersion,
        plansByTransactionId: [String: [StoredEndpoint]]
    ) {
        self.version = version
        self.plansByTransactionId = plansByTransactionId
    }
}

private enum PendingSubmitPlanStoreError: Error {
    case unsupportedVersion(Int)
}

private struct StoredEndpoint: Codable, Equatable {
    let host: String
    let port: Int
    let secure: Bool
    let singleCallTimeoutInMillis: Int64
    let streamingCallTimeoutInMillis: Int64

    init(endpoint: LightWalletEndpoint) {
        host = endpoint.host
        port = endpoint.port
        secure = endpoint.secure
        singleCallTimeoutInMillis = endpoint.singleCallTimeoutInMillis
        streamingCallTimeoutInMillis = endpoint.streamingCallTimeoutInMillis
    }

    var endpoint: LightWalletEndpoint {
        LightWalletEndpoint(
            address: host,
            port: port,
            secure: secure,
            singleCallTimeoutInMillis: singleCallTimeoutInMillis,
            streamingCallTimeoutInMillis: streamingCallTimeoutInMillis
        )
    }
}

private extension Data {
    var stablePlanKey: String { hexEncodedString() }
}

struct KeychainSubmitPlanPersistence: PendingSubmitPlanPersistence {
    private enum Constants {
        static let service = "cash.z.ecc.ZcashLightClientKit.pending-submit-plans"
    }

    private let account: String

    init(
        alias: ZcashSynchronizerAlias,
        networkType: NetworkType
    ) {
        self.account = "\(networkType.networkId)_\(alias.description)"
    }

    func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainSubmitPlanPersistenceError.unhandledStatus(status)
        }
    }

    func save(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            attributes.forEach { addQuery[$0.key] = $0.value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainSubmitPlanPersistenceError.unhandledStatus(addStatus)
            }
        default:
            throw KeychainSubmitPlanPersistenceError.unhandledStatus(updateStatus)
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSubmitPlanPersistenceError.unhandledStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.service,
            kSecAttrAccount as String: account
        ]
    }
}

private enum KeychainSubmitPlanPersistenceError: Error {
    case unhandledStatus(OSStatus)
}
