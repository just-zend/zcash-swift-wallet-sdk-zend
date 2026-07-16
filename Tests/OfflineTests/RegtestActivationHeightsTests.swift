//
//  RegtestActivationHeightsTests.swift
//  ZcashLightClientKit
//
//  Offline coverage for configurable NU activation heights (regtest / custom network).
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class RegtestActivationHeightsTests: XCTestCase {
    private static let ffiActivationHeights = NetworkActivationHeights(
        overwinter: 1,
        sapling: 1,
        blossom: 1,
        heartwood: 1,
        canopy: 1,
        nu5: 100,
        nu6: 200,
        nu6_3: 700
    )

    // MARK: - Network model

    func testRegtestNetworkIdentity() {
        XCTAssertEqual(NetworkType.regtest.networkId, 2)
        XCTAssertEqual(NetworkType.regtest.chainName, "regtest")
        XCTAssertEqual(NetworkType.forChainName("regtest"), .regtest)
        XCTAssertEqual(NetworkType.forNetworkId(2), .regtest)
    }

    func testRegtestBuilderCarriesActivationHeights() {
        let heights = NetworkActivationHeights(sapling: 1, nu5: 100, nu6: 200, nu6_3: 700, nu7: nil)
        let network = ZcashNetworkBuilder.regtest(activationHeights: heights)

        XCTAssertEqual(network.networkType, .regtest)
        XCTAssertEqual(network.chainName, "regtest")
        XCTAssertEqual(network.saplingActivationHeight, 1)
        XCTAssertEqual(network.customActivationHeights, heights)
        XCTAssertEqual(NetworkUpgrade.nu7.rawValue, 10)
    }

    func testRegtestSaplingActivationDefaultsToOneWhenUnset() {
        let network = ZcashNetworkBuilder.regtest(activationHeights: NetworkActivationHeights(nu5: 100))
        XCTAssertEqual(network.saplingActivationHeight, 1)
    }

    func testCustomNetworkCanonicalizesAndStoresExpectedChainNameOnce() {
        let network = ZcashNetworkBuilder.custom(
            base: .mainnet,
            chainName: " MAIN ",
            activationHeights: NetworkActivationHeights(sapling: 1, nu6_3: 700)
        )

        XCTAssertEqual(network.networkType, .regtest)
        XCTAssertEqual(network.customNetworkBase, .mainnet)
        XCTAssertEqual(network.chainName, "main")
    }

    func testMainnetTestnetAreUnaffected() {
        let mainnet = ZcashNetworkBuilder.network(for: .mainnet)
        let testnet = ZcashNetworkBuilder.network(for: .testnet)

        XCTAssertNil(mainnet.customActivationHeights)
        XCTAssertNil(testnet.customActivationHeights)
        XCTAssertEqual(mainnet.saplingActivationHeight, 419_200)
        XCTAssertEqual(testnet.saplingActivationHeight, 280_000)
    }

    // MARK: - Checkpoints

    func testRegtestCheckpointFloorIsEmptyTreeAtSaplingHeight() {
        let source = CheckpointSourceFactory.fromBundle(
            for: .regtest,
            regtestActivationHeights: NetworkActivationHeights(sapling: 7)
        )

        XCTAssertEqual(source.network, .regtest)
        XCTAssertEqual(source.saplingActivation.height, 7)
        XCTAssertEqual(source.saplingActivation.saplingTree, "000000")
        XCTAssertNil(source.saplingActivation.orchardTree)
        XCTAssertNil(source.saplingActivation.ironwoodTree)
        // Regtest ships no bundled checkpoints, so any requested birthday resolves to the floor.
        XCTAssertEqual(source.birthday(for: 10_000).height, 7)
        XCTAssertEqual(source.latestKnownCheckpoint().height, 7)
    }

    // MARK: - FFI integration: consensus branch id honors the configured heights

    func testStandardNu6_3ActivationHeightsComeFromLinkedRustConsensus() throws {
        let mainnet = ZcashRustBackend.makeForTests(
            fsBlockDbRoot: Environment.uniqueTestTempDirectory,
            networkType: .mainnet
        )
        let testnet = ZcashRustBackend.makeForTests(
            fsBlockDbRoot: Environment.uniqueTestTempDirectory,
            networkType: .testnet
        )

        XCTAssertEqual(try mainnet.networkUpgradeActivationHeight(.nu6_3), 3_428_143)
        XCTAssertEqual(try mainnet.nu6_3ActivationHeight(), 3_428_143)
        XCTAssertEqual(try testnet.networkUpgradeActivationHeight(.nu6_3), 4_134_000)
        XCTAssertEqual(try testnet.nu6_3ActivationHeight(), 4_134_000)
        XCTAssertNil(try mainnet.networkUpgradeActivationHeight(.nu7))
        XCTAssertNil(try testnet.networkUpgradeActivationHeight(.nu7))
        XCTAssertEqual(try mainnet.consensusChainName(), "main")
        XCTAssertEqual(try testnet.consensusChainName(), "test")
        XCTAssertEqual(
            try mainnet.consensusParametersFingerprint(),
            "bdb246591c8e7b307586301653684dfe3dadd1dfd85039ce1809b5937ee4946c"
        )
        XCTAssertEqual(
            try testnet.consensusParametersFingerprint(),
            "06a419eb689f524cfd6f08476a03693dd1f8e647729bb33f4c97a2dc36291490"
        )
        XCTAssertNotEqual(
            try mainnet.consensusParametersFingerprint(),
            try testnet.consensusParametersFingerprint()
        )
    }

    func testCustomActivationAndFingerprintComeFromRegisteredRustConsensus() throws {
        XCTAssertTrue(
            ZcashRustBackend.setCustomNetwork(
                base: .regtest,
                chainName: " REGTEST ",
                Self.ffiActivationHeights
            )
        )
        let backend = ZcashRustBackend.makeForTests(
            fsBlockDbRoot: Environment.uniqueTestTempDirectory,
            networkType: .regtest
        )

        XCTAssertEqual(try backend.networkUpgradeActivationHeight(.nu5), 100)
        XCTAssertEqual(try backend.networkUpgradeActivationHeight(.nu6_2), nil)
        XCTAssertEqual(try backend.nu6_3ActivationHeight(), 700)
        XCTAssertNil(try backend.networkUpgradeActivationHeight(.nu7))
        XCTAssertEqual(try backend.consensusChainName(), "regtest")
        XCTAssertEqual(try backend.consensusParametersFingerprint().count, 64)
    }

    func testRegtestConsensusBranchIdReflectsCustomActivationHeights() throws {
        // Configure a regtest network with NU5 at 100 and NU6 at 200.
        XCTAssertTrue(
            ZcashRustBackend.setCustomNetwork(
                base: .regtest,
                chainName: "regtest",
                Self.ffiActivationHeights
            )
        )

        let backend = ZcashRustBackend.makeForTests(
            fsBlockDbRoot: Environment.uniqueTestTempDirectory,
            networkType: .regtest
        )

        // Well-known Zcash consensus branch ids (see zcash_protocol LocalNetwork docs / zcash.conf nuparams).
        let nu5BranchId = Int32(bitPattern: 0xc2d6_d0b4)
        let nu6BranchId = Int32(bitPattern: 0xc8e7_1055)
        let nu6_3BranchId = Int32(bitPattern: 0x37a5_165b)

        // Below the configured NU5 height the branch id is not NU5's...
        XCTAssertNotEqual(try backend.consensusBranchIdFor(height: 50), nu5BranchId)
        // ...at/after the configured NU5 height it is NU5's...
        XCTAssertEqual(try backend.consensusBranchIdFor(height: 100), nu5BranchId)
        XCTAssertEqual(try backend.consensusBranchIdFor(height: 150), nu5BranchId)
        // ...and at/after the configured NU6 height it is NU6's.
        XCTAssertEqual(try backend.consensusBranchIdFor(height: 200), nu6BranchId)
        XCTAssertEqual(try backend.consensusBranchIdFor(height: 699), nu6BranchId)
        // NU6.3/Ironwood becomes authoritative at its own configured boundary.
        XCTAssertEqual(try backend.consensusBranchIdFor(height: 700), nu6_3BranchId)
        XCTAssertEqual(try backend.consensusBranchIdFor(height: 5000), nu6_3BranchId)
    }
}
