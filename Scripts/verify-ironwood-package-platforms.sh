#!/bin/bash

# Parses the manifest through SwiftPM; source comments or lookalike text cannot satisfy this gate.

set -euo pipefail
package_path="${1:-.}"
dump=$(mktemp)
cleanup() { rm -f "$dump"; }
trap cleanup EXIT

if ! swift package --package-path "$package_path" dump-package > "$dump" \
    || ! jq -e '
        (.platforms | sort_by(.platformName)) == [
            {"options": [], "platformName": "ios", "version": "13.0"},
            {"options": [], "platformName": "macos", "version": "12.0"}
        ]
    ' "$dump" >/dev/null
then
    echo "Error: parsed Package.swift platform floors differ from iOS 13 / macOS 12" >&2
    exit 1
fi

echo "Parsed Package.swift declares exactly iOS 13 and macOS 12."
