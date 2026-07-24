#!/bin/bash

# Packages the reviewed XCFramework twice, requires identical ZIP bytes, extracts each archive into
# a fresh directory, and runs the full layout/manifest/ABI/platform/provenance verifier there.

set -euo pipefail
cd "$(dirname "$0")/.."

temp_root=$(mktemp -d)
cleanup() { rm -rf "$temp_root"; }
trap cleanup EXIT

zip_one="$temp_root/one.zip"
zip_two="$temp_root/two.zip"
./Scripts/package-ironwood-xcframework.sh "$zip_one" >/dev/null
./Scripts/package-ironwood-xcframework.sh "$zip_two" >/dev/null
if ! cmp -s "$zip_one" "$zip_two"; then
    echo "Error: identical XCFramework inputs produced different ZIP bytes" >&2
    exit 1
fi

for archive_number in one two; do
    archive="$temp_root/$archive_number.zip"
    extraction="$temp_root/extracted-$archive_number"
    mkdir -p "$extraction"
    /usr/bin/unzip -q "$archive" -d "$extraction"
    extracted_xcframework="$extraction/libzcashlc.xcframework"
    top_level=$(find "$extraction" -mindepth 1 -maxdepth 1 -print)
    if [[ "$top_level" != "$extracted_xcframework" \
        || ! -d "$extracted_xcframework" || -L "$extracted_xcframework" ]]
    then
        echo "Error: deterministic archive must extract exactly one XCFramework directory" >&2
        exit 1
    fi
    ./Scripts/compare-ironwood-xcframeworks.sh \
        LocalPackages/libzcashlc.xcframework "$extracted_xcframework" >/dev/null
    ./Scripts/verify-ironwood-ffi-artifact.sh "$extracted_xcframework"
done

checksum=$(shasum -a 256 "$zip_one" | awk '{print $1}')
echo "Two deterministic ZIPs and both extracted XCFrameworks verified identically: $checksum"
