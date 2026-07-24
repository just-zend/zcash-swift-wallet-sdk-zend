#!/bin/bash

# Byte-for-byte comparison of two already allowlisted XCFrameworks. Regular files are compared
# directly and every symlink kind/target is compared without following it.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <expected-xcframework> <actual-xcframework>" >&2
    exit 1
fi
expected="$1"
actual="$2"

./Scripts/verify-ironwood-ffi-layout.sh "$expected" >/dev/null
./Scripts/verify-ironwood-ffi-layout.sh "$actual" >/dev/null

while IFS= read -r -d '' expected_path; do
    relative="${expected_path#"$expected"/}"
    actual_path="$actual/$relative"
    if [[ -L "$expected_path" ]]; then
        if [[ ! -L "$actual_path" || "$(readlink "$expected_path")" != "$(readlink "$actual_path")" ]]; then
            echo "Error: XCFramework symlink differs: $relative" >&2
            exit 1
        fi
    elif [[ -f "$expected_path" ]]; then
        if [[ ! -f "$actual_path" || -L "$actual_path" ]] || ! cmp -s "$expected_path" "$actual_path"; then
            echo "Error: XCFramework file differs: $relative" >&2
            exit 1
        fi
    elif [[ ! -d "$actual_path" || -L "$actual_path" ]]; then
        echo "Error: XCFramework directory kind differs: $relative" >&2
        exit 1
    fi
done < <(find "$expected" -mindepth 1 -print0 | LC_ALL=C sort -z)

expected_hash=$(./Scripts/hash-ironwood-xcframework.sh "$expected")
actual_hash=$(./Scripts/hash-ironwood-xcframework.sh "$actual")
if [[ "$expected_hash" != "$actual_hash" ]]; then
    echo "Error: XCFramework manifests differ after byte comparison" >&2
    exit 1
fi

echo "XCFrameworks are byte-identical with matching file and symlink manifests: $actual_hash"
