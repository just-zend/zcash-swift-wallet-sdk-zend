#!/bin/bash

# Portable, artifact-independent validation of the exact reviewed Rust/SDK migration source locks.
# The full XCFramework verifier additionally proves Git merge topology and source ancestry.

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <build-record> [matching-build-record]" >&2
    exit 1
fi

records=("$@")

read_unique_field() {
    local file="$1" field="$2" matches
    if [[ ! -f "$file" ]]; then
        echo "Error: reviewed source-lock record not found: $file" >&2
        exit 1
    fi
    matches=$(grep -c "^${field}=" "$file" || true)
    if [[ "$matches" != "1" ]]; then
        echo "Error: $file must contain exactly one $field" >&2
        exit 1
    fi
    sed -n "s/^${field}=//p" "$file"
}

assert_exact() {
    local file="$1" field="$2" expected="$3" actual
    actual=$(read_unique_field "$file" "$field")
    if [[ "$actual" != "$expected" ]]; then
        echo "Error: $file records an unreviewed $field" >&2
        exit 1
    fi
}

feature_merge_revision=""
ffi_merge_revision=""
swift_merge_revision=""
for record in "${records[@]}"; do
    assert_exact "$record" \
        SDK_MIGRATION_FEATURE_BASE_REVISION \
        1f5061a6773b811382f18aed8a5ab50e69cdc59e
    assert_exact "$record" \
        UPSTREAM_MIGRATION_FEATURE_REVISION \
        e1fdd10eec9c97cdbee4e944d571ee38fa748ae9
    assert_exact "$record" \
        UPSTREAM_MIGRATION_FFI_REVISION \
        90306346725d2e45e9cc4d25cef62732c7e7fd09
    assert_exact "$record" \
        UPSTREAM_MIGRATION_SWIFT_REVISION \
        37b03692c089c5cccd0ff5b5feafe1dcaaf4b312
    assert_exact "$record" \
        INCLUDED_UPSTREAM_1825_REVISION \
        93ed4ed957df3c1962bad283cd588dc385f955a0
    assert_exact "$record" \
        INCLUDED_UPSTREAM_KEYSTONE_REVISION \
        5960351ab1effc488009b426d441f67530f015f3
    assert_exact "$record" \
        INCLUDED_UPSTREAM_KEYSTONE_SWIFT_REVISION \
        3c9d6cb9a00649489f7740abea608eae8ea8630e
    assert_exact "$record" \
        SDK_PR_1825_SEMANTIC_PORT_REVISION \
        641e8f6ee7f998cd6810fe4ce231419a1e933a01
    assert_exact "$record" \
        LIBRUSTZCASH_REVISION \
        1d63c9c07b0b40b3de633c8396008ff543464a01
    assert_exact "$record" \
        KEYSTONE_UR_REVISION \
        81b8bb3b6b3a823128489c81ffee5bb4001ba2ae
    assert_exact "$record" \
        KEYSTONE_UR_REGISTRY_REVISION \
        7c90bf1ae504720c3f4b44ff26f996836d8b1553

    record_feature_merge=$(read_unique_field "$record" UPSTREAM_MIGRATION_FEATURE_MERGE_REVISION)
    record_ffi_merge=$(read_unique_field "$record" UPSTREAM_MIGRATION_FFI_MERGE_REVISION)
    record_swift_merge=$(read_unique_field "$record" UPSTREAM_MIGRATION_SWIFT_MERGE_REVISION)
    for merge in "$record_feature_merge" "$record_ffi_merge" "$record_swift_merge"; do
        if [[ ! "$merge" =~ ^[0-9a-f]{40}$ ]]; then
            echo "Error: $record has an invalid upstream migration merge revision" >&2
            exit 1
        fi
    done
    if [[ -n "$feature_merge_revision" && "$record_feature_merge" != "$feature_merge_revision" ]] \
        || [[ -n "$ffi_merge_revision" && "$record_ffi_merge" != "$ffi_merge_revision" ]] \
        || [[ -n "$swift_merge_revision" && "$record_swift_merge" != "$swift_merge_revision" ]]
    then
        echo "Error: reviewed source-lock records disagree on an upstream migration merge" >&2
        exit 1
    fi
    feature_merge_revision="$record_feature_merge"
    ffi_merge_revision="$record_ffi_merge"
    swift_merge_revision="$record_swift_merge"
done

echo "Reviewed Ironwood Rust, proposal-handle, and Keystone source locks are exact."
