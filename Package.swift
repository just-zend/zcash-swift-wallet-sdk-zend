// swift-tools-version:5.6
import PackageDescription
import Foundation

// Automatically detect the in-repo FFI.
// When LocalPackages/libzcashlc.xcframework exists (committed on this branch, and also what
// Scripts/init-local-ffi.sh produces), the SDK builds against it as a path-based binary target —
// this works both for local checkouts and when the SDK is consumed as a remote git package
// (a sub-package under LocalPackages would not resolve remotely). Run `rm -rf LocalPackages`
// to fall back to the released binary.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let useLocalFFI = FileManager.default.fileExists(atPath: packageDir + "/LocalPackages/libzcashlc.xcframework/Info.plist")

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.24.2"),
    .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.3")
]

var sdkDependencies: [Target.Dependency] = [
    .product(name: "SQLite", package: "SQLite.swift"),
    .product(name: "GRPC", package: "grpc-swift"),
]

var targets: [Target] = []

if useLocalFFI {
    targets.append(
        .binaryTarget(
            name: "libzcashlc",
            path: "LocalPackages/libzcashlc.xcframework"
        )
    )
    sdkDependencies.append("libzcashlc")
} else {
    // Binary target for the Rust FFI library
    // Updated by Scripts/release.sh during the release process
    targets.append(
        .binaryTarget(
            name: "libzcashlc",
            url: "https://github.com/zcash/zcash-swift-wallet-sdk/releases/download/2.6.0-alpha.6/libzcashlc.xcframework.zip",
            checksum: "c58c1714440f8fd40bed33eefa3be325896e58eb568ed8747c05a27dae3a74b2"
        )
    )
    sdkDependencies.append("libzcashlc")
}

targets.append(contentsOf: [
    .target(
        name: "ZcashLightClientKit",
        dependencies: sdkDependencies,
        exclude: [
            "Modules/Service/GRPC/ProtoBuf/proto/compact_formats.proto",
            "Modules/Service/GRPC/ProtoBuf/proto/proposal.proto",
            "Modules/Service/GRPC/ProtoBuf/proto/service.proto",
            "Error/Sourcery/",
            // Voting is gated off on this Ironwood branch: the underlying zcashlc_voting_* FFI
            // symbols are not built (valargroup orchard fork incompatibility). See Cargo.toml.
            "Rust/Voting"
        ],
        resources: [
            .copy("Resources/checkpoints")
        ]
    ),
    .target(
        name: "TestUtils",
        dependencies: ["ZcashLightClientKit"],
        path: "Tests/TestUtils",
        exclude: [
            "proto/darkside.proto",
            "Sourcery/AutoMockable.stencil",
            "Sourcery/generateMocks.sh"
        ],
        resources: [
            .copy("Resources/test_data.db"),
            .copy("Resources/cache.db"),
            .copy("Resources/darkside_caches.db"),
            .copy("Resources/darkside_data.db"),
            .copy("Resources/sandblasted_mainnet_block.json"),
            .copy("Resources/txBase64String.txt"),
            .copy("Resources/txFromAndroidSDK.txt"),
            .copy("Resources/integerOverflowJSON.json"),
            .copy("Resources/sapling-spend.params"),
            .copy("Resources/sapling-output.params")
        ]
    ),
    .testTarget(
        name: "OfflineTests",
        dependencies: ["ZcashLightClientKit", "TestUtils"],
        exclude: [
            // Voting is gated off on this Ironwood branch (see the ZcashLightClientKit target):
            // these test the excluded Rust/Voting layer (VotingRustBackend, PirSnapshotResolver).
            "VotingRustBackendTests.swift",
            "PirSnapshotResolverTests.swift"
        ]
    ),
    .testTarget(
        name: "NetworkTests",
        dependencies: ["ZcashLightClientKit", "TestUtils"]
    ),
    .testTarget(
        name: "DarksideTests",
        dependencies: ["ZcashLightClientKit", "TestUtils"]
    ),
    .testTarget(
        name: "AliasDarksideTests",
        dependencies: ["ZcashLightClientKit", "TestUtils"],
        exclude: [
            "scripts/"
        ]
    ),
    .testTarget(
        name: "PerformanceTests",
        dependencies: ["ZcashLightClientKit", "TestUtils"]
    )
])

let package = Package(
    name: "ZcashLightClientKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "ZcashLightClientKit",
            targets: ["ZcashLightClientKit"]
        )
    ],
    dependencies: dependencies,
    targets: targets
)
