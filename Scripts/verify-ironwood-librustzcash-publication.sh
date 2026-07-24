#!/bin/bash

# Release-only network gate: the Rust commit recorded in artifact provenance must have the recorded
# tree and be durably reachable from just-zend/librustzcash main. PR CI intentionally does not call
# this gate because a reviewed Rust commit may still live only on its public PR branch.

set -euo pipefail
cd "$(dirname "$0")/.."

provenance="${1:-LocalPackages/IRONWOOD_FFI_PROVENANCE.env}"
if [[ ! -f "$provenance" ]]; then
    echo "Error: artifact provenance not found: $provenance" >&2
    exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh is required for the durable librustzcash publication check" >&2
    exit 1
fi

read_unique_field() {
    local field="$1"
    local matches value
    matches=$(grep -c "^${field}=" "$provenance" || true)
    if [[ "$matches" != "1" ]]; then
        echo "Error: provenance must contain exactly one $field" >&2
        exit 1
    fi
    value=$(sed -n "s/^${field}=//p" "$provenance")
    printf '%s\n' "$value"
}

repository=$(read_unique_field LIBRUSTZCASH_REPOSITORY)
revision=$(read_unique_field LIBRUSTZCASH_REVISION)
tree=$(read_unique_field LIBRUSTZCASH_TREE)
if [[ "$repository" != "https://github.com/just-zend/librustzcash" \
    || ! "$revision" =~ ^[0-9a-f]{40}$ \
    || ! "$tree" =~ ^[0-9a-f]{40}$ ]]
then
    echo "Error: invalid canonical librustzcash provenance" >&2
    exit 1
fi

remote_tree=$(gh api "repos/just-zend/librustzcash/git/commits/$revision" --jq .tree.sha)
if [[ "$remote_tree" != "$tree" ]]; then
    echo "Error: public librustzcash commit tree differs from artifact provenance" >&2
    exit 1
fi

comparison_status=$(gh api \
    "repos/just-zend/librustzcash/compare/${revision}...main" \
    --jq .status)
if [[ "$comparison_status" != "ahead" && "$comparison_status" != "identical" ]]; then
    echo "Error: librustzcash $revision is not durably reachable from just-zend/librustzcash main" >&2
    exit 1
fi

echo "Public librustzcash $revision ($tree) is durably reachable from just-zend/librustzcash main."
