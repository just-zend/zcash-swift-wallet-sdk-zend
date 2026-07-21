#!/bin/bash

# Shared Rust build environment for every FFI artifact route. Local incremental builds and
# BuildSupport release builds source this file so platform floors, NU6.3 cfgs, and reproducible
# path remapping cannot drift.

ironwood_rust_build_env_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

ironwood_configure_rust_build_env() {
    local repo_root separator cargo_home encoded c_prefix_flags mapping build_recipe source_epoch
    local flags path_mappings
    repo_root=$(cd "$ironwood_rust_build_env_script_dir/.." && pwd -P)

    export MACOSX_DEPLOYMENT_TARGET="12.0"
    export IPHONEOS_DEPLOYMENT_TARGET="13.0"
    # arm64 iOS Simulator is available from iOS 14 even though physical devices retain iOS 13.
    export IRONWOOD_IOS_ARM64_SIMULATOR_MINIMUM_OS="14.0"

    separator=$'\x1f'
    cargo_home="${CARGO_HOME:-$HOME/.cargo}"
    flags=()
    path_mappings=(
        "/Users=/host-users"
        "/home/runner=/home/build"
        "$HOME=/home/build"
        "$cargo_home=/cargo/home"
        "$cargo_home/registry=/cargo/registry"
        "$cargo_home/git/checkouts=/cargo/git-checkouts"
        "$repo_root=/src/zcash-swift-wallet-sdk-zend"
    )
    for mapping in "${path_mappings[@]}"; do
        flags+=("--remap-path-prefix=$mapping")
    done

    # CARGO_ENCODED_RUSTFLAGS overrides .cargo/config.toml, so repeat the cfg as two encoded
    # rustc arguments. zcash_voting otherwise compiles its NU6.3 protocol enum with no variants.
    flags+=("--cfg" 'zcash_unstable="nu6.3"')

    encoded=""
    for flag in "${flags[@]}"; do
        if [[ -n "$encoded" ]]; then encoded+="$separator"; fi
        encoded+="$flag"
    done
    unset RUSTFLAGS
    export CARGO_ENCODED_RUSTFLAGS="$encoded"

    c_prefix_flags=""
    for mapping in "${path_mappings[@]}"; do
        c_prefix_flags+=" -ffile-prefix-map=$mapping -fdebug-prefix-map=$mapping"
    done
    export CFLAGS="${CFLAGS:-}$c_prefix_flags"
    export CXXFLAGS="${CXXFLAGS:-}$c_prefix_flags"

    if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
        build_recipe="$repo_root/BuildSupport/IRONWOOD_FFI_BUILD.env"
        source_epoch=""
        if [[ -f "$build_recipe" ]]; then
            source_epoch=$(sed -n 's/^SOURCE_DATE_EPOCH=//p' "$build_recipe")
        fi
        if [[ -z "$source_epoch" ]] && git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
            source_epoch=$(git -C "$repo_root" log -1 --format=%ct)
        fi
        if [[ -z "$source_epoch" ]]; then
            echo "Error: SOURCE_DATE_EPOCH must come from the frozen build recipe" >&2
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
