#!/bin/bash

# Public-artifact gate for the committed Ironwood FFI. It requires no external Rust checkout and
# validates the complete ABI used by production Swift code in every binary slice. An alternate
# extracted XCFramework may be supplied as the first argument; provenance and recipe default to
# the reviewed files in this checkout.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 3 ]]; then
    echo "Usage: $0 [xcframework [provenance [build-recipe]]]" >&2
    exit 1
fi
xcframework="${1:-LocalPackages/libzcashlc.xcframework}"
provenance="${2:-LocalPackages/IRONWOOD_FFI_PROVENANCE.env}"
build_recipe="${3:-BuildSupport/IRONWOOD_FFI_BUILD.env}"
test -f "$xcframework/Info.plist"
test -f "$provenance"
test -f "$build_recipe"

./Scripts/verify-ironwood-static-release-inputs.sh >/dev/null

if find LocalPackages -type f \( -name '*.rs' -o -name Cargo.toml -o -name Cargo.lock -o -name '*.rlib' \) | grep -q .; then
    echo "Error: Rust source material must not be committed under LocalPackages" >&2
    exit 1
fi
if find LocalPackages -type d -name .git | grep -q .; then
    echo "Error: nested source repository found under LocalPackages" >&2
    exit 1
fi

binaries=(
    "$xcframework/ios-arm64/libzcashlc.framework/libzcashlc"
    "$xcframework/ios-arm64_x86_64-simulator/libzcashlc.framework/libzcashlc"
    "$xcframework/macos-arm64_x86_64/libzcashlc.framework/libzcashlc"
)
for binary in "${binaries[@]}"; do test -f "$binary"; done
binary_count=$(find "$xcframework" \( -type f -o -type l \) -path '*/libzcashlc.framework/libzcashlc' | wc -l | tr -d ' ')
if [[ "$binary_count" != "3" ]]; then
    echo "Error: expected exactly three platform slices in the full XCFramework, found $binary_count" >&2
    exit 1
fi

# Reject any extra payload or unsafe link before following framework paths, then validate the exact
# semantic SwiftPM routing table independently of the self-recorded plist hash.
./Scripts/verify-ironwood-ffi-layout.sh "$xcframework"
./Scripts/verify-ironwood-xcframework-metadata.sh "$xcframework"

max_git_blob_bytes=100000000
for binary in "${binaries[@]}"; do
    binary_size=$(stat -f '%z' "$binary")
    if (( binary_size >= max_git_blob_bytes )); then
        echo "Error: committed archive exceeds GitHub's object limit: $binary ($binary_size bytes)" >&2
        exit 1
    fi
done

work_dir=$(mktemp -d)
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

# Parse every thin archive with the same Apple linker used by Swift/Xcode. This catches malformed
# unwind relocations that can pass symbol and architecture checks but fail at final link time.
linked_thin_architectures=0
thin_archives=()
thin_headers=()
thin_labels=()
thin_expected_platforms=()
thin_maximum_minos=()
thin_legacy_commands=()
link_smoke_binary() {
    local binary="$1"
    local platform="$2"
    local minimum_version="$3"
    local sdk="$4"
    local expected_arches="$5"
    local expected_platform="$6"
    local legacy_command="$7"
    local sdk_version actual_arches arch thin_archive linked_object
    sdk_version=$(xcrun --sdk "$sdk" --show-sdk-version)
    actual_arches=$(lipo -archs "$binary" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
    if [[ "$actual_arches" != "$expected_arches" ]]; then
        echo "Error: unexpected architectures for linker smoke test $binary: $actual_arches" >&2
        exit 1
    fi
    while IFS= read -r arch; do
        thin_archive="$work_dir/$platform-$arch.a"
        linked_object="$thin_archive.linked.o"
        if [[ "$(lipo -archs "$binary" | wc -w | tr -d ' ')" == "1" ]]; then
            cp "$binary" "$thin_archive"
        else
            lipo "$binary" -thin "$arch" -output "$thin_archive"
        fi
        xcrun ld -r -all_load -arch "$arch" \
            -platform_version "$platform" "$minimum_version" "$sdk_version" \
            "$thin_archive" -o "$linked_object"
        if (( $(stat -f '%z' "$linked_object") < 1000000 )); then
            echo "Error: Apple linker smoke test did not load the full $arch archive" >&2
            exit 1
        fi
        thin_archives+=("$thin_archive")
        thin_headers+=("$(dirname "$binary")/Headers/zcashlc.h")
        thin_labels+=("$platform-$arch")
        thin_expected_platforms+=("$expected_platform")
        thin_maximum_minos+=("$minimum_version")
        thin_legacy_commands+=("$legacy_command")
        linked_thin_architectures=$((linked_thin_architectures + 1))
    done < <(lipo -archs "$binary" | tr ' ' '\n')
}
link_smoke_binary "${binaries[0]}" ios 13.0 iphoneos "arm64" 2 LC_VERSION_MIN_IPHONEOS
link_smoke_binary "${binaries[1]}" ios-simulator 14.0 iphonesimulator "arm64 x86_64" 7 LC_VERSION_MIN_IPHONEOS
link_smoke_binary "${binaries[2]}" macos 12.0 macosx "arm64 x86_64" 1 LC_VERSION_MIN_MACOSX
if [[ "$linked_thin_architectures" != "5" || ${#thin_archives[@]} -ne 5 ]]; then
    echo "Error: Apple linker smoke-tested $linked_thin_architectures thin architectures instead of five" >&2
    exit 1
fi
echo "Apple linker smoke-tested all five thin architectures"

required_symbols=()
while IFS= read -r symbol; do
    required_symbols+=("$symbol")
done < <(
    rg --pcre2 -o --no-filename 'zcashlc_[a-z0-9_]+(?=\s*\()' Sources/ZcashLightClientKit/Rust \
        | LC_ALL=C sort -u
)
if [[ ${#required_symbols[@]} -eq 0 ]]; then
    echo "Error: no production zcashlc ABI calls were discovered" >&2
    exit 1
fi
# v1 is intentionally absent from production Swift: it preserves the original prerelease ABI but
# always fails closed because that signature has no maximum-gross authorization. Keep both versions
# in every artifact so an old header can never call a differently-shaped function under the same
# exported name.
required_symbols+=(
    zcashlc_migration_reserve_immediate_v1
    zcashlc_migration_reserve_immediate_v2
)

# Apple nm cannot reliably parse LLVM 22 attributes emitted by Rust 1.96. Use llvm-nm from the
# exact pinned toolchain instead.
symbol_toolchain=$(sed -nE 's/^channel = "([^"]+)"/\1/p' rust-toolchain.toml)
symbol_host=$(rustup run "$symbol_toolchain" rustc --version --verbose | sed -n 's/^host: //p')
llvm_nm="$(rustup run "$symbol_toolchain" rustc --print sysroot)/lib/rustlib/$symbol_host/bin/llvm-nm"
if [[ ! -x "$llvm_nm" ]]; then
    echo "Error: pinned llvm-nm is missing; install llvm-tools-preview for Rust $symbol_toolchain" >&2
    exit 1
fi

forbidden_paths=(
    '/host-users/'
    '/home/runner'
    '/private/tmp/'
    '.codex/worktrees'
    "$(pwd -P)"
)
if [[ -n "${IRONWOOD_ADDITIONAL_FORBIDDEN_BUILD_ROOTS:-}" ]]; then
    while IFS= read -r build_root; do
        if [[ -n "$build_root" ]]; then forbidden_paths+=("$build_root"); fi
    done < <(printf '%s\n' "$IRONWOOD_ADDITIONAL_FORBIDDEN_BUILD_ROOTS" | tr ':' '\n')
fi
retired_pattern='zodl_ironwood_migration|ZODLIronwoodMigrationRust|github\.com/(just-zend|Chlup)/ZODLIronwoodMigrationRust'
while IFS= read -r artifact_file; do
    for forbidden in "${forbidden_paths[@]}"; do
        if LC_ALL=C grep -aFq "$forbidden" "$artifact_file"; then
            echo "Error: non-reproducible build path '$forbidden' found in $artifact_file" >&2
            exit 1
        fi
    done
    if LC_ALL=C grep -aiEq "$retired_pattern" "$artifact_file"; then
        echo "Error: retired standalone migration-engine metadata found in $artifact_file" >&2
        exit 1
    fi
done < <(find "$xcframework" -type f | LC_ALL=C sort; printf '%s\n' "$provenance" "$build_recipe")

# Rust's compiler-builtins archive can carry this public upstream CI prefix; no other /Users path
# may remain after remapping.
while IFS= read -r artifact_file; do
    if strings "$artifact_file" \
        | sed 's@/Users/runner/work/rust/rust/@/rust-distribution/@g' \
        | LC_ALL=C grep -Fq '/Users/'
    then
        echo "Error: non-reproducible /Users path found in $artifact_file" >&2
        exit 1
    fi
done < <(find "$xcframework" -type f | LC_ALL=C sort)

header_hash=""
for binary in "${binaries[@]}"; do
    header="$(dirname "$binary")/Headers/zcashlc.h"
    test -f "$header"
    current_header_hash=$(shasum -a 256 "$header" | awk '{print $1}')
    if [[ -n "$header_hash" && "$current_header_hash" != "$header_hash" ]]; then
        echo "Error: generated FFI headers differ between platform slices" >&2
        exit 1
    fi
    header_hash="$current_header_hash"

    for symbol in "${required_symbols[@]}"; do
        if ! rg -q --pcre2 "\\b${symbol}\\s*\\(" "$header"; then
            echo "Error: $symbol missing from $header" >&2
            exit 1
        fi
    done
done

# Symbol-name checks alone cannot detect a C ABI break. Compile exact function-pointer assignments
# against the generated header so argument insertion, removal, reordering, or type drift fails the
# artifact gate. The v1 prototype is permanently frozen; authorized reservation belongs to v2.
signature_audit="$work_dir/migration-reserve-abi.c"
cat > "$signature_audit" <<'EOF'
#include "zcashlc.h"

typedef struct FfiMigrationClaimHandle *(*migration_reserve_immediate_v1_fn)(
    const uint8_t *, uintptr_t, const uint8_t *, uint32_t, uint8_t, uint8_t, const char *
);
typedef struct FfiMigrationClaimHandle *(*migration_reserve_immediate_v2_fn)(
    const uint8_t *, uintptr_t, const uint8_t *, uint32_t, uint8_t, int64_t, uint8_t, const char *
);

_Static_assert(
    __builtin_types_compatible_p(
        __typeof__(&zcashlc_migration_reserve_immediate_v1),
        migration_reserve_immediate_v1_fn
    ),
    "zcashlc_migration_reserve_immediate_v1 ABI changed"
);
_Static_assert(
    __builtin_types_compatible_p(
        __typeof__(&zcashlc_migration_reserve_immediate_v2),
        migration_reserve_immediate_v2_fn
    ),
    "zcashlc_migration_reserve_immediate_v2 ABI changed"
);
EOF
xcrun clang -std=c11 -fsyntax-only -Werror \
    -I "$(dirname "${binaries[0]}")/Headers" "$signature_audit"
echo "Generated migration reservation header passed exact v1/v2 signature audit"

for thin_index in "${!thin_archives[@]}"; do
    thin_archive="${thin_archives[$thin_index]}"
    thin_header="${thin_headers[$thin_index]}"
    thin_label="${thin_labels[$thin_index]}"
    ./Scripts/verify-ironwood-macho-floor.sh \
        "$thin_archive" \
        "${thin_expected_platforms[$thin_index]}" \
        "${thin_maximum_minos[$thin_index]}" \
        "${thin_legacy_commands[$thin_index]}"
    symbols_file="$work_dir/symbols-$thin_label.txt"
    nm_output="$symbols_file.raw"
    nm_errors="$symbols_file.err"
    if ! "$llvm_nm" --defined-only --extern-only --just-symbol-name "$thin_archive" \
        > "$nm_output" 2> "$nm_errors"
    then
        echo "Error: llvm-nm could not parse the complete $thin_label archive" >&2
        sed -n '1,20p' "$nm_errors" >&2
        exit 1
    fi
    sed 's/^_//' "$nm_output" | LC_ALL=C sort -u > "$symbols_file"
    for symbol in "${required_symbols[@]}"; do
        if ! grep -Fxq "$symbol" "$symbols_file"; then
            echo "Error: $symbol missing from exported symbols in $thin_label" >&2
            echo "Header: $thin_header" >&2
            exit 1
        fi
    done
done

read_field() {
    local field="$1"
    local file="${2:-$provenance}"
    local matches
    matches=$(grep -c "^${field}=" "$file" || true)
    if [[ "$matches" != "1" ]]; then
        echo "Error: $file must contain exactly one $field" >&2
        exit 1
    fi
    sed -n "s/^${field}=//p" "$file"
}

verify_exact_merge() {
    local label="$1"
    local merge_revision="$2"
    local expected_first_parent="$3"
    local expected_second_parent="$4"
    local parents
    if ! git cat-file -e "${merge_revision}^{commit}" 2>/dev/null; then
        echo "Error: $label merge commit is absent; checkout history must be complete" >&2
        exit 1
    fi
    parents=$(git show -s --format=%P "$merge_revision")
    if [[ "$parents" != "$expected_first_parent $expected_second_parent" ]]; then
        echo "Error: $label merge topology differs from the reviewed two-parent merge" >&2
        exit 1
    fi
}

source_revision=$(read_field SDK_FFI_SOURCE_REVISION)
source_tree=$(read_field SDK_FFI_SOURCE_TREE)
implementation_revision=$(read_field SDK_IRONWOOD_IMPLEMENTATION_REVISION)
sdk_base_revision=$(read_field SDK_BASE_REVISION)
sdk_ironwood_upstream_revision=$(read_field SDK_IRONWOOD_UPSTREAM_REVISION)
sdk_ironwood_merge_revision=$(read_field SDK_IRONWOOD_MERGE_REVISION)
sdk_pool_upstream_revision=$(read_field SDK_POOL_MIGRATION_UPSTREAM_REVISION)
sdk_pool_merge_revision=$(read_field SDK_POOL_MIGRATION_MERGE_REVISION)
sdk_pr1812_upstream_revision=$(read_field SDK_PR_1812_UPSTREAM_REVISION)
sdk_pr1812_merge_revision=$(read_field SDK_PR_1812_MERGE_REVISION)
upstream_1807_merge_revision=$(read_field UPSTREAM_1807_MERGE_REVISION)
included_1813_revision=$(read_field INCLUDED_UPSTREAM_1813_REVISION)
included_1821_revision=$(read_field INCLUDED_UPSTREAM_1821_REVISION)
included_1822_revision=$(read_field INCLUDED_UPSTREAM_1822_REVISION)
upstream_1821_merge_revision=$(read_field UPSTREAM_1821_MERGE_REVISION)
upstream_1822_merge_revision=$(read_field UPSTREAM_1822_MERGE_REVISION)

for revision in \
    "$source_revision" "$source_tree" "$implementation_revision" \
    "$sdk_base_revision" "$sdk_ironwood_upstream_revision" "$sdk_ironwood_merge_revision" \
    "$sdk_pool_upstream_revision" "$sdk_pool_merge_revision" \
    "$sdk_pr1812_upstream_revision" "$sdk_pr1812_merge_revision" \
    "$upstream_1807_merge_revision" \
    "$included_1813_revision" "$included_1821_revision" "$included_1822_revision" \
    "$upstream_1821_merge_revision" "$upstream_1822_merge_revision"
do
    if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Error: invalid SDK lineage revision: $revision" >&2
        exit 1
    fi
done
if ! git cat-file -e "${source_revision}^{commit}" 2>/dev/null \
    || [[ "$(git rev-parse "${source_revision}^{tree}")" != "$source_tree" ]]
then
    echo "Error: recorded SDK source revision/tree does not identify the reviewed source" >&2
    exit 1
fi
verify_exact_merge SDK_IRONWOOD \
    "$sdk_ironwood_merge_revision" "$sdk_base_revision" "$sdk_ironwood_upstream_revision"
verify_exact_merge SDK_POOL_MIGRATION \
    "$sdk_pool_merge_revision" "$sdk_ironwood_merge_revision" "$sdk_pool_upstream_revision"
verify_exact_merge UPSTREAM_1821 \
    "$upstream_1821_merge_revision" "$sdk_pool_merge_revision" "$included_1821_revision"
verify_exact_merge UPSTREAM_1822 \
    "$upstream_1822_merge_revision" "$upstream_1821_merge_revision" "$included_1822_revision"
verify_exact_merge SDK_PR_1812 \
    "$sdk_pr1812_merge_revision" "$upstream_1822_merge_revision" "$sdk_pr1812_upstream_revision"
if ! git merge-base --is-ancestor "$included_1813_revision" "$sdk_pr1812_upstream_revision" \
    || ! git merge-base --is-ancestor "$implementation_revision" "$source_revision" \
    || ! git merge-base --is-ancestor "$sdk_pr1812_merge_revision" "$source_revision" \
    || ! git merge-base --is-ancestor "$source_revision" HEAD
then
    echo "Error: SDK source/implementation/merge ancestry differs from the reviewed lineage" >&2
    exit 1
fi

verify_hash() {
    local variable="$1"
    local relative_path="$2"
    local expected actual
    expected=$(read_field "$variable")
    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        echo "Error: missing or invalid $variable in $provenance" >&2
        exit 1
    fi
    actual=$(shasum -a 256 "$relative_path" | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        echo "Error: hash mismatch for $relative_path" >&2
        exit 1
    fi
}

verify_hash IOS_ARM64_SHA256 "${binaries[0]}"
verify_hash IOS_SIMULATOR_UNIVERSAL_SHA256 "${binaries[1]}"
verify_hash MACOS_UNIVERSAL_SHA256 "${binaries[2]}"
verify_hash XCFRAMEWORK_INFO_SHA256 "$xcframework/Info.plist"

recorded_manifest_hash=$(read_field XCFRAMEWORK_MANIFEST_SHA256)
actual_manifest_hash=$(./Scripts/hash-ironwood-xcframework.sh "$xcframework")
if [[ ! "$recorded_manifest_hash" =~ ^[0-9a-f]{64}$ \
    || "$recorded_manifest_hash" != "$actual_manifest_hash" ]]
then
    echo "Error: complete XCFramework file/symlink manifest differs from artifact provenance" >&2
    exit 1
fi

verify_arches() {
    local binary="$1"
    local expected="$2"
    local actual
    actual=$(lipo -archs "$binary" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
    if [[ "$actual" != "$expected" ]]; then
        echo "Error: unexpected architectures for $binary: $actual" >&2
        exit 1
    fi
}
verify_arches "${binaries[0]}" "arm64"
verify_arches "${binaries[1]}" "arm64 x86_64"
verify_arches "${binaries[2]}" "arm64 x86_64"

recorded_source_hash=$(read_field SDK_FFI_SOURCE_SHA256)
actual_source_hash=$(./Scripts/hash-ironwood-ffi-sources.sh)
if [[ ! "$recorded_source_hash" =~ ^[0-9a-f]{64}$ || "$recorded_source_hash" != "$actual_source_hash" ]]; then
    echo "Error: SDK FFI source hash differs from artifact provenance" >&2
    exit 1
fi

recorded_toolchain=$(read_field RUST_TOOLCHAIN)
expected_toolchain=$(sed -nE 's/^channel = "([^"]+)"/\1/p' rust-toolchain.toml)
makefile_toolchain=$(sed -nE 's/^RUST_TOOLCHAIN = ([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' BuildSupport/Makefile)
if [[ "$recorded_toolchain" != "$expected_toolchain" \
    || "$makefile_toolchain" != "$expected_toolchain" \
    || ! "$recorded_toolchain" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
then
    echo "Error: artifact, rust-toolchain.toml, and BuildSupport/Makefile toolchains differ" >&2
    exit 1
fi
for field in RUSTC_RELEASE CARGO_RELEASE; do
    if [[ "$(read_field "$field")" != "$recorded_toolchain" ]]; then
        echo "Error: $field differs from the pinned Rust toolchain" >&2
        exit 1
    fi
done
for field in RUSTC_COMMIT CARGO_COMMIT; do
    if [[ ! "$(read_field "$field")" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Error: missing or invalid $field in artifact provenance" >&2
        exit 1
    fi
done

if [[ "$(read_field BUILD_PATH_POLICY)" != "explicit-required-tool-dirs-normalized-rust-v1" \
    || ! "$(read_field BUILD_PATH_SHA256)" =~ ^[0-9a-f]{64}$ \
    || "$(read_field RUSTUP_HOME_POLICY)" != "ephemeral-empty-v1" \
    || "$(read_field GIT_CONFIG_POLICY)" != "system-global-disabled-v1" ]]
then
    echo "Error: artifact provenance does not record the hermetic PATH/Rustup/Git policy" >&2
    exit 1
fi

tool_sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
}
declare -a tool_fields=(
    RUSTUP_SHA256 GIT_SHA256 MAKE_SHA256 LLVM_OBJCOPY_SHA256
    APPLE_LD_SHA256 APPLE_LIPO_SHA256 APPLE_STRIP_SHA256 APPLE_CLANG_SHA256
)
declare -a tool_paths=(
    "$(command -v rustup)" "/usr/bin/git" "/usr/bin/make" "$(dirname "$llvm_nm")/llvm-objcopy"
    "$(xcrun --find ld)" "$(xcrun --find lipo)" "$(xcrun --find strip)" "$(xcrun --find clang)"
)
for tool_index in "${!tool_fields[@]}"; do
    tool_field="${tool_fields[$tool_index]}"
    tool_path="${tool_paths[$tool_index]}"
    if [[ ! -x "$tool_path" || "$(read_field "$tool_field")" != "$(tool_sha256 "$tool_path")" ]]; then
        echo "Error: $tool_field differs from the tool selected for verification" >&2
        exit 1
    fi
done
if [[ "$(read_field XCODE_DEVELOPER_DIR)" != "$(xcode-select -p)" ]]; then
    echo "Error: artifact Xcode developer directory differs from the selected Xcode" >&2
    exit 1
fi

if [[ "$(read_field MACOSX_DEPLOYMENT_TARGET)" != "12.0" \
    || "$(read_field IPHONEOS_DEPLOYMENT_TARGET)" != "13.0" \
    || "$(read_field IOS_ARM64_SIMULATOR_MINIMUM_OS)" != "14.0" \
    || "$(read_field MACOSX_DEPLOYMENT_TARGET "$build_recipe")" != "12.0" \
    || "$(read_field IPHONEOS_DEPLOYMENT_TARGET "$build_recipe")" != "13.0" \
    || "$(read_field IOS_ARM64_SIMULATOR_MINIMUM_OS "$build_recipe")" != "14.0" ]]
then
    echo "Error: artifact deployment targets differ from the Swift package platform floor" >&2
    exit 1
fi
./Scripts/verify-ironwood-package-platforms.sh

for field in XCODE_VERSION IPHONEOS_SDK_VERSION IPHONESIMULATOR_SDK_VERSION MACOSX_SDK_VERSION MACOS_VERSION; do
    if [[ ! "$(read_field "$field")" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
        echo "Error: missing or invalid $field in artifact provenance" >&2
        exit 1
    fi
done
for field in XCODE_BUILD_VERSION MACOS_BUILD_VERSION; do
    if [[ ! "$(read_field "$field")" =~ ^[0-9A-Za-z]+$ ]]; then
        echo "Error: missing or invalid $field in artifact provenance" >&2
        exit 1
    fi
done

recipe_fields=(
    SDK_FFI_SOURCE_REVISION SDK_FFI_SOURCE_TREE SDK_IRONWOOD_IMPLEMENTATION_REVISION
    SDK_BASE_REVISION SDK_IRONWOOD_UPSTREAM_REVISION SDK_IRONWOOD_MERGE_REVISION
    SDK_POOL_MIGRATION_UPSTREAM_REVISION SDK_POOL_MIGRATION_MERGE_REVISION
    SDK_PR_1812_UPSTREAM_REVISION SDK_PR_1812_MERGE_REVISION
    UPSTREAM_1807_MERGE_REVISION INCLUDED_UPSTREAM_1813_REVISION
    INCLUDED_UPSTREAM_1821_REVISION INCLUDED_UPSTREAM_1822_REVISION
    UPSTREAM_1821_MERGE_REVISION UPSTREAM_1822_MERGE_REVISION
    LIBRUSTZCASH_REPOSITORY LIBRUSTZCASH_REVISION LIBRUSTZCASH_TREE
    ZCASH_VOTING_REVISION ORCHARD_VERSION ORCHARD_CHECKSUM
    MIGRATION_RESERVE_ABI_POLICY
    SOURCE_DATE_EPOCH RUST_TOOLCHAIN BUILD_ENVIRONMENT_POLICY FFI_ARCHIVE_POSTPROCESSING
    BUILD_PATH_POLICY BUILD_PATH_SHA256 RUSTUP_HOME_POLICY GIT_CONFIG_POLICY
    RUSTUP_SHA256 GIT_SHA256 MAKE_SHA256 LLVM_OBJCOPY_SHA256
    APPLE_LD_SHA256 APPLE_LIPO_SHA256 APPLE_STRIP_SHA256 APPLE_CLANG_SHA256
    XCODE_DEVELOPER_DIR
    MACOSX_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET IOS_ARM64_SIMULATOR_MINIMUM_OS
)
for field in "${recipe_fields[@]}"; do
    if [[ -z "$(read_field "$field")" || "$(read_field "$field")" != "$(read_field "$field" "$build_recipe")" ]]; then
        echo "Error: $field differs from the frozen build recipe" >&2
        exit 1
    fi
done

if [[ "$(read_field SDK_BASE_REVISION)" != "9476ced615d90407270d3d741823d5797ef0f501" \
    || "$(read_field SDK_IRONWOOD_UPSTREAM_REVISION)" != "61be7e006d0b4bacb5933d8da28b08410f8ee126" \
    || "$(read_field SDK_IRONWOOD_MERGE_REVISION)" != "71f6977dce5b281d69a86597051849bf88ea13d0" \
    || "$(read_field SDK_POOL_MIGRATION_UPSTREAM_REVISION)" != "92a9b2b663bb0c5275794788c1d33a0e3fe0adc8" \
    || "$(read_field SDK_POOL_MIGRATION_MERGE_REVISION)" != "d2dbd935a896630a878d997c792d8e3b7c46563a" \
    || "$(read_field SDK_PR_1812_UPSTREAM_REVISION)" != "daf1aa1bda57cbc4044f8978cb6170f82940a3d8" \
    || "$(read_field SDK_PR_1812_MERGE_REVISION)" != "0835b3cd3275580802e5d26b0fd0896b2c1e3155" \
    || "$(read_field UPSTREAM_1807_MERGE_REVISION)" != "ef6c31420cf861d459b5fe41a47997fe255ffa4b" \
    || "$(read_field INCLUDED_UPSTREAM_1813_REVISION)" != "adfe9ca7a989f7a7197f8b10138519f8a02f790f" \
    || "$(read_field INCLUDED_UPSTREAM_1821_REVISION)" != "eb219e2f86f5725377ebdf3985815c809a954450" \
    || "$(read_field INCLUDED_UPSTREAM_1822_REVISION)" != "5aa8b4b4bb1ff4075a670b56de268295cff45589" \
    || "$(read_field LIBRUSTZCASH_REPOSITORY)" != "https://github.com/just-zend/librustzcash" \
    || "$(read_field ZCASH_VOTING_REVISION)" != "04d255628f1d56de0479e3fb6963409dbe44ec1f" \
    || "$(read_field ORCHARD_VERSION)" != "0.15.4" \
    || "$(read_field ORCHARD_CHECKSUM)" != "793e2e8c2323f35f082d1b3467ca8f576d646f9c93aef8c5168809d099245af8" \
    || "$(read_field MIGRATION_RESERVE_ABI_POLICY)" != "legacy-v1-fail-closed-authorized-v2" ]]
then
    echo "Error: provenance does not record the reviewed Ironwood source graph" >&2
    exit 1
fi
for field in \
    SDK_FFI_SOURCE_REVISION SDK_FFI_SOURCE_TREE SDK_IRONWOOD_IMPLEMENTATION_REVISION \
    UPSTREAM_1821_MERGE_REVISION UPSTREAM_1822_MERGE_REVISION
do
    if [[ ! "$(read_field "$field")" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Error: invalid canonical SDK source field $field" >&2
        exit 1
    fi
done
publication_ref=$(read_field LIBRUSTZCASH_PUBLICATION_REF_AT_BUILD)
publication_tip=$(read_field LIBRUSTZCASH_PUBLICATION_TIP_AT_BUILD)
if [[ ! "$publication_ref" =~ ^refs/(heads|tags)/[-A-Za-z0-9._/]+$ \
    || ! "$publication_tip" =~ ^[0-9a-f]{40}$ ]]
then
    echo "Error: invalid non-canonical librustzcash publication evidence" >&2
    exit 1
fi
for field in LIBRUSTZCASH_REVISION LIBRUSTZCASH_TREE; do
    if [[ ! "$(read_field "$field")" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Error: invalid $field in artifact provenance" >&2
        exit 1
    fi
done
if [[ ! "$(read_field SOURCE_DATE_EPOCH)" =~ ^[0-9]+$ \
    || "$(read_field BUILD_ENVIRONMENT_POLICY)" != "hermetic-v1" \
    || "$(read_field FFI_ARCHIVE_POSTPROCESSING)" != "thin-llvm-objcopy-remove-bitcode_lipo_apple-strip-S-x" ]]
then
    echo "Error: invalid source epoch or archive post-processing provenance" >&2
    exit 1
fi

EXPECTED_LIBRUSTZCASH_REVISION="$(read_field LIBRUSTZCASH_REVISION)" \
    ./Scripts/verify-ironwood-cargo-pins.sh

echo "Committed Ironwood FFI passed source, hash, architecture, ABI, platform, and path-leak checks."
