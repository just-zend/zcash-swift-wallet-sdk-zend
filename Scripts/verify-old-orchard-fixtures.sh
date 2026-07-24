#!/bin/bash

# Verifies the exact pre-Ironwood production fixtures without rebuilding Rust. The Swift regression
# performs the full current-SDK upgrade.

set -euo pipefail
cd "$(dirname "$0")/.."

assert_equal() {
    local expected="$1"
    local actual="$2"
    local description="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "Error: $description: expected '$expected', found '$actual'" >&2
        exit 1
    fi
}

verify_fixture() {
    local fixture="$1"
    local provenance="$2"
    local compact_blocks="$3"
    local expected_hash="$4"
    local expected_compact_blocks_hash="$5"
    local expected_first_height="$6"
    local expected_last_height="$7"
    local expected_account_prefix="$8"
    local expected_uivk_prefix="$9"
    local expected_scan_queue="${10}"
    local unified_prefix="${11}"
    local transparent_prefix_pattern="${12}"

    test -f "$fixture"
    test -f "$provenance"
    test -f "$compact_blocks"
    local actual_hash
    actual_hash=$(shasum -a 256 "$fixture" | awk '{print $1}')
    assert_equal "$expected_hash" "$actual_hash" "$fixture SHA-256"
    grep -Fq -- "- SHA-256: \`$expected_hash\`" "$provenance"

    local actual_compact_blocks_hash
    actual_compact_blocks_hash=$(shasum -a 256 "$compact_blocks" | awk '{print $1}')
    assert_equal \
        "$expected_compact_blocks_hash" \
        "$actual_compact_blocks_hash" \
        "$compact_blocks SHA-256"
    grep -Fq -- "- Compact blocks SHA-256: \`$expected_compact_blocks_hash\`" "$provenance"
    assert_equal "21" "$(wc -l < "$compact_blocks" | tr -d ' ')" "$compact_blocks line count"
    assert_equal \
        "$expected_first_height" \
        "$(head -n 1 "$compact_blocks" | cut -d: -f1)" \
        "$compact_blocks first height"
    assert_equal \
        "$expected_last_height" \
        "$(tail -n 1 "$compact_blocks" | cut -d: -f1)" \
        "$compact_blocks last height"

    local expected_height="$expected_first_height"
    while IFS=: read -r height payload; do
        assert_equal "$expected_height" "$height" "$compact_blocks contiguous height"
        if [[ ! "$payload" =~ ^[0-9a-f]+$ ]] || (( ${#payload} % 2 != 0 )); then
            echo "Error: $compact_blocks height $height is not an even-length lowercase hex protobuf" >&2
            exit 1
        fi
        expected_height=$((expected_height + 1))
    done < "$compact_blocks"
    assert_equal "$((expected_last_height + 1))" "$expected_height" "$compact_blocks terminal height"

    assert_equal "1" "$(sqlite3 "$fixture" "SELECT COUNT(*) FROM accounts")" "$fixture account count"
    assert_equal \
        "$expected_account_prefix" \
        "$(sqlite3 "$fixture" "SELECT substr(ufvk, 1, length('$expected_account_prefix')) FROM accounts")" \
        "$fixture UFVK network"
    assert_equal \
        "$expected_uivk_prefix" \
        "$(sqlite3 "$fixture" "SELECT substr(uivk, 1, length('$expected_uivk_prefix')) FROM accounts")" \
        "$fixture UIVK network"
    assert_equal "1" "$(sqlite3 "$fixture" "SELECT COUNT(*) FROM orchard_received_notes")" "$fixture Orchard note count"
    assert_equal \
        "123456789" \
        "$(sqlite3 "$fixture" "SELECT value FROM orchard_received_notes")" \
        "$fixture Orchard value"
    assert_equal \
        "$expected_scan_queue" \
        "$(sqlite3 "$fixture" "SELECT group_concat(entry, ',') FROM (SELECT block_range_start || ':' || block_range_end || ':' || priority AS entry FROM scan_queue ORDER BY block_range_start)")" \
        "$fixture scan queue"
    assert_equal \
        "0" \
        "$(sqlite3 "$fixture" "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE '%ironwood%'")" \
        "$fixture Ironwood schema count"
    assert_equal \
        "0" \
        "$(sqlite3 "$fixture" "SELECT COUNT(*) FROM transactions WHERE raw IS NOT NULL")" \
        "$fixture raw transaction count"

    local wrong_address_count
    wrong_address_count=$(sqlite3 "$fixture" \
        "SELECT COUNT(*) FROM addresses
         WHERE address NOT LIKE '${unified_prefix}%'
           AND address NOT GLOB '${transparent_prefix_pattern}'")
    assert_equal "0" "$wrong_address_count" "$fixture cached address network"
    assert_equal \
        "0" \
        "$(sqlite3 "$fixture" "SELECT COUNT(*) FROM addresses WHERE address LIKE 'uregtest%'")" \
        "$fixture regtest address leakage"
}

verify_fixture \
    Tests/TestUtils/Resources/zend_2_6_0_alpha_6_orchard.sqlite \
    Tests/TestUtils/Resources/zend_2_6_0_alpha_6_orchard.provenance.md \
    Tests/TestUtils/Resources/zend_2_6_0_alpha_6_orchard.compactblocks \
    d06a9aeed38380a063857f481e6766ff73417fe4f7bb41ff25b7954c2088f2d9 \
    b8505a5aba88658fa3e327189ecd5d78794f7dfc9e9c513fba086a97af095827 \
    4133990 \
    4134010 \
    uviewtest \
    uivktest \
    '280000:4133990:0,4133990:4134011:10' \
    utest1 \
    't[m2]*'

verify_fixture \
    Tests/TestUtils/Resources/zend_2_6_0_alpha_6_orchard_mainnet.sqlite \
    Tests/TestUtils/Resources/zend_2_6_0_alpha_6_orchard_mainnet.provenance.md \
    Tests/TestUtils/Resources/zend_2_6_0_alpha_6_orchard_mainnet.compactblocks \
    9608094ebf7d2b9f5b6bc0beab56fc3c0c020aa360462ad6a2f76efbeb894c71 \
    68b30d21382546ce613a5d36ce2eb44b59f8a42cbda9d0267ecdbcc8de12ee33 \
    3428133 \
    3428153 \
    uview1 \
    uivk1 \
    '419200:3428133:0,3428133:3428154:10' \
    u1 \
    't[13]*'

echo "Canonical pre-Ironwood TestNetwork and MainNetwork fixtures passed hash, schema, address, and value checks."
