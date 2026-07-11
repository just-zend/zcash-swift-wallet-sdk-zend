//
//  MigrationFFITests.swift
//  OfflineTests
//
//  Exercises the migration FFI marshalling + the empty-DB state machine through the real
//  ZcashRustBackend welding. The balance/signing paths need a seeded, synced wallet DB (a
//  documented integration gap), so they are not covered here.
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class MigrationFFITests: XCTestCase {
    var dbData: URL!
    var rustBackend: ZcashRustBackendWelding!
    let account = AccountUUID(id: [UInt8](repeating: 7, count: 16))
    let policyFingerprint = String(repeating: "0", count: 64)

    override func setUp() {
        super.setUp()
        dbData = try! __dataDbURL()
        rustBackend = ZcashRustBackend.makeForTests(
            dbData: dbData,
            fsBlockDbRoot: Environment.uniqueTestTempDirectory,
            networkType: .testnet
        )
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: dbData!)
        rustBackend = nil
    }

    func testMigrationStateOnFreshWalletIsNotStarted() async throws {
        let state = try await rustBackend.migrationState(for: account)
        XCTAssertEqual(state, .notStarted)
    }

    func testMigrationProgressIsNilWhenNotStarted() async throws {
        let progress = try await rustBackend.migrationProgress(for: account)
        XCTAssertNil(progress)
    }

    func testInitializePostUpgradeSucceeds() async throws {
        try await rustBackend.migrationInitializePostUpgrade(for: account)
    }

    func testRecordTransferResultWithNoActiveRunThrows() async throws {
        do {
            try await rustBackend.migrationRecordTransferResult(
                transferId: "does-not-exist",
                result: .success(txid: "abc"),
                for: account
            )
            XCTFail("expected recording a result with no active migration run to throw")
        } catch {
            // The crate returns MigrationError::InvalidState -> null ptr -> rustMigrationRecordTransferResult.
        }
    }

    func testExtractBroadcastTxWithInvalidPcztThrows() async throws {
        do {
            _ = try await rustBackend.migrationExtractBroadcastTx(pczt: [0, 1, 2, 3], for: account)
            XCTFail("expected extracting a tx from invalid PCZT bytes to throw")
        } catch {
            // Invalid PCZT bytes -> crate deserialization error -> null ptr -> rustMigrationExtractBroadcastTx.
        }
    }

    func testStoreSignedNoteSplitPCZTWithNothingStagedThrows() async throws {
        do {
            let policy = SubmissionPolicy(
                transport: .direct,
                endpointIdentity: "https://test.example:443",
                consensusFingerprint: policyFingerprint
            )
            _ = try await rustBackend.migrationStoreSignedNoteSplitPCZT(
                claim: ClaimedNoteSplitPCZT(
                    runId: "00000000-0000-4000-8000-000000000007",
                    pczt: Pczt([0]),
                    signerToken: "signer",
                    anchorHeight: 1,
                    expiryHeight: 2,
                    submissionPolicy: BoundSubmissionPolicy(
                        policy: policy,
                        policyFingerprint: policyFingerprint,
                        revision: 1
                    )
                ),
                pczt: Pczt([0, 1, 2]),
                expectedPolicyFingerprint: policyFingerprint,
                for: account
            )
            XCTFail("expected storing a signed split with nothing staged to throw")
        } catch {
            // No staged note-split PCZT -> MigrationError::InvalidState -> null ptr ->
            // rustMigrationStoreSignedNoteSplitPCZT.
        }
    }

    func testStoreSignedSchedulePCZTsWithNothingStagedThrows() async throws {
        do {
            try await rustBackend.migrationStoreSignedSchedulePCZTs(
                pczts: [MigrationTransferPCZT(id: "run-0", pczt: Pczt([1, 2, 3]))],
                expectedPolicyFingerprint: policyFingerprint,
                for: account
            )
            XCTFail("expected storing signed transfers with nothing staged to throw")
        } catch {
            // No staged transfer PCZTs -> MigrationError::InvalidState -> null ptr ->
            // rustMigrationStoreSignedSchedulePCZTs.
        }
    }

    func testStoreSignedSchedulePCZTsWithEmptySetThrows() async throws {
        do {
            try await rustBackend.migrationStoreSignedSchedulePCZTs(
                pczts: [],
                expectedPolicyFingerprint: policyFingerprint,
                for: account
            )
            XCTFail("expected storing an empty signed-transfer set to throw")
        } catch {
            // Empty set -> MigrationError::InvalidState -> null ptr -> rustMigrationStoreSignedSchedulePCZTs.
        }
    }

    func testCreateUnsignedTransferPCZTsWithEmptyScheduleThrows() async throws {
        // Round-trips the caller-provided schedule through the FFI's JSON marshalling into the
        // crate, which rejects an empty schedule before any PCZT work.
        do {
            _ = try await rustBackend.migrationCreateUnsignedTransferPCZTs(
                schedule: MigrationSchedule(transfers: [], estimatedDurationHours: 0),
                expectedPolicyFingerprint: policyFingerprint,
                for: account
            )
            XCTFail("expected building PCZTs for an empty schedule to throw")
        } catch {
            // Empty schedule -> MigrationError::InvalidState -> null ptr ->
            // rustMigrationCreateUnsignedTransferPCZTs.
        }
    }

    func testSpendAndMigrationMutationBoundariesStaySynchronousOnDBActor() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let backendSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/ZcashLightClientKit/Rust/ZcashRustBackend.swift"),
            encoding: .utf8
        )
        let guardedFunctions = [
            "proposeTransfer",
            "proposeTransferFromURI",
            "createPCZTFromProposal",
            "extractAndStoreTxFromPCZT",
            "createProposedTransactions",
            "migrationBeginPrivate",
            "migrationBindSubmissionPolicy",
            "migrationSignNoteSplit",
            "migrationCreateUnsignedNoteSplitPCZT",
            "migrationCommitIntents",
            "migrationSignAndStore",
            "migrationMaterializeAndClaimNextDue",
            "migrationStageNextDueExternalPCZT",
            "migrationStoreSignedDueIntent"
        ]

        for function in guardedFunctions {
            let body = try Self.dbActorFunctionBody(named: function, in: backendSource)
            XCTAssertFalse(
                body.contains("await "),
                "\(function) must hold DBActor continuously across its synchronous FFI boundary"
            )
            XCTAssertTrue(body.contains("zcashlc_"), "\(function) must retain its direct FFI boundary")
        }
    }

    func testPublicSynchronizerContractExposesOnlyIntentJITMigrationMutations() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contract = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/ZcashLightClientKit/Synchronizer.swift"),
            encoding: .utf8
        )
        let implementation = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/ZcashLightClientKit/Synchronizer/SDKSynchronizer.swift"),
            encoding: .utf8
        )
        let legacyPreSignAllAPIs = [
            "func signAndStoreMigrationSchedule(",
            "func proposeMigrationTransferPCZTs(",
            "func storeSignedMigrationTransferPCZTs(",
            "func executeNextPendingTransfer(",
            "func refreshStaleTransfers(",
            "func restartCurrentMigrationStep("
        ]

        for signature in legacyPreSignAllAPIs {
            XCTAssertFalse(contract.contains(signature), "public migration contract leaked \(signature)")
            XCTAssertFalse(implementation.contains("public \(signature)"), "legacy implementation became public: \(signature)")
        }
        for signature in [
            "func beginPrivateMigration(",
            "func commitMigrationIntents(",
            "func executeNextMigrationAction(",
            "func stageNextDueMigrationPCZT("
        ] {
            XCTAssertTrue(contract.contains(signature), "missing intent/JIT API \(signature)")
        }
    }

    private static func dbActorFunctionBody(named name: String, in source: String) throws -> Substring {
        let marker = "@DBActor"
        let nameMarker = "func \(name)("
        guard let functionName = source.range(of: nameMarker),
              let actorMarker = source[..<functionName.lowerBound].range(of: marker, options: .backwards),
              source[actorMarker.upperBound..<functionName.lowerBound].allSatisfy({ $0.isWhitespace }),
              let openingBrace = source[functionName.upperBound...].firstIndex(of: "{") else {
            throw SourceAuditError.missingDBActorFunction(name)
        }

        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return source[actorMarker.lowerBound...cursor]
                }
            default: break
            }
            cursor = source.index(after: cursor)
        }
        throw SourceAuditError.unterminatedFunction(name)
    }

    private enum SourceAuditError: Error {
        case missingDBActorFunction(String)
        case unterminatedFunction(String)
    }
}
