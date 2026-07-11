#!/bin/bash

# Shared Rust build environment for every FFI artifact route. This file is sourced by local
# incremental builds and BuildSupport release builds so reproducible path remapping cannot drift.

ironwood_rust_build_env_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

ironwood_configure_rust_build_env() {
    local repo_root separator migration_path cargo_home encoded flag canonical_path c_prefix_flags mapping
    local build_recipe source_epoch
    local flags
    local path_mappings
    repo_root=$(cd "$ironwood_rust_build_env_script_dir/.." && pwd -P)

    # Cargo's Rust targets and every native dependency built through `cc` must agree with the
    # Swift package's declared platform floor. Without explicit values, current Xcode stamps C/asm
    # archive members with the host SDK version (for example macOS 26.5), which links with warnings
    # and can fail at runtime on otherwise supported devices.
    export MACOSX_DEPLOYMENT_TARGET="12.0"
    export IPHONEOS_DEPLOYMENT_TARGET="13.0"
    # arm64 iOS Simulator was introduced at iOS 14; Clang correctly clamps an iOS 13 package
    # floor to 14.0 for this architecture even while physical arm64 devices remain at 13.0.
    export IRONWOOD_IOS_ARM64_SIMULATOR_MINIMUM_OS="14.0"

    separator=$'\x1f'
    cargo_home="${CARGO_HOME:-$HOME/.cargo}"
    flags=()

    # Rust applies the last matching remap when prefixes overlap. Start with broad safety-net
    # mappings and finish with the most specific roots so a local username can never survive as
    # `/host-users/<name>` in a release artifact.
    path_mappings=(
        "/Users=/host-users"
        "/home/runner=/home/build"
        "$HOME=/home/build"
        "$cargo_home=/cargo/home"
        "$cargo_home/registry=/cargo/registry"
        "$cargo_home/git/checkouts=/cargo/git-checkouts"
        "$repo_root=/src/zcash-swift-wallet-sdk-zend"
    )

    # During coordinated local development the private engine may be a path dependency. Release
    # builds use its exact git revision under Cargo home. A local path is the most specific mapping.
    migration_path=$(sed -nE 's@^zodl_ironwood_migration = \{ path = "([^"]+)" \}@\1@p' "$repo_root/Cargo.toml" | head -1)
    if [[ -n "$migration_path" && -d "$migration_path" ]]; then
        canonical_path=$(cd "$migration_path" && pwd -P)
        path_mappings+=("$canonical_path=/src/migration-engine")
    fi
    for mapping in "${path_mappings[@]}"; do
        flags+=("--remap-path-prefix=$mapping")
    done

    encoded=""
    for flag in "${flags[@]}"; do
        if [[ -n "$encoded" ]]; then encoded+="$separator"; fi
        encoded+="$flag"
    done

    # CARGO_ENCODED_RUSTFLAGS intentionally overrides ambient RUSTFLAGS. NU6.3/Ironwood is stable
    # in the pinned upstream revision, so this contains path remaps only; no synthetic cfg gate.
    unset RUSTFLAGS
    export CARGO_ENCODED_RUSTFLAGS="$encoded"
    # Native dependencies built through the `cc` crate can also embed `__FILE__`/debug paths.
    # Apply the equivalent Clang remaps so the final static archive passes the same path-leak gate.
    c_prefix_flags=""
    for mapping in "${path_mappings[@]}"; do
        c_prefix_flags+=" -ffile-prefix-map=$mapping -fdebug-prefix-map=$mapping"
    done
    export CFLAGS="${CFLAGS:-}$c_prefix_flags"
    export CXXFLAGS="${CXXFLAGS:-}$c_prefix_flags"

    # Never derive reproducible timestamps from the SDK checkout's moving HEAD. Coordinated path
    # builds use the private engine's frozen commit time. Exact-git release builds consume the
    # recorded constant written by build-ironwood-ffi-artifact.sh, unless the caller explicitly
    # supplies the same SOURCE_DATE_EPOCH.
    if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
        build_recipe="$repo_root/BuildSupport/IRONWOOD_FFI_BUILD.env"
        source_epoch=""
        if [[ -n "$migration_path" && -d "$migration_path" ]] \
            && git -C "$migration_path" rev-parse --git-dir >/dev/null 2>&1
        then
            source_epoch=$(git -C "$migration_path" log -1 --format=%ct)
        elif [[ -f "$build_recipe" ]]; then
            source_epoch=$(sed -n 's/^SOURCE_DATE_EPOCH=//p' "$build_recipe")
        fi
        if [[ -z "$source_epoch" ]]; then
            echo "Error: SOURCE_DATE_EPOCH must come from the frozen migration-engine commit" >&2
            return 1
        fi
        export SOURCE_DATE_EPOCH="$source_epoch"
    fi
    if [[ ! "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]]; then
        echo "Error: SOURCE_DATE_EPOCH must be a non-negative integer" >&2
        return 1
    fi
}

ironwood_configure_rust_build_env
