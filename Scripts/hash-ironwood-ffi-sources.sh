#!/bin/bash

# Emits one deterministic SHA-256 over every public SDK input that can change the Rust FFI binary
# or XCFramework assembly. Private migration-engine source is represented separately by its exact
# commit and tree in IRONWOOD_FFI_PROVENANCE.env.

set -euo pipefail
cd "$(dirname "$0")/.."

files=(
    .cargo/config.toml
    Cargo.lock
    Cargo.toml
    rust-toolchain.toml
    BuildSupport/Info.plist
    BuildSupport/Makefile
    BuildSupport/module.modulemap
    BuildSupport/platform-Info.plist
    Scripts/init-local-ffi.sh
    Scripts/rebuild-local-ffi.sh
    Scripts/rust-build-env.sh
)

while IFS= read -r file; do
    files+=("$file")
done < <(find rust -type f | LC_ALL=C sort)

for file in "${files[@]}"; do
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
