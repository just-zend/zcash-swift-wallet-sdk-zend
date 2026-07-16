#!/bin/bash

# Builds the three arm64 Ironwood FFI slices from a frozen private-engine commit and writes the
# complete reproducibility/provenance record consumed by public CI. The final Cargo dependency
# must already be an immutable git revision; path dependencies are intentionally rejected.

set -euo pipefail
cd "$(dirname "$0")/.."

migration_engine_repo="${IRONWOOD_MIGRATION_ENGINE_REPO:-}"
if [[ -z "$migration_engine_repo" || ! -d "$migration_engine_repo" ]]; then
    echo "Error: set IRONWOOD_MIGRATION_ENGINE_REPO to the frozen private-engine checkout" >&2
    exit 1
fi
migration_engine_repo=$(cd "$migration_engine_repo" && pwd -P)
if [[ -n "$(git -C "$migration_engine_repo" status --porcelain)" ]]; then
    echo "Error: migration-engine checkout must be clean before an artifact build" >&2
    exit 1
fi

migration_revision=$(git -C "$migration_engine_repo" rev-parse HEAD)
migration_tree=$(git -C "$migration_engine_repo" rev-parse 'HEAD^{tree}')
source_date_epoch=$(git -C "$migration_engine_repo" log -1 --format=%ct)
expected_migration_repository="ssh://git@github.com/just-zend/ZODLIronwoodMigrationRust.git"
migration_repository=$(sed -nE \
    's@^zodl_ironwood_migration = \{ git = "([^"]+)", rev = "[0-9a-f]{40}".*@\1@p' \
    Cargo.toml)
expected_migration_revision=$(sed -nE \
    's@^zodl_ironwood_migration = \{ git = "[^"]+", rev = "([0-9a-f]{40})".*@\1@p' \
    Cargo.toml)
if [[ "$migration_repository" != "$expected_migration_repository" ]]; then
    echo "Error: Cargo.toml must use the canonical private migration-engine repository" >&2
    exit 1
fi
if [[ -z "$expected_migration_revision" ]]; then
    echo "Error: Cargo.toml must use an exact git revision for zodl_ironwood_migration" >&2
    exit 1
fi
if [[ "$migration_revision" != "$expected_migration_revision" ]]; then
    echo "Error: private-engine checkout HEAD differs from the Cargo.toml revision" >&2
    exit 1
fi

librustzcash_revision=$(sed -nE \
    's@^zcash_client_backend = .*rev = "([0-9a-f]{40})".*@\1@p' \
    Cargo.toml | tail -1)
rust_toolchain=$(sed -nE 's/^channel = "([^"]+)"/\1/p' rust-toolchain.toml)
if [[ ! "$librustzcash_revision" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Error: Cargo.toml must pin zcash_client_backend to an exact revision" >&2
    exit 1
fi
if [[ ! "$rust_toolchain" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: rust-toolchain.toml must pin an exact stable release" >&2
    exit 1
fi

rustup toolchain install "$rust_toolchain" --profile minimal
rustc_release=$(rustc "+$rust_toolchain" --version --verbose | sed -n 's/^release: //p')
rustc_commit=$(rustc "+$rust_toolchain" --version --verbose | sed -n 's/^commit-hash: //p')
cargo_release=$(cargo "+$rust_toolchain" --version --verbose | sed -n 's/^release: //p')
cargo_commit=$(cargo "+$rust_toolchain" --version --verbose | sed -n 's/^commit-hash: //p')

xcode_version=$(xcodebuild -version | sed -n '1s/^Xcode //p')
xcode_build_version=$(xcodebuild -version | sed -n '2s/^Build version //p')
iphoneos_sdk_version=$(xcrun --sdk iphoneos --show-sdk-version)
iphonesimulator_sdk_version=$(xcrun --sdk iphonesimulator --show-sdk-version)
macosx_sdk_version=$(xcrun --sdk macosx --show-sdk-version)
macos_version=$(sw_vers -productVersion)
macos_build_version=$(sw_vers -buildVersion)

export SOURCE_DATE_EPOCH="$source_date_epoch"
# shellcheck source=rust-build-env.sh
source Scripts/rust-build-env.sh

mkdir -p BuildSupport
build_recipe_temp=$(mktemp)
trap 'rm -f "$build_recipe_temp"' EXIT
printf '%s\n' \
    "MIGRATION_ENGINE_REPOSITORY=$migration_repository" \
    "MIGRATION_ENGINE_REVISION=$migration_revision" \
    "MIGRATION_ENGINE_TREE=$migration_tree" \
    "SOURCE_DATE_EPOCH=$source_date_epoch" \
    "RUST_TOOLCHAIN=$rust_toolchain" \
    "MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET" \
    "IPHONEOS_DEPLOYMENT_TARGET=$IPHONEOS_DEPLOYMENT_TARGET" \
    "IOS_ARM64_SIMULATOR_MINIMUM_OS=$IRONWOOD_IOS_ARM64_SIMULATOR_MINIMUM_OS" \
    > "$build_recipe_temp"
mv "$build_recipe_temp" BuildSupport/IRONWOOD_FFI_BUILD.env

./Scripts/audit-ironwood-dependency-graph.sh
./Scripts/init-local-ffi.sh --arm-all

sdk_ffi_source_sha256=$(./Scripts/hash-ironwood-ffi-sources.sh)
xcframework=LocalPackages/libzcashlc.xcframework
ios_arm64_sha256=$(shasum -a 256 "$xcframework/ios-arm64/libzcashlc.framework/libzcashlc" | awk '{print $1}')
ios_arm64_simulator_sha256=$(shasum -a 256 "$xcframework/ios-arm64-simulator/libzcashlc.framework/libzcashlc" | awk '{print $1}')
macos_arm64_sha256=$(shasum -a 256 "$xcframework/macos-arm64/libzcashlc.framework/libzcashlc" | awk '{print $1}')

provenance_temp=$(mktemp)
trap 'rm -f "$provenance_temp"' EXIT
printf '%s\n' \
    "MIGRATION_ENGINE_REPOSITORY=$migration_repository" \
    "MIGRATION_ENGINE_REVISION=$migration_revision" \
    "MIGRATION_ENGINE_TREE=$migration_tree" \
    "LIBRUSTZCASH_REVISION=$librustzcash_revision" \
    "SDK_FFI_SOURCE_SHA256=$sdk_ffi_source_sha256" \
    "SOURCE_DATE_EPOCH=$source_date_epoch" \
    "RUST_TOOLCHAIN=$rust_toolchain" \
    "MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET" \
    "IPHONEOS_DEPLOYMENT_TARGET=$IPHONEOS_DEPLOYMENT_TARGET" \
    "IOS_ARM64_SIMULATOR_MINIMUM_OS=$IRONWOOD_IOS_ARM64_SIMULATOR_MINIMUM_OS" \
    "RUSTC_RELEASE=$rustc_release" \
    "RUSTC_COMMIT=$rustc_commit" \
    "CARGO_RELEASE=$cargo_release" \
    "CARGO_COMMIT=$cargo_commit" \
    "XCODE_VERSION=$xcode_version" \
    "XCODE_BUILD_VERSION=$xcode_build_version" \
    "IPHONEOS_SDK_VERSION=$iphoneos_sdk_version" \
    "IPHONESIMULATOR_SDK_VERSION=$iphonesimulator_sdk_version" \
    "MACOSX_SDK_VERSION=$macosx_sdk_version" \
    "MACOS_VERSION=$macos_version" \
    "MACOS_BUILD_VERSION=$macos_build_version" \
    "IOS_ARM64_SHA256=$ios_arm64_sha256" \
    "IOS_ARM64_SIMULATOR_SHA256=$ios_arm64_simulator_sha256" \
    "MACOS_ARM64_SHA256=$macos_arm64_sha256" \
    > "$provenance_temp"
mv "$provenance_temp" LocalPackages/IRONWOOD_FFI_PROVENANCE.env

./Scripts/verify-ironwood-ffi-artifact.sh
