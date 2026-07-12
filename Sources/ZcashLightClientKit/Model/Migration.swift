//
//  Migration.swift
//  ZcashLightClientKit
//
//  Public Codable models for the Orchard -> Ironwood migration engine (`zodl_ironwood_migration`).
//  Field names and enum tags mirror the crate's serde output exactly: structs use snake_case keys;
//  enums use serde external tagging (a unit variant is a bare string, a data variant is a
//  single-key object). These are decoded from the FFI JSON by the `ZcashRustBackend` welding.
//

import Foundation
import CryptoKit

/// Live migration progress for the progress UI.
public struct MigrationProgress: Equatable, Codable {
    public let completedTransfers: UInt32
    public let totalTransfers: UInt32
    public let remainingOrchard: UInt64
    public let nextTransferReadyAtHeight: UInt32?

    public init(
        completedTransfers: UInt32,
        totalTransfers: UInt32,
        remainingOrchard: UInt64,
        nextTransferReadyAtHeight: UInt32?
    ) {
        self.completedTransfers = completedTransfers
        self.totalTransfers = totalTransfers
        self.remainingOrchard = remainingOrchard
        self.nextTransferReadyAtHeight = nextTransferReadyAtHeight
    }

    enum CodingKeys: String, CodingKey {
        case completedTransfers = "completed_transfers"
        case totalTransfers = "total_transfers"
        case remainingOrchard = "remaining_orchard"
        case nextTransferReadyAtHeight = "next_transfer_ready_at_height"
    }
}

/// A pre-signed transaction for the platform to broadcast. `rawPczt` is a serialized PCZT (serde
/// encodes `Vec<u8>` as a JSON array of bytes); the Swift layer turns it into a consensus
/// transaction via `migrationExtractBroadcastTx` before broadcasting. `txid` is its pre-computed id.
public struct PreparedTx: Equatable, Codable {
    public let id: String
    public let txid: String
    public let rawPczt: [UInt8]

    public init(id: String, txid: String, rawPczt: [UInt8]) {
        self.id = id
        self.txid = txid
        self.rawPczt = rawPczt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case txid
        case rawPczt = "raw_pczt"
    }
}

/// A migration-transfer PCZT paired with the transfer id it belongs to, for the external-signer
/// (hardware wallet) flow. `proposeMigrationTransferPCZTs` returns one per scheduled transfer with
/// `pczt` holding the unsigned PCZT for the signing device; the app hands the same pairs back to
/// `storeSignedMigrationTransferPCZTs` with `pczt` replaced by the device-signed PCZT — the crate
/// matches them to its staged originals by `id`. The JSON wire format mirrors the crate's
/// `TransferPczt` (`raw_pczt` as a byte array), converted to `Pczt` (`Data`) here.
public struct MigrationTransferPCZT: Equatable, Codable {
    public let id: String
    public let pczt: Pczt

    public init(id: String, pczt: Pczt) {
        self.id = id
        self.pczt = pczt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case pczt = "raw_pczt"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        pczt = Pczt(try container.decode([UInt8].self, forKey: .pczt))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode([UInt8](pczt), forKey: .pczt)
    }
}

/// A proposed note split: the per-note output values (zatoshi) and the prep-transaction fee.
public struct NoteSplitProposal: Equatable, Codable {
    public let outputNotes: [UInt64]
    public let fee: UInt64

    public init(outputNotes: [UInt64], fee: UInt64) {
        self.outputNotes = outputNotes
        self.fee = fee
    }

    enum CodingKeys: String, CodingKey {
        case outputNotes = "output_notes"
        case fee
    }
}

/// A single scheduled migration transfer. `anchorHeight` comes from a shared 288-block bucket;
/// the transfer may broadcast after `nextExecutableAfterHeight` and is invalid after `expiryHeight`.
public struct TransferProposal: Equatable, Codable {
    public let id: String
    public let amount: UInt64
    public let anchorHeight: UInt32
    public let nextExecutableAfterHeight: UInt32
    public let expiryHeight: UInt32

    public init(
        id: String,
        amount: UInt64,
        anchorHeight: UInt32,
        nextExecutableAfterHeight: UInt32,
        expiryHeight: UInt32
    ) {
        self.id = id
        self.amount = amount
        self.anchorHeight = anchorHeight
        self.nextExecutableAfterHeight = nextExecutableAfterHeight
        self.expiryHeight = expiryHeight
    }

    enum CodingKeys: String, CodingKey {
        case id
        case amount
        case anchorHeight = "anchor_height"
        case nextExecutableAfterHeight = "next_executable_after_height"
        case expiryHeight = "expiry_height"
    }
}

/// The full migration schedule presented to the user for one-time confirmation.
public struct MigrationSchedule: Equatable, Codable {
    public let transfers: [TransferProposal]
    public let estimatedDurationHours: UInt32

    public init(transfers: [TransferProposal], estimatedDurationHours: UInt32) {
        self.transfers = transfers
        self.estimatedDurationHours = estimatedDurationHours
    }

    enum CodingKeys: String, CodingKey {
        case transfers
        case estimatedDurationHours = "estimated_duration_hours"
    }
}

/// Exact, read-only economics for an immediate Orchard-to-Ironwood migration. Computing this
/// value does not create a draft, run, reservation, signature, or transaction.
public enum ImmediateMigrationPreview: Equatable, Sendable, Codable {
    /// The spendable Orchard balance can pay the exact ZIP-317 fee and leave value to migrate.
    case actionable(spendableBalance: UInt64, migrationAmount: UInt64, fee: UInt64)
    /// Positive Orchard value exists, but none remains after the exact ZIP-317 fee.
    case positiveBalanceAtOrBelowFee(spendableBalance: UInt64, fee: UInt64)
    /// No Orchard value is currently spendable, including value committed by a pending spend.
    case noSpendableFunds

    private enum CodingKeys: String, CodingKey {
        case status
        case spendableBalance = "spendable_balance"
        case migrationAmount = "migration_amount"
        case fee
    }

    private enum Status: String, Codable {
        case actionable
        case positiveBalanceAtOrBelowFee = "positive_balance_at_or_below_fee"
        case noSpendableFunds = "no_spendable_funds"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .actionable:
            self = try .actionable(
                spendableBalance: container.decode(UInt64.self, forKey: .spendableBalance),
                migrationAmount: container.decode(UInt64.self, forKey: .migrationAmount),
                fee: container.decode(UInt64.self, forKey: .fee)
            )
        case .positiveBalanceAtOrBelowFee:
            self = try .positiveBalanceAtOrBelowFee(
                spendableBalance: container.decode(UInt64.self, forKey: .spendableBalance),
                fee: container.decode(UInt64.self, forKey: .fee)
            )
        case .noSpendableFunds:
            self = .noSpendableFunds
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .actionable(let spendableBalance, let migrationAmount, let fee):
            try container.encode(Status.actionable, forKey: .status)
            try container.encode(spendableBalance, forKey: .spendableBalance)
            try container.encode(migrationAmount, forKey: .migrationAmount)
            try container.encode(fee, forKey: .fee)
        case .positiveBalanceAtOrBelowFee(let spendableBalance, let fee):
            try container.encode(Status.positiveBalanceAtOrBelowFee, forKey: .status)
            try container.encode(spendableBalance, forKey: .spendableBalance)
            try container.encode(fee, forKey: .fee)
        case .noSpendableFunds:
            try container.encode(Status.noSpendableFunds, forKey: .status)
        }
    }
}

/// Sanitized, stable cause for a migration-engine initialization failure. These cases are safe for
/// UI state and telemetry; no Rust, SQLite, path, schema-object, or SQL text is retained.
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
    case backend = "backend"
    case pipeline = "pipeline"
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

/// Public typed error thrown when the Rust FFI can safely classify migration-engine startup.
public struct MigrationEngineInitializationError: Error, Equatable, Sendable, LocalizedError {
    public let cause: MigrationEngineInitializationFailureCause

    public init(cause: MigrationEngineInitializationFailureCause) {
        self.cause = cause
    }

    public var errorDescription: String? {
        switch cause {
        case .notSynced:
            "Wallet synchronization must finish before migration can start."
        case .notInitialized:
            "Migration initialization has not completed."
        case .schemaIncompatible:
            "This wallet database uses an incompatible migration schema."
        case .engineSchemaNewer:
            "This wallet was opened by a newer migration engine."
        case .engineSchemaCorrupt:
            "The migration database state is incomplete or damaged."
        case .consensusMismatch:
            "The migration state belongs to a different network configuration."
        case .databaseBusy, .databaseLocked:
            "The wallet database is temporarily busy."
        case .databaseFull:
            "The device does not have enough storage for migration."
        case .databaseReadOnly:
            "The wallet database cannot be updated."
        case .databaseCorrupt:
            "The wallet database appears to be damaged."
        case .databaseUnavailable:
            "The wallet database is unavailable."
        case .backend:
            "The wallet backend could not initialize migration."
        case .pipeline:
            "The migration transaction pipeline could not initialize."
        case .otherInvalid:
            "The migration state is not valid for initialization."
        }
    }
}

/// One user-approved, anchorless migration transfer intent. A transaction anchor and consensus
/// expiry do not exist until the engine materializes this intent at its due height.
public struct MigrationIntent: Equatable, Codable {
    public let id: String
    public let amount: UInt64
    /// Exact engine-computed fee included in the user's approval.
    public let fee: UInt64
    public let notBeforeHeight: UInt32
    public let targetWindowEndHeight: UInt32

    public init(
        id: String,
        amount: UInt64,
        fee: UInt64,
        notBeforeHeight: UInt32,
        targetWindowEndHeight: UInt32
    ) {
        self.id = id
        self.amount = amount
        self.fee = fee
        self.notBeforeHeight = notBeforeHeight
        self.targetWindowEndHeight = targetWindowEndHeight
    }

    enum CodingKeys: String, CodingKey {
        case id
        case amount
        case fee
        case notBeforeHeight = "not_before_height"
        case targetWindowEndHeight = "target_window_end_height"
    }
}

/// The authoritative anchorless intent schedule presented for confirmation. `expectedRevision`
/// is a compare-and-set token: committing a stale or changed schedule is rejected by the engine.
public struct MigrationIntentSchedule: Equatable, Codable {
    public let runId: String
    public let expectedRevision: UInt64
    public let intents: [MigrationIntent]
    public let estimatedDurationHours: UInt32

    public init(
        runId: String,
        expectedRevision: UInt64,
        intents: [MigrationIntent],
        estimatedDurationHours: UInt32
    ) {
        self.runId = runId
        self.expectedRevision = expectedRevision
        self.intents = intents
        self.estimatedDurationHours = estimatedDurationHours
    }

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case expectedRevision = "expected_revision"
        case intents
        case estimatedDurationHours = "estimated_duration_hours"
    }
}

/// Immutable execution mode of a persisted migration run.
public enum MigrationRunMode: String, Equatable, Codable {
    case privateScheduled = "private_scheduled"
    case immediate
}

/// Exact persisted phase of the migration state machine. UI code should render the authoritative
/// ``MigrationSnapshot`` instead of trying to infer this phase from progress counts.
public enum MigrationPhase: String, Equatable, Codable {
    case noOrchardFunds = "no_orchard_funds"
    case waitingForSpendableOrchard = "waiting_for_spendable_orchard"
    case readyToPrepare = "ready_to_prepare"
    case preparingDenominations = "preparing_denominations"
    case waitingDenomConfirmations = "waiting_denom_confirmations"
    case readyToMigrate = "ready_to_migrate"
    case broadcastScheduled = "broadcast_scheduled"
    case broadcasting
    case waitingMigrationConfirmations = "waiting_migration_confirmations"
    case complete
    case paused
    case failedRecoverable = "failed_recoverable"
    case failedTerminal = "failed_terminal"
    /// Cancellation was requested, but exact signed attempts are not yet safe to release.
    case abandoning
    case abandoned
}

/// Stable, machine-actionable reason the migration cannot currently advance.
public enum MigrationFailureCode: String, Equatable, Codable {
    case syncRequired = "sync_required"
    case anchorUnavailable = "anchor_unavailable"
    case insufficientFunds = "insufficient_funds"
    case invalidPreparedNote = "invalid_prepared_note"
    case transferExpired = "transfer_expired"
    case networkUnavailable = "network_unavailable"
    case submissionRejected = "submission_rejected"
    case submissionOutcomeUnknown = "submission_outcome_unknown"
    case submissionCancelled = "submission_cancelled"
    case transportSetupFailed = "transport_setup_failed"
    case leaseBudgetInsufficient = "lease_budget_insufficient"
    case endpointConsensusMismatch = "endpoint_consensus_mismatch"
    case submissionPolicyMismatch = "submission_policy_mismatch"
    case transactionBranchNotCurrent = "transaction_branch_not_current"
    case transactionExpiryWindowClosed = "transaction_expiry_window_closed"
    case malformedPczt = "malformed_pczt"
    case txidMismatch = "txid_mismatch"
    case signerMismatch = "signer_mismatch"
    case persistenceFailure = "persistence_failure"
    case schemaIncompatible = "schema_incompatible"
    case externalSignerIncomplete = "external_signer_incomplete"
    case approvedFeeChanged = "approved_fee_changed"
    case planSemanticsChanged = "plan_semantics_changed"
    /// SDK-only projection used when the wallet's engine schema is newer than this binary.
    case appUpdateRequired = "app_update_required"
    case unknown
}

/// Recovery operation paired with a typed migration failure.
public enum RecoveryAction: String, Equatable, Codable {
    case retryAutomatically = "retry_automatically"
    case waitForSync = "wait_for_sync"
    case rebuildSchedule = "rebuild_schedule"
    case recreateTransaction = "recreate_transaction"
    case waitForSubmissionResolution = "wait_for_submission_resolution"
    case wipeAndRescanTestnet = "wipe_and_rescan_testnet"
    case contactSupport = "contact_support"
    case requireUserReapproval = "require_user_reapproval"
    /// SDK-only recovery action for a newer on-disk engine schema.
    case updateApp = "update_app"
}

/// The engine's next safe action. This is intentionally more precise than ``MigrationState`` so
/// foreground and background executors make the same decision after a relaunch.
public enum NextAction: String, Equatable, Codable {
    case initialize
    case awaitUserChoice = "await_user_choice"
    case waitForSync = "wait_for_sync"
    case preparePrivateSplit = "prepare_private_split"
    case waitForSplitConfirmation = "wait_for_split_confirmation"
    case proposePrivateSchedule = "propose_private_schedule"
    case stageNoteSplitExternalSignature = "stage_note_split_external_signature"
    case materializeDueTransaction = "materialize_due_transaction"
    case stageDueExternalSignature = "stage_due_external_signature"
    case resumeStagedSubmission = "resume_staged_submission"
    case waitForWorkerLease = "wait_for_worker_lease"
    case awaitExternalSignature = "await_external_signature"
    case claimDueTransaction = "claim_due_transaction"
    case waitForDueHeight = "wait_for_due_height"
    case waitForConfirmation = "wait_for_confirmation"
    case waitForSubmissionResolution = "wait_for_submission_resolution"
    case reviewUpdatedIntentFee = "review_updated_intent_fee"
    case reviewUpdatedMigrationPlan = "review_updated_migration_plan"
    case resumeMigration = "resume_migration"
    case waitForCancellationSafety = "wait_for_cancellation_safety"
    case recover
    case none
}

/// How one high-level migration driver invocation completed. Callers render ``snapshot`` rather
/// than inferring durable state from the network result.
public enum MigrationExecutionDisposition: String, Equatable, Codable {
    /// The fresh snapshot did not authorize an SDK/background mutation.
    case noAction = "no_action"
    /// The network result was accepted by the engine using the claim's compare-and-set token.
    case resultRecorded = "result_recorded"
    /// The submit outcome is deliberately suppressed because it was ambiguous, cancellation was
    /// observed after networking began, or the claim token expired before the result could commit.
    /// The engine retains and later resumes its exact staged bytes.
    case verifying
}

/// Result of one snapshot-driven migration execution. It always includes a fresh authoritative
/// snapshot; `submissionResult` is absent when returning a stale network outcome could contradict
/// engine state.
public struct MigrationExecutionResult: Equatable, Codable {
    public let disposition: MigrationExecutionDisposition
    public let submissionResult: TransferResult?
    public let snapshot: MigrationSnapshot

    public init(
        disposition: MigrationExecutionDisposition,
        submissionResult: TransferResult?,
        snapshot: MigrationSnapshot
    ) {
        self.disposition = disposition
        self.submissionResult = submissionResult
        self.snapshot = snapshot
    }
}

/// Provenance of the wallet schema used by the migration engine.
public enum SchemaProvenance: String, Equatable, Codable {
    case compatible
    case forkIncompatibleSharedMigrationId = "fork_incompatible_shared_migration_id"
    case walletSchemaUnavailable = "wallet_schema_unavailable"
    /// SDK-only projection for a wallet written by a newer migration engine.
    case engineSchemaNewer = "engine_schema_newer"
}

/// Stable read-only metadata available even when a newer engine schema prevents context creation.
struct MigrationEngineSchemaMetadata: Equatable, Codable {
    let foundVersion: UInt32?
    let supportedVersion: UInt32
    let isNewer: Bool

    enum CodingKeys: String, CodingKey {
        case foundVersion = "found_version"
        case supportedVersion = "supported_version"
        case isNewer = "is_newer"
    }
}

/// Counts read in the same SQLite snapshot as ``MigrationSnapshot``.
public struct MigrationCounts: Equatable, Codable {
    public let preparedLocked: UInt32
    public let preparedSpentMigration: UInt32
    public let preparedSpentExternal: UInt32
    public let preparedReleased: UInt32
    public let intentsPlanned: UInt32
    public let intentsMaterializing: UInt32
    public let intentsStaged: UInt32
    public let intentsAwaitingSignature: UInt32
    public let intentsSubmitting: UInt32
    public let intentsOutcomeUnknown: UInt32
    public let intentsBroadcasted: UInt32
    public let intentsConfirmed: UInt32
    public let intentsRejected: UInt32
    public let intentsInvalidated: UInt32
    public let intentsFeeReapprovalRequired: UInt32
    public let intentsPlanReapprovalRequired: UInt32
    public let transfersScheduled: UInt32
    public let transfersSubmitting: UInt32
    public let transfersBroadcasted: UInt32
    public let transfersConfirmed: UInt32
    public let transfersTotal: UInt32

    public init(
        preparedLocked: UInt32,
        preparedSpentMigration: UInt32,
        preparedSpentExternal: UInt32,
        preparedReleased: UInt32,
        intentsPlanned: UInt32,
        intentsMaterializing: UInt32,
        intentsStaged: UInt32,
        intentsAwaitingSignature: UInt32,
        intentsRejected: UInt32,
        intentsInvalidated: UInt32,
        intentsFeeReapprovalRequired: UInt32,
        intentsPlanReapprovalRequired: UInt32,
        transfersScheduled: UInt32,
        transfersSubmitting: UInt32,
        transfersBroadcasted: UInt32,
        transfersConfirmed: UInt32,
        transfersTotal: UInt32,
        intentsSubmitting: UInt32 = 0,
        intentsOutcomeUnknown: UInt32 = 0,
        intentsBroadcasted: UInt32 = 0,
        intentsConfirmed: UInt32 = 0
    ) {
        self.preparedLocked = preparedLocked
        self.preparedSpentMigration = preparedSpentMigration
        self.preparedSpentExternal = preparedSpentExternal
        self.preparedReleased = preparedReleased
        self.intentsPlanned = intentsPlanned
        self.intentsMaterializing = intentsMaterializing
        self.intentsStaged = intentsStaged
        self.intentsAwaitingSignature = intentsAwaitingSignature
        self.intentsSubmitting = intentsSubmitting
        self.intentsOutcomeUnknown = intentsOutcomeUnknown
        self.intentsBroadcasted = intentsBroadcasted
        self.intentsConfirmed = intentsConfirmed
        self.intentsRejected = intentsRejected
        self.intentsInvalidated = intentsInvalidated
        self.intentsFeeReapprovalRequired = intentsFeeReapprovalRequired
        self.intentsPlanReapprovalRequired = intentsPlanReapprovalRequired
        self.transfersScheduled = transfersScheduled
        self.transfersSubmitting = transfersSubmitting
        self.transfersBroadcasted = transfersBroadcasted
        self.transfersConfirmed = transfersConfirmed
        self.transfersTotal = transfersTotal
    }

    enum CodingKeys: String, CodingKey {
        case preparedLocked = "prepared_locked"
        case preparedSpentMigration = "prepared_spent_migration"
        case preparedSpentExternal = "prepared_spent_external"
        case preparedReleased = "prepared_released"
        case intentsPlanned = "intents_planned"
        case intentsMaterializing = "intents_materializing"
        case intentsStaged = "intents_staged"
        case intentsAwaitingSignature = "intents_awaiting_signature"
        case intentsSubmitting = "intents_submitting"
        case intentsOutcomeUnknown = "intents_outcome_unknown"
        case intentsBroadcasted = "intents_broadcasted"
        case intentsConfirmed = "intents_confirmed"
        case intentsRejected = "intents_rejected"
        case intentsInvalidated = "intents_invalidated"
        case intentsFeeReapprovalRequired = "intents_fee_reapproval_required"
        case intentsPlanReapprovalRequired = "intents_plan_reapproval_required"
        case transfersScheduled = "transfers_scheduled"
        case transfersSubmitting = "transfers_submitting"
        case transfersBroadcasted = "transfers_broadcasted"
        case transfersConfirmed = "transfers_confirmed"
        case transfersTotal = "transfers_total"
    }
}

/// Durable state of one user-approved migration intent. Unknown future statuses intentionally fail
/// decoding so an older app cannot present a new engine state as a familiar one.
public enum MigrationIntentStatus: String, Equatable, Codable {
    case planned
    case materializing
    case staged
    case awaitingSignature = "awaiting_signature"
    case submitting
    case outcomeUnknown = "outcome_unknown"
    case broadcasted
    case confirmed
    case rejected
    case invalidated
    case invalidatedExternal = "invalidated_external"
    case feeReapprovalRequired = "fee_reapproval_required"
    case planReapprovalRequired = "plan_reapproval_required"
}

/// Sanitized UI projection of one durable intent, read atomically with ``MigrationSnapshot``.
/// Transaction ids, note references, PCZT bytes, anchors, claim tokens, and leases remain
/// engine-private.
public struct MigrationIntentSummary: Equatable, Codable {
    public let id: String
    public let sequenceIndex: UInt32
    public let amount: UInt64
    /// Exact fee the user previously approved for this intent.
    public let fee: UInt64
    /// Fresh exact fee requiring approval when status is ``feeReapprovalRequired``.
    public let requiredFee: UInt64?
    public let notBeforeHeight: UInt32
    public let targetWindowEndHeight: UInt32
    public let materializedExpiryHeight: UInt32?
    public let status: MigrationIntentStatus

    public init(
        id: String,
        sequenceIndex: UInt32,
        amount: UInt64,
        fee: UInt64,
        requiredFee: UInt64?,
        notBeforeHeight: UInt32,
        targetWindowEndHeight: UInt32,
        materializedExpiryHeight: UInt32?,
        status: MigrationIntentStatus
    ) {
        self.id = id
        self.sequenceIndex = sequenceIndex
        self.amount = amount
        self.fee = fee
        self.requiredFee = requiredFee
        self.notBeforeHeight = notBeforeHeight
        self.targetWindowEndHeight = targetWindowEndHeight
        self.materializedExpiryHeight = materializedExpiryHeight
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sequenceIndex = "sequence_index"
        case amount
        case fee
        case requiredFee = "required_fee"
        case notBeforeHeight = "not_before_height"
        case targetWindowEndHeight = "target_window_end_height"
        case materializedExpiryHeight = "materialized_expiry_height"
        case status
    }
}

/// One authoritative, revisioned read of migration state and its next safe operation.
public struct MigrationSnapshot: Equatable, Codable {
    /// Current Rust/Swift snapshot schema understood by this SDK build.
    public static let supportedSchemaVersion: UInt32 = 4

    public let schemaVersion: UInt32
    public let revision: UInt64
    public let runId: String?
    public let accountUuid: String
    public let network: String
    public let consensusFingerprint: String
    public let mode: MigrationRunMode?
    public let phase: MigrationPhase?
    public let state: MigrationState
    public let counts: MigrationCounts
    public let intents: [MigrationIntentSummary]
    public let nextDueHeight: UInt32?
    public let nextExpiryHeight: UInt32?
    public let failureCode: MigrationFailureCode?
    public let recoveryAction: RecoveryAction?
    public let nextAction: NextAction
    public let externalSigner: Bool
    public let ordinarySpendsBlocked: Bool
    public let schemaProvenance: SchemaProvenance
    public let submissionPolicy: BoundSubmissionPolicy?

    public init(
        schemaVersion: UInt32,
        revision: UInt64,
        runId: String?,
        accountUuid: String,
        network: String,
        mode: MigrationRunMode?,
        phase: MigrationPhase?,
        state: MigrationState,
        counts: MigrationCounts,
        intents: [MigrationIntentSummary],
        nextDueHeight: UInt32?,
        nextExpiryHeight: UInt32?,
        failureCode: MigrationFailureCode?,
        recoveryAction: RecoveryAction?,
        nextAction: NextAction,
        externalSigner: Bool,
        ordinarySpendsBlocked: Bool,
        schemaProvenance: SchemaProvenance,
        consensusFingerprint: String = "",
        submissionPolicy: BoundSubmissionPolicy? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.runId = runId
        self.accountUuid = accountUuid
        self.network = network
        self.consensusFingerprint = consensusFingerprint
        self.mode = mode
        self.phase = phase
        self.state = state
        self.counts = counts
        self.intents = intents
        self.nextDueHeight = nextDueHeight
        self.nextExpiryHeight = nextExpiryHeight
        self.failureCode = failureCode
        self.recoveryAction = recoveryAction
        self.nextAction = nextAction
        self.externalSigner = externalSigner
        self.ordinarySpendsBlocked = ordinarySpendsBlocked
        self.schemaProvenance = schemaProvenance
        self.submissionPolicy = submissionPolicy
    }

    /// Fail-closed projection used when the wallet was written by a newer migration engine. It is
    /// safe to render but never actionable: ordinary spending stays blocked and the background
    /// driver receives ``NextAction/none`` until the app is updated.
    public static func appUpdateRequired(
        foundSchemaVersion: UInt32,
        accountUuid: String,
        network: String
    ) -> Self {
        Self(
            schemaVersion: foundSchemaVersion,
            revision: 0,
            runId: nil,
            accountUuid: accountUuid,
            network: network,
            mode: nil,
            phase: nil,
            state: .requiresAttention(.appUpdateRequired),
            counts: MigrationCounts(
                preparedLocked: 0,
                preparedSpentMigration: 0,
                preparedSpentExternal: 0,
                preparedReleased: 0,
                intentsPlanned: 0,
                intentsMaterializing: 0,
                intentsStaged: 0,
                intentsAwaitingSignature: 0,
                intentsRejected: 0,
                intentsInvalidated: 0,
                intentsFeeReapprovalRequired: 0,
                intentsPlanReapprovalRequired: 0,
                transfersScheduled: 0,
                transfersSubmitting: 0,
                transfersBroadcasted: 0,
                transfersConfirmed: 0,
                transfersTotal: 0
            ),
            intents: [],
            nextDueHeight: nil,
            nextExpiryHeight: nil,
            failureCode: .appUpdateRequired,
            recoveryAction: .updateApp,
            nextAction: .none,
            externalSigner: false,
            ordinarySpendsBlocked: true,
            schemaProvenance: .engineSchemaNewer,
            consensusFingerprint: "",
            submissionPolicy: nil
        )
    }

    /// SDK-only fail-closed projection for a wallet snapshot that could not be read, decoded, or
    /// structurally validated. It preserves wallet identity for rendering/telemetry but deliberately
    /// carries no run identity or executable action, so callers can never fall back to a stale
    /// runnable cache while the authoritative store is unavailable.
    public static func unavailable(
        accountUuid: String,
        network: String,
        consensusFingerprint: String
    ) -> Self {
        Self(
            schemaVersion: supportedSchemaVersion,
            revision: 0,
            runId: nil,
            accountUuid: accountUuid,
            network: network,
            mode: nil,
            phase: nil,
            state: .requiresAttention(.recoveryRequired),
            counts: MigrationCounts(
                preparedLocked: 0,
                preparedSpentMigration: 0,
                preparedSpentExternal: 0,
                preparedReleased: 0,
                intentsPlanned: 0,
                intentsMaterializing: 0,
                intentsStaged: 0,
                intentsAwaitingSignature: 0,
                intentsRejected: 0,
                intentsInvalidated: 0,
                intentsFeeReapprovalRequired: 0,
                intentsPlanReapprovalRequired: 0,
                transfersScheduled: 0,
                transfersSubmitting: 0,
                transfersBroadcasted: 0,
                transfersConfirmed: 0,
                transfersTotal: 0
            ),
            intents: [],
            nextDueHeight: nil,
            nextExpiryHeight: nil,
            failureCode: .persistenceFailure,
            recoveryAction: .retryAutomatically,
            nextAction: .none,
            externalSigner: false,
            ordinarySpendsBlocked: true,
            schemaProvenance: .walletSchemaUnavailable,
            consensusFingerprint: consensusFingerprint,
            submissionPolicy: nil
        )
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case revision
        case runId = "run_id"
        case accountUuid = "account_uuid"
        case network
        case consensusFingerprint = "consensus_fingerprint"
        case mode
        case phase
        case state
        case counts
        case intents
        case nextDueHeight = "next_due_height"
        case nextExpiryHeight = "next_expiry_height"
        case failureCode = "failure_code"
        case recoveryAction = "recovery_action"
        case nextAction = "next_action"
        case externalSigner = "external_signer"
        case ordinarySpendsBlocked = "ordinary_spends_blocked"
        case schemaProvenance = "schema_provenance"
        case submissionPolicy = "submission_policy"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(UInt32.self, forKey: .schemaVersion)
        if schemaVersion > Self.supportedSchemaVersion {
            self = .appUpdateRequired(
                foundSchemaVersion: schemaVersion,
                accountUuid: try container.decodeIfPresent(String.self, forKey: .accountUuid) ?? "unknown",
                network: try container.decodeIfPresent(String.self, forKey: .network) ?? "unknown"
            )
            return
        }

        self.init(
            schemaVersion: schemaVersion,
            revision: try container.decode(UInt64.self, forKey: .revision),
            runId: try container.decodeIfPresent(String.self, forKey: .runId),
            accountUuid: try container.decode(String.self, forKey: .accountUuid),
            network: try container.decode(String.self, forKey: .network),
            mode: try container.decodeIfPresent(MigrationRunMode.self, forKey: .mode),
            phase: try container.decodeIfPresent(MigrationPhase.self, forKey: .phase),
            state: try container.decode(MigrationState.self, forKey: .state),
            counts: try container.decode(MigrationCounts.self, forKey: .counts),
            intents: try container.decode([MigrationIntentSummary].self, forKey: .intents),
            nextDueHeight: try container.decodeIfPresent(UInt32.self, forKey: .nextDueHeight),
            nextExpiryHeight: try container.decodeIfPresent(UInt32.self, forKey: .nextExpiryHeight),
            failureCode: try container.decodeIfPresent(MigrationFailureCode.self, forKey: .failureCode),
            recoveryAction: try container.decodeIfPresent(RecoveryAction.self, forKey: .recoveryAction),
            nextAction: try container.decode(NextAction.self, forKey: .nextAction),
            externalSigner: try container.decode(Bool.self, forKey: .externalSigner),
            ordinarySpendsBlocked: try container.decode(Bool.self, forKey: .ordinarySpendsBlocked),
            schemaProvenance: try container.decode(SchemaProvenance.self, forKey: .schemaProvenance),
            consensusFingerprint: try container.decode(String.self, forKey: .consensusFingerprint),
            submissionPolicy: try container.decodeIfPresent(BoundSubmissionPolicy.self, forKey: .submissionPolicy)
        )
    }
}

/// A decoded engine snapshot was self-contradictory or did not belong to the requested wallet
/// identity. Callers must treat this as corruption: never cache, render as operational, or execute
/// an action from the rejected value.
public enum MigrationSnapshotValidationError: Error, Equatable {
    case identityMismatch
    case schemaMismatch(found: UInt32)
    case consensusMismatch
    case invalidFutureSchemaProjection
    case invariantViolation(String)
}

extension MigrationSnapshot {
    /// Defensively validates the complete v4 wire snapshot before any UI/background consumer sees
    /// it. A newer schema is converted to the single fail-closed app-update projection; every
    /// compatible schema violation is rejected as typed corruption.
    // Validation deliberately enumerates the complete untrusted wire-state matrix in one choke point.
    // swiftlint:disable:next cyclomatic_complexity
    func validated(
        accountUuid expectedAccountUuid: String,
        network expectedNetwork: String,
        consensusFingerprint expectedConsensusFingerprint: String
    ) throws -> Self {
        if schemaProvenance == .engineSchemaNewer {
            guard schemaVersion > Self.supportedSchemaVersion,
                  case .requiresAttention(.appUpdateRequired) = state,
                  failureCode == .appUpdateRequired,
                  recoveryAction == .updateApp,
                  nextAction == .none,
                  ordinarySpendsBlocked,
                  runId == nil,
                  mode == nil,
                  phase == nil,
                  submissionPolicy == nil,
                  intents.isEmpty else {
                throw MigrationSnapshotValidationError.invalidFutureSchemaProjection
            }
            return .appUpdateRequired(
                foundSchemaVersion: schemaVersion,
                accountUuid: expectedAccountUuid,
                network: expectedNetwork
            )
        }

        guard schemaVersion == Self.supportedSchemaVersion else {
            throw MigrationSnapshotValidationError.schemaMismatch(found: schemaVersion)
        }
        guard accountUuid == expectedAccountUuid,
              network == expectedNetwork,
              Self.isCanonicalUuid(accountUuid) else {
            throw MigrationSnapshotValidationError.identityMismatch
        }
        guard consensusFingerprint == expectedConsensusFingerprint,
              Self.isLowercaseSha256(consensusFingerprint) else {
            throw MigrationSnapshotValidationError.consensusMismatch
        }

        let fail: (String) throws -> Never = { rule in
            throw MigrationSnapshotValidationError.invariantViolation(rule)
        }
        let hasRun = runId != nil
        guard hasRun == (mode != nil), hasRun == (phase != nil) else {
            try fail("run_mode_phase_coherence")
        }

        if !hasRun {
            guard revision == 0,
                  counts.isAllZero,
                  intents.isEmpty,
                  nextDueHeight == nil,
                  nextExpiryHeight == nil,
                  !externalSigner,
                  submissionPolicy == nil else {
                try fail("no_run_is_empty")
            }
            switch schemaProvenance {
            case .compatible:
                guard state == .notStarted,
                      failureCode == nil,
                      recoveryAction == nil,
                      nextAction == .awaitUserChoice,
                      !ordinarySpendsBlocked else {
                    try fail("compatible_no_run_projection")
                }
            case .walletSchemaUnavailable:
                let engineInitializationProjection = state == .notStarted
                    && failureCode == nil
                    && recoveryAction == nil
                    && nextAction == .initialize
                    && ordinarySpendsBlocked
                let sdkUnavailableProjection = state == .requiresAttention(.recoveryRequired)
                    && failureCode == .persistenceFailure
                    && recoveryAction == .retryAutomatically
                    && nextAction == .none
                    && ordinarySpendsBlocked
                guard engineInitializationProjection || sdkUnavailableProjection else {
                    try fail("unavailable_schema_projection")
                }
            case .forkIncompatibleSharedMigrationId:
                guard state == .requiresAttention(.schemaIncompatible),
                      failureCode == .schemaIncompatible,
                      recoveryAction == .wipeAndRescanTestnet,
                      nextAction == .recover,
                      ordinarySpendsBlocked else {
                    try fail("incompatible_schema_projection")
                }
            case .engineSchemaNewer:
                try fail("future_schema_already_handled")
            }
            return self
        }

        guard revision > 0,
              let runId,
              Self.isCanonicalUuid(runId),
              let phase,
              mode != nil else {
            try fail("run_identity")
        }

        if let submissionPolicy {
            guard submissionPolicy.revision > 0,
                  submissionPolicy.revision <= revision,
                  submissionPolicy.policy.consensusFingerprint == consensusFingerprint,
                  Self.isLowercaseSha256(submissionPolicy.policyFingerprint),
                  Self.submissionPolicyFingerprint(submissionPolicy.policy) == submissionPolicy.policyFingerprint else {
                try fail("submission_policy_binding")
            }
        }

        let sorted = intents.sorted { $0.sequenceIndex < $1.sequenceIndex }
        guard sorted == intents else {
            try fail("intent_order")
        }
        var seenIds = Set<String>()
        for (offset, intent) in intents.enumerated() {
            let runPrefix = "\(runId)-"
            let isEngineIntentId = intent.id.hasPrefix(runPrefix)
                && intent.id.count > runPrefix.count
            guard intent.sequenceIndex == UInt32(offset),
                  isEngineIntentId,
                  seenIds.insert(intent.id).inserted,
                  intent.amount > 0,
                  intent.fee > 0,
                  intent.targetWindowEndHeight >= intent.notBeforeHeight,
                  (intent.status == .feeReapprovalRequired) == (intent.requiredFee != nil),
                  intent.requiredFee.map({ $0 > 0 }) ?? true else {
                try fail("intent_structure")
            }
            if let expiry = intent.materializedExpiryHeight,
               expiry <= intent.notBeforeHeight {
                try fail("intent_expiry_order")
            }
        }

        let statusCount: (MigrationIntentStatus) -> UInt32 = { status in
            UInt32(self.intents.lazy.filter { $0.status == status }.count)
        }
        guard statusCount(.planned) == counts.intentsPlanned,
              statusCount(.materializing) == counts.intentsMaterializing,
              statusCount(.staged) == counts.intentsStaged,
              statusCount(.awaitingSignature) == counts.intentsAwaitingSignature,
              statusCount(.submitting) == counts.intentsSubmitting,
              statusCount(.outcomeUnknown) == counts.intentsOutcomeUnknown,
              statusCount(.broadcasted) == counts.intentsBroadcasted,
              statusCount(.confirmed) == counts.intentsConfirmed,
              statusCount(.rejected) == counts.intentsRejected,
              statusCount(.invalidated) + statusCount(.invalidatedExternal) == counts.intentsInvalidated,
              statusCount(.feeReapprovalRequired) == counts.intentsFeeReapprovalRequired,
              statusCount(.planReapprovalRequired) == counts.intentsPlanReapprovalRequired else {
            try fail("intent_status_counts_exact")
        }

        let intentTotal = UInt64(intents.count)
        let classifiedTransferTotal = UInt64(counts.transfersScheduled)
            + UInt64(counts.transfersSubmitting)
            + UInt64(counts.transfersBroadcasted)
            + UInt64(counts.transfersConfirmed)
        guard intentTotal <= UInt64(counts.transfersTotal),
              classifiedTransferTotal <= UInt64(counts.transfersTotal),
              counts.transfersConfirmed <= counts.transfersTotal,
              counts.transfersSubmitting <= counts.transfersTotal,
              counts.transfersBroadcasted <= counts.transfersTotal else {
            try fail("transfer_counts_bounded")
        }

        guard (failureCode == nil) == (recoveryAction == nil) else {
            try fail("failure_recovery_pair")
        }
        if failureCode == .approvedFeeChanged {
            guard recoveryAction == .requireUserReapproval,
                  counts.intentsFeeReapprovalRequired > 0 else {
                try fail("fee_reapproval_failure")
            }
        }
        if failureCode == .planSemanticsChanged {
            guard recoveryAction == .requireUserReapproval,
                  counts.intentsPlanReapprovalRequired > 0 else {
                try fail("plan_reapproval_failure")
            }
        }

        if schemaProvenance == .forkIncompatibleSharedMigrationId {
            guard state == .requiresAttention(.schemaIncompatible),
                  failureCode == .schemaIncompatible,
                  recoveryAction == .wipeAndRescanTestnet,
                  nextAction == .recover,
                  ordinarySpendsBlocked else {
                try fail("incompatible_schema_projection")
            }
        } else {
            guard schemaProvenance == .compatible else {
                try fail("run_schema_provenance")
            }
            guard Self.state(state, matches: phase, counts: counts, nextDueHeight: nextDueHeight) else {
                try fail("phase_state")
            }
            guard Self.action(nextAction, isAllowedFor: phase, snapshot: self) else {
                try fail("phase_next_action")
            }
        }

        let terminal = phase == .complete || phase == .abandoned
        if terminal {
            guard (schemaProvenance != .compatible || !ordinarySpendsBlocked),
                  counts.preparedLocked == 0,
                  counts.transfersSubmitting == 0,
                  counts.transfersBroadcasted == 0,
                  counts.intentsMaterializing == 0,
                  counts.intentsStaged == 0,
                  counts.intentsAwaitingSignature == 0,
                  counts.intentsSubmitting == 0,
                  counts.intentsOutcomeUnknown == 0 else {
                try fail("terminal_has_no_live_work")
            }
        } else if schemaProvenance == .compatible && !ordinarySpendsBlocked {
            try fail("active_run_blocks_ordinary_spends")
        }
        if phase == .complete {
            guard counts.transfersTotal > 0,
                  counts.transfersConfirmed == counts.transfersTotal,
                  counts.preparedSpentExternal == 0,
                  counts.intentsRejected == 0,
                  counts.intentsInvalidated == 0,
                  counts.intentsFeeReapprovalRequired == 0,
                  counts.intentsPlanReapprovalRequired == 0 else {
                try fail("complete_has_full_positive_crossing_evidence")
            }
        }

        let dueIntents = intents.filter {
            [.planned, .materializing, .staged, .submitting, .outcomeUnknown].contains($0.status)
        }
        if let minimumIntentDue = dueIntents.map(\.notBeforeHeight).min() {
            guard let nextDueHeight, nextDueHeight <= minimumIntentDue else {
                try fail("next_due_height")
            }
        }
        let expiringIntents = intents.compactMap { intent -> UInt32? in
            guard [
                MigrationIntentStatus.staged,
                .awaitingSignature,
                .submitting,
                .outcomeUnknown,
                .broadcasted,
                .rejected,
                .invalidated
            ].contains(intent.status) else { return nil }
            return intent.materializedExpiryHeight
        }
        if let minimumIntentExpiry = expiringIntents.min() {
            guard let nextExpiryHeight, nextExpiryHeight <= minimumIntentExpiry else {
                try fail("next_expiry_height")
            }
        }

        let hasArtifact = counts.preparedLocked > 0
            || counts.preparedSpentMigration > 0
            || counts.preparedSpentExternal > 0
            || counts.transfersScheduled > 0
            || counts.transfersSubmitting > 0
            || counts.transfersBroadcasted > 0
            || counts.transfersConfirmed > 0
            || counts.intentsMaterializing > 0
            || counts.intentsStaged > 0
            || counts.intentsAwaitingSignature > 0
            || counts.intentsSubmitting > 0
            || counts.intentsOutcomeUnknown > 0
            || counts.intentsBroadcasted > 0
            || counts.intentsConfirmed > 0
            || counts.intentsRejected > 0
            || counts.intentsInvalidated > 0
            || [.preparingDenominations, .waitingDenomConfirmations, .readyToMigrate, .complete].contains(phase)
        // Schema-v4 upgrades project an active legacy run that already owns transaction bytes but
        // predates submission-policy persistence into one exact, fail-closed repair state. It may
        // be decoded so the UI can explain the durable recovery action, but no execution path may
        // claim or submit from it until a revisioned policy bind succeeds. Completed/abandoned
        // legacy runs are inert and likewise do not need a retroactive transport policy.
        let firstBindActionIsExact: Bool
        if phase == .paused {
            firstBindActionIsExact = nextAction == .resumeMigration
        } else if phase == .abandoning {
            firstBindActionIsExact = nextAction == .waitForCancellationSafety
        } else if counts.intentsFeeReapprovalRequired > 0 {
            firstBindActionIsExact = nextAction == .reviewUpdatedIntentFee
        } else if counts.intentsPlanReapprovalRequired > 0 {
            firstBindActionIsExact = nextAction == .reviewUpdatedMigrationPlan
        } else {
            firstBindActionIsExact = nextAction == .recover
        }
        let policylessFirstBindRepair = failureCode == .submissionPolicyMismatch
            && recoveryAction == .requireUserReapproval
            && ordinarySpendsBlocked
            && firstBindActionIsExact
        let policylessChainResolution = failureCode == .submissionPolicyMismatch
            && recoveryAction == .waitForSubmissionResolution
            && ordinarySpendsBlocked
            && (
                (phase == .failedRecoverable
                    && state == .requiresAttention(.recoveryRequired)
                    && nextAction == .waitForSubmissionResolution)
                    || (phase == .paused && nextAction == .resumeMigration)
                    || (phase == .abandoning && nextAction == .waitForCancellationSafety)
            )
        let policylessLegacyRepair = policylessFirstBindRepair || policylessChainResolution
        if hasArtifact && submissionPolicy == nil && !terminal && !policylessLegacyRepair {
            try fail("artifact_requires_submission_policy")
        }
        return self
    }

    private static func isCanonicalUuid(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func isLowercaseSha256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains($0)
        }
    }

    private static func submissionPolicyFingerprint(_ policy: SubmissionPolicy) -> String? {
        guard isLowercaseSha256(policy.consensusFingerprint),
              let consensus = Data(hexEncoded: policy.consensusFingerprint),
              consensus.count == 32 else { return nil }
        let endpoint = Data(policy.endpointIdentity.utf8)
        guard !endpoint.isEmpty,
              endpoint.count <= Int(UInt16.max),
              policy.endpointIdentity == policy.endpointIdentity.trimmingCharacters(in: .whitespacesAndNewlines),
              endpoint.allSatisfy({ (0x21 ... 0x7e).contains($0) }) else {
            return nil
        }
        var encoded = Data("zend-submission-policy-v1\0".utf8)
        encoded.append(policy.transport == .tor ? 0 : 1)
        encoded.append(consensus)
        var endpointLength = UInt16(endpoint.count).bigEndian
        withUnsafeBytes(of: &endpointLength) { encoded.append(contentsOf: $0) }
        encoded.append(endpoint)
        return Data(SHA256.hash(data: encoded)).hexEncodedString()
    }

    private static func state(
        _ state: MigrationState,
        matches phase: MigrationPhase,
        counts: MigrationCounts,
        nextDueHeight: UInt32?
    ) -> Bool {
        switch phase {
        case .noOrchardFunds, .waitingForSpendableOrchard, .readyToPrepare, .abandoned:
            return state == .notStarted
        case .preparingDenominations, .waitingDenomConfirmations:
            return state == .splitPendingConfirmation
        case .readyToMigrate:
            return state == .readyToPropose
        case .broadcastScheduled, .broadcasting, .waitingMigrationConfirmations, .paused, .abandoning:
            guard case .inProgress(let progress) = state else { return false }
            return progress.completedTransfers == counts.transfersConfirmed
                && progress.totalTransfers == counts.transfersTotal
                && progress.nextTransferReadyAtHeight == nextDueHeight
        case .complete:
            return state == .complete
        case .failedRecoverable, .failedTerminal:
            guard case .requiresAttention = state else { return false }
            return true
        }
    }

    // This is the exhaustive phase/action authorization matrix; splitting it risks inconsistent gates.
    // swiftlint:disable:next cyclomatic_complexity
    private static func action(
        _ action: NextAction,
        isAllowedFor phase: MigrationPhase,
        snapshot: MigrationSnapshot
    ) -> Bool {
        switch action {
        case .initialize:
            return false
        case .awaitUserChoice:
            return phase == .abandoned
        case .waitForSync:
            return [.noOrchardFunds, .waitingForSpendableOrchard].contains(phase)
                || snapshot.recoveryAction == .waitForSync
        case .preparePrivateSplit:
            return snapshot.mode == .privateScheduled
                && [.readyToPrepare, .preparingDenominations].contains(phase)
        case .stageNoteSplitExternalSignature:
            return snapshot.mode == .privateScheduled
                && [.readyToPrepare, .preparingDenominations].contains(phase)
                && snapshot.externalSigner
        case .waitForSplitConfirmation:
            return phase == .waitingDenomConfirmations
        case .proposePrivateSchedule:
            return phase == .readyToMigrate && snapshot.mode == .privateScheduled
        case .materializeDueTransaction:
            return [.broadcastScheduled, .broadcasting].contains(phase) && !snapshot.externalSigner
        case .stageDueExternalSignature:
            return [.broadcastScheduled, .broadcasting].contains(phase) && snapshot.externalSigner
        case .resumeStagedSubmission:
            return snapshot.counts.intentsStaged > 0
                || snapshot.counts.intentsSubmitting > 0
                || snapshot.counts.intentsOutcomeUnknown > 0
                || snapshot.counts.transfersSubmitting > 0
        case .waitForWorkerLease:
            return snapshot.counts.intentsMaterializing > 0
        case .awaitExternalSignature:
            return snapshot.externalSigner
                && (
                    snapshot.counts.intentsAwaitingSignature > 0
                        || snapshot.counts.intentsStaged > 0
                        // A staged note-split PCZT lives in the dedicated prep table, so schema v4
                        // has no intent count that can expose it. This narrow phase/mode projection
                        // is what the engine emits after a process dies before external signing;
                        // the revisioned resume API still proves the exact durable row/token.
                        || (snapshot.mode == .privateScheduled && phase == .preparingDenominations)
                )
        case .claimDueTransaction:
            return [.preparingDenominations, .broadcastScheduled, .broadcasting].contains(phase)
        case .waitForDueHeight:
            return [.broadcastScheduled, .broadcasting].contains(phase)
        case .waitForConfirmation:
            return [.waitingDenomConfirmations, .broadcastScheduled, .broadcasting, .waitingMigrationConfirmations].contains(phase)
        case .waitForSubmissionResolution:
            return snapshot.recoveryAction == .waitForSubmissionResolution
                || snapshot.counts.intentsOutcomeUnknown > 0
                || snapshot.counts.intentsSubmitting > 0
                || snapshot.counts.transfersSubmitting > 0
                // The denomination-split claim is stored outside intent/pending-transfer counts.
                // A live prep submission therefore has no count bit in schema v4; the exact phase
                // is the narrow projection emitted until its lease/result resolves.
                || (snapshot.mode == .privateScheduled && phase == .preparingDenominations)
        case .reviewUpdatedIntentFee:
            return snapshot.recoveryAction == .requireUserReapproval
                && (
                    snapshot.failureCode == .approvedFeeChanged
                        || (snapshot.failureCode == .submissionPolicyMismatch
                            && snapshot.submissionPolicy == nil
                            && snapshot.counts.intentsFeeReapprovalRequired > 0)
                )
        case .reviewUpdatedMigrationPlan:
            return snapshot.recoveryAction == .requireUserReapproval
                && (
                    snapshot.failureCode == .planSemanticsChanged
                        || (snapshot.failureCode == .submissionPolicyMismatch
                            && snapshot.submissionPolicy == nil
                            && snapshot.counts.intentsPlanReapprovalRequired > 0)
                )
        case .resumeMigration:
            return phase == .paused
        case .waitForCancellationSafety:
            return phase == .abandoning
        case .recover:
            guard snapshot.failureCode != nil,
                  let recoveryAction = snapshot.recoveryAction,
                  [
                      RecoveryAction.rebuildSchedule,
                      .recreateTransaction,
                      .contactSupport,
                      .requireUserReapproval
                  ].contains(recoveryAction),
                  ![.paused, .abandoning, .abandoned, .complete].contains(phase) else {
                return false
            }
            // Fee/plan review has higher engine precedence than the generic recovery surface.
            return recoveryAction != .requireUserReapproval
                || (snapshot.counts.intentsFeeReapprovalRequired == 0
                    && snapshot.counts.intentsPlanReapprovalRequired == 0)
        case .none:
            return phase == .complete
        }
    }
}

private extension MigrationCounts {
    var isAllZero: Bool {
        self == MigrationCounts(
            preparedLocked: 0,
            preparedSpentMigration: 0,
            preparedSpentExternal: 0,
            preparedReleased: 0,
            intentsPlanned: 0,
            intentsMaterializing: 0,
            intentsStaged: 0,
            intentsAwaitingSignature: 0,
            intentsRejected: 0,
            intentsInvalidated: 0,
            intentsFeeReapprovalRequired: 0,
            intentsPlanReapprovalRequired: 0,
            transfersScheduled: 0,
            transfersSubmitting: 0,
            transfersBroadcasted: 0,
            transfersConfirmed: 0,
            transfersTotal: 0
        )
    }
}

/// A signed transaction atomically leased to one submission attempt.
public struct ClaimedTx: Equatable, Codable {
    public let id: String
    public let txid: String
    public let rawPczt: [UInt8]
    public let attemptToken: String
    public let leaseExpiresAtMs: UInt64
    /// Consensus expiry parsed from the exact signed transaction. Rust repairs legacy rows before
    /// claim, so the SDK never guesses or submits a missing value.
    public let expiryHeight: UInt32
    public let submissionPolicy: BoundSubmissionPolicy

    public init(
        id: String,
        txid: String,
        rawPczt: [UInt8],
        attemptToken: String,
        leaseExpiresAtMs: UInt64,
        expiryHeight: UInt32,
        submissionPolicy: BoundSubmissionPolicy
    ) {
        self.id = id
        self.txid = txid
        self.rawPczt = rawPczt
        self.attemptToken = attemptToken
        self.leaseExpiresAtMs = leaseExpiresAtMs
        self.expiryHeight = expiryHeight
        self.submissionPolicy = submissionPolicy
    }

    enum CodingKeys: String, CodingKey {
        case id
        case txid
        case rawPczt = "raw_pczt"
        case attemptToken = "attempt_token"
        case leaseExpiresAtMs = "lease_expires_at_ms"
        case expiryHeight = "expiry_height"
        case submissionPolicy = "submission_policy"
    }
}

/// One proven-but-unsigned denomination split bound to an exact external-signer round.
public struct ClaimedNoteSplitPCZT: Equatable, Codable {
    public let runId: String
    public let pczt: Pczt
    /// Wire name remains `attempt_token`; semantically this is a signer token and is never valid
    /// for network result callbacks.
    public let signerToken: String
    public let anchorHeight: UInt32
    public let expiryHeight: UInt32
    public let submissionPolicy: BoundSubmissionPolicy

    public init(
        runId: String,
        pczt: Pczt,
        signerToken: String,
        anchorHeight: UInt32,
        expiryHeight: UInt32,
        submissionPolicy: BoundSubmissionPolicy
    ) {
        self.runId = runId
        self.pczt = pczt
        self.signerToken = signerToken
        self.anchorHeight = anchorHeight
        self.expiryHeight = expiryHeight
        self.submissionPolicy = submissionPolicy
    }

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case pczt = "raw_pczt"
        case signerToken = "attempt_token"
        case anchorHeight = "anchor_height"
        case expiryHeight = "expiry_height"
        case submissionPolicy = "submission_policy"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runId = try container.decode(String.self, forKey: .runId)
        pczt = Pczt(try container.decode([UInt8].self, forKey: .pczt))
        signerToken = try container.decode(String.self, forKey: .signerToken)
        anchorHeight = try container.decode(UInt32.self, forKey: .anchorHeight)
        expiryHeight = try container.decode(UInt32.self, forKey: .expiryHeight)
        submissionPolicy = try container.decode(BoundSubmissionPolicy.self, forKey: .submissionPolicy)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runId, forKey: .runId)
        try container.encode([UInt8](pczt), forKey: .pczt)
        try container.encode(signerToken, forKey: .signerToken)
        try container.encode(anchorHeight, forKey: .anchorHeight)
        try container.encode(expiryHeight, forKey: .expiryHeight)
        try container.encode(submissionPolicy, forKey: .submissionPolicy)
    }
}

/// A submission attempt ended before any transport call could expose the exact bytes.
public enum KnownUnsentReason: String, Equatable, Codable, Sendable {
    case cancelledBeforeTransport = "cancelled_before_transport"
    case transportSetupFailed = "transport_setup_failed"
    case insufficientLeaseBudget = "insufficient_lease_budget"
    case endpointConsensusMismatch = "endpoint_consensus_mismatch"
    case submissionPolicyMismatch = "submission_policy_mismatch"
    case transactionBranchNotCurrent = "transaction_branch_not_current"
    case transactionExpiryWindowClosed = "transaction_expiry_window_closed"
}

/// A local integrity failure quarantines exact bytes and never enters automatic network retry.
public enum LocalSubmissionFailure: String, Equatable, Codable, Sendable {
    case malformedPczt = "malformed_pczt"
    case txidMismatch = "txid_mismatch"
    case signerMismatch = "signer_mismatch"
    case persistenceFailure = "persistence_failure"
}

/// Consensus bytes extracted from a signed PCZT together with the transaction id recomputed by
/// librustzcash from those exact bytes. The SDK compares this id with the engine claim before any
/// network submission.
public struct ExtractedTx: Equatable, Codable {
    public let txid: String
    public let rawTx: [UInt8]
    public let consensusBranchId: UInt32
    public let expiryHeight: UInt32

    public init(txid: String, rawTx: [UInt8], consensusBranchId: UInt32, expiryHeight: UInt32) {
        self.txid = txid
        self.rawTx = rawTx
        self.consensusBranchId = consensusBranchId
        self.expiryHeight = expiryHeight
    }

    enum CodingKeys: String, CodingKey {
        case txid
        case rawTx = "raw_tx"
        case consensusBranchId = "consensus_branch_id"
        case expiryHeight = "expiry_height"
    }
}

/// One due, proven-but-unsigned intent leased for an external signer round-trip.
public struct ClaimedTransferPCZT: Equatable, Codable {
    public let intentId: String
    public let pczt: Pczt
    public let signerToken: String
    public let leaseExpiresAtMs: UInt64
    public let expiryHeight: UInt32
    public let submissionPolicy: BoundSubmissionPolicy

    public init(
        intentId: String,
        pczt: Pczt,
        signerToken: String,
        leaseExpiresAtMs: UInt64,
        expiryHeight: UInt32,
        submissionPolicy: BoundSubmissionPolicy
    ) {
        self.intentId = intentId
        self.pczt = pczt
        self.signerToken = signerToken
        self.leaseExpiresAtMs = leaseExpiresAtMs
        self.expiryHeight = expiryHeight
        self.submissionPolicy = submissionPolicy
    }

    enum CodingKeys: String, CodingKey {
        case intentId = "intent_id"
        case pczt = "raw_pczt"
        case signerToken = "signer_token"
        case leaseExpiresAtMs = "lease_expires_at_ms"
        case expiryHeight = "expiry_height"
        case submissionPolicy = "submission_policy"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intentId = try container.decode(String.self, forKey: .intentId)
        pczt = Pczt(try container.decode([UInt8].self, forKey: .pczt))
        signerToken = try container.decode(String.self, forKey: .signerToken)
        leaseExpiresAtMs = try container.decode(UInt64.self, forKey: .leaseExpiresAtMs)
        expiryHeight = try container.decode(UInt32.self, forKey: .expiryHeight)
        submissionPolicy = try container.decode(BoundSubmissionPolicy.self, forKey: .submissionPolicy)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(intentId, forKey: .intentId)
        try container.encode([UInt8](pczt), forKey: .pczt)
        try container.encode(signerToken, forKey: .signerToken)
        try container.encode(leaseExpiresAtMs, forKey: .leaseExpiresAtMs)
        try container.encode(expiryHeight, forKey: .expiryHeight)
        try container.encode(submissionPolicy, forKey: .submissionPolicy)
    }
}

/// Durable transport class for migration submission. Once signed bytes exist, changing transport
/// requires explicit engine policy replacement rather than a mutable UI preference.
public enum SubmissionTransport: String, Equatable, Codable, Sendable {
    case tor
    case direct
}

/// Canonical submission policy requested only after the SDK validates endpoint security and
/// consensus identity. `endpointIdentity` is normalized and contains no credentials or path.
public struct SubmissionPolicy: Equatable, Codable, Sendable {
    public let transport: SubmissionTransport
    public let endpointIdentity: String
    public let consensusFingerprint: String

    public init(
        transport: SubmissionTransport,
        endpointIdentity: String,
        consensusFingerprint: String
    ) {
        self.transport = transport
        self.endpointIdentity = endpointIdentity
        self.consensusFingerprint = consensusFingerprint
    }

    enum CodingKeys: String, CodingKey {
        case transport
        case endpointIdentity = "endpoint_identity"
        case consensusFingerprint = "consensus_fingerprint"
    }
}

/// Immutable engine-bound policy carried by snapshots, signer claims, and network claims.
public struct BoundSubmissionPolicy: Equatable, Codable, Sendable {
    public let policy: SubmissionPolicy
    public let policyFingerprint: String
    public let revision: UInt64

    public init(policy: SubmissionPolicy, policyFingerprint: String, revision: UInt64) {
        self.policy = policy
        self.policyFingerprint = policyFingerprint
        self.revision = revision
    }

    enum CodingKeys: String, CodingKey {
        case policy
        case policyFingerprint = "policy_fingerprint"
        case revision
    }
}

/// Stable reasons the SDK can durably report when endpoint/policy validation fails before
/// transport begins. The raw values are part of the Rust FFI ABI; do not reorder them.
public enum SubmissionPolicyValidationFailure: UInt32, Equatable, Sendable {
    case endpointConsensusMismatch = 0
    case submissionPolicyMismatch = 1
}

/// Typed, non-prose classification for the one bind failure the SDK may convert into a durable
/// user-actionable policy mismatch. All other Rust bind failures retain their original error.
enum MigrationSubmissionPolicyBindingError: Error, Equatable {
    case immutablePolicyConflict
}

#if DEBUG
private let debugMigrationConsensusFingerprint = String(repeating: "0", count: 64)
private let debugMigrationSubmissionPolicy = BoundSubmissionPolicy(
    policy: SubmissionPolicy(
        transport: .direct,
        endpointIdentity: "https://debug.invalid:443",
        consensusFingerprint: debugMigrationConsensusFingerprint
    ),
    policyFingerprint: String(repeating: "0", count: 64),
    revision: 1
)

extension ClaimedTx {
    init(
        id: String,
        txid: String,
        rawPczt: [UInt8],
        attemptToken: String,
        leaseExpiresAtMs: UInt64,
        expiryHeight: UInt32?
    ) {
        self.init(
            id: id,
            txid: txid,
            rawPczt: rawPczt,
            attemptToken: attemptToken,
            leaseExpiresAtMs: leaseExpiresAtMs,
            expiryHeight: expiryHeight ?? 0,
            submissionPolicy: debugMigrationSubmissionPolicy
        )
    }
}

extension ClaimedTransferPCZT {
    var attemptToken: String { signerToken }

    init(
        intentId: String,
        pczt: Pczt,
        attemptToken: String,
        leaseExpiresAtMs: UInt64
    ) {
        self.init(
            intentId: intentId,
            pczt: pczt,
            signerToken: attemptToken,
            leaseExpiresAtMs: leaseExpiresAtMs,
            expiryHeight: 0,
            submissionPolicy: debugMigrationSubmissionPolicy
        )
    }
}

extension ExtractedTx {
    init(txid: String, rawTx: [UInt8]) {
        self.init(
            txid: txid,
            rawTx: rawTx,
            consensusBranchId: UInt32(bitPattern: Int32(bitPattern: 0xc2d6d0b4)),
            expiryHeight: 0
        )
    }
}
#endif

/// How the platform should broadcast migration transactions. `submissionEndpoint == nil` means
/// broadcast over the same lightwalletd used for sync; a secondary endpoint de-correlates traffic.
public struct NetworkPrivacyOptions: Equatable, Codable {
    public let useTor: Bool
    public let submissionEndpoint: String?

    public init(useTor: Bool, submissionEndpoint: String?) {
        self.useTor = useTor
        self.submissionEndpoint = submissionEndpoint
    }

    enum CodingKeys: String, CodingKey {
        case useTor = "use_tor"
        case submissionEndpoint = "submission_endpoint"
    }
}

/// Why a migration requires user attention.
public enum AttentionReason: Equatable, Codable {
    /// An input note was spent externally before its transfer was broadcast.
    case invalidTransfer(transferId: String)
    /// A transaction's anchor/expiry elapsed before broadcast.
    case transferExpired
    /// A transfer produced change back to Orchard that must be synced before the next spend.
    case syncRequiredBeforeNext
    /// The wallet carries the incompatible pre-upstream migration schema and must not be mutated.
    case schemaIncompatible
    /// A submission is still leased because its network outcome cannot yet be determined.
    case submissionOutcomeUnknown
    /// A typed failure needs a recovery flow; ``MigrationSnapshot/failureCode`` is the detailed
    /// machine authority and must drive the UI copy and available action.
    case recoveryRequired
    /// The wallet was opened by a newer migration engine; this app must be updated before use.
    case appUpdateRequired

    enum CodingKeys: String, CodingKey {
        case invalidTransfer = "InvalidTransfer"
    }

    private struct InvalidTransferPayload: Codable {
        let transferId: String
        enum CodingKeys: String, CodingKey {
            case transferId = "transfer_id"
        }
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let tag = try? single.decode(String.self) {
            switch tag {
            case "TransferExpired":
                self = .transferExpired
                return
            case "SyncRequiredBeforeNext":
                self = .syncRequiredBeforeNext
                return
            case "SchemaIncompatible":
                self = .schemaIncompatible
                return
            case "SubmissionOutcomeUnknown":
                self = .submissionOutcomeUnknown
                return
            case "RecoveryRequired":
                self = .recoveryRequired
                return
            case "AppUpdateRequired":
                self = .appUpdateRequired
                return
            default:
                break
            }
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let payload = try container.decode(InvalidTransferPayload.self, forKey: .invalidTransfer)
        self = .invalidTransfer(transferId: payload.transferId)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .transferExpired:
            var container = encoder.singleValueContainer()
            try container.encode("TransferExpired")
        case .syncRequiredBeforeNext:
            var container = encoder.singleValueContainer()
            try container.encode("SyncRequiredBeforeNext")
        case .schemaIncompatible:
            var container = encoder.singleValueContainer()
            try container.encode("SchemaIncompatible")
        case .submissionOutcomeUnknown:
            var container = encoder.singleValueContainer()
            try container.encode("SubmissionOutcomeUnknown")
        case .recoveryRequired:
            var container = encoder.singleValueContainer()
            try container.encode("RecoveryRequired")
        case .appUpdateRequired:
            var container = encoder.singleValueContainer()
            try container.encode("AppUpdateRequired")
        case .invalidTransfer(let transferId):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(InvalidTransferPayload(transferId: transferId), forKey: .invalidTransfer)
        }
    }
}

/// The outcome of a broadcast attempt, reported back to the engine by the platform.
public enum TransferResult: Equatable, Codable {
    case success(txid: String)
    /// Transient network failure; `retryable` indicates whether to retry in a later window.
    case networkError(retryable: Bool)
    /// The input note was already spent.
    case invalidNote
    /// The transaction's anchor/expiry height has passed.
    case expired
    /// Submission may have reached the server, but the platform could not determine the outcome.
    /// The engine retains the active claim until it can safely reconcile or retry.
    case outcomeUnknown

    enum CodingKeys: String, CodingKey {
        case success = "Success"
        case networkError = "NetworkError"
    }

    private struct SuccessPayload: Codable {
        let txid: String
    }

    private struct NetworkErrorPayload: Codable {
        let retryable: Bool
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let tag = try? single.decode(String.self) {
            switch tag {
            case "InvalidNote":
                self = .invalidNote
                return
            case "Expired":
                self = .expired
                return
            case "OutcomeUnknown":
                self = .outcomeUnknown
                return
            default:
                break
            }
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let payload = try? container.decode(SuccessPayload.self, forKey: .success) {
            self = .success(txid: payload.txid)
            return
        }
        let payload = try container.decode(NetworkErrorPayload.self, forKey: .networkError)
        self = .networkError(retryable: payload.retryable)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .invalidNote:
            var container = encoder.singleValueContainer()
            try container.encode("InvalidNote")
        case .expired:
            var container = encoder.singleValueContainer()
            try container.encode("Expired")
        case .outcomeUnknown:
            var container = encoder.singleValueContainer()
            try container.encode("OutcomeUnknown")
        case .success(let txid):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(SuccessPayload(txid: txid), forKey: .success)
        case .networkError(let retryable):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(NetworkErrorPayload(retryable: retryable), forKey: .networkError)
        }
    }
}

/// Top-level migration state machine surfaced to the app.
public enum MigrationState: Equatable, Codable {
    /// No migration has been initiated.
    case notStarted
    /// Note-split transaction submitted, awaiting on-chain confirmation.
    case splitPendingConfirmation
    /// Split confirmed (or not needed); ready to propose transfers.
    case readyToPropose
    /// Schedule committed; transfers are executing.
    case inProgress(MigrationProgress)
    /// A transfer cannot proceed automatically; the app must act.
    case requiresAttention(AttentionReason)
    /// All transfers confirmed; Orchard balance is migrated.
    case complete

    enum CodingKeys: String, CodingKey {
        case inProgress = "InProgress"
        case requiresAttention = "RequiresAttention"
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let tag = try? single.decode(String.self) {
            switch tag {
            case "NotStarted":
                self = .notStarted
                return
            case "SplitPendingConfirmation":
                self = .splitPendingConfirmation
                return
            case "ReadyToPropose":
                self = .readyToPropose
                return
            case "Complete":
                self = .complete
                return
            default:
                break
            }
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let progress = try? container.decode(MigrationProgress.self, forKey: .inProgress) {
            self = .inProgress(progress)
            return
        }
        let reason = try container.decode(AttentionReason.self, forKey: .requiresAttention)
        self = .requiresAttention(reason)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .notStarted:
            var container = encoder.singleValueContainer()
            try container.encode("NotStarted")
        case .splitPendingConfirmation:
            var container = encoder.singleValueContainer()
            try container.encode("SplitPendingConfirmation")
        case .readyToPropose:
            var container = encoder.singleValueContainer()
            try container.encode("ReadyToPropose")
        case .complete:
            var container = encoder.singleValueContainer()
            try container.encode("Complete")
        case .inProgress(let progress):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(progress, forKey: .inProgress)
        case .requiresAttention(let reason):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(reason, forKey: .requiresAttention)
        }
    }
}
