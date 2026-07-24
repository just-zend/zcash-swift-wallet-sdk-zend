#!/bin/bash

# Verifies the fund-moving Rust graph before an FFI artifact is rebuilt. The exact Zend
# librustzcash revision is derived from Cargo.toml and, once generated, cross-checked against the
# frozen build recipe; no moving branch or separately maintained revision constant is accepted.

set -euo pipefail
cd "$(dirname "$0")/.."

expected_librustzcash_repository="https://github.com/just-zend/librustzcash"
expected_zcash_voting_revision="a4daaf77f793b35a98a3d811b920a01b95fbfa7a"
rust_toolchain=$(sed -nE 's/^channel = "([^"]+)"/\1/p' rust-toolchain.toml)
expected_librustzcash_revision=$(./Scripts/verify-ironwood-cargo-pins.sh --print-revision)

tree_file=$(mktemp)
cleanup() {
    rm -f "$tree_file"
}
trap cleanup EXIT

if [[ -f .cargo/config.toml ]]; then
    echo "Error: the retired private-git credential workaround .cargo/config.toml remains" >&2
    exit 1
fi
if rg -q 'zodl_ironwood_migration|ZODLIronwoodMigrationRust' Cargo.toml Cargo.lock rust Sources; then
    echo "Error: retired standalone migration-engine code remains in a live source path" >&2
    exit 1
fi
if rg -q 'zcash_unstable.*nu6\.3|Ironwood FFI requires --cfg' \
    Cargo.toml rust Scripts/rust-build-env.sh Scripts/init-local-ffi.sh \
    Scripts/rebuild-local-ffi.sh BuildSupport/Makefile
then
    echo "Error: obsolete synthetic NU6.3 cfg gate remains in a live build path" >&2
    exit 1
fi
if ! grep -Fxq \
    'zcash_client_sqlite = { version = "0.22.0-rc.1", features = ["migration-delivery", "orchard", "transparent-inputs", "unstable", "serde"] }' \
    Cargo.toml
then
    echo "Error: the Rust FFI graph does not opt into zcash_client_sqlite/migration-delivery" >&2
    exit 1
fi

recipe="BuildSupport/IRONWOOD_FFI_BUILD.env"
read_recipe_field() {
    sed -n "s/^${1}=//p" "$recipe"
}
if [[ -f "$recipe" && -n "$(read_recipe_field LIBRUSTZCASH_REVISION)" ]]; then
    if [[ "$(read_recipe_field LIBRUSTZCASH_REPOSITORY)" != "$expected_librustzcash_repository" \
        || "$(read_recipe_field LIBRUSTZCASH_REVISION)" != "$expected_librustzcash_revision" ]]
    then
        echo "Error: Cargo graph differs from the frozen librustzcash build recipe" >&2
        exit 1
    fi
fi

# `--target all` includes every target-specific dependency edge, and therefore covers the five
# Apple architectures without silently auditing only the host macOS graph.
cargo "+$rust_toolchain" tree --locked --target all -e normal --prefix none --format '{p}' \
    | sed 's/ (\*)$//' \
    | LC_ALL=C sort -u > "$tree_file"

assert_one() {
    local crate="$1"
    local expected_version="$2"
    local expected_source="${3:-}"
    local matches count line
    matches=$(awk -v crate="$crate" '$1 == crate { print }' "$tree_file")
    count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')
    if [[ "$count" != "1" ]]; then
        echo "Error: expected one resolved $crate package, found $count" >&2
        printf '%s\n' "$matches" >&2
        exit 1
    fi
    line=$(printf '%s\n' "$matches")
    if [[ "$line" != "$crate v$expected_version"* ]]; then
        echo "Error: unexpected $crate version: $line" >&2
        exit 1
    fi
    if [[ -n "$expected_source" && "$line" != *"$expected_source"* ]]; then
        echo "Error: unexpected $crate source: $line" >&2
        exit 1
    fi
}

for crate_and_version in \
    "equihash 0.3.0" \
    "f4jumble 0.1.1" \
    "pczt 0.8.0-rc.1" \
    "zcash_address 0.13.0" \
    "zcash_client_backend 0.24.0-rc.1" \
    "zcash_client_sqlite 0.22.0-rc.1" \
    "zcash_encoding 0.4.0" \
    "zcash_keys 0.15.0" \
    "zcash_pool_migration 0.1.0-alpha.1" \
    "zcash_primitives 0.29.0" \
    "zcash_protocol 0.10.1" \
    "zcash_transparent 0.10.0" \
    "zip321 0.9.0-rc.1"
do
    read -r crate version <<< "$crate_and_version"
    assert_one "$crate" "$version" "github.com/just-zend/librustzcash?rev=$expected_librustzcash_revision"
done
assert_one zcash_voting 1.0.0 "github.com/zodl-inc/zcash_voting.git?rev=$expected_zcash_voting_revision"
assert_one orchard 0.15.4
assert_one voting-circuits 0.9.0-rc.3
assert_one imt-tree 0.2.0

echo "Ironwood dependency graph is unified at just-zend/librustzcash $expected_librustzcash_revision."
echo "Orchard 0.15.4 and the reviewed voting graph are locked; no synthetic NU6.3 cfg is active."
