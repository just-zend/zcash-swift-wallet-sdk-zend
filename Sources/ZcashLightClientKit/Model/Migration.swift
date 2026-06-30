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

/// Live migration progress for the progress UI.
public struct MigrationProgress: Equatable, Codable {
    public let completedTransfers: UInt32
    public let totalTransfers: UInt32
    public let remainingOrchard: UInt64
    public let nextTransferReadyAtHeight: UInt32?

    public init(
        completedTransfers: UInt32,
        totalTransfers: UInt32,
        remainingOrchardZatoshi: UInt64,
        nextTransferReadyAtHeight: UInt32?
    ) {
        self.completedTransfers = completedTransfers
        self.totalTransfers = totalTransfers
        self.remainingOrchardZatoshi = remainingOrchardZatoshi
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

    public init(id: String, txid: String, rawTx: [UInt8]) {
        self.id = id
        self.txid = txid
        self.rawTx = rawTx
    }

    enum CodingKeys: String, CodingKey {
        case id
        case txid
        case rawPczt = "raw_pczt"
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
        amountZatoshi: UInt64,
        anchorHeight: UInt32,
        nextExecutableAfterHeight: UInt32,
        expiryHeight: UInt32
    ) {
        self.id = id
        self.amountZatoshi = amountZatoshi
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
