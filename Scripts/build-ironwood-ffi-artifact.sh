#!/bin/bash

# Builds the full five-architecture Ironwood XCFramework from the frozen public Rust graph and
# writes the reproducibility/provenance records consumed by public CI.

set -euo pipefail
cd "$(dirname "$0")/.."

expected_librustzcash_repository="https://github.com/just-zend/librustzcash"
expected_sdk_base_revision="9476ced615d90407270d3d741823d5797ef0f501"
expected_sdk_ironwood_upstream_revision="61be7e006d0b4bacb5933d8da28b08410f8ee126"
expected_sdk_ironwood_merge_revision="71f6977dce5b281d69a86597051849bf88ea13d0"
expected_sdk_pool_migration_upstream_revision="92a9b2b663bb0c5275794788c1d33a0e3fe0adc8"
expected_sdk_pool_migration_merge_revision="d2dbd935a896630a878d997c792d8e3b7c46563a"
expected_sdk_pr1812_upstream_revision="daf1aa1bda57cbc4044f8978cb6170f82940a3d8"
expected_sdk_pr1812_merge_revision="0835b3cd3275580802e5d26b0fd0896b2c1e3155"
upstream_1807_merge_revision="ef6c31420cf861d459b5fe41a47997fe255ffa4b"
included_upstream_1813_revision="adfe9ca7a989f7a7197f8b10138519f8a02f790f"
included_upstream_1821_revision="eb219e2f86f5725377ebdf3985815c809a954450"
included_upstream_1822_revision="5aa8b4b4bb1ff4075a670b56de268295cff45589"
zcash_voting_revision="a4daaf77f793b35a98a3d811b920a01b95fbfa7a"
orchard_version="0.15.4"
orchard_checksum="793e2e8c2323f35f082d1b3467ca8f576d646f9c93aef8c5168809d099245af8"
archive_postprocessing="thin-llvm-objcopy-remove-bitcode_lipo_apple-strip-S-x"

# Disable ambient Git configuration before the first repository query. In particular, URL rewrite,
# object-store, or worktree overrides must not be able to change the source identity that is frozen
# into artifact provenance.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
while IFS= read -r git_variable; do
    case "$git_variable" in
        GIT_CONFIG_COUNT|GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*|GIT_CONFIG_SYSTEM)
            unset "$git_variable"
            ;;
    esac
done < <(compgen -v)

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Error: SDK checkout must be clean before an artifact build" >&2
    exit 1
fi

# Reduce the executable search path to reviewed system/Xcode tools plus the directories containing
# the explicitly required bootstrap tools. Global/system Git configuration and ambient Rustup
# selection are disabled; the exact toolchain is installed into a fresh build-owned home below.
trusted_tool_dirs=(/usr/bin /bin /usr/sbin /sbin)
for required_tool in rustup rg jq cmake ninja pkg-config; do
    if ! tool_path=$(command -v "$required_tool" 2>/dev/null) \
        || [[ "$tool_path" != /* || ! -x "$tool_path" ]]
    then
        echo "Error: required artifact-build tool is unavailable: $required_tool" >&2
        exit 1
    fi
    trusted_tool_dirs+=("$(cd "$(dirname "$tool_path")" && pwd -P)")
done
trusted_path=""
for tool_dir in "${trusted_tool_dirs[@]}"; do
    case ":$trusted_path:" in
        *":$tool_dir:"*) ;;
        *) trusted_path="${trusted_path:+$trusted_path:}$tool_dir" ;;
    esac
done
export PATH="$trusted_path"
unset RUSTUP_TOOLCHAIN RUSTUP_DIST_SERVER RUSTUP_UPDATE_ROOT

sdk_ffi_source_revision=$(git rev-parse HEAD)
sdk_ffi_source_tree=$(git rev-parse 'HEAD^{tree}')
sdk_ironwood_implementation_revision="${SDK_IRONWOOD_IMPLEMENTATION_REVISION:-$sdk_ffi_source_revision}"
if [[ ! "$sdk_ffi_source_revision" =~ ^[0-9a-f]{40}$ \
    || ! "$sdk_ffi_source_tree" =~ ^[0-9a-f]{40}$ \
    || ! "$sdk_ironwood_implementation_revision" =~ ^[0-9a-f]{40}$ ]]
then
    echo "Error: SDK source/implementation provenance must name exact commits" >&2
    exit 1
fi
if ! git merge-base --is-ancestor "$sdk_ironwood_implementation_revision" HEAD; then
    echo "Error: SDK Ironwood implementation revision is not reachable from HEAD" >&2
    exit 1
fi

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

normalize_github_repository() {
    local repository="$1"
    repository="${repository%.git}"
    repository="${repository#git@github.com:}"
    repository="${repository#ssh://git@github.com/}"
    repository="${repository#https://github.com/}"
    printf 'https://github.com/%s\n' "$repository"
}

librustzcash_origin=$(normalize_github_repository "$(git -C "$librustzcash_repo" remote get-url origin)")
librustzcash_revision=$(git -C "$librustzcash_repo" rev-parse HEAD)
librustzcash_tree=$(git -C "$librustzcash_repo" rev-parse 'HEAD^{tree}')
source_date_epoch=$(git -C "$librustzcash_repo" log -1 --format=%ct)
if [[ "$librustzcash_origin" != "$expected_librustzcash_repository" \
    || ! "$librustzcash_revision" =~ ^[0-9a-f]{40}$ \
    || ! "$librustzcash_tree" =~ ^[0-9a-f]{40}$ ]]
then
    echo "Error: librustzcash checkout is not an exact commit in the canonical Zend repository" >&2
    exit 1
fi

# Before merge, an exact branch or tag normally points at the reviewed revision. After merge and
# branch deletion, pass LIBRUSTZCASH_PUBLISHED_REF=refs/heads/main (or another reviewed ref); the
# exact revision must then be reachable from that live remote ref.
published_ref="${LIBRUSTZCASH_PUBLISHED_REF:-}"
if [[ -z "$published_ref" ]]; then
    published_ref=$(git -C "$librustzcash_repo" ls-remote --refs origin \
        | awk -v revision="$librustzcash_revision" '$1 == revision { print $2; exit }')
    if [[ -z "$published_ref" ]]; then
        echo "Error: exact librustzcash revision is not a remote ref tip; set LIBRUSTZCASH_PUBLISHED_REF" >&2
        exit 1
    fi
fi
if [[ ! "$published_ref" =~ ^refs/(heads|tags)/[-A-Za-z0-9._/]+$ ]]; then
    echo "Error: librustzcash published ref must be a full branch or tag ref: $published_ref" >&2
    exit 1
fi
published_tip=$(git -C "$librustzcash_repo" ls-remote --refs origin "$published_ref" | awk 'NR == 1 { print $1 }')
if [[ ! "$published_tip" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Error: librustzcash published ref does not exist on origin: $published_ref" >&2
    exit 1
fi
git -C "$librustzcash_repo" fetch --no-tags origin "$published_ref"
if [[ "$(git -C "$librustzcash_repo" rev-parse FETCH_HEAD)" != "$published_tip" ]] \
    || ! git -C "$librustzcash_repo" merge-base --is-ancestor "$librustzcash_revision" FETCH_HEAD
then
    echo "Error: exact librustzcash revision is not reachable from $published_ref" >&2
    exit 1
fi
publication_tip_at_build="$published_tip"
if [[ -n "${LIBRUSTZCASH_RECORDED_PUBLICATION_TIP:-}" ]]; then
    recorded_publication_tip="$LIBRUSTZCASH_RECORDED_PUBLICATION_TIP"
    if [[ ! "$recorded_publication_tip" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Error: recorded librustzcash publication tip must be an exact commit" >&2
        exit 1
    fi
    git -C "$librustzcash_repo" fetch --no-tags origin "$recorded_publication_tip"
    if ! git -C "$librustzcash_repo" merge-base --is-ancestor \
            "$librustzcash_revision" "$recorded_publication_tip" \
        || ! git -C "$librustzcash_repo" merge-base --is-ancestor \
            "$recorded_publication_tip" "$published_tip"
    then
        echo "Error: recorded publication tip is not on the live containing-ref lineage" >&2
        exit 1
    fi
    publication_tip_at_build="$recorded_publication_tip"
fi

recipe_temp=$(mktemp)
provenance_temp=""
hermetic_root=$(mktemp -d)
mkdir -p "$hermetic_root/home" "$hermetic_root/cargo" "$hermetic_root/rustup" "$hermetic_root/tmp"
export HOME="$hermetic_root/home"
export CARGO_HOME="$hermetic_root/cargo"
export RUSTUP_HOME="$hermetic_root/rustup"
export TMPDIR="$hermetic_root/tmp"
cleanup() {
    rm -f "$recipe_temp"
    if [[ -n "$provenance_temp" ]]; then rm -f "$provenance_temp"; fi
    rm -rf "$hermetic_root"
}
trap cleanup EXIT

EXPECTED_LIBRUSTZCASH_REVISION="$librustzcash_revision" \
    ./Scripts/verify-ironwood-cargo-pins.sh

verify_merge() {
    local merge_revision="$1"
    local expected_first_parent="$2"
    local expected_second_parent="$3"
    if [[ "$(git rev-parse "$merge_revision^1")" != "$expected_first_parent" \
        || "$(git rev-parse "$merge_revision^2")" != "$expected_second_parent" ]]
    then
        echo "Error: SDK merge topology differs at $merge_revision" >&2
        exit 1
    fi
}
verify_merge \
    "$expected_sdk_ironwood_merge_revision" \
    "$expected_sdk_base_revision" \
    "$expected_sdk_ironwood_upstream_revision"
verify_merge \
    "$expected_sdk_pool_migration_merge_revision" \
    "$expected_sdk_ironwood_merge_revision" \
    "$expected_sdk_pool_migration_upstream_revision"

resolve_integration_merge() {
    local label="$1"
    local included_revision="$2"
    local requested_revision="$3"
    local candidates candidate_count requested_count parents parent_count
    candidates=$(git rev-list --parents HEAD | awk -v included="$included_revision" '
        {
            for (parent = 3; parent <= NF; parent += 1) {
                if ($parent == included) print $1
            }
        }
    ')
    candidate_count=$(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l | tr -d ' ')
    if [[ -n "$requested_revision" ]]; then
        requested_count=$(printf '%s\n' "$candidates" | grep -Fxc "$requested_revision" || true)
        if [[ ! "$requested_revision" =~ ^[0-9a-f]{40}$ \
            || "$requested_count" != "1" ]]
        then
            echo "Error: requested $label merge does not integrate the exact reviewed head" >&2
            exit 1
        fi
        printf '%s\n' "$requested_revision"
        return
    fi
    if [[ "$candidate_count" != "1" ]]; then
        echo "Error: expected one $label integration merge, found $candidate_count; set ${label}_MERGE_REVISION" >&2
        exit 1
    fi
    parents=$(git show -s --format=%P "$candidates")
    parent_count=$(printf '%s\n' "$parents" | wc -w | tr -d ' ')
    if (( parent_count < 2 )); then
        echo "Error: $label integration provenance is not a merge commit" >&2
        exit 1
    fi
    printf '%s\n' "$candidates"
}

upstream_1821_merge_revision=$(resolve_integration_merge \
    UPSTREAM_1821 \
    "$included_upstream_1821_revision" \
    "${UPSTREAM_1821_MERGE_REVISION:-}")
upstream_1822_merge_revision=$(resolve_integration_merge \
    UPSTREAM_1822 \
    "$included_upstream_1822_revision" \
    "${UPSTREAM_1822_MERGE_REVISION:-}")
verify_merge \
    "$upstream_1821_merge_revision" \
    "$expected_sdk_pool_migration_merge_revision" \
    "$included_upstream_1821_revision"
verify_merge \
    "$upstream_1822_merge_revision" \
    "$upstream_1821_merge_revision" \
    "$included_upstream_1822_revision"
verify_merge \
    "$expected_sdk_pr1812_merge_revision" \
    "$upstream_1822_merge_revision" \
    "$expected_sdk_pr1812_upstream_revision"
if [[ "$(git rev-parse "$upstream_1807_merge_revision^2")" != "$expected_sdk_ironwood_upstream_revision" ]] \
    || ! git merge-base --is-ancestor "$included_upstream_1813_revision" "$expected_sdk_pr1812_upstream_revision" \
    || ! git merge-base --is-ancestor "$included_upstream_1821_revision" HEAD \
    || ! git merge-base --is-ancestor "$included_upstream_1822_revision" HEAD \
    || ! git merge-base --is-ancestor "$expected_sdk_pool_migration_merge_revision" HEAD \
    || ! git merge-base --is-ancestor "$expected_sdk_pr1812_merge_revision" HEAD
then
    echo "Error: SDK checkout does not contain the reviewed #1807/#1812 source graph" >&2
    exit 1
fi

rust_toolchain=$(sed -nE 's/^channel = "([^"]+)"/\1/p' rust-toolchain.toml)
makefile_toolchain=$(sed -nE 's/^RUST_TOOLCHAIN = ([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' BuildSupport/Makefile)
if [[ ! "$rust_toolchain" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
    || "$makefile_toolchain" != "$rust_toolchain" ]]
then
    echo "Error: rust-toolchain.toml and BuildSupport/Makefile must share one exact stable release" >&2
    exit 1
fi

rustup toolchain install "$rust_toolchain" --profile minimal
rustup component add --toolchain "$rust_toolchain" llvm-tools-preview
rustup target add --toolchain "$rust_toolchain" \
    aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim \
    x86_64-apple-darwin x86_64-apple-ios

# `RUSTUP_HOME` and `CARGO_HOME` above are deliberately fresh, so rustup does not install proxy
# shims such as `$CARGO_HOME/bin/rustc`. Resolve the binaries from the installed toolchain itself
# and add only their reviewed directory to the already-reduced PATH. This keeps the build hermetic
# and works on runners that provide `rustup` without ambient `rustc`/`cargo` shims.
rustc_binary=$(rustup which --toolchain "$rust_toolchain" rustc)
cargo_binary=$(rustup which --toolchain "$rust_toolchain" cargo)
for rust_tool in "$rustc_binary" "$cargo_binary"; do
    if [[ "$rust_tool" != /* || ! -x "$rust_tool" ]]; then
        echo "Error: rustup returned an invalid pinned toolchain binary: $rust_tool" >&2
        exit 1
    fi
done
rust_toolchain_bin=$(cd "$(dirname "$rustc_binary")" && pwd -P)
if [[ "$(cd "$(dirname "$cargo_binary")" && pwd -P)" != "$rust_toolchain_bin" ]]; then
    echo "Error: pinned rustc and cargo did not resolve from one toolchain directory" >&2
    exit 1
fi
export PATH="$rust_toolchain_bin:$PATH"

rustc_release=$("$rustc_binary" --version --verbose | sed -n 's/^release: //p')
rustc_commit=$("$rustc_binary" --version --verbose | sed -n 's/^commit-hash: //p')
cargo_release=$("$cargo_binary" --version --verbose | sed -n 's/^release: //p')
cargo_commit=$("$cargo_binary" --version --verbose | sed -n 's/^commit-hash: //p')
xcode_version=$(xcodebuild -version | sed -n '1s/^Xcode //p')
xcode_build_version=$(xcodebuild -version | sed -n '2s/^Build version //p')
iphoneos_sdk_version=$(xcrun --sdk iphoneos --show-sdk-version)
iphonesimulator_sdk_version=$(xcrun --sdk iphonesimulator --show-sdk-version)
macosx_sdk_version=$(xcrun --sdk macosx --show-sdk-version)
macos_version=$(sw_vers -productVersion)
macos_build_version=$(sw_vers -buildVersion)
rust_host=$("$rustc_binary" --version --verbose | sed -n 's/^host: //p')
llvm_objcopy="$("$rustc_binary" --print sysroot)/lib/rustlib/$rust_host/bin/llvm-objcopy"
if [[ ! -x "$llvm_objcopy" ]]; then
    echo "Error: pinned llvm-objcopy is missing after llvm-tools installation" >&2
    exit 1
fi
xcode_developer_dir=$(xcode-select -p)
apple_ld=$(xcrun --find ld)
apple_lipo=$(xcrun --find lipo)
apple_strip=$(xcrun --find strip)
apple_clang=$(xcrun --find clang)
rustup_binary=$(command -v rustup)
git_binary=$(command -v git)
make_binary=$(command -v make)
tool_sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
}
rustup_sha256=$(tool_sha256 "$rustup_binary")
git_sha256=$(tool_sha256 "$git_binary")
make_sha256=$(tool_sha256 "$make_binary")
llvm_objcopy_sha256=$(tool_sha256 "$llvm_objcopy")
apple_ld_sha256=$(tool_sha256 "$apple_ld")
apple_lipo_sha256=$(tool_sha256 "$apple_lipo")
apple_strip_sha256=$(tool_sha256 "$apple_strip")
apple_clang_sha256=$(tool_sha256 "$apple_clang")
build_path_sha256=$(./Scripts/hash-ironwood-build-path.sh "$PATH" "$rust_toolchain_bin")

export SOURCE_DATE_EPOCH="$source_date_epoch"
export IRONWOOD_HERMETIC_BUILD=true
# shellcheck source=Scripts/rust-build-env.sh
source Scripts/rust-build-env.sh
if [[ "$IRONWOOD_BUILD_ENVIRONMENT_POLICY" != "hermetic-v1" ]]; then
    echo "Error: canonical artifact build did not enter the hermetic environment policy" >&2
    exit 1
fi

printf '%s\n' \
    "SDK_FFI_SOURCE_REVISION=$sdk_ffi_source_revision" \
    "SDK_FFI_SOURCE_TREE=$sdk_ffi_source_tree" \
    "SDK_IRONWOOD_IMPLEMENTATION_REVISION=$sdk_ironwood_implementation_revision" \
    "SDK_BASE_REVISION=$expected_sdk_base_revision" \
    "SDK_IRONWOOD_UPSTREAM_REVISION=$expected_sdk_ironwood_upstream_revision" \
    "SDK_IRONWOOD_MERGE_REVISION=$expected_sdk_ironwood_merge_revision" \
    "SDK_POOL_MIGRATION_UPSTREAM_REVISION=$expected_sdk_pool_migration_upstream_revision" \
    "SDK_POOL_MIGRATION_MERGE_REVISION=$expected_sdk_pool_migration_merge_revision" \
    "SDK_PR_1812_UPSTREAM_REVISION=$expected_sdk_pr1812_upstream_revision" \
    "SDK_PR_1812_MERGE_REVISION=$expected_sdk_pr1812_merge_revision" \
    "UPSTREAM_1807_MERGE_REVISION=$upstream_1807_merge_revision" \
    "INCLUDED_UPSTREAM_1813_REVISION=$included_upstream_1813_revision" \
    "INCLUDED_UPSTREAM_1821_REVISION=$included_upstream_1821_revision" \
    "INCLUDED_UPSTREAM_1822_REVISION=$included_upstream_1822_revision" \
    "UPSTREAM_1821_MERGE_REVISION=$upstream_1821_merge_revision" \
    "UPSTREAM_1822_MERGE_REVISION=$upstream_1822_merge_revision" \
    "LIBRUSTZCASH_REPOSITORY=$expected_librustzcash_repository" \
    "LIBRUSTZCASH_REVISION=$librustzcash_revision" \
    "LIBRUSTZCASH_TREE=$librustzcash_tree" \
    "ZCASH_VOTING_REVISION=$zcash_voting_revision" \
    "ORCHARD_VERSION=$orchard_version" \
    "ORCHARD_CHECKSUM=$orchard_checksum" \
    "SOURCE_DATE_EPOCH=$source_date_epoch" \
    "RUST_TOOLCHAIN=$rust_toolchain" \
    "BUILD_ENVIRONMENT_POLICY=$IRONWOOD_BUILD_ENVIRONMENT_POLICY" \
    "FFI_ARCHIVE_POSTPROCESSING=$archive_postprocessing" \
    "BUILD_PATH_POLICY=explicit-required-tool-dirs-normalized-rust-v1" \
    "BUILD_PATH_SHA256=$build_path_sha256" \
    "RUSTUP_HOME_POLICY=ephemeral-empty-v1" \
    "GIT_CONFIG_POLICY=system-global-disabled-v1" \
    "RUSTUP_SHA256=$rustup_sha256" \
    "GIT_SHA256=$git_sha256" \
    "MAKE_SHA256=$make_sha256" \
    "LLVM_OBJCOPY_SHA256=$llvm_objcopy_sha256" \
    "APPLE_LD_SHA256=$apple_ld_sha256" \
    "APPLE_LIPO_SHA256=$apple_lipo_sha256" \
    "APPLE_STRIP_SHA256=$apple_strip_sha256" \
    "APPLE_CLANG_SHA256=$apple_clang_sha256" \
    "XCODE_DEVELOPER_DIR=$xcode_developer_dir" \
    "MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET" \
    "IPHONEOS_DEPLOYMENT_TARGET=$IPHONEOS_DEPLOYMENT_TARGET" \
    "IOS_ARM64_SIMULATOR_MINIMUM_OS=$IRONWOOD_IOS_ARM64_SIMULATOR_MINIMUM_OS" \
    > "$recipe_temp"
mv "$recipe_temp" BuildSupport/IRONWOOD_FFI_BUILD.env

sdk_ffi_source_sha256_before=$(./Scripts/hash-ironwood-ffi-sources.sh)
IRONWOOD_STATIC_SKIP_ARTIFACT=true ./Scripts/verify-ironwood-static-release-inputs.sh
./Scripts/audit-ironwood-dependency-graph.sh
make -C BuildSupport clean
IRONWOOD_DEFER_ARCHIVE_POSTPROCESSING=true ./Scripts/init-local-ffi.sh
./Scripts/strip-ironwood-ffi-archives.sh LocalPackages/libzcashlc.xcframework

sdk_ffi_source_sha256_after=$(./Scripts/hash-ironwood-ffi-sources.sh)
if [[ "$sdk_ffi_source_sha256_before" != "$sdk_ffi_source_sha256_after" ]]; then
    echo "Error: SDK FFI source inputs changed during the artifact build" >&2
    exit 1
fi
sdk_ffi_source_sha256="$sdk_ffi_source_sha256_before"
xcframework=LocalPackages/libzcashlc.xcframework
ios_arm64_sha256=$(shasum -a 256 "$xcframework/ios-arm64/libzcashlc.framework/libzcashlc" | awk '{print $1}')
ios_simulator_universal_sha256=$(shasum -a 256 "$xcframework/ios-arm64_x86_64-simulator/libzcashlc.framework/libzcashlc" | awk '{print $1}')
macos_universal_sha256=$(shasum -a 256 "$xcframework/macos-arm64_x86_64/libzcashlc.framework/libzcashlc" | awk '{print $1}')
xcframework_info_sha256=$(shasum -a 256 "$xcframework/Info.plist" | awk '{print $1}')
xcframework_manifest_sha256=$(./Scripts/hash-ironwood-xcframework.sh "$xcframework")

provenance_temp=$(mktemp)
cat BuildSupport/IRONWOOD_FFI_BUILD.env > "$provenance_temp"
printf '%s\n' \
    "LIBRUSTZCASH_PUBLICATION_REF_AT_BUILD=$published_ref" \
    "LIBRUSTZCASH_PUBLICATION_TIP_AT_BUILD=$publication_tip_at_build" \
    "SDK_FFI_SOURCE_SHA256=$sdk_ffi_source_sha256" \
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
    "XCFRAMEWORK_MANIFEST_SHA256=$xcframework_manifest_sha256" \
    >> "$provenance_temp"
mv "$provenance_temp" LocalPackages/IRONWOOD_FFI_PROVENANCE.env
provenance_temp=""

./Scripts/verify-ironwood-static-release-inputs.sh
IRONWOOD_ADDITIONAL_FORBIDDEN_BUILD_ROOTS="$(pwd -P):$librustzcash_repo:$hermetic_root:$CARGO_HOME:$RUSTUP_HOME:$HOME:$TMPDIR" \
    ./Scripts/verify-ironwood-ffi-artifact.sh
