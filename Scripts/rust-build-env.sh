#!/bin/bash

# Shared Rust build environment for every FFI artifact route. This file is sourced by local
# incremental builds and BuildSupport release builds so platform floors and reproducible path
# remapping cannot drift.

ironwood_rust_build_env_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

ironwood_configure_rust_build_env() {
    local repo_root separator cargo_home rustup_home temp_root encoded c_prefix_flags mapping variable
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
    rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
    temp_root="${TMPDIR:-/tmp}"
    temp_root="${temp_root%/}"
    if [[ -z "$temp_root" ]]; then temp_root=/tmp; fi
    flags=()

    # Release artifacts are built under a hermetic policy. Clear every ambient compiler, linker,
    # bindgen, Cargo-target, and release-profile override that can alter generated code or native
    # dependencies. Local incremental builds retain developer overrides, but cannot be mistaken for
    # release builds because only build-ironwood-ffi-artifact.sh enables and records this policy.
    if [[ "${IRONWOOD_HERMETIC_BUILD:-false}" == "true" ]]; then
        while IFS= read -r variable; do
            case "$variable" in
                RUSTFLAGS|RUSTDOCFLAGS|RUSTC|RUSTDOC|RUSTC_BOOTSTRAP|\
                CARGO_ENCODED_RUSTFLAGS|CARGO_ENCODED_RUSTDOCFLAGS|\
                CARGO_BUILD_TARGET|CARGO_BUILD_TARGET_DIR|CARGO_TARGET_DIR|CARGO_INCREMENTAL|\
                CARGO_BUILD_INCREMENTAL|CARGO_BUILD_RUSTC|CARGO_BUILD_RUSTDOC|\
                CARGO_BUILD_RUSTFLAGS|CARGO_BUILD_RUSTDOCFLAGS|CARGO_PROFILE_RELEASE_*|\
                CARGO_TARGET_*_RUSTFLAGS|CARGO_TARGET_*_RUSTDOCFLAGS|\
                CARGO_TARGET_*_LINKER|CARGO_TARGET_*_AR|RUSTC_WRAPPER|RUSTC_WORKSPACE_WRAPPER|\
                CFLAGS|CFLAGS_*|CXXFLAGS|CXXFLAGS_*|CPPFLAGS|CPPFLAGS_*|LDFLAGS|LDFLAGS_*|\
                CC|CC_*|CXX|CXX_*|CPP|CPP_*|AR|AR_*|ARFLAGS|ARFLAGS_*|AS|AS_*|\
                LD|LD_*|NM|NM_*|RANLIB|RANLIB_*|STRIP|STRIP_*|OBJCOPY|OBJCOPY_*|\
                HOST_CC|HOST_CXX|HOST_AR|TARGET_CC|TARGET_CXX|TARGET_AR|\
                BINDGEN_EXTRA_CLANG_ARGS|BINDGEN_EXTRA_CLANG_ARGS_*|SDKROOT|\
                CMAKE_*|MESON_*|NINJAFLAGS|MAKEFLAGS|PKG_CONFIG|PKG_CONFIG_*)
                    unset "$variable"
                    ;;
            esac
        done < <(compgen -v)
        export IRONWOOD_BUILD_ENVIRONMENT_POLICY="hermetic-v1"
    else
        export IRONWOOD_BUILD_ENVIRONMENT_POLICY="developer-ambient-v1"
    fi

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
        "$rustup_home=/rustup/home"
        "$temp_root=/tmp/build"
        "$repo_root=/src/zcash-swift-wallet-sdk-zend"
    )

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

    # Never derive artifact timestamps from the SDK checkout's moving HEAD. The release builder
    # supplies the canonical librustzcash commit time; other build routes consume the frozen recipe.
    if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
        build_recipe="$repo_root/BuildSupport/IRONWOOD_FFI_BUILD.env"
        source_epoch=""
        if [[ -f "$build_recipe" ]]; then
            source_epoch=$(sed -n 's/^SOURCE_DATE_EPOCH=//p' "$build_recipe")
        fi
        if [[ -z "$source_epoch" ]]; then
            echo "Error: SOURCE_DATE_EPOCH must come from the frozen librustzcash build recipe" >&2
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
