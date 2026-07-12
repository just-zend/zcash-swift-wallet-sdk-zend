#!/bin/bash

# Public-artifact gate for the committed Ironwood FFI. This intentionally requires no access to
# the private migration-engine repository.

set -euo pipefail
cd "$(dirname "$0")/.."

xcframework="LocalPackages/libzcashlc.xcframework"
provenance="LocalPackages/IRONWOOD_FFI_PROVENANCE.env"
build_recipe="BuildSupport/IRONWOOD_FFI_BUILD.env"
test -f "$xcframework/Info.plist"
test -f "$provenance"
test -f "$build_recipe"

if find LocalPackages -type f \( -name '*.rs' -o -name Cargo.toml -o -name Cargo.lock -o -name '*.rlib' \) | grep -q .; then
    echo "Error: private/source Rust material must not be committed under LocalPackages" >&2
    exit 1
fi
if find LocalPackages -type d -name .git | grep -q .; then
    echo "Error: nested source repository found under LocalPackages" >&2
    exit 1
fi

required_symbols=(
    zcashlc_network_upgrade_activation_height
    zcashlc_consensus_chain_id
    zcashlc_consensus_parameters_fingerprint
    zcashlc_last_migration_error_code
)

# Derive the complete migration ABI from every production Swift welding call. A hand-maintained
# subset previously let a stale XCFramework pass while newer lifecycle/resume/commit entry points
# were absent. The committed artifact must export every migration symbol the SDK can call, in every
# slice, and its generated header must declare the same set.
while IFS= read -r symbol; do
    required_symbols+=("$symbol")
done < <(
    LC_ALL=C grep -Eo 'zcashlc_migration_[a-z0-9_]+' \
        Sources/ZcashLightClientKit/Rust/ZcashRustBackend.swift \
        | LC_ALL=C sort -u
)

forbidden_paths=(
    '/host-users/'
    '/home/runner'
    '.codex/worktrees'
)
while IFS= read -r artifact_file; do
    for forbidden in "${forbidden_paths[@]}"; do
        if LC_ALL=C grep -aFq "$forbidden" "$artifact_file"; then
            echo "Error: non-reproducible/private build path '$forbidden' found in $artifact_file" >&2
            exit 1
        fi
    done
done < <(find LocalPackages -type f | LC_ALL=C sort)

# Rust's precompiled macOS compiler-builtins archive carries its public upstream CI source prefix.
# Build-time remapping cannot rewrite those already-compiled members. Allow only that exact Rust
# distribution prefix; any other `/Users/...` string is a local/private path leak.
while IFS= read -r artifact_file; do
    if strings "$artifact_file" \
        | sed 's@/Users/runner/work/rust/rust/@/rust-distribution/@g' \
        | LC_ALL=C grep -Fq '/Users/'
    then
        echo "Error: non-reproducible/private /Users path found in $artifact_file" >&2
        exit 1
    fi
done < <(find LocalPackages -type f | LC_ALL=C sort)

# The repository basename is intentionally present once in the canonical provenance URL. It must
# not leak into any generated framework/header, where it would indicate embedded private source
# metadata or a build path.
while IFS= read -r artifact_file; do
    if LC_ALL=C grep -aFq 'ZODLIronwoodMigrationRust' "$artifact_file"; then
        echo "Error: private migration-engine source metadata found in $artifact_file" >&2
        exit 1
    fi
done < <(find LocalPackages -type f ! -path "$provenance" | LC_ALL=C sort)

binary_count=0
while IFS= read -r binary; do
    binary_count=$((binary_count + 1))
    header="$(dirname "$binary")/Headers/zcashlc.h"
    test -f "$header"
    symbols_file=$(mktemp)
    nm_output=$(mktemp)
    nm_errors=$(mktemp)
    nm_status=0
    # Rust 1.96 uses LLVM 22 bitcode attributes that the current Apple `nm` may warn it cannot
    # decode for unrelated compiler-builtins archive members. Capture all successfully decoded
    # global defined symbols and verify every required ABI entry explicitly; do not let those
    # unrelated member diagnostics hide a missing production symbol.
    nm -gUj "$binary" > "$nm_output" 2> "$nm_errors" || nm_status=$?
    sed 's/^_//' "$nm_output" | LC_ALL=C sort -u > "$symbols_file"
    for symbol in "${required_symbols[@]}"; do
        if ! grep -Fq "$symbol" "$header"; then
            echo "Error: $symbol missing from $header" >&2
            rm -f "$symbols_file" "$nm_output" "$nm_errors"
            exit 1
        fi
        if ! grep -Fxq "$symbol" "$symbols_file"; then
            echo "Error: $symbol missing from exported symbols in $binary" >&2
            if [[ "$nm_status" != "0" ]]; then
                sed -n '1,10p' "$nm_errors" >&2
            fi
            rm -f "$symbols_file" "$nm_output" "$nm_errors"
            exit 1
        fi
    done
    rm -f "$symbols_file" "$nm_output" "$nm_errors"
done < <(find "$xcframework" -type f -path '*/libzcashlc.framework/libzcashlc' | LC_ALL=C sort)

if [[ "$binary_count" == "0" ]]; then
    echo "Error: no FFI binaries found" >&2
    exit 1
fi

verify_hash() {
    local variable="$1"
    local relative_path="$2"
    local expected actual
    expected=$(sed -n "s/^${variable}=//p" "$provenance")
    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        echo "Error: missing or invalid $variable in $provenance" >&2
        exit 1
    fi
    test -f "$relative_path"
    actual=$(shasum -a 256 "$relative_path" | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        echo "Error: hash mismatch for $relative_path" >&2
        exit 1
    fi
}

verify_hash IOS_ARM64_SHA256 "$xcframework/ios-arm64/libzcashlc.framework/libzcashlc"
verify_hash IOS_ARM64_SIMULATOR_SHA256 "$xcframework/ios-arm64-simulator/libzcashlc.framework/libzcashlc"
verify_hash MACOS_ARM64_SHA256 "$xcframework/macos-arm64/libzcashlc.framework/libzcashlc"

verify_archive_platform_floor() {
    local binary="$1"
    local expected_platform="$2"
    local maximum_minos="$3"
    if ! otool -l "$binary" 2>/dev/null | awk \
        -v expected_platform="$expected_platform" -v maximum_minos="$maximum_minos" '
        function version_gt(found, maximum, f, m, i) {
            split(found, f, ".")
            split(maximum, m, ".")
            for (i = 1; i <= 3; i++) {
                if ((f[i] + 0) > (m[i] + 0)) return 1
                if ((f[i] + 0) < (m[i] + 0)) return 0
            }
            return 0
        }
        $1 == "platform" {
            found_build_version = 1
            if ($2 != expected_platform) invalid = 1
        }
        $1 == "minos" && version_gt($2, maximum_minos) { invalid = 1 }
        END { exit (!found_build_version || invalid) }
        '
    then
        echo "Error: $binary contains a wrong-platform or too-new deployment target" >&2
        exit 1
    fi
}

# Mach-O LC_BUILD_VERSION platform constants: macOS=1, iOS=2, iOS Simulator=7.
verify_archive_platform_floor \
    "$xcframework/ios-arm64/libzcashlc.framework/libzcashlc" 2 13.0
verify_archive_platform_floor \
    "$xcframework/ios-arm64-simulator/libzcashlc.framework/libzcashlc" 7 14.0
verify_archive_platform_floor \
    "$xcframework/macos-arm64/libzcashlc.framework/libzcashlc" 1 12.0

read_field() {
    local field="$1"
    local file="${2:-$provenance}"
    sed -n "s/^${field}=//p" "$file"
}

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

recorded_source_date_epoch=$(read_field SOURCE_DATE_EPOCH)
recipe_source_date_epoch=$(read_field SOURCE_DATE_EPOCH "$build_recipe")
if [[ ! "$recorded_source_date_epoch" =~ ^[0-9]+$ || "$recorded_source_date_epoch" != "$recipe_source_date_epoch" ]]; then
    echo "Error: SOURCE_DATE_EPOCH differs from the frozen build recipe" >&2
    exit 1
fi

expected_librustzcash_rev="54ff673169ec8be5a4b023a7ae69bcf5caead2a3"
recorded_librustzcash_rev=$(read_field LIBRUSTZCASH_REVISION)
if [[ "$recorded_librustzcash_rev" != "$expected_librustzcash_rev" ]]; then
    echo "Error: provenance does not record the audited librustzcash revision" >&2
    exit 1
fi

migration_revision=$(read_field MIGRATION_ENGINE_REVISION)
migration_tree=$(read_field MIGRATION_ENGINE_TREE)
expected_migration_repository="ssh://git@github.com/just-zend/ZODLIronwoodMigrationRust.git"
migration_repository=$(read_field MIGRATION_ENGINE_REPOSITORY)
if [[ ! "$migration_revision" =~ ^[0-9a-f]{40}$ || ! "$migration_tree" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Error: invalid migration-engine commit/tree provenance" >&2
    exit 1
fi
if [[ "$migration_repository" != "$expected_migration_repository" \
    || "$migration_repository" != "$(read_field MIGRATION_ENGINE_REPOSITORY "$build_recipe")" \
    || "$migration_revision" != "$(read_field MIGRATION_ENGINE_REVISION "$build_recipe")" \
    || "$migration_tree" != "$(read_field MIGRATION_ENGINE_TREE "$build_recipe")" \
    || "$recorded_toolchain" != "$(read_field RUST_TOOLCHAIN "$build_recipe")" ]]
then
    echo "Error: artifact provenance differs from the frozen build recipe" >&2
    exit 1
fi
if ! grep -Fxq \
    "zodl_ironwood_migration = { git = \"$migration_repository\", rev = \"$migration_revision\" }" \
    Cargo.toml
then
    echo "Error: Cargo.toml migration-engine pin differs from FFI provenance" >&2
    exit 1
fi

echo "Committed Ironwood FFI passed provenance, hash, symbol, and path-leak checks."
