#!/bin/bash

# Verifies the fund-moving Rust graph before an FFI artifact is rebuilt. Public SDK CI consumes
# the committed XCFramework; this source audit runs only in an authenticated release/private-Rust
# environment where the exact migration-engine revision is available.

set -euo pipefail
cd "$(dirname "$0")/.."

expected_librustzcash_rev="292e758462e3bc7dfb4d7272d9f88ab671bf1cab"
tree_file=$(mktemp)
duplicates_file=$(mktemp)
trap 'rm -f "$tree_file" "$duplicates_file"' EXIT

# Cargo repeats shared nodes with `(*)`; normalize those markers before checking unique resolved
# packages. Optional voting is intentionally absent from the default graph.
cargo tree --locked -e normal --prefix none --format '{p}' \
    | sed 's/ (\*)$//' \
    | LC_ALL=C sort -u > "$tree_file"
cargo tree --locked -e normal -d > "$duplicates_file"

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

assert_one orchard 0.15.0
for crate_and_version in \
    "pczt 0.7.0" \
    "zcash_address 0.13.0" \
    "zcash_client_backend 0.23.0" \
    "zcash_client_sqlite 0.21.1" \
    "zcash_keys 0.15.0" \
    "zcash_primitives 0.29.0" \
    "zcash_proofs 0.29.0" \
    "zcash_protocol 0.10.0" \
    "zcash_transparent 0.9.0" \
    "zip321 0.8.0"
do
    read -r crate version <<< "$crate_and_version"
    assert_one "$crate" "$version" "github.com/zcash/librustzcash?rev=$expected_librustzcash_rev"
done

if grep -q '^zcash_voting ' "$tree_file"; then
    echo "Error: optional voting stack entered the default Ironwood graph" >&2
    exit 1
fi

# The upstream default backend still owns narrowly scoped `unstable-*` serialization/tree
# features. SQLite's broad feature is intentionally retained because this exact revision exposes
# the SDK's existing FsBlockDb/BlockMeta/init_blockmeta_db cache API behind no narrower feature.
# Upstream SQLite's feature itself activates backend/unstable transitively, so audit that it is
# present for this concrete cache dependency but never requested directly by this SDK.
features_file=$(mktemp)
trap 'rm -f "$tree_file" "$duplicates_file" "$features_file"' EXIT
cargo tree --locked -e features --prefix none > "$features_file"
if ! grep -Eq '^zcash_client_sqlite feature "unstable"( \(\*\))?$' "$features_file"
then
    echo "Error: required filesystem compact-block cache feature is absent" >&2
    exit 1
fi
if awk '
    /^zcash_client_backend =/ { in_backend = 1 }
    in_backend { print }
    in_backend && /] }$/ { exit }
' Cargo.toml | grep -Eq '"unstable"'
then
    echo "Error: zcash_client_backend unstable must not be requested directly" >&2
    exit 1
fi

if rg -q 'zcash_unstable.*nu6\.3|Ironwood FFI requires --cfg' \
    .cargo \
    Cargo.toml \
    rust \
    Scripts/rust-build-env.sh \
    Scripts/init-local-ffi.sh \
    Scripts/rebuild-local-ffi.sh \
    BuildSupport/Makefile
then
    echo "Error: obsolete synthetic NU6.3 cfg gate remains in a live build path" >&2
    exit 1
fi

echo "Ironwood dependency graph is unified at librustzcash $expected_librustzcash_rev."
echo "Stable default builds use no synthetic NU6.3 cfg or direct backend unstable feature."
echo "SQLite unstable is retained for the legacy filesystem compact-block cache API."
