#!/bin/bash

# Exact allowlist for the release XCFramework. Any extra payload, missing payload, or unexpected
# symlink is a hard failure. The only allowed links are the conventional macOS framework links,
# whose relative targets are fixed below and cannot escape the bundle.

set -euo pipefail
cd "$(dirname "$0")/.."

xcframework="${1:-LocalPackages/libzcashlc.xcframework}"
if [[ ! -d "$xcframework" ]]; then
    echo "Error: XCFramework not found: $xcframework" >&2
    exit 1
fi

expected=$(mktemp)
actual=$(mktemp)
cleanup() {
    rm -f "$expected" "$actual"
}
trap cleanup EXIT

cat > "$expected" <<'EOF'
d ios-arm64
d ios-arm64/libzcashlc.framework
d ios-arm64/libzcashlc.framework/Headers
d ios-arm64/libzcashlc.framework/Modules
d ios-arm64_x86_64-simulator
d ios-arm64_x86_64-simulator/libzcashlc.framework
d ios-arm64_x86_64-simulator/libzcashlc.framework/Headers
d ios-arm64_x86_64-simulator/libzcashlc.framework/Modules
d macos-arm64_x86_64
d macos-arm64_x86_64/libzcashlc.framework
d macos-arm64_x86_64/libzcashlc.framework/Versions
d macos-arm64_x86_64/libzcashlc.framework/Versions/A
d macos-arm64_x86_64/libzcashlc.framework/Versions/A/Headers
d macos-arm64_x86_64/libzcashlc.framework/Versions/A/Modules
d macos-arm64_x86_64/libzcashlc.framework/Versions/A/Resources
f Info.plist
f ios-arm64/libzcashlc.framework/Headers/zcashlc.h
f ios-arm64/libzcashlc.framework/Info.plist
f ios-arm64/libzcashlc.framework/Modules/module.modulemap
f ios-arm64/libzcashlc.framework/libzcashlc
f ios-arm64_x86_64-simulator/libzcashlc.framework/Headers/zcashlc.h
f ios-arm64_x86_64-simulator/libzcashlc.framework/Info.plist
f ios-arm64_x86_64-simulator/libzcashlc.framework/Modules/module.modulemap
f ios-arm64_x86_64-simulator/libzcashlc.framework/libzcashlc
f macos-arm64_x86_64/libzcashlc.framework/Versions/A/Headers/zcashlc.h
f macos-arm64_x86_64/libzcashlc.framework/Versions/A/Modules/module.modulemap
f macos-arm64_x86_64/libzcashlc.framework/Versions/A/Resources/Info.plist
f macos-arm64_x86_64/libzcashlc.framework/Versions/A/libzcashlc
l macos-arm64_x86_64/libzcashlc.framework/Headers -> Versions/Current/Headers
l macos-arm64_x86_64/libzcashlc.framework/Modules -> Versions/Current/Modules
l macos-arm64_x86_64/libzcashlc.framework/Resources -> Versions/Current/Resources
l macos-arm64_x86_64/libzcashlc.framework/Versions/Current -> A
l macos-arm64_x86_64/libzcashlc.framework/libzcashlc -> Versions/Current/libzcashlc
EOF
LC_ALL=C sort -o "$expected" "$expected"

unsupported=$(find "$xcframework" -mindepth 1 ! -type d ! -type f ! -type l -print -quit)
if [[ -n "$unsupported" ]]; then
    echo "Error: unsupported XCFramework filesystem object: $unsupported" >&2
    exit 1
fi

while IFS= read -r -d '' path; do
    relative="${path#"$xcframework"/}"
    if [[ -L "$path" ]]; then
        target=$(readlink "$path")
        if [[ "$target" == /* || "/$target/" == *"/../"* ]]; then
            echo "Error: absolute or escaping XCFramework symlink: $relative -> $target" >&2
            exit 1
        fi
        printf 'l %s -> %s\n' "$relative" "$target" >> "$actual"
    elif [[ -d "$path" ]]; then
        printf 'd %s\n' "$relative" >> "$actual"
    elif [[ -f "$path" ]]; then
        printf 'f %s\n' "$relative" >> "$actual"
    fi
done < <(find "$xcframework" -mindepth 1 -print0 | LC_ALL=C sort -z)
LC_ALL=C sort -o "$actual" "$actual"

if ! cmp -s "$expected" "$actual"; then
    echo "Error: XCFramework layout differs from the exact reviewed allowlist" >&2
    diff -u "$expected" "$actual" >&2 || true
    exit 1
fi

modulemaps=(
    "$xcframework/ios-arm64/libzcashlc.framework/Modules/module.modulemap"
    "$xcframework/ios-arm64_x86_64-simulator/libzcashlc.framework/Modules/module.modulemap"
    "$xcframework/macos-arm64_x86_64/libzcashlc.framework/Versions/A/Modules/module.modulemap"
)
for modulemap in "${modulemaps[@]}"; do
    if ! cmp -s BuildSupport/module.modulemap "$modulemap"; then
        echo "Error: packaged module map differs from BuildSupport/module.modulemap: $modulemap" >&2
        exit 1
    fi
done

echo "XCFramework layout and module maps match the exact reviewed allowlist."
