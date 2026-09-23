#!/usr/bin/env bash

# Release-specific provenance and artifact checks for the last MIT-licensed,
# pre-Slipstream Zend SDK line.

set -euo pipefail

readonly EXPECTED_VERSION="2.8.0-rc.2-zend.1"
readonly EXPECTED_UPSTREAM_COMMIT="1f4e12ba9a58d90e1416d4e3b145d3e63d10cf27"
readonly NM_TOOL="${NM:-nm}"

usage() {
    echo "Usage: $0 <version> [xcframework-path]" >&2
    exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || usage

readonly VERSION="$1"
readonly XCFRAMEWORK_PATH="${2:-}"

cd "$(dirname "$0")/.."

if [[ "$VERSION" != "$EXPECTED_VERSION" ]]; then
    echo "Error: this release line only permits ${EXPECTED_VERSION}; got ${VERSION}." >&2
    exit 1
fi

git cat-file -e "${EXPECTED_UPSTREAM_COMMIT}^{commit}"
if ! git merge-base --is-ancestor "$EXPECTED_UPSTREAM_COMMIT" HEAD; then
    echo "Error: HEAD is not based on approved upstream commit ${EXPECTED_UPSTREAM_COMMIT}." >&2
    exit 1
fi

# Release plumbing may change, but the SDK, Rust implementation, dependency
# graph, license, and FFI build inputs must remain byte-for-byte identical to
# the approved upstream commit.
readonly SOURCE_PATHS=(
    LICENSE
    Cargo.lock
    Cargo.toml
    Sources
    rust
    BuildSupport
)

if ! git diff --quiet "$EXPECTED_UPSTREAM_COMMIT" -- "${SOURCE_PATHS[@]}"; then
    echo "Error: runtime source, dependencies, license, or FFI build inputs differ from ${EXPECTED_UPSTREAM_COMMIT}." >&2
    git diff --stat "$EXPECTED_UPSTREAM_COMMIT" -- "${SOURCE_PATHS[@]}" >&2
    exit 1
fi

if ! grep -Eq '^license = "MIT"$' Cargo.toml; then
    echo "Error: Cargo.toml is not MIT licensed." >&2
    exit 1
fi

if git grep -nEiI \
    'slipstream|AGPL-3([.]0)?|GNU Affero General Public License|zodl[_-]qa' \
    HEAD -- Cargo.lock Cargo.toml Package.swift Sources rust BuildSupport; then
    echo "Error: prohibited release content was found." >&2
    exit 1
fi

echo "Source provenance verified: ${EXPECTED_UPSTREAM_COMMIT} (${EXPECTED_VERSION})."

if [[ -z "$XCFRAMEWORK_PATH" ]]; then
    exit 0
fi

if [[ ! -d "$XCFRAMEWORK_PATH" ]]; then
    echo "Error: XCFramework not found at ${XCFRAMEWORK_PATH}." >&2
    exit 1
fi

readonly REQUIRED_SLICES=(
    ios-arm64
    ios-arm64_x86_64-simulator
    macos-arm64_x86_64
)

for slice in "${REQUIRED_SLICES[@]}"; do
    framework="${XCFRAMEWORK_PATH}/${slice}/libzcashlc.framework"
    [[ -f "${framework}/Headers/zcashlc.h" ]] || {
        echo "Error: missing ${slice} header." >&2
        exit 1
    }
    [[ -f "${framework}/libzcashlc" ]] || {
        echo "Error: missing ${slice} library." >&2
        exit 1
    }
done

readonly REFERENCE_HEADER="${XCFRAMEWORK_PATH}/${REQUIRED_SLICES[0]}/libzcashlc.framework/Headers/zcashlc.h"
for slice in "${REQUIRED_SLICES[@]:1}"; do
    header="${XCFRAMEWORK_PATH}/${slice}/libzcashlc.framework/Headers/zcashlc.h"
    if ! cmp -s "$REFERENCE_HEADER" "$header"; then
        echo "Error: generated headers differ between XCFramework slices." >&2
        exit 1
    fi
done

if grep -aEiIq 'slipstream|AGPL-3([.]0)?|GNU Affero General Public License' "$REFERENCE_HEADER"; then
    echo "Error: prohibited API or license text found in generated header." >&2
    exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

git grep -hEo 'zcashlc_[A-Za-z0-9_]+' HEAD -- Sources \
    | LC_ALL=C sort -u > "${tmp_dir}/swift-symbols"
grep -hEo 'zcashlc_[A-Za-z0-9_]+' "$REFERENCE_HEADER" \
    | LC_ALL=C sort -u > "${tmp_dir}/header-symbols"
comm -23 "${tmp_dir}/swift-symbols" "${tmp_dir}/header-symbols" > "${tmp_dir}/missing-symbols"

if [[ -s "${tmp_dir}/missing-symbols" ]]; then
    echo "Error: generated header is missing Swift-referenced FFI symbols:" >&2
    sed 's/^/  /' "${tmp_dir}/missing-symbols" >&2
    exit 1
fi

for slice in "${REQUIRED_SLICES[@]}"; do
    binary="${XCFRAMEWORK_PATH}/${slice}/libzcashlc.framework/libzcashlc"
    symbols="${tmp_dir}/${slice}.symbols"
    if ! "$NM_TOOL" -gj "$binary" > "$symbols" 2>/dev/null; then
        echo "Error: could not inspect linked symbols for ${slice}." >&2
        exit 1
    fi
    if grep -Eiq 'slipstream|(^|_)zcashlc_voting_' "$symbols"; then
        echo "Error: prohibited or compile-time-disabled symbols are linked in ${slice}." >&2
        exit 1
    fi
done

echo "XCFramework provenance and ABI verified for all Apple slices."
