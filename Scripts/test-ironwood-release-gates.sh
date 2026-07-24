#!/bin/bash

# Fast adversarial fixtures for the release gates. The expensive double rebuild and double-package
# checks are exercised by their dedicated CI scripts; this suite pins the negative cases reviewers
# identified so future refactors cannot silently weaken them.

set -euo pipefail
cd "$(dirname "$0")/.."

expect_failure() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "Error: negative fixture unexpectedly passed: $label" >&2
        exit 1
    fi
}

temp_root=$(mktemp -d)
cleanup() { rm -rf "$temp_root"; }
trap cleanup EXIT

pristine="$temp_root/pristine.xcframework"
cp -R -P LocalPackages/libzcashlc.xcframework "$pristine"
./Scripts/verify-ironwood-ffi-layout.sh "$pristine" >/dev/null

extra="$temp_root/extra.xcframework"
cp -R -P "$pristine" "$extra"
touch "$extra/unreviewed-payload"
expect_failure "extra XCFramework payload" ./Scripts/verify-ironwood-ffi-layout.sh "$extra"

wrong_modulemap="$temp_root/wrong-modulemap.xcframework"
cp -R -P "$pristine" "$wrong_modulemap"
printf '\nmodule injected {}\n' >> \
    "$wrong_modulemap/ios-arm64/libzcashlc.framework/Modules/module.modulemap"
expect_failure "unreviewed module map" ./Scripts/verify-ironwood-ffi-layout.sh "$wrong_modulemap"

escaping_link="$temp_root/escaping-link.xcframework"
cp -R -P "$pristine" "$escaping_link"
rm "$escaping_link/macos-arm64_x86_64/libzcashlc.framework/Headers"
ln -s ../../../../outside "$escaping_link/macos-arm64_x86_64/libzcashlc.framework/Headers"
expect_failure "escaping framework symlink" ./Scripts/verify-ironwood-ffi-layout.sh "$escaping_link"

tampered="$temp_root/tampered.xcframework"
cp -R -P "$pristine" "$tampered"
printf '\0' >> "$tampered/ios-arm64/libzcashlc.framework/libzcashlc"
tampered_provenance="$temp_root/tampered-provenance.env"
cp LocalPackages/IRONWOOD_FFI_PROVENANCE.env "$tampered_provenance"
replace_field() {
    local file="$1" field="$2" value="$3"
    local replacement="$file.replacement"
    awk -v field="$field" -v value="$value" '
        index($0, field "=") == 1 { print field "=" value; next }
        { print }
    ' "$file" > "$replacement"
    mv "$replacement" "$file"
}
replace_field "$tampered_provenance" IOS_ARM64_SHA256 \
    "$(shasum -a 256 "$tampered/ios-arm64/libzcashlc.framework/libzcashlc" | awk '{print $1}')"
replace_field "$tampered_provenance" XCFRAMEWORK_MANIFEST_SHA256 \
    "$(./Scripts/hash-ironwood-xcframework.sh "$tampered")"
expect_failure "tampered binary with recomputed editable provenance" \
    ./Scripts/compare-ironwood-xcframeworks.sh "$pristine" "$tampered"

retired_source="$temp_root/retired.rs"
printf 'use zodl_ironwood_migration::MigrationContext;\n' > "$retired_source"
expect_failure "lowercase retired engine source" env \
    IRONWOOD_STATIC_LIVE_SOURCE_PATHS="$retired_source" \
    IRONWOOD_STATIC_SKIP_ARTIFACT=true IRONWOOD_STATIC_SKIP_CARGO_PINS=true \
    ./Scripts/verify-ironwood-static-release-inputs.sh

retired_binary="$temp_root/retired.bin"
touch "$retired_source.clean"
printf 'ssh://git@github.com/Chlup/ZODLIronwoodMigrationRust.git\0' > "$retired_binary"
expect_failure "retired engine binary metadata" env \
    IRONWOOD_STATIC_LIVE_SOURCE_PATHS="$retired_source.clean" \
    IRONWOOD_STATIC_ARTIFACT_ROOT="$retired_binary" IRONWOOD_STATIC_SKIP_CARGO_PINS=true \
    ./Scripts/verify-ironwood-static-release-inputs.sh

disabled_swift="$temp_root/disabled-swift"
mkdir -p "$disabled_swift"
printf 'func unsafeMigrationCall() { zcashlc_migration_restart_step() }\n' \
    > "$disabled_swift/Production.swift"
expect_failure "production call to disabled migration FFI" \
    ./Scripts/audit-disabled-migration-ffi.sh "$disabled_swift"

source_root="$temp_root/source-root"
mkdir -p "$source_root"
cp Cargo.toml Cargo.lock Package.swift rust-toolchain.toml "$source_root/"
cp -R BuildSupport Scripts rust .github "$source_root/"
ln -s ../Cargo.toml "$source_root/rust/injected-source-link.rs"
expect_failure "symbolic link in FFI sources" env IRONWOOD_FFI_SOURCE_ROOT="$source_root" \
    ./Scripts/hash-ironwood-ffi-sources.sh

package_fixture="$temp_root/commented-platforms"
mkdir -p "$package_fixture/Sources/Fixture"
cat > "$package_fixture/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription
// Lookalikes must not pass: .iOS(.v13), .macOS(.v12)
let package = Package(
    name: "Fixture",
    platforms: [.iOS(.v14), .macOS(.v13)],
    targets: [.target(name: "Fixture")]
)
EOF
printf 'public struct Fixture {}\n' > "$package_fixture/Sources/Fixture/Fixture.swift"
expect_failure "comment-only supported platform floors" \
    ./Scripts/verify-ironwood-package-platforms.sh "$package_fixture"

valid_otool="$temp_root/valid-legacy.txt"
cat > "$valid_otool" <<'EOF'
Archive : fixture.a
fixture.a(legacy.o):
Load command 0
      cmd LC_VERSION_MIN_IPHONEOS
  cmdsize 16
  version 13.0
      sdk 16.0
EOF
./Scripts/verify-ironwood-macho-floor.sh \
    --otool-output "$valid_otool" 2 13.0 LC_VERSION_MIN_IPHONEOS

valid_build_otool="$temp_root/valid-build.txt"
cat > "$valid_build_otool" <<'EOF'
Archive : fixture.a
fixture.a(build.o):
Load command 0
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 2
    minos 13.0
      sdk 16.0
   ntools 1
EOF
./Scripts/verify-ironwood-macho-floor.sh \
    --otool-output "$valid_build_otool" 2 13.0 LC_VERSION_MIN_IPHONEOS

wrong_otool="$temp_root/wrong-legacy.txt"
cat > "$wrong_otool" <<'EOF'
Archive : fixture.a
fixture.a(wrong.o):
Load command 0
      cmd LC_VERSION_MIN_MACOSX
  cmdsize 16
  version 14.0
      sdk 16.0
EOF
expect_failure "wrong legacy platform and deployment floor" \
    ./Scripts/verify-ironwood-macho-floor.sh \
    --otool-output "$wrong_otool" 2 13.0 LC_VERSION_MIN_IPHONEOS

too_new_otool="$temp_root/too-new-build.txt"
sed 's/minos 13\.0/minos 14.0/' "$valid_build_otool" > "$too_new_otool"
expect_failure "too-new build-version deployment floor" \
    ./Scripts/verify-ironwood-macho-floor.sh \
    --otool-output "$too_new_otool" 2 13.0 LC_VERSION_MIN_IPHONEOS

mixed_otool="$temp_root/mixed-load-commands.txt"
cat > "$mixed_otool" <<'EOF'
Archive : fixture.a
fixture.a(mixed.o):
Load command 0
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 2
    minos 13.0
      sdk 16.0
   ntools 1
Load command 1
      cmd LC_VERSION_MIN_IPHONEOS
  cmdsize 16
  version 13.0
      sdk 16.0
EOF
expect_failure "mixed deployment-target commands" \
    ./Scripts/verify-ironwood-macho-floor.sh \
    --otool-output "$mixed_otool" 2 13.0 LC_VERSION_MIN_IPHONEOS

missing_otool="$temp_root/missing-load-command.txt"
cat > "$missing_otool" <<'EOF'
Archive : fixture.a
fixture.a(missing.o):
Load command 0
      cmd LC_SEGMENT_64
  cmdsize 72
EOF
expect_failure "missing deployment-target command" \
    ./Scripts/verify-ironwood-macho-floor.sh \
    --otool-output "$missing_otool" 2 13.0 LC_VERSION_MIN_IPHONEOS

wrong_lineage_provenance="$temp_root/wrong-lineage-provenance.env"
wrong_lineage_recipe="$temp_root/wrong-lineage-recipe.env"
cp LocalPackages/IRONWOOD_FFI_PROVENANCE.env "$wrong_lineage_provenance"
cp BuildSupport/IRONWOOD_FFI_BUILD.env "$wrong_lineage_recipe"
replace_field "$wrong_lineage_provenance" SDK_PR_1812_MERGE_REVISION \
    0000000000000000000000000000000000000000
replace_field "$wrong_lineage_recipe" SDK_PR_1812_MERGE_REVISION \
    0000000000000000000000000000000000000000
expect_failure "wrong SDK merge lineage" ./Scripts/verify-ironwood-ffi-artifact.sh \
    "$pristine" "$wrong_lineage_provenance" "$wrong_lineage_recipe"

extra_git_manifest="$temp_root/Cargo-extra.toml"
cp Cargo.toml "$extra_git_manifest"
printf '\nunreviewed = { git = "https://example.invalid/unreviewed", rev = "0000000000000000000000000000000000000000" }\n' \
    >> "$extra_git_manifest"
expect_failure "extra non-registry dependency" env \
    IRONWOOD_CARGO_MANIFEST="$extra_git_manifest" IRONWOOD_CARGO_LOCKFILE=Cargo.lock \
    ./Scripts/verify-ironwood-cargo-pins.sh

multiline_git_manifest="$temp_root/Cargo-multiline-git.toml"
cp Cargo.toml "$multiline_git_manifest"
cat >> "$multiline_git_manifest" <<'EOF'

[target.'cfg(target_os = "ios")'.dependencies.unreviewed]
"git" = "https://example.invalid/unreviewed"
rev = "0000000000000000000000000000000000000000"
EOF
expect_failure "quoted multiline non-registry dependency" env \
    IRONWOOD_CARGO_MANIFEST="$multiline_git_manifest" IRONWOOD_CARGO_LOCKFILE=Cargo.lock \
    ./Scripts/verify-ironwood-cargo-pins.sh

path_manifest="$temp_root/Cargo-path.toml"
cp Cargo.toml "$path_manifest"
cat >> "$path_manifest" <<'EOF'

[target.'cfg(target_os = "ios")'.dependencies.unreviewed]
'path' = "../unreviewed"
EOF
expect_failure "quoted target-specific path dependency" env \
    IRONWOOD_CARGO_MANIFEST="$path_manifest" IRONWOOD_CARGO_LOCKFILE=Cargo.lock \
    ./Scripts/verify-ironwood-cargo-pins.sh

extra_lock="$temp_root/Cargo-extra.lock"
cp Cargo.lock "$extra_lock"
cat >> "$extra_lock" <<'EOF'

[[package]]
name = "unreviewed"
version = "0.0.0"
source = "git+https://example.invalid/unreviewed?rev=0000000000000000000000000000000000000000#0000000000000000000000000000000000000000"
EOF
expect_failure "extra non-registry lockfile source" env \
    IRONWOOD_CARGO_MANIFEST=Cargo.toml IRONWOOD_CARGO_LOCKFILE="$extra_lock" \
    ./Scripts/verify-ironwood-cargo-pins.sh

release_sha=1111111111111111111111111111111111111111
valid_environment="$temp_root/valid-environment.json"
cat > "$valid_environment" <<'EOF'
{
  "name": "sdk-release",
  "protection_rules": [
    {
      "id": 1,
      "type": "required_reviewers",
      "prevent_self_review": true,
      "reviewers": [
        {"type": "User", "reviewer": {"id": 7, "login": "reviewer"}}
      ]
    },
    {"id": 2, "type": "branch_policy"}
  ],
  "deployment_branch_policy": {
    "protected_branches": true,
    "custom_branch_policies": false
  }
}
EOF
valid_branch="$temp_root/valid-main.json"
cat > "$valid_branch" <<EOF
{
  "name": "main",
  "protected": true,
  "commit": {"sha": "$release_sha"}
}
EOF
bash ./Scripts/verify-sdk-release-environment.sh \
    --fixture "$valid_environment" "$valid_branch" "$release_sha" >/dev/null

missing_reviewers="$temp_root/missing-reviewers.json"
jq 'del(.protection_rules[] | select(.type == "required_reviewers"))' \
    "$valid_environment" > "$missing_reviewers"
expect_failure "release environment without required reviewers" \
    bash ./Scripts/verify-sdk-release-environment.sh \
    --fixture "$missing_reviewers" "$valid_branch" "$release_sha"

self_review="$temp_root/self-review.json"
jq '(.protection_rules[] | select(.type == "required_reviewers")).prevent_self_review = false' \
    "$valid_environment" > "$self_review"
expect_failure "release environment allowing self-review" \
    bash ./Scripts/verify-sdk-release-environment.sh \
    --fixture "$self_review" "$valid_branch" "$release_sha"

unrestricted_environment="$temp_root/unrestricted-environment.json"
jq '.deployment_branch_policy = {"protected_branches": false, "custom_branch_policies": true}' \
    "$valid_environment" > "$unrestricted_environment"
expect_failure "release environment without protected-branch policy" \
    bash ./Scripts/verify-sdk-release-environment.sh \
    --fixture "$unrestricted_environment" "$valid_branch" "$release_sha"

unprotected_main="$temp_root/unprotected-main.json"
jq '.protected = false' "$valid_branch" > "$unprotected_main"
expect_failure "unprotected main release source" \
    bash ./Scripts/verify-sdk-release-environment.sh \
    --fixture "$valid_environment" "$unprotected_main" "$release_sha"

expect_failure "release source no longer at main tip" \
    bash ./Scripts/verify-sdk-release-environment.sh \
    --fixture "$valid_environment" "$valid_branch" \
    2222222222222222222222222222222222222222

echo "All adversarial Ironwood release-gate fixtures failed closed as expected."
