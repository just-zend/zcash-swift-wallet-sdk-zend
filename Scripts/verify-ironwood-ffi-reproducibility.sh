#!/bin/bash

# Primary release trust gate: rebuild the five-architecture artifact twice from independent,
# detached checkouts of the recorded SDK source and exact public Rust revision, then byte-compare
# both results with each other and with the artifact committed at the release head.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Error: reproducibility verification requires a clean release checkout" >&2
    exit 1
fi

provenance=LocalPackages/IRONWOOD_FFI_PROVENANCE.env
read_field() {
    local field="$1"
    local matches
    matches=$(grep -c "^${field}=" "$provenance" || true)
    if [[ "$matches" != "1" ]]; then
        echo "Error: provenance must contain exactly one $field" >&2
        exit 1
    fi
    sed -n "s/^${field}=//p" "$provenance"
}

./Scripts/verify-ironwood-static-release-inputs.sh
./Scripts/verify-ironwood-ffi-artifact.sh

source_revision=$(read_field SDK_FFI_SOURCE_REVISION)
source_tree=$(read_field SDK_FFI_SOURCE_TREE)
source_hash=$(read_field SDK_FFI_SOURCE_SHA256)
implementation_revision=$(read_field SDK_IRONWOOD_IMPLEMENTATION_REVISION)
rust_revision=$(read_field LIBRUSTZCASH_REVISION)
rust_tree=$(read_field LIBRUSTZCASH_TREE)
publication_ref=$(read_field LIBRUSTZCASH_PUBLICATION_REF_AT_BUILD)
publication_tip=$(read_field LIBRUSTZCASH_PUBLICATION_TIP_AT_BUILD)
upstream_1821_merge=$(read_field UPSTREAM_1821_MERGE_REVISION)
upstream_1822_merge=$(read_field UPSTREAM_1822_MERGE_REVISION)

for revision in \
    "$source_revision" "$source_tree" "$implementation_revision" "$rust_revision" "$rust_tree" \
    "$publication_tip" "$upstream_1821_merge" "$upstream_1822_merge"
do
    if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Error: invalid reproducibility revision: $revision" >&2
        exit 1
    fi
done
if [[ ! "$source_hash" =~ ^[0-9a-f]{64}$ \
    || ! "$publication_ref" =~ ^refs/(heads|tags)/[-A-Za-z0-9._/]+$ ]]
then
    echo "Error: invalid source hash or public Rust containing ref" >&2
    exit 1
fi
if [[ "$(git rev-parse "${source_revision}^{tree}")" != "$source_tree" ]]; then
    echo "Error: recorded SDK source tree differs from its commit" >&2
    exit 1
fi
live_source_hash=$(./Scripts/hash-ironwood-ffi-sources.sh)
if [[ "$live_source_hash" != "$source_hash" ]]; then
    echo "Error: release HEAD changed FFI/release inputs after the recorded artifact source" >&2
    exit 1
fi

temp_root=$(mktemp -d)
build_roots=()
cleanup() {
    for build_root in "${build_roots[@]}"; do
        git worktree remove --force "$build_root" >/dev/null 2>&1 || true
    done
    rm -rf "$temp_root"
}
trap cleanup EXIT

for build_number in 1 2; do
    sdk_build="$temp_root/sdk-$build_number"
    rust_checkout="$temp_root/librustzcash-$build_number"
    git worktree add --detach "$sdk_build" "$source_revision" >/dev/null
    build_roots+=("$sdk_build")

    git clone --quiet --no-checkout https://github.com/just-zend/librustzcash "$rust_checkout"
    git -C "$rust_checkout" fetch --quiet --no-tags origin "$publication_ref"
    git -C "$rust_checkout" checkout --quiet --detach "$rust_revision"
    if [[ "$(git -C "$rust_checkout" rev-parse 'HEAD^{tree}')" != "$rust_tree" \
        || -n "$(git -C "$rust_checkout" status --porcelain)" ]]
    then
        echo "Error: clean public Rust checkout differs from recorded revision/tree" >&2
        exit 1
    fi

    (
        cd "$sdk_build"
        LIBRUSTZCASH_REPO="$rust_checkout" \
        LIBRUSTZCASH_PUBLISHED_REF="$publication_ref" \
        LIBRUSTZCASH_RECORDED_PUBLICATION_TIP="$publication_tip" \
        SDK_IRONWOOD_IMPLEMENTATION_REVISION="$implementation_revision" \
        UPSTREAM_1821_MERGE_REVISION="$upstream_1821_merge" \
        UPSTREAM_1822_MERGE_REVISION="$upstream_1822_merge" \
            ./Scripts/build-ironwood-ffi-artifact.sh
    )

    ./Scripts/compare-ironwood-xcframeworks.sh \
        LocalPackages/libzcashlc.xcframework \
        "$sdk_build/LocalPackages/libzcashlc.xcframework"
    if ! cmp -s BuildSupport/IRONWOOD_FFI_BUILD.env "$sdk_build/BuildSupport/IRONWOOD_FFI_BUILD.env" \
        || ! cmp -s "$provenance" "$sdk_build/$provenance"
    then
        echo "Error: rebuilt recipe/provenance differs from the committed reviewed record" >&2
        exit 1
    fi
done

./Scripts/compare-ironwood-xcframeworks.sh \
    "$temp_root/sdk-1/LocalPackages/libzcashlc.xcframework" \
    "$temp_root/sdk-2/LocalPackages/libzcashlc.xcframework"
if ! cmp -s "$temp_root/sdk-1/BuildSupport/IRONWOOD_FFI_BUILD.env" \
        "$temp_root/sdk-2/BuildSupport/IRONWOOD_FFI_BUILD.env" \
    || ! cmp -s "$temp_root/sdk-1/$provenance" "$temp_root/sdk-2/$provenance"
then
    echo "Error: the two independent rebuilds produced different provenance" >&2
    exit 1
fi

echo "Two clean five-architecture rebuilds are byte-identical to the committed artifact."
