#!/bin/bash

# Deterministically packages the exact allowlisted XCFramework. A private staging copy receives
# normalized modes and SOURCE_DATE_EPOCH timestamps; Info-ZIP extra fields are disabled and paths
# are supplied in byte-sorted order. The source tree is never mutated.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <output.zip> [xcframework]" >&2
    exit 1
fi
output="$1"
xcframework="${2:-LocalPackages/libzcashlc.xcframework}"

./Scripts/verify-ironwood-ffi-layout.sh "$xcframework" >/dev/null
source_epoch=$(sed -n 's/^SOURCE_DATE_EPOCH=//p' BuildSupport/IRONWOOD_FFI_BUILD.env)
if [[ ! "$source_epoch" =~ ^[0-9]+$ ]]; then
    echo "Error: frozen build recipe has no valid SOURCE_DATE_EPOCH" >&2
    exit 1
fi

mkdir -p "$(dirname "$output")"
output_dir=$(cd "$(dirname "$output")" && pwd -P)
output="$output_dir/$(basename "$output")"
stage=$(mktemp -d)
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT

export COPYFILE_DISABLE=1
cp -R -P "$xcframework" "$stage/libzcashlc.xcframework"
xattr -cr "$stage/libzcashlc.xcframework" 2>/dev/null || true

while IFS= read -r -d '' path; do chmod 0644 "$path"; done \
    < <(find "$stage/libzcashlc.xcframework" -type f -print0)
while IFS= read -r -d '' path; do chmod 0755 "$path"; done \
    < <(find "$stage/libzcashlc.xcframework" -type d -print0)

zip_timestamp=$(date -u -r "$source_epoch" '+%Y%m%d%H%M.%S')
while IFS= read -r -d '' path; do touch -h -t "$zip_timestamp" "$path"; done \
    < <(find "$stage/libzcashlc.xcframework" -type l -print0)
while IFS= read -r -d '' path; do touch -t "$zip_timestamp" "$path"; done \
    < <(find "$stage/libzcashlc.xcframework" -type f -print0)
while IFS= read -r -d '' path; do touch -t "$zip_timestamp" "$path"; done \
    < <(find "$stage/libzcashlc.xcframework" -type d -print0)

rm -f "$output"
(
    cd "$stage"
    find libzcashlc.xcframework -print | LC_ALL=C sort \
        | TZ=UTC /usr/bin/zip -X -y -q "$output" -@
)

if [[ ! -s "$output" ]]; then
    echo "Error: deterministic XCFramework archive was not created" >&2
    exit 1
fi
printf '%s\n' "$(shasum -a 256 "$output" | awk '{print $1}')"
