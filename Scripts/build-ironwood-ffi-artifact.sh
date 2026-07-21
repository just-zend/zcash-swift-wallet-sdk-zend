#!/bin/bash

# Builds the full five-architecture Ironwood XCFramework from the frozen Rust source graph and
# writes the reproducibility/provenance record consumed by public CI.

set -euo pipefail
cd "$(dirname "$0")/.."

librustzcash_repo="${LIBRUSTZCASH_REPO:-}"
if [[ -z "$librustzcash_repo" || ! -d "$librustzcash_repo" ]]; then
    echo "Error: set LIBRUSTZCASH_REPO to the frozen just-zend/librustzcash checkout" >&2
    exit 1
fi
librustzcash_repo=$(cd "$librustzcash_repo" && pwd -P)
if [[ -n "$(git -C "$librustzcash_repo" status --porcelain)" ]]; then
    echo "Error: librustzcash checkout must be clean before an artifact build" >&2
    exit 1
fi

expected_librustzcash_repository="https://github.com/just-zend/librustzcash"
expected_librustzcash_branch="agent/ironwood-nu63-compatibility"
expected_librustzcash_revision="5115cf26da590a3d610446f1d926ff7f2873c9d1"
expected_librustzcash_tree="62f79c17fe172735fce3df4e03991e90a736b60a"
expected_sdk_base_revision="8f85838bcc7f59e11de45c96e1ed783093712901"
expected_sdk_upstream_revision="2922143e4d686c999d9b3530282988a3838af220"
expected_sdk_merge_revision="d555d060815b89def2337a9ad37407362b49f352"
excluded_slipstream_sdk_revision="226333494ebe6bc377aaf4bbb513bb1ccbf16750"
voting_circuits_revision="a5aae410a6fb14fcbea2f0ce3393035195e86f69"
vote_nullifier_pir_revision="0dea3485429c80033e67a1ddb18ee72cc450cefb"
zcash_voting_revision="464f974865f2afa82bdac15d169168c77ecb9c74"
archive_postprocessing="thin-llvm-objcopy-remove-bitcode_lipo_apple-strip-S-x"

librustzcash_revision=$(git -C "$librustzcash_repo" rev-parse HEAD)
librustzcash_tree=$(git -C "$librustzcash_repo" rev-parse 'HEAD^{tree}')
librustzcash_branch=$(git -C "$librustzcash_repo" branch --show-current)
source_date_epoch=$(git -C "$librustzcash_repo" log -1 --format=%ct)
if [[ "$librustzcash_revision" != "$expected_librustzcash_revision" \
    || "$librustzcash_tree" != "$expected_librustzcash_tree" \
    || "$librustzcash_branch" != "$expected_librustzcash_branch" ]]
then
    echo "Error: librustzcash checkout does not match the frozen compatibility branch/revision/tree" >&2
    exit 1
fi
if ! git merge-base --is-ancestor "$expected_sdk_merge_revision" HEAD \
    || [[ "$(git rev-parse "$expected_sdk_merge_revision^1")" != "$expected_sdk_base_revision" \
    || "$(git rev-parse "$expected_sdk_merge_revision^2")" != "$expected_sdk_upstream_revision" ]]
then
    echo "Error: SDK checkout does not contain the reviewed base/upstream merge" >&2
    exit 1
fi

rust_toolchain=$(sed -nE 's/^channel = "([^"]+)"/\1/p' rust-toolchain.toml)
if [[ ! "$rust_toolchain" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: rust-toolchain.toml must pin an exact stable release" >&2
    exit 1
fi

rustup toolchain install "$rust_toolchain" --profile minimal
rustup component add --toolchain "$rust_toolchain" llvm-tools-preview
rustup target add --toolchain "$rust_toolchain" \
    aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim \
    x86_64-apple-darwin x86_64-apple-ios
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

recipe_temp=$(mktemp)
provenance_temp=""
cleanup() {
    rm -f "$recipe_temp"
    if [[ -n "$provenance_temp" ]]; then rm -f "$provenance_temp"; fi
}
trap cleanup EXIT
printf '%s\n' \
    "SDK_BASE_REVISION=$expected_sdk_base_revision" \
    "SDK_UPSTREAM_REVISION=$expected_sdk_upstream_revision" \
    "SDK_MERGE_REVISION=$expected_sdk_merge_revision" \
    "SYNC_ENGINE=SDKSynchronizer" \
    "SLIPSTREAM_INCLUDED=false" \
    "EXCLUDED_SLIPSTREAM_SDK_REVISION=$excluded_slipstream_sdk_revision" \
    "LIBRUSTZCASH_REPOSITORY=$expected_librustzcash_repository" \
    "LIBRUSTZCASH_BRANCH=$expected_librustzcash_branch" \
    "LIBRUSTZCASH_REVISION=$librustzcash_revision" \
    "LIBRUSTZCASH_TREE=$librustzcash_tree" \
    "VOTING_CIRCUITS_REVISION=$voting_circuits_revision" \
    "VOTE_NULLIFIER_PIR_REVISION=$vote_nullifier_pir_revision" \
    "ZCASH_VOTING_REVISION=$zcash_voting_revision" \
    "SOURCE_DATE_EPOCH=$source_date_epoch" \
    "RUST_TOOLCHAIN=$rust_toolchain" \
    "FFI_ARCHIVE_POSTPROCESSING=$archive_postprocessing" \
    "MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET" \
    "IPHONEOS_DEPLOYMENT_TARGET=$IPHONEOS_DEPLOYMENT_TARGET" \
    "IOS_ARM64_SIMULATOR_MINIMUM_OS=$IRONWOOD_IOS_ARM64_SIMULATOR_MINIMUM_OS" \
    > "$recipe_temp"
mv "$recipe_temp" BuildSupport/IRONWOOD_FFI_BUILD.env

./Scripts/audit-ironwood-dependency-graph.sh
make -C BuildSupport clean
./Scripts/init-local-ffi.sh

sdk_ffi_source_sha256=$(./Scripts/hash-ironwood-ffi-sources.sh)
xcframework=LocalPackages/libzcashlc.xcframework
ios_arm64_sha256=$(shasum -a 256 "$xcframework/ios-arm64/libzcashlc.framework/libzcashlc" | awk '{print $1}')
ios_simulator_universal_sha256=$(shasum -a 256 "$xcframework/ios-arm64_x86_64-simulator/libzcashlc.framework/libzcashlc" | awk '{print $1}')
macos_universal_sha256=$(shasum -a 256 "$xcframework/macos-arm64_x86_64/libzcashlc.framework/libzcashlc" | awk '{print $1}')
xcframework_info_sha256=$(shasum -a 256 "$xcframework/Info.plist" | awk '{print $1}')

provenance_temp=$(mktemp)
printf '%s\n' \
    "SDK_BASE_REVISION=$expected_sdk_base_revision" \
    "SDK_UPSTREAM_REVISION=$expected_sdk_upstream_revision" \
    "SDK_MERGE_REVISION=$expected_sdk_merge_revision" \
    "SYNC_ENGINE=SDKSynchronizer" \
    "SLIPSTREAM_INCLUDED=false" \
    "EXCLUDED_SLIPSTREAM_SDK_REVISION=$excluded_slipstream_sdk_revision" \
    "LIBRUSTZCASH_REPOSITORY=$expected_librustzcash_repository" \
    "LIBRUSTZCASH_BRANCH=$expected_librustzcash_branch" \
    "LIBRUSTZCASH_REVISION=$librustzcash_revision" \
    "LIBRUSTZCASH_TREE=$librustzcash_tree" \
    "VOTING_CIRCUITS_REVISION=$voting_circuits_revision" \
    "VOTE_NULLIFIER_PIR_REVISION=$vote_nullifier_pir_revision" \
    "ZCASH_VOTING_REVISION=$zcash_voting_revision" \
    "SDK_FFI_SOURCE_SHA256=$sdk_ffi_source_sha256" \
    "SOURCE_DATE_EPOCH=$source_date_epoch" \
    "RUST_TOOLCHAIN=$rust_toolchain" \
    "FFI_ARCHIVE_POSTPROCESSING=$archive_postprocessing" \
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
    "IOS_SIMULATOR_UNIVERSAL_SHA256=$ios_simulator_universal_sha256" \
    "MACOS_UNIVERSAL_SHA256=$macos_universal_sha256" \
    "XCFRAMEWORK_INFO_SHA256=$xcframework_info_sha256" \
    > "$provenance_temp"
mv "$provenance_temp" LocalPackages/IRONWOOD_FFI_PROVENANCE.env
provenance_temp=""

./Scripts/verify-ironwood-ffi-artifact.sh
