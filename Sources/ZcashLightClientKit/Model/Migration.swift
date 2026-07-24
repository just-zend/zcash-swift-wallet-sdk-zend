//
//  Migration.swift
//  ZcashLightClientKit
//
//  Zend-owned delivery-control projections layered on the canonical
//  zcash_pool_migration models in MigrationModels.swift.
//

import Foundation

/// Sanitized, stable cause for a wallet database initialization failure.
public enum WalletDatabaseInitializationFailureCause: String, Equatable, Sendable, Codable {
    case databaseBusy = "database_busy"
    case databaseLocked = "database_locked"
    case databaseFull = "database_full"
    case databaseReadOnly = "database_read_only"
    case databaseCorrupt = "database_corrupt"
    case databaseUnavailable = "database_unavailable"
    case schemaIncompatible = "schema_incompatible"
    case backend

    init?(ffiCode: UInt32) {
        switch ffiCode {
        case 1: self = .databaseBusy
        case 2: self = .databaseLocked
        case 3: self = .databaseFull
        case 4: self = .databaseReadOnly
        case 5: self = .databaseCorrupt
        case 6: self = .databaseUnavailable
        case 7: self = .schemaIncompatible
        case 8: self = .backend
        default: return nil
        }
    }
}

/// Public typed error thrown when the canonical wallet database migration fails.
public struct WalletDatabaseInitializationError: Error, Equatable, Sendable, LocalizedError {
    public let cause: WalletDatabaseInitializationFailureCause

    public init(cause: WalletDatabaseInitializationFailureCause) {
        self.cause = cause
    }

    public var errorDescription: String? {
        switch cause {
        case .databaseBusy, .databaseLocked:
            return "The wallet database is temporarily busy."
        case .databaseFull:
            return "The device does not have enough storage to update the wallet."
        case .databaseReadOnly:
            return "The wallet database cannot be updated."
        case .databaseCorrupt:
            return "The wallet database appears to be damaged."
        case .databaseUnavailable:
            return "The wallet database is unavailable."
        case .schemaIncompatible:
            return "This wallet database was created by an incompatible SDK version."
        case .backend:
            return "The wallet database could not be initialized."
        }
    }
}

/// Sanitized, stable cause for a migration-engine initialization failure.
public enum MigrationEngineInitializationFailureCause: String, Equatable, Sendable, Codable {
    case notSynced = "not_synced"
    case notInitialized = "not_initialized"
    case schemaIncompatible = "schema_incompatible"
    case engineSchemaNewer = "engine_schema_newer"
    case engineSchemaCorrupt = "engine_schema_corrupt"
    case consensusMismatch = "consensus_mismatch"
    case databaseBusy = "database_busy"
    case databaseLocked = "database_locked"
    case databaseFull = "database_full"
    case databaseReadOnly = "database_read_only"
    case databaseCorrupt = "database_corrupt"
    case databaseUnavailable = "database_unavailable"
    case backend
    case pipeline
    case otherInvalid = "other_invalid"

    init?(ffiCode: UInt32) {
        switch ffiCode {
        case 10: self = .notSynced
        case 11: self = .notInitialized
        case 12: self = .schemaIncompatible
        case 13: self = .engineSchemaNewer
        case 14: self = .engineSchemaCorrupt
        case 15: self = .consensusMismatch
        case 20: self = .databaseBusy
        case 21: self = .databaseLocked
        case 22: self = .databaseFull
        case 23: self = .databaseReadOnly
        case 24: self = .databaseCorrupt
        case 25: self = .databaseUnavailable
        case 30: self = .backend
        case 31: self = .pipeline
        case 32: self = .otherInvalid
        default: return nil
        }
    }
}

/// Public typed error thrown when Rust safely classifies migration startup.
public struct MigrationEngineInitializationError: Error, Equatable, Sendable, LocalizedError {
    public let cause: MigrationEngineInitializationFailureCause

    public init(cause: MigrationEngineInitializationFailureCause) {
        self.cause = cause
    }

    public var errorDescription: String? {
        switch cause {
        case .notSynced:
            return "Wallet synchronization must finish before migration can start."
        case .notInitialized:
            return "Migration initialization has not completed."
        case .schemaIncompatible:
            return "This wallet database uses an incompatible migration schema."
        case .engineSchemaNewer:
            return "This wallet was opened by a newer migration engine."
        case .engineSchemaCorrupt:
            return "The migration database state is incomplete or damaged."
        case .consensusMismatch:
            return "The migration state belongs to a different network configuration."
        case .databaseBusy, .databaseLocked:
            return "The wallet database is temporarily busy."
        case .databaseFull:
            return "The device does not have enough storage for migration."
        case .databaseReadOnly:
            return "The wallet database cannot be updated."
        case .databaseCorrupt:
            return "The wallet database appears to be damaged."
        case .databaseUnavailable:
            return "The wallet database is unavailable."
        case .backend:
            return "The wallet backend could not initialize migration."
        case .pipeline:
            return "The migration transaction pipeline could not initialize."
        case .otherInvalid:
            return "The migration state is not valid for initialization."
        }
    }
}

// MARK: - Rust-owned delivery capabilities

/// ARC storage for one opaque Rust capability. Swift can retain and pass the pointer, but cannot
/// inspect or reconstruct the revision, run identity, source owner, policy fingerprint, token, or
/// lease clock sealed inside it.
final class MigrationOpaqueHandleStorage: @unchecked Sendable {
    let pointer: OpaquePointer
    private let release: (OpaquePointer) -> Void

    init(pointer: OpaquePointer, release: @escaping (OpaquePointer) -> Void) {
        self.pointer = pointer
        self.release = release
    }

    deinit {
        release(pointer)
    }
}

struct MigrationRunHandle: @unchecked Sendable {
    fileprivate let storage: MigrationOpaqueHandleStorage

    init(storage: MigrationOpaqueHandleStorage) {
        self.storage = storage
    }

    var pointer: OpaquePointer { storage.pointer }
}

struct MigrationClaimHandle: @unchecked Sendable {
    fileprivate let storage: MigrationOpaqueHandleStorage

    init(storage: MigrationOpaqueHandleStorage) {
        self.storage = storage
    }

    var pointer: OpaquePointer { storage.pointer }
}

// MARK: - Raw host intent

/// Transport intent accepted at the public boundary. Rust validates the raw endpoint, derives the
/// network/consensus binding, normalizes the endpoint, fingerprints the policy, and persists it.
public enum MigrationSubmissionTransport: String, Equatable, Sendable, Codable {
    case directTLS = "direct_tls"
    case torOnion = "tor_onion"
    case loopbackDevelopment = "loopback_development"
}

/// Raw submission intent. This is not a bound policy and carries no delivery authority.
public struct MigrationSubmissionIntent: Equatable, Sendable, CustomStringConvertible {
    public let transport: MigrationSubmissionTransport
    public let endpoint: String

    public init(transport: MigrationSubmissionTransport, endpoint: String) {
        self.transport = transport
        self.endpoint = endpoint
    }

    public var description: String {
        "MigrationSubmissionIntent(transport: \(transport), endpoint: <redacted>)"
    }
}

// MARK: - Sanitized projections

public enum MigrationDeliveryLane: String, Equatable, Sendable, Codable {
    case scheduled
    case immediate
}

public enum MigrationSignerOwnership: String, Equatable, Sendable, Codable {
    case sdk
    case external
}

public enum MigrationDeliveryPhase: String, Equatable, Sendable, Codable {
    case active
    case paused
    case abandoning
    case abandoned
}

public enum MigrationDeliveryClaimKind: String, Equatable, Sendable, Codable {
    case materialization
    case submission
    case outcomeResolution = "outcome_resolution"
}

public enum MigrationDeliveryClaimStatus: String, Equatable, Sendable, Codable {
    case materializing
    case materializationFailed = "materialization_failed"
    case awaitingExternalSignature = "awaiting_external_signature"
    case staged
    case submitting
    case outcomeUnknown = "outcome_unknown"
    case broadcasted
    case confirmed
    case expiredUnmined = "expired_unmined"
    case externalSigningExpiredUnmined = "external_signing_expired_unmined"
}

public enum MigrationDeliveryFailureReason: String, Equatable, Sendable, Codable {
    case materializationFailed = "materialization_failed"
    case materializationLeaseExpired = "materialization_lease_expired"
    case signingCancelled = "signing_cancelled"
    case transportSetupFailed = "transport_setup_failed"
    case transportDidNotBegin = "transport_did_not_begin"
    case submissionLeaseExpired = "submission_lease_expired"
    case transportOutcomeUnknown = "transport_outcome_unknown"
}

public enum MigrationPolicyValidationFailure: String, Equatable, Sendable, Codable {
    case invalidEncoding = "invalid_encoding"
    case policyTooLarge = "policy_too_large"
    case networkMismatch = "network_mismatch"
    case consensusMismatch = "consensus_mismatch"
    case unsupported
}

public enum MigrationStorageRecoveryReason: String, Equatable, Sendable, Codable {
    case transferEvidenceLost = "transfer_evidence_lost"
    case rewoundBeyondFinalityHorizon = "rewound_beyond_finality_horizon"
    case corruptFinalityEvidence = "corrupt_finality_evidence"
    case externalSigningExposureUnresolved = "external_signing_exposure_unresolved"
}

public enum MigrationStorageFinality: Equatable, Sendable {
    case noRun
    case active
    case completePendingFinality(releaseAtHeight: BlockHeight)
    case finalized(releaseAtHeight: BlockHeight)
    case recoveryRequired(MigrationStorageRecoveryReason)
}

public enum MigrationDestinationSpendability: String, Equatable, Sendable, Codable {
    case notSpendable = "not_spendable"
    case spendable
    case alreadySpent = "already_spent"
    case notApplicable = "not_applicable"
}

public enum MigrationSchemaProvenance: Equatable, Sendable {
    case compatible(version: UInt32)
    case unavailable
    case future(version: UInt32)
    case corrupt
}

public enum MigrationLegacyCutoverStatus: Equatable, Sendable {
    case fresh
    case recoveryRequired(objects: UInt32)
}

public enum MigrationCanonicalStatus: String, Equatable, Sendable, Codable {
    case planning
    case committed
    case inProgress = "in_progress"
    case complete
    case failed
}

public struct MigrationCanonicalSummary: Equatable, Sendable {
    public let status: MigrationCanonicalStatus?
    public let transactionCount: UInt32

    init(status: MigrationCanonicalStatus?, transactionCount: UInt32) {
        self.status = status
        self.transactionCount = transactionCount
    }
}

public enum MigrationRuntimeUnavailableReason: Equatable, Sendable {
    case schemaUnavailable
    case futureSchema(version: UInt32)
    case corruptDeliveryState
    case legacyCutoverRecovery(objects: UInt32)
    case submissionPolicyMissing
    case submissionPolicyMismatch
    case deliveryInconsistent
    case finalityRecovery(MigrationStorageRecoveryReason)
}

public enum MigrationRuntimeAvailability: Equatable, Sendable {
    case available
    case unavailable(MigrationRuntimeUnavailableReason)
}

public enum MigrationOrdinarySpendBlockReason: Equatable, Sendable {
    case migrationActive
    case destinationNotSpendable
    case runtimeUnavailable
    case finalityRecovery(MigrationStorageRecoveryReason)
}

public enum MigrationOrdinarySpendAuthorization: Equatable, Sendable {
    case unrestricted
    case excludingMigrationSources(releaseAtHeight: BlockHeight)
    case blocked(MigrationOrdinarySpendBlockReason)
}

public enum MigrationAccountDeletionBlockReason: String, Equatable, Sendable, Codable {
    case runtimeUnavailable = "runtime_unavailable"
    case unresolvedDelivery = "unresolved_delivery"
}

public enum MigrationAccountDeletionAuthorization: Equatable, Sendable {
    case allowed
    case blocked(MigrationAccountDeletionBlockReason)
}

public enum MigrationCanonicalMutationBlockReason: String, Equatable, Sendable, Codable {
    case runtimeUnavailable = "runtime_unavailable"
    case deliveryOwned = "delivery_owned"
}

public enum MigrationCanonicalMutationAuthorization: Equatable, Sendable {
    case allowed
    case blocked(MigrationCanonicalMutationBlockReason)
}

public enum MigrationArtifactIdentitySummary: Equatable, Sendable {
    case scheduled(transactionID: UInt32)
    case immediate(identity: Data)
}

/// Read-only metadata for one exact artifact. Exact proposal, PCZT, signed PCZT, transaction bytes,
/// and claim authority stay behind the internal opaque handle and are copied only on demand.
public struct MigrationDeliveryClaimSummary: Equatable, Sendable, CustomStringConvertible {
    public let artifact: MigrationArtifactIdentitySummary
    public let signerOwnership: MigrationSignerOwnership
    public let status: MigrationDeliveryClaimStatus
    public let activeClaimKind: MigrationDeliveryClaimKind?
    public let externallyExposed: Bool
    public let hasSignedPCZT: Bool
    public let hasExactTransaction: Bool
    public let expiryHeight: BlockHeight
    /// Raw/internal byte order, matching `TxId.id`.
    public let txid: Data?
    public let lastError: MigrationDeliveryFailureReason?
    let claimHandle: MigrationClaimHandle

    init(
        artifact: MigrationArtifactIdentitySummary,
        signerOwnership: MigrationSignerOwnership,
        status: MigrationDeliveryClaimStatus,
        activeClaimKind: MigrationDeliveryClaimKind?,
        externallyExposed: Bool,
        hasSignedPCZT: Bool,
        hasExactTransaction: Bool,
        expiryHeight: BlockHeight,
        txid: Data?,
        lastError: MigrationDeliveryFailureReason?,
        claimHandle: MigrationClaimHandle
    ) {
        self.artifact = artifact
        self.signerOwnership = signerOwnership
        self.status = status
        self.activeClaimKind = activeClaimKind
        self.externallyExposed = externallyExposed
        self.hasSignedPCZT = hasSignedPCZT
        self.hasExactTransaction = hasExactTransaction
        self.expiryHeight = expiryHeight
        self.txid = txid
        self.lastError = lastError
        self.claimHandle = claimHandle
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.artifact == rhs.artifact &&
            lhs.signerOwnership == rhs.signerOwnership &&
            lhs.status == rhs.status &&
            lhs.activeClaimKind == rhs.activeClaimKind &&
            lhs.externallyExposed == rhs.externallyExposed &&
            lhs.hasSignedPCZT == rhs.hasSignedPCZT &&
            lhs.hasExactTransaction == rhs.hasExactTransaction &&
            lhs.expiryHeight == rhs.expiryHeight &&
            lhs.txid == rhs.txid &&
            lhs.lastError == rhs.lastError
    }

    public var description: String {
        "MigrationDeliveryClaimSummary(artifact: \(artifact), signer: \(signerOwnership), " +
            "status: \(status), claim: \(String(describing: activeClaimKind)), " +
            "externallyExposed: \(externallyExposed), exactTransaction: \(hasExactTransaction), " +
            "expiryHeight: \(expiryHeight), txid: <redacted>, lastError: \(String(describing: lastError)))"
    }
}

/// Read-only delivery projection. The numeric CAS revision is intentionally not surfaced as a
/// host-authored value; every mutation consumes `runHandle` and returns a fresh capability.
public struct MigrationDeliverySnapshot: Equatable, Sendable, CustomStringConvertible {
    public let lane: MigrationDeliveryLane
    public let phase: MigrationDeliveryPhase
    public let storageFinality: MigrationStorageFinality
    public let activeSourceReservationCount: UInt64
    public let hasSubmissionPolicy: Bool
    public let policyValidationFailure: MigrationPolicyValidationFailure?
    public let safeToCancel: Bool
    public let claims: [MigrationDeliveryClaimSummary]
    let runHandle: MigrationRunHandle

    init(
        lane: MigrationDeliveryLane,
        phase: MigrationDeliveryPhase,
        storageFinality: MigrationStorageFinality,
        activeSourceReservationCount: UInt64,
        hasSubmissionPolicy: Bool,
        policyValidationFailure: MigrationPolicyValidationFailure?,
        safeToCancel: Bool,
        claims: [MigrationDeliveryClaimSummary],
        runHandle: MigrationRunHandle
    ) {
        self.lane = lane
        self.phase = phase
        self.storageFinality = storageFinality
        self.activeSourceReservationCount = activeSourceReservationCount
        self.hasSubmissionPolicy = hasSubmissionPolicy
        self.policyValidationFailure = policyValidationFailure
        self.safeToCancel = safeToCancel
        self.claims = claims
        self.runHandle = runHandle
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.lane == rhs.lane &&
            lhs.phase == rhs.phase &&
            lhs.storageFinality == rhs.storageFinality &&
            lhs.activeSourceReservationCount == rhs.activeSourceReservationCount &&
            lhs.hasSubmissionPolicy == rhs.hasSubmissionPolicy &&
            lhs.policyValidationFailure == rhs.policyValidationFailure &&
            lhs.safeToCancel == rhs.safeToCancel &&
            lhs.claims == rhs.claims
    }

    public var description: String {
        "MigrationDeliverySnapshot(lane: \(lane), phase: \(phase), finality: \(storageFinality), " +
            "reservations: \(activeSourceReservationCount), policy: \(hasSubmissionPolicy), " +
            "policyFailure: \(String(describing: policyValidationFailure)), " +
            "safeToCancel: \(safeToCancel), claims: \(claims))"
    }
}

public struct MigrationRetainedRun: Equatable, Sendable {
    public let canonical: MigrationCanonicalSummary
    public let destinationSpendability: MigrationDestinationSpendability
    public let delivery: MigrationDeliverySnapshot

    init(
        canonical: MigrationCanonicalSummary,
        destinationSpendability: MigrationDestinationSpendability,
        delivery: MigrationDeliverySnapshot
    ) {
        self.canonical = canonical
        self.destinationSpendability = destinationSpendability
        self.delivery = delivery
    }
}

/// Atomic Rust-owned runtime projection for one wallet account.
public struct MigrationRuntimeSnapshot: Equatable, Sendable, CustomStringConvertible {
    public let account: AccountUUID
    public let canonical: MigrationCanonicalSummary
    public let schemaProvenance: MigrationSchemaProvenance
    public let legacyCutover: MigrationLegacyCutoverStatus
    public let destinationSpendability: MigrationDestinationSpendability
    public let availability: MigrationRuntimeAvailability
    public let ordinarySpendAuthorization: MigrationOrdinarySpendAuthorization
    public let accountDeletionAuthorization: MigrationAccountDeletionAuthorization
    public let canonicalMutationAuthorization: MigrationCanonicalMutationAuthorization
    /// Wallet-wide finality across the active delivery and every retained predecessor.
    public let aggregateStorageFinality: MigrationStorageFinality
    public let delivery: MigrationDeliverySnapshot?
    public let retainedRuns: [MigrationRetainedRun]

    init(
        account: AccountUUID,
        canonical: MigrationCanonicalSummary,
        schemaProvenance: MigrationSchemaProvenance,
        legacyCutover: MigrationLegacyCutoverStatus,
        destinationSpendability: MigrationDestinationSpendability,
        availability: MigrationRuntimeAvailability,
        ordinarySpendAuthorization: MigrationOrdinarySpendAuthorization,
        accountDeletionAuthorization: MigrationAccountDeletionAuthorization,
        canonicalMutationAuthorization: MigrationCanonicalMutationAuthorization,
        aggregateStorageFinality: MigrationStorageFinality,
        delivery: MigrationDeliverySnapshot?,
        retainedRuns: [MigrationRetainedRun]
    ) {
        self.account = account
        self.canonical = canonical
        self.schemaProvenance = schemaProvenance
        self.legacyCutover = legacyCutover
        self.destinationSpendability = destinationSpendability
        self.availability = availability
        self.ordinarySpendAuthorization = ordinarySpendAuthorization
        self.accountDeletionAuthorization = accountDeletionAuthorization
        self.canonicalMutationAuthorization = canonicalMutationAuthorization
        self.aggregateStorageFinality = aggregateStorageFinality
        self.delivery = delivery
        self.retainedRuns = retainedRuns
    }

    public var description: String {
        "MigrationRuntimeSnapshot(account: <redacted>, canonical: \(canonical), " +
            "schema: \(schemaProvenance), cutover: \(legacyCutover), " +
            "destination: \(destinationSpendability), availability: \(availability), " +
            "ordinarySpend: \(ordinarySpendAuthorization), accountDeletion: " +
            "\(accountDeletionAuthorization), canonicalMutation: \(canonicalMutationAuthorization), " +
            "aggregateFinality: \(aggregateStorageFinality), " +
            "delivery: \(String(describing: delivery)), retainedRuns: \(retainedRuns.count))"
    }
}

/// Rust's typed interpretation of one network attempt. The claim handle, not this enum, authorizes
/// the durable state transition.
public enum MigrationSubmissionOutcome: String, Equatable, Sendable, Codable {
    case accepted
    case knownUnsent = "known_unsent"
    case unknown
}

/// A Rust-built, proven immediate-migration PCZT together with the opaque claim that exclusively
/// authorizes its signer round trip.
///
/// The PCZT may be handed to an external signer, but callers cannot construct or alter the claim,
/// proposal, source reservation, expiry, submission policy, or expected transaction. Return this
/// exact value with the signer's PCZT to
/// ``Synchronizer/submitExternallySignedImmediateMigration(accountUUID:request:signedPCZT:)``.
public struct ImmediateMigrationExternalSigningRequest: @unchecked Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    /// The canonical, proven PCZT to pass to the external signer.
    public let pczt: Data
    let claim: MigrationClaimHandle

    init(pczt: Data, claim: MigrationClaimHandle) {
        self.pczt = pczt
        self.claim = claim
    }

    public var description: String {
        "ImmediateMigrationExternalSigningRequest(pczt: <redacted>, claim: <opaque>)"
    }

    public var debugDescription: String { description }
}

/// One Rust-owned scheduled migration transaction staged for an external signer.
///
/// The public transaction id is display metadata only. Authority to accept the signer response,
/// advance canonical state, prove, and submit the exact transaction remains in the private opaque
/// claim. Callers must return this exact request with the signed PCZT.
public struct ScheduledMigrationExternalSigningRequest: @unchecked Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let transactionID: UInt32
    public let pczt: Data
    let claim: MigrationClaimHandle

    init(transactionID: UInt32, pczt: Data, claim: MigrationClaimHandle) {
        self.transactionID = transactionID
        self.pczt = pczt
        self.claim = claim
    }

    public var description: String {
        "ScheduledMigrationExternalSigningRequest(transactionID: \(transactionID), pczt: <redacted>, claim: <opaque>)"
    }

    public var debugDescription: String { description }
}

/// Fail-closed SDK composition errors for Rust-owned migration delivery claims.
public enum MigrationDeliveryError: Error, Equatable, Sendable, LocalizedError {
    case claimUnavailable
    case externalSigningClaimUnavailable
    case deliveryRunUnavailable
    case scheduledDeliveryRunUnavailable
    case expiredTransferUnavailable(transactionID: UInt32)
    case missingExternalSigningPCZT
    case missingExactTransaction
    case missingTransactionID
    case submissionTargetUnavailable
    case submissionTransportUnavailable
    case runtimeUnavailable(MigrationRuntimeUnavailableReason)

    public var errorDescription: String? {
        switch self {
        case .claimUnavailable:
            return "The immediate migration claim is not currently available."
        case .externalSigningClaimUnavailable:
            return "The migration external-signing claim expired or cannot be resumed."
        case .deliveryRunUnavailable:
            return "No migration delivery run is available for this account."
        case .scheduledDeliveryRunUnavailable:
            return "No scheduled migration delivery run is available for this account."
        case .expiredTransferUnavailable:
            return "The requested migration transaction is not the current exact expired attempt."
        case .missingExternalSigningPCZT:
            return "The migration engine did not return the reserved external-signing PCZT."
        case .missingExactTransaction:
            return "The migration engine did not return the reserved exact transaction."
        case .missingTransactionID:
            return "The migration engine did not return the reserved transaction identifier."
        case .submissionTargetUnavailable:
            return "The migration run has no validated submission target."
        case .submissionTransportUnavailable:
            return "The migration submission transport is unavailable in this SDK composition."
        case .runtimeUnavailable:
            return "The migration runtime is unavailable and cannot safely execute delivery work."
        }
    }
}

/// Rust-normalized transport details copied from a bound run only for creating the network client.
struct MigrationBoundSubmissionTarget: Equatable, Sendable {
    let transport: MigrationSubmissionTransport
    let endpoint: String
}
