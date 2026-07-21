#!/bin/bash

# Public-artifact gate for the committed Ironwood FFI. It requires no source checkout beyond this
# SDK and validates the complete ABI used by production Swift code in every binary slice.

set -euo pipefail
cd "$(dirname "$0")/.."

xcframework="LocalPackages/libzcashlc.xcframework"
provenance="LocalPackages/IRONWOOD_FFI_PROVENANCE.env"
build_recipe="BuildSupport/IRONWOOD_FFI_BUILD.env"
test -f "$xcframework/Info.plist"
test -f "$provenance"
test -f "$build_recipe"

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

max_git_blob_bytes=100000000
for binary in "${binaries[@]}"; do
    binary_size=$(stat -f '%z' "$binary")
    if (( binary_size >= max_git_blob_bytes )); then
        echo "Error: committed archive exceeds GitHub's object limit: $binary ($binary_size bytes)" >&2
        exit 1
    fi
done

# Parse every thin archive with the same Apple linker used by Swift/Xcode. This is a focused
# regression gate for Mach-O unwind relocations: llvm-strip -x can leave an archive that passes
# llvm-nm and architecture checks but crashes Apple ld while reading compiler_builtins.
link_smoke_dir=$(mktemp -d)
cleanup_link_smoke() {
    rm -rf "$link_smoke_dir"
}
trap cleanup_link_smoke EXIT
link_smoke_binary() {
    local binary="$1"
    local platform="$2"
    local minimum_version="$3"
    local sdk="$4"
    local sdk_version arch thin_archive linked_object
    sdk_version=$(xcrun --sdk "$sdk" --show-sdk-version)
    while IFS= read -r arch; do
        thin_archive="$link_smoke_dir/$(basename "$(dirname "$binary")")-$platform-$arch.a"
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
    done < <(lipo -archs "$binary" | tr ' ' '\n')
}
link_smoke_binary "${binaries[0]}" ios 13.0 iphoneos
link_smoke_binary "${binaries[1]}" ios-simulator 14.0 iphonesimulator
link_smoke_binary "${binaries[2]}" macos 12.0 macosx

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

# Apple nm in Xcode 26 cannot parse the LLVM 22 attributes emitted by Rust 1.96.1's
# compiler_builtins objects. Inspect the archives with llvm-nm from the exact pinned Rust
# toolchain instead; the builder installs llvm-tools-preview for that toolchain.
symbol_toolchain=$(sed -nE 's/^channel = "([^"]+)"/\1/p' rust-toolchain.toml)
symbol_host=$(rustc "+$symbol_toolchain" --version --verbose | sed -n 's/^host: //p')
llvm_nm="$(rustc "+$symbol_toolchain" --print sysroot)/lib/rustlib/$symbol_host/bin/llvm-nm"
if [[ ! -x "$llvm_nm" ]]; then
    echo "Error: pinned llvm-nm is missing; install llvm-tools-preview for Rust $symbol_toolchain" >&2
    exit 1
fi

forbidden_paths=(
    '/host-users/'
    '/home/runner'
    '/private/tmp/'
    '.codex/worktrees'
)
while IFS= read -r artifact_file; do
    for forbidden in "${forbidden_paths[@]}"; do
        if LC_ALL=C grep -aFq "$forbidden" "$artifact_file"; then
            echo "Error: non-reproducible build path '$forbidden' found in $artifact_file" >&2
            exit 1
        fi
    done
done < <(find LocalPackages -type f | LC_ALL=C sort)

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
done < <(find LocalPackages -type f | LC_ALL=C sort)

for binary in "${binaries[@]}"; do
    header="$(dirname "$binary")/Headers/zcashlc.h"
    test -f "$header"
    symbols_file=$(mktemp)
    nm_output=$(mktemp)
    nm_errors=$(mktemp)
    nm_status=0
    "$llvm_nm" --defined-only --extern-only --just-symbol-name "$binary" > "$nm_output" 2> "$nm_errors" || nm_status=$?
    sed 's/^_//' "$nm_output" | LC_ALL=C sort -u > "$symbols_file"
    for symbol in "${required_symbols[@]}"; do
        if ! grep -Fq "$symbol" "$header"; then
            echo "Error: $symbol missing from $header" >&2
            rm -f "$symbols_file" "$nm_output" "$nm_errors"
            exit 1
        fi
        if ! grep -Fxq "$symbol" "$symbols_file"; then
            echo "Error: $symbol missing from exported symbols in $binary" >&2
            if [[ "$nm_status" != "0" ]]; then sed -n '1,10p' "$nm_errors" >&2; fi
            rm -f "$symbols_file" "$nm_output" "$nm_errors"
            exit 1
        fi
    done
    rm -f "$symbols_file" "$nm_output" "$nm_errors"
done

read_field() {
    local field="$1"
    local file="${2:-$provenance}"
    sed -n "s/^${field}=//p" "$file"
}

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

verify_archive_platform_floor() {
    local binary="$1"
    local expected_platform="$2"
    local maximum_minos="$3"
    if ! otool -l "$binary" 2>/dev/null | awk \
        -v expected_platform="$expected_platform" -v maximum_minos="$maximum_minos" '
        function version_gt(found, maximum, f, m, i) {
            split(found, f, "."); split(maximum, m, ".")
            for (i = 1; i <= 3; i++) {
                if ((f[i] + 0) > (m[i] + 0)) return 1
                if ((f[i] + 0) < (m[i] + 0)) return 0
            }
            return 0
        }
        $1 == "platform" { found = 1; if ($2 != expected_platform) invalid = 1 }
        $1 == "minos" && version_gt($2, maximum_minos) { invalid = 1 }
        END { exit (!found || invalid) }
        '
    then
        echo "Error: $binary contains a wrong-platform or too-new deployment target" >&2
        exit 1
    fi
}
verify_archive_platform_floor "${binaries[0]}" 2 13.0
verify_archive_platform_floor "${binaries[1]}" 7 14.0
verify_archive_platform_floor "${binaries[2]}" 1 12.0

recorded_source_hash=$(read_field SDK_FFI_SOURCE_SHA256)
actual_source_hash=$(./Scripts/hash-ironwood-ffi-sources.sh)
if [[ ! "$recorded_source_hash" =~ ^[0-9a-f]{64}$ || "$recorded_source_hash" != "$actual_source_hash" ]]; then
    echo "Error: SDK FFI source hash differs from artifact provenance" >&2
    exit 1
fi

recorded_toolchain=$(read_field RUST_TOOLCHAIN)
expected_toolchain=$(sed -nE 's/^channel = "([^"]+)"/\1/p' rust-toolchain.toml)
if [[ "$recorded_toolchain" != "$expected_toolchain" || ! "$recorded_toolchain" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: artifact Rust toolchain differs from rust-toolchain.toml" >&2
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
if ! grep -Fq '.iOS(.v13)' Package.swift || ! grep -Fq '.macOS(.v12)' Package.swift; then
    echo "Error: Package.swift platform floor differs from the frozen FFI deployment targets" >&2
    exit 1
fi

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

expected_fields=(
    SDK_BASE_REVISION SDK_UPSTREAM_REVISION SDK_MERGE_REVISION
    SYNC_ENGINE SLIPSTREAM_INCLUDED EXCLUDED_SLIPSTREAM_SDK_REVISION
    LIBRUSTZCASH_REPOSITORY LIBRUSTZCASH_BRANCH LIBRUSTZCASH_REVISION LIBRUSTZCASH_TREE
    VOTING_CIRCUITS_REVISION VOTE_NULLIFIER_PIR_REVISION ZCASH_VOTING_REVISION
    SOURCE_DATE_EPOCH RUST_TOOLCHAIN FFI_ARCHIVE_POSTPROCESSING
    MACOSX_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET
    IOS_ARM64_SIMULATOR_MINIMUM_OS
)
for field in "${expected_fields[@]}"; do
    if [[ -z "$(read_field "$field")" || "$(read_field "$field")" != "$(read_field "$field" "$build_recipe")" ]]; then
        echo "Error: $field differs from the frozen build recipe" >&2
        exit 1
    fi
done

if [[ "$(read_field SDK_BASE_REVISION)" != "8f85838bcc7f59e11de45c96e1ed783093712901" \
    || "$(read_field SDK_UPSTREAM_REVISION)" != "2922143e4d686c999d9b3530282988a3838af220" \
    || "$(read_field SDK_MERGE_REVISION)" != "d555d060815b89def2337a9ad37407362b49f352" \
    || "$(read_field SYNC_ENGINE)" != "SDKSynchronizer" \
    || "$(read_field SLIPSTREAM_INCLUDED)" != "false" \
    || "$(read_field EXCLUDED_SLIPSTREAM_SDK_REVISION)" != "226333494ebe6bc377aaf4bbb513bb1ccbf16750" \
    || "$(read_field LIBRUSTZCASH_REPOSITORY)" != "https://github.com/just-zend/librustzcash" \
    || "$(read_field LIBRUSTZCASH_BRANCH)" != "agent/ironwood-nu63-compatibility" \
    || "$(read_field LIBRUSTZCASH_REVISION)" != "5115cf26da590a3d610446f1d926ff7f2873c9d1" \
    || "$(read_field LIBRUSTZCASH_TREE)" != "62f79c17fe172735fce3df4e03991e90a736b60a" \
    || "$(read_field VOTING_CIRCUITS_REVISION)" != "a5aae410a6fb14fcbea2f0ce3393035195e86f69" \
    || "$(read_field VOTE_NULLIFIER_PIR_REVISION)" != "0dea3485429c80033e67a1ddb18ee72cc450cefb" \
    || "$(read_field ZCASH_VOTING_REVISION)" != "464f974865f2afa82bdac15d169168c77ecb9c74" ]]
then
    echo "Error: provenance does not record the reviewed Ironwood source graph" >&2
    exit 1
fi

if [[ "$(read_field FFI_ARCHIVE_POSTPROCESSING)" != "thin-llvm-objcopy-remove-bitcode_lipo_apple-strip-S-x" ]]; then
    echo "Error: provenance does not record the relocation-safe archive post-processing pipeline" >&2
    exit 1
fi

if [[ ! "$(read_field SOURCE_DATE_EPOCH)" =~ ^[0-9]+$ ]]; then
    echo "Error: invalid SOURCE_DATE_EPOCH" >&2
    exit 1
fi

echo "Committed Ironwood FFI passed source, hash, architecture, ABI, platform, and path-leak checks."
