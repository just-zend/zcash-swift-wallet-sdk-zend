#!/bin/bash

# Emits one deterministic SHA-256 over every SDK input that can change the Rust FFI binary or
# XCFramework assembly. Exact external git sources are represented by Cargo.lock and the frozen
# repository revision/tree in IRONWOOD_FFI_PROVENANCE.env.

set -euo pipefail
repo_root="${IRONWOOD_FFI_SOURCE_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}"
cd "$repo_root"

files=(
    Cargo.lock
    Cargo.toml
    Package.swift
    rust-toolchain.toml
    BuildSupport/IRONWOOD_FFI_BUILD.env
    BuildSupport/Info.plist
    BuildSupport/Makefile
    BuildSupport/module.modulemap
    BuildSupport/platform-Info.plist
    Scripts/audit-disabled-migration-ffi.sh
    Scripts/audit-ironwood-dependency-graph.sh
    Scripts/build-ironwood-ffi-artifact.sh
    Scripts/compare-ironwood-xcframeworks.sh
    Scripts/hash-ironwood-build-path.sh
    Scripts/hash-ironwood-xcframework.sh
    Scripts/hash-ironwood-ffi-sources.sh
    Scripts/init-local-ffi.sh
    Scripts/import-ironwood-ffi-candidate.sh
    Scripts/rebuild-local-ffi.sh
    Scripts/rust-build-env.sh
    Scripts/package-ironwood-xcframework.sh
    Scripts/strip-ironwood-ffi-archives.sh
    Scripts/test-ironwood-release-gates.sh
    Scripts/validate-ironwood-release-version.sh
    Scripts/verify-ironwood-ffi-artifact.sh
    Scripts/verify-ironwood-ffi-layout.sh
    Scripts/verify-ironwood-ffi-reproducibility.sh
    Scripts/verify-ironwood-librustzcash-publication.sh
    Scripts/verify-ironwood-macho-floor.sh
    Scripts/verify-ironwood-package-platforms.sh
    Scripts/verify-ironwood-package-reproducibility.sh
    Scripts/verify-ironwood-cargo-pins.sh
    Scripts/verify-ironwood-static-release-inputs.sh
    Scripts/verify-ironwood-xcframework-metadata.sh
    Scripts/verify-sdk-release-environment.sh
    Scripts/version-macos-framework.sh
    .github/workflows/build-ffi.yml
    .github/workflows/ffi-reproducibility.yml
    .github/workflows/swift.yml
    .github/workflows/codeql.yml
)

unsupported=$(find rust ! -type d ! -type f -print -quit)
if [[ -n "$unsupported" ]]; then
    echo "Error: Rust FFI source tree contains a symlink or unsupported object: $unsupported" >&2
    exit 1
fi
while IFS= read -r file; do
    files+=("$file")
done < <(find rust -type f | LC_ALL=C sort)

for file in "${files[@]}"; do
    if [[ -L "$file" ]]; then
        echo "Error: FFI source inputs must not be symbolic links: $file" >&2
        exit 1
    fi
    if [[ ! -f "$file" ]]; then
        echo "Error: missing FFI source input $file" >&2
        exit 1
    fi
done

{
    for file in "${files[@]}"; do
        printf 'path=%s\n' "$file"
        shasum -a 256 "$file"
    done
} | shasum -a 256 | awk '{print $1}'
