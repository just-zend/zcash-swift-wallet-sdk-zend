#!/bin/bash

# Hashes the reduced artifact-build PATH after replacing the fresh Rustup toolchain directory with
# a stable marker. The toolchain's exact release and compiler hashes are recorded separately; its
# random mktemp parent must not make otherwise identical rebuild provenance differ.

set -euo pipefail

build_path="${1:-${PATH:-}}"
rust_toolchain_bin="${2:-${IRONWOOD_RUST_TOOLCHAIN_BIN:-}}"
if [[ -z "$build_path" || -z "$rust_toolchain_bin" || "$rust_toolchain_bin" != /* ]]; then
    echo "Error: build PATH and absolute pinned Rust toolchain directory are required" >&2
    exit 1
fi
if [[ ":$build_path:" == *::* ]]; then
    echo "Error: artifact-build PATH contains an empty entry" >&2
    exit 1
fi

normalized_path=""
toolchain_entries=0
IFS=':' read -r -a path_entries <<< "$build_path"
for path_entry in "${path_entries[@]}"; do
    if [[ "$path_entry" != /* ]]; then
        echo "Error: artifact-build PATH contains a relative entry" >&2
        exit 1
    fi
    if [[ "$path_entry" == "$rust_toolchain_bin" ]]; then
        path_entry='<PINNED_RUST_TOOLCHAIN_BIN>'
        toolchain_entries=$((toolchain_entries + 1))
    fi
    normalized_path="${normalized_path:+$normalized_path:}$path_entry"
done

if [[ "$toolchain_entries" != "1" ]]; then
    echo "Error: artifact-build PATH must contain the pinned Rust toolchain directory exactly once" >&2
    exit 1
fi

printf '%s' "$normalized_path" | shasum -a 256 | awk '{print $1}'
