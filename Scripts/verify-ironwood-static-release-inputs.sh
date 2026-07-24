#!/bin/bash

# Network-free release-input gate. It rejects the retired standalone migration engine everywhere
# it could affect or impersonate a shipped build, and proves that every non-registry Rust source is
# one of the reviewed exact pins. This intentionally runs before Cargo or any network access in CI.

set -euo pipefail
cd "$(dirname "$0")/.."

for cargo_config in .cargo/config .cargo/config.toml; do
    if [[ -e "$cargo_config" || -L "$cargo_config" ]]; then
        echo "Error: repository-local Cargo configuration is forbidden in release inputs: $cargo_config" >&2
        exit 1
    fi
done

retired_pattern='zodl_ironwood_migration|ZODLIronwoodMigrationRust|github\.com/(just-zend|Chlup)/ZODLIronwoodMigrationRust'
if [[ -n "${IRONWOOD_STATIC_LIVE_SOURCE_PATHS:-}" ]]; then
    live_source_paths=()
    while IFS= read -r live_path; do
        if [[ -n "$live_path" ]]; then live_source_paths+=("$live_path"); fi
    done < <(printf '%s\n' "$IRONWOOD_STATIC_LIVE_SOURCE_PATHS" | tr ':' '\n')
else
    live_source_paths=(Cargo.toml Cargo.lock rust Sources)
fi

if rg -n -i "$retired_pattern" "${live_source_paths[@]}"; then
    echo "Error: retired standalone migration-engine source or repository remains live" >&2
    exit 1
fi

artifact_root="${IRONWOOD_STATIC_ARTIFACT_ROOT:-LocalPackages}"
if [[ "${IRONWOOD_STATIC_SKIP_ARTIFACT:-false}" != "true" && -e "$artifact_root" ]]; then
    while IFS= read -r artifact_file; do
        if LC_ALL=C grep -aiEq "$retired_pattern" "$artifact_file"; then
            echo "Error: retired standalone migration-engine metadata found in $artifact_file" >&2
            exit 1
        fi
    done < <(find "$artifact_root" -type f | LC_ALL=C sort)
fi

if [[ "${IRONWOOD_STATIC_SKIP_CARGO_PINS:-false}" != "true" ]]; then
    ./Scripts/verify-ironwood-cargo-pins.sh
fi

./Scripts/audit-disabled-migration-ffi.sh

echo "Static Ironwood release inputs contain only the canonical librustzcash migration engine."
