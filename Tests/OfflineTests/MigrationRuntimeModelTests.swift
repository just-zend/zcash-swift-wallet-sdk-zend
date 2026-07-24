//
//  MigrationRuntimeModelTests.swift
//  OfflineTests
//

import Foundation
import XCTest
@testable import ZcashLightClientKit

final class MigrationRuntimeModelTests: XCTestCase {
    private let account = AccountUUID(id: Array(repeating: 0x73, count: 16))

    func testMigrationEngineInitializationFailureCodeMappingIsCompleteAndSanitized() {
        let expected: [(UInt32, MigrationEngineInitializationFailureCause)] = [
            (10, .notSynced),
            (11, .notInitialized),
            (12, .schemaIncompatible),
            (13, .engineSchemaNewer),
            (14, .engineSchemaCorrupt),
            (15, .consensusMismatch),
            (20, .databaseBusy),
            (21, .databaseLocked),
            (22, .databaseFull),
            (23, .databaseReadOnly),
            (24, .databaseCorrupt),
            (25, .databaseUnavailable),
            (30, .backend),
            (31, .pipeline),
            (32, .otherInvalid)
        ]

        for (code, cause) in expected {
            XCTAssertEqual(MigrationEngineInitializationFailureCause(ffiCode: code), cause)
            XCTAssertFalse(MigrationEngineInitializationError(cause: cause).localizedDescription.contains("private-path"))
        }
        XCTAssertNil(MigrationEngineInitializationFailureCause(ffiCode: 0))
        XCTAssertNil(MigrationEngineInitializationFailureCause(ffiCode: .max))
    }

    func testWalletDatabaseInitializationFailureCodeMappingIsCompleteAndSanitized() {
        let expected: [(UInt32, WalletDatabaseInitializationFailureCause)] = [
            (1, .databaseBusy),
            (2, .databaseLocked),
            (3, .databaseFull),
            (4, .databaseReadOnly),
            (5, .databaseCorrupt),
            (6, .databaseUnavailable),
            (7, .schemaIncompatible),
            (8, .backend)
        ]

        for (code, cause) in expected {
            XCTAssertEqual(WalletDatabaseInitializationFailureCause(ffiCode: code), cause)
            XCTAssertFalse(WalletDatabaseInitializationError(cause: cause).localizedDescription.contains("private-path"))
        }
        XCTAssertNil(WalletDatabaseInitializationFailureCause(ffiCode: 0))
        XCTAssertNil(WalletDatabaseInitializationFailureCause(ffiCode: .max))
    }

    func testSubmissionIntentRedactsEndpoint() {
        let endpoint = "https://secret-submit.example:9067"
        let intent = MigrationSubmissionIntent(transport: .directTLS, endpoint: endpoint)

        XCTAssertEqual(intent.transport, .directTLS)
        XCTAssertEqual(intent.endpoint, endpoint)
        XCTAssertFalse(intent.description.contains(endpoint))
    }

    func testClaimSummaryExposesOnlySanitizedMetadata() {
        let txid = Data("secret-transaction-id".utf8)
        let claim = makeOutcomeUnknownSDKClaim(
            txid: txid,
            handleIdentity: 1
        )

        XCTAssertEqual(claim.artifact, .scheduled(transactionID: 7))
        XCTAssertEqual(claim.status, .outcomeUnknown)
        XCTAssertEqual(claim.activeClaimKind, .outcomeResolution)
        XCTAssertEqual(claim.txid, txid)
        XCTAssertTrue(claim.hasExactTransaction)
        XCTAssertFalse(claim.description.contains("secret-transaction-id"))
        XCTAssertTrue(claim.description.contains("txid: <redacted>"))
    }

    func testSanitizedEqualityDoesNotExposeOpaqueCapabilityIdentity() {
        let firstClaim = makeStagedSDKClaim(handleIdentity: 2)
        let secondClaim = makeStagedSDKClaim(handleIdentity: 3)
        XCTAssertEqual(firstClaim, secondClaim)

        let firstDelivery = makeDelivery(claim: firstClaim, runIdentity: 4)
        let secondDelivery = makeDelivery(claim: secondClaim, runIdentity: 5)
        XCTAssertEqual(firstDelivery, secondDelivery)
    }

    func testRuntimeSnapshotCarriesRustComputedFailClosedAuthorizations() {
        let delivery = makeDelivery(claim: makeStagedSDKClaim(handleIdentity: 6), runIdentity: 7)
        let snapshot = MigrationRuntimeSnapshot(
            account: account,
            canonical: MigrationCanonicalSummary(status: .inProgress, transactionCount: 1),
            schemaProvenance: .compatible(version: 1),
            legacyCutover: .fresh,
            destinationSpendability: .notSpendable,
            availability: .unavailable(.submissionPolicyMissing),
            ordinarySpendAuthorization: .blocked(.runtimeUnavailable),
            accountDeletionAuthorization: .blocked(.unresolvedDelivery),
            canonicalMutationAuthorization: .blocked(.deliveryOwned),
            aggregateStorageFinality: .active,
            delivery: delivery,
            retainedRuns: []
        )

        XCTAssertEqual(snapshot.canonical.status, .inProgress)
        XCTAssertEqual(snapshot.canonical.transactionCount, 1)
        XCTAssertEqual(snapshot.availability, .unavailable(.submissionPolicyMissing))
        XCTAssertEqual(snapshot.ordinarySpendAuthorization, .blocked(.runtimeUnavailable))
        XCTAssertEqual(snapshot.accountDeletionAuthorization, .blocked(.unresolvedDelivery))
        XCTAssertEqual(snapshot.canonicalMutationAuthorization, .blocked(.deliveryOwned))
        XCTAssertFalse(snapshot.description.contains(account.id.description))
        XCTAssertTrue(snapshot.description.contains("account: <redacted>"))
    }

    func testRetainedRunsKeepFinalityVisibleWithoutRestoringMutationAuthority() {
        let retainedDelivery = makeDelivery(
            claim: makeConfirmedSDKClaim(handleIdentity: 8),
            runIdentity: 9,
            finality: .completePendingFinality(releaseAtHeight: 2_000_101)
        )
        let retained = MigrationRetainedRun(
            canonical: MigrationCanonicalSummary(status: .complete, transactionCount: 1),
            destinationSpendability: .spendable,
            delivery: retainedDelivery
        )
        let snapshot = MigrationRuntimeSnapshot(
            account: account,
            canonical: MigrationCanonicalSummary(status: nil, transactionCount: 0),
            schemaProvenance: .compatible(version: 1),
            legacyCutover: .fresh,
            destinationSpendability: .notApplicable,
            availability: .available,
            ordinarySpendAuthorization: .excludingMigrationSources(releaseAtHeight: 2_000_101),
            accountDeletionAuthorization: .allowed,
            canonicalMutationAuthorization: .allowed,
            aggregateStorageFinality: .completePendingFinality(releaseAtHeight: 2_000_101),
            delivery: nil,
            retainedRuns: [retained]
        )

        XCTAssertEqual(snapshot.retainedRuns, [retained])
        XCTAssertEqual(
            snapshot.aggregateStorageFinality,
            .completePendingFinality(releaseAtHeight: 2_000_101)
        )
    }

    func testImmediateExternalSigningRequestRedactsPCZTAndClaim() {
        let pczt = Data("secret-pczt".utf8)
        let request = ImmediateMigrationExternalSigningRequest(
            pczt: pczt,
            claim: makeClaimHandle(10)
        )

        XCTAssertEqual(request.pczt, pczt)
        XCTAssertFalse(request.description.contains("secret-pczt"))
        XCTAssertEqual(request.description, request.debugDescription)
    }

    func testSubmissionOutcomeUsesStableWireValues() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for outcome in [
            MigrationSubmissionOutcome.accepted,
            .knownUnsent,
            .unknown
        ] {
            XCTAssertEqual(try decoder.decode(MigrationSubmissionOutcome.self, from: encoder.encode(outcome)), outcome)
        }
        XCTAssertEqual(MigrationSubmissionOutcome.knownUnsent.rawValue, "known_unsent")
    }

    func testMigrationScheduleCodingStripsProcessLocalPlanAuthority() throws {
        let schedule = MigrationSchedule(
            transfers: [],
            estimatedDurationHours: 7,
            proposalHandle: 0xFEED_FACE
        )
        let encoded = try JSONEncoder().encode(schedule)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["proposalHandle"])

        let roundTripped = try JSONDecoder().decode(MigrationSchedule.self, from: encoded)
        XCTAssertEqual(roundTripped.proposalHandle, 0)
        XCTAssertEqual(roundTripped.transfers, schedule.transfers)
        XCTAssertEqual(roundTripped.estimatedDurationHours, schedule.estimatedDurationHours)

        let preReleasePayload = Data(
            #"{"transfers":[],"estimatedDurationHours":7,"proposalHandle":4277009102}"#.utf8
        )
        let decodedPreRelease = try JSONDecoder().decode(MigrationSchedule.self, from: preReleasePayload)
        XCTAssertEqual(decodedPreRelease.proposalHandle, 0)
    }

    private func makeStagedSDKClaim(
        handleIdentity: Int
    ) -> MigrationDeliveryClaimSummary {
        MigrationDeliveryClaimSummary(
            artifact: .scheduled(transactionID: 7),
            signerOwnership: .sdk,
            status: .staged,
            activeClaimKind: nil,
            externallyExposed: false,
            hasSignedPCZT: false,
            hasExactTransaction: true,
            expiryHeight: 2_000_040,
            txid: Data(repeating: 0x44, count: 32),
            lastError: nil,
            claimHandle: makeClaimHandle(handleIdentity)
        )
    }

    private func makeOutcomeUnknownSDKClaim(
        txid: Data,
        handleIdentity: Int
    ) -> MigrationDeliveryClaimSummary {
        MigrationDeliveryClaimSummary(
            artifact: .scheduled(transactionID: 7),
            signerOwnership: .sdk,
            status: .outcomeUnknown,
            activeClaimKind: .outcomeResolution,
            externallyExposed: false,
            hasSignedPCZT: false,
            hasExactTransaction: true,
            expiryHeight: 2_000_040,
            txid: txid,
            lastError: .transportOutcomeUnknown,
            claimHandle: makeClaimHandle(handleIdentity)
        )
    }

    private func makeConfirmedSDKClaim(
        handleIdentity: Int
    ) -> MigrationDeliveryClaimSummary {
        MigrationDeliveryClaimSummary(
            artifact: .scheduled(transactionID: 7),
            signerOwnership: .sdk,
            status: .confirmed,
            activeClaimKind: nil,
            externallyExposed: false,
            hasSignedPCZT: false,
            hasExactTransaction: true,
            expiryHeight: 2_000_040,
            txid: Data(repeating: 0x44, count: 32),
            lastError: nil,
            claimHandle: makeClaimHandle(handleIdentity)
        )
    }

    private func makeDelivery(
        claim: MigrationDeliveryClaimSummary,
        runIdentity: Int,
        finality: MigrationStorageFinality = .active
    ) -> MigrationDeliverySnapshot {
        MigrationDeliverySnapshot(
            lane: .scheduled,
            phase: .active,
            storageFinality: finality,
            activeSourceReservationCount: 1,
            hasSubmissionPolicy: true,
            policyValidationFailure: nil,
            safeToCancel: false,
            claims: [claim],
            runHandle: makeRunHandle(runIdentity)
        )
    }

    private func makeClaimHandle(_ identity: Int) -> MigrationClaimHandle {
        MigrationClaimHandle(
            storage: MigrationOpaqueHandleStorage(
                pointer: OpaquePointer(bitPattern: identity)!,
                release: { _ in }
            )
        )
    }

    private func makeRunHandle(_ identity: Int) -> MigrationRunHandle {
        MigrationRunHandle(
            storage: MigrationOpaqueHandleStorage(
                pointer: OpaquePointer(bitPattern: identity)!,
                release: { _ in }
            )
        )
    }
}
