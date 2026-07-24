#!/bin/bash

# Removes embedded LLVM payloads from each thin Rust archive, rebuilds universal archives, then
# lets Apple's Mach-O-aware strip remove debug/local symbols. Global FFI exports and unwind
# relocations remain intact, while every committed binary stays below Zend's conservative
# 100,000,000-byte Git-blob safety cap without Git LFS. This intentionally leaves headroom below
# GitHub's 100 MiB hard limit.

set -euo pipefail
cd "$(dirname "$0")/.."

xcframework="${1:-LocalPackages/libzcashlc.xcframework}"
rust_toolchain=$(sed -nE 's/^channel = "([^"]+)"/\1/p' rust-toolchain.toml)
rust_host=$(rustup run "$rust_toolchain" rustc --version --verbose | sed -n 's/^host: //p')
llvm_objcopy="$(rustup run "$rust_toolchain" rustc --print sysroot)/lib/rustlib/$rust_host/bin/llvm-objcopy"
if [[ ! -x "$llvm_objcopy" ]]; then
    echo "Error: pinned llvm-objcopy is missing; install llvm-tools-preview for Rust $rust_toolchain" >&2
    exit 1
fi
apple_strip=$(xcrun --find strip)

macos_binary="$xcframework/macos-arm64_x86_64/libzcashlc.framework/libzcashlc"
if [[ -f "$xcframework/macos-arm64_x86_64/libzcashlc.framework/Versions/A/libzcashlc" ]]; then
    macos_binary="$xcframework/macos-arm64_x86_64/libzcashlc.framework/Versions/A/libzcashlc"
fi
binaries=(
    "$xcframework/ios-arm64/libzcashlc.framework/libzcashlc"
    "$xcframework/ios-arm64_x86_64-simulator/libzcashlc.framework/libzcashlc"
    "$macos_binary"
)
expected_arch_sets=(
    "arm64"
    "arm64 x86_64"
    "arm64 x86_64"
)

zend_git_blob_safety_cap_bytes=100000000
work_dir=$(mktemp -d)
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

binary_index=0
processed_thin_architectures=0
for binary in "${binaries[@]}"; do
    if [[ ! -f "$binary" ]]; then
        echo "Error: missing full-build archive $binary" >&2
        exit 1
    fi

    binary_work_dir="$work_dir/$binary_index"
    mkdir -p "$binary_work_dir"
    archs=()
    while IFS= read -r arch; do
        archs+=("$arch")
    done < <(lipo -archs "$binary" | tr ' ' '\n')
    if [[ ${#archs[@]} -eq 0 ]]; then
        echo "Error: no architectures found in $binary" >&2
        exit 1
    fi
    actual_arch_set=$(printf '%s\n' "${archs[@]}" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
    if [[ "$actual_arch_set" != "${expected_arch_sets[$binary_index]}" ]]; then
        echo "Error: unexpected pre-strip architectures for $binary: $actual_arch_set" >&2
        exit 1
    fi

    cleaned_archives=()
    for arch in "${archs[@]}"; do
        thin_archive="$binary_work_dir/$arch.a"
        cleaned_archive="$binary_work_dir/$arch-clean.a"
        if [[ ${#archs[@]} -eq 1 ]]; then
            cp "$binary" "$thin_archive"
        else
            lipo "$binary" -thin "$arch" -output "$thin_archive"
        fi

        # Rust 1.96's LLVM strip -x removes local symbols that Mach-O SUBTRACTOR relocations in
        # __eh_frame still reference. Remove only embedded LLVM payloads here; Apple's strip below
        # preserves those relocation pairs while bringing universal archives under Zend's cap.
        "$llvm_objcopy" \
            --remove-section='__LLVM,__bitcode' \
            --remove-section='__LLVM,__cmdline' \
            "$thin_archive" "$cleaned_archive"
        cleaned_archives+=("$cleaned_archive")
        processed_thin_architectures=$((processed_thin_architectures + 1))
    done

    rebuilt_archive="$binary_work_dir/rebuilt.a"
    if [[ ${#cleaned_archives[@]} -eq 1 ]]; then
        cp "${cleaned_archives[0]}" "$rebuilt_archive"
    else
        lipo -create "${cleaned_archives[@]}" -output "$rebuilt_archive"
    fi
    "$apple_strip" -S -x "$rebuilt_archive"
    mv "$rebuilt_archive" "$binary"

    size=$(stat -f '%z' "$binary")
    if (( size >= zend_git_blob_safety_cap_bytes )); then
        echo "Error: post-processed archive exceeds Zend's Git-blob safety cap: $binary ($size bytes)" >&2
        exit 1
    fi
    echo "Post-processed $binary ($size bytes)"
    binary_index=$((binary_index + 1))
done

if [[ "$binary_index" != "3" || "$processed_thin_architectures" != "5" ]]; then
    echo "Error: expected to post-process three archives and five thin architectures" >&2
    exit 1
fi
echo "Post-processed all five thin architectures across three platform archives"
