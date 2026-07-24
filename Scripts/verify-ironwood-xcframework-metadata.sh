#!/bin/bash

# Validates the exact SwiftPM routing table for the release XCFramework. This is deliberately
# semantic rather than a hash-only check: a newly generated plist with the wrong platform or
# architecture advertisement must fail even when its bytes are faithfully recorded in provenance.

set -euo pipefail

xcframework="${1:-LocalPackages/libzcashlc.xcframework}"
info_plist="$xcframework/Info.plist"
if [[ ! -f "$info_plist" ]]; then
    echo "Error: XCFramework Info.plist not found: $info_plist" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for semantic XCFramework metadata verification" >&2
    exit 1
fi

expected_libraries='[{"LibraryIdentifier":"ios-arm64","LibraryPath":"libzcashlc.framework","SupportedArchitectures":["arm64"],"SupportedPlatform":"ios","SupportedPlatformVariant":null},{"LibraryIdentifier":"ios-arm64_x86_64-simulator","LibraryPath":"libzcashlc.framework","SupportedArchitectures":["arm64","x86_64"],"SupportedPlatform":"ios","SupportedPlatformVariant":"simulator"},{"LibraryIdentifier":"macos-arm64_x86_64","LibraryPath":"libzcashlc.framework","SupportedArchitectures":["arm64","x86_64"],"SupportedPlatform":"macos","SupportedPlatformVariant":null}]'
if ! actual_libraries=$(plutil -convert json -o - "$info_plist" | jq -cer '
    if .CFBundlePackageType != "XFWK" or .XCFrameworkFormatVersion != "1.0" then
        error("invalid XCFramework envelope")
    else
        .AvailableLibraries
        | if type != "array" or length != 3 then error("expected three libraries") else . end
        | sort_by(.LibraryIdentifier)
        | map({
            LibraryIdentifier,
            LibraryPath,
            SupportedArchitectures: (.SupportedArchitectures | sort),
            SupportedPlatform,
            SupportedPlatformVariant: (.SupportedPlatformVariant // null)
        })
    end
')
then
    echo "Error: invalid XCFramework AvailableLibraries metadata" >&2
    exit 1
fi
if [[ "$actual_libraries" != "$expected_libraries" ]]; then
    echo "Error: XCFramework AvailableLibraries does not describe the required three slices and five architectures" >&2
    diff -u \
        <(printf '%s\n' "$expected_libraries" | jq .) \
        <(printf '%s\n' "$actual_libraries" | jq .) >&2 || true
    exit 1
fi

echo "XCFramework metadata advertises the exact three slices and five architectures."
