#!/bin/bash

# Verifies the fund-moving Rust source graph before an FFI artifact is rebuilt.

set -euo pipefail
cd "$(dirname "$0")/.."

expected_librustzcash_repository="https://github.com/just-zend/librustzcash"
expected_librustzcash_revision="5115cf26da590a3d610446f1d926ff7f2873c9d1"
expected_voting_circuits_revision="a5aae410a6fb14fcbea2f0ce3393035195e86f69"
expected_vote_nullifier_pir_revision="0dea3485429c80033e67a1ddb18ee72cc450cefb"
expected_zcash_voting_revision="464f974865f2afa82bdac15d169168c77ecb9c74"
rust_toolchain=$(sed -nE 's/^channel = "([^"]+)"/\1/p' rust-toolchain.toml)
tree_file=$(mktemp)
librust_lines=$(mktemp)
trap 'rm -f "$tree_file" "$librust_lines"' EXIT

grep -E '^[a-zA-Z0-9_-]+[[:space:]]*=.*git = ".*librustzcash"' Cargo.toml > "$librust_lines"
if [[ $(wc -l < "$librust_lines" | tr -d ' ') -lt 13 ]]; then
    echo "Error: incomplete librustzcash family pin set" >&2
    exit 1
fi
if grep -Ev "git = \"${expected_librustzcash_repository}\", rev = \"${expected_librustzcash_revision}\"" "$librust_lines" | grep -q .; then
    echo "Error: every librustzcash-family dependency must use the Zend fork at the exact audited revision" >&2
    exit 1
fi
if rg -q 'zodl_ironwood_migration|ZODLIronwoodMigrationRust|266a75ae3af076bbe9437088947fddb1add8bd99' Cargo.toml Cargo.lock rust Sources; then
    echo "Error: superseded private-engine graph remains in a live source path" >&2
    exit 1
fi

grep -Fxq "voting-circuits = { git = \"https://github.com/zodl-inc/voting-circuits.git\", rev = \"${expected_voting_circuits_revision}\" }" Cargo.toml
grep -Fxq "imt-tree = { git = \"https://github.com/zodl-inc/vote-nullifier-pir.git\", rev = \"${expected_vote_nullifier_pir_revision}\" }" Cargo.toml
grep -Fxq "zcash_voting = { git = \"https://github.com/zodl-inc/zcash_voting.git\", rev = \"${expected_zcash_voting_revision}\" }" Cargo.toml

grep -Fq 'rustflags = ["--cfg", '\''zcash_unstable="nu6.3"'\'']' .cargo/config.toml
grep -Fq 'flags+=("--cfg" '\''zcash_unstable="nu6.3"'\'')' Scripts/rust-build-env.sh

lock_librust_sources=$(grep -E '^source = "git\+https://github.com/.*/librustzcash\?rev=' Cargo.lock | LC_ALL=C sort -u)
expected_lock_source="source = \"git+${expected_librustzcash_repository}?rev=${expected_librustzcash_revision}#${expected_librustzcash_revision}\""
if [[ "$lock_librust_sources" != "$expected_lock_source" ]]; then
    echo "Error: Cargo.lock does not resolve one exact just-zend/librustzcash source" >&2
    printf '%s\n' "$lock_librust_sources" >&2
    exit 1
fi

cargo "+$rust_toolchain" tree --locked -e normal --prefix none --format '{p}' \
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

assert_one orchard 0.15.0
for crate_and_version in \
    "zcash_pool_migration 0.1.0" \
    "pczt 0.8.0-rc.1" \
    "zcash_address 0.13.0" \
    "zcash_client_backend 0.24.0-rc.1" \
    "zcash_client_sqlite 0.22.0-rc.1" \
    "zcash_encoding 0.4.0" \
    "zcash_keys 0.15.0" \
    "zcash_primitives 0.29.0" \
    "zcash_protocol 0.10.0" \
    "zcash_transparent 0.9.0" \
    "zip321 0.9.0-rc.1"
do
    read -r crate version <<< "$crate_and_version"
    assert_one "$crate" "$version" "github.com/just-zend/librustzcash?rev=$expected_librustzcash_revision"
done
assert_one zcash_voting 1.0.0 "github.com/zodl-inc/zcash_voting.git?rev=$expected_zcash_voting_revision"
assert_one voting-circuits 0.9.0-rc.2 "github.com/zodl-inc/voting-circuits.git?rev=$expected_voting_circuits_revision"
assert_one imt-tree 0.2.0 "github.com/zodl-inc/vote-nullifier-pir.git?rev=$expected_vote_nullifier_pir_revision"

echo "Ironwood dependency graph is unified at just-zend/librustzcash $expected_librustzcash_revision."
echo "Voting pins and the required NU6.3 cfg are present."
