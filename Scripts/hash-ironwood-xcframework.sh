#!/bin/bash

# Emits one deterministic SHA-256 over every regular file and symbolic link shipped inside the
# XCFramework. File modes and timestamps are intentionally excluded; file contents, relative paths,
# file kinds, and exact symlink targets are included with NUL separators so unusual paths cannot
# alias one another.

set -euo pipefail

xcframework="${1:-LocalPackages/libzcashlc.xcframework}"
if [[ ! -d "$xcframework" || ! -f "$xcframework/Info.plist" ]]; then
    echo "Error: XCFramework not found: $xcframework" >&2
    exit 1
fi

unsupported=$(find "$xcframework" ! -type d ! -type f ! -type l -print -quit)
if [[ -n "$unsupported" ]]; then
    echo "Error: unsupported XCFramework filesystem object: $unsupported" >&2
    exit 1
fi
if ! find "$xcframework" \( -type f -o -type l \) -print -quit | grep -q .; then
    echo "Error: XCFramework contains no files or symbolic links" >&2
    exit 1
fi

{
    while IFS= read -r -d '' path; do
        relative_path="${path#"$xcframework"/}"
        if [[ -L "$path" ]]; then
            printf 'symlink\0%s\0%s\0' "$relative_path" "$(readlink "$path")"
        else
            printf 'file\0%s\0%s\0' \
                "$relative_path" \
                "$(shasum -a 256 "$path" | awk '{print $1}')"
        fi
    done < <(find "$xcframework" \( -type f -o -type l \) -print0 | LC_ALL=C sort -z)
} | shasum -a 256 | awk '{print $1}'
