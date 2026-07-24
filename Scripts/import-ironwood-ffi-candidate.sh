#!/bin/bash

# Downloads, authenticates, validates, and atomically installs the artifact-only handoff produced
# by build-ffi.yml's read-only candidate job. The candidate job performs the full exact-toolchain
# verifier on Xcode 16; this importer repeats portable layout, hash, source, and lineage checks
# before replacing any tracked artifact.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 4 ]]; then
    echo "Usage: $0 <workflow-run-id> <sdk-source-sha> <librustzcash-revision> <publication-ref>" >&2
    exit 1
fi

run_id="$1"
expected_source_sha="$2"
expected_rust_revision="$3"
expected_publication_ref="$4"
repository="just-zend/zcash-swift-wallet-sdk-zend"
workflow_path=".github/workflows/build-ffi.yml"
artifact_name="ironwood-ffi-candidate-${expected_source_sha}-${expected_rust_revision}"

if [[ ! "$run_id" =~ ^[1-9][0-9]*$ \
    || ! "$expected_source_sha" =~ ^[0-9a-f]{40}$ \
    || ! "$expected_rust_revision" =~ ^[0-9a-f]{40}$ \
    || ! "$expected_publication_ref" =~ ^refs/(heads|tags)/[-A-Za-z0-9._/]+$ ]]
then
    echo "Error: candidate import requires an exact run, SDK SHA, Rust SHA, and public ref" >&2
    exit 1
fi
if [[ "$(git rev-parse HEAD)" != "$expected_source_sha" \
    || -n "$(git status --porcelain)" ]]
then
    echo "Error: candidate import requires the clean exact SDK source commit" >&2
    exit 1
fi
cmp -s BuildSupport/LocalPackages-Package.swift LocalPackages/Package.swift

# Authenticate the run before trusting its self-described handoff manifest.
gh auth status >/dev/null
gh api user --jq .login >/dev/null
run_conclusion=$(gh api "repos/$repository/actions/runs/$run_id" --jq .conclusion)
run_event=$(gh api "repos/$repository/actions/runs/$run_id" --jq .event)
run_head_sha=$(gh api "repos/$repository/actions/runs/$run_id" --jq .head_sha)
run_head_repository=$(gh api "repos/$repository/actions/runs/$run_id" --jq .head_repository.full_name)
workflow_id=$(gh api "repos/$repository/actions/runs/$run_id" --jq .workflow_id)
actual_workflow_path=$(gh api "repos/$repository/actions/workflows/$workflow_id" --jq .path)
if [[ "$run_conclusion" != "success" || "$run_event" != "workflow_dispatch" \
    || "$run_head_sha" != "$expected_source_sha" || "$run_head_repository" != "$repository" \
    || "$actual_workflow_path" != "$workflow_path" ]]
then
    echo "Error: GitHub run is not the successful exact-source candidate workflow" >&2
    exit 1
fi
artifact_count=$(gh api "repos/$repository/actions/runs/$run_id/artifacts" \
    --jq "[.artifacts[] | select(.name == \"$artifact_name\" and .expired == false)] | length")
if [[ "$artifact_count" != "1" ]]; then
    echo "Error: expected one live exact-name candidate artifact, found $artifact_count" >&2
    exit 1
fi

temp_root=$(mktemp -d)
replacement_started=false
success=false
cleanup() {
    if [[ "$replacement_started" == true && "$success" != true ]]; then
        rm -rf LocalPackages/libzcashlc.xcframework
        cp -R -P "$temp_root/backup/libzcashlc.xcframework" LocalPackages/
        cp "$temp_root/backup/IRONWOOD_FFI_BUILD.env" BuildSupport/
        cp "$temp_root/backup/IRONWOOD_FFI_PROVENANCE.env" LocalPackages/
    fi
    rm -rf "$temp_root"
}
trap cleanup EXIT

handoff="$temp_root/handoff"
mkdir -p "$handoff"
gh run download "$run_id" --repo "$repository" --name "$artifact_name" --dir "$handoff"

actual_files=$(find "$handoff" -mindepth 1 -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort)
expected_files=$(printf '%s\n' \
    IRONWOOD_FFI_BUILD.env \
    IRONWOOD_FFI_PROVENANCE.env \
    candidate.env \
    libzcashlc.xcframework.zip)
unsupported=$(find "$handoff" -mindepth 1 -maxdepth 1 ! -type f -print -quit)
if [[ "$actual_files" != "$expected_files" || -n "$unsupported" ]]
then
    echo "Error: candidate handoff is not the exact four-file allowlist" >&2
    exit 1
fi

read_field() {
    local file="$1" field="$2" matches
    matches=$(grep -c "^${field}=" "$file" || true)
    if [[ "$matches" != "1" ]]; then
        echo "Error: $file must contain exactly one $field" >&2
        exit 1
    fi
    sed -n "s/^${field}=//p" "$file"
}
candidate="$handoff/candidate.env"
provenance="$handoff/IRONWOOD_FFI_PROVENANCE.env"
recipe="$handoff/IRONWOOD_FFI_BUILD.env"
archive="$handoff/libzcashlc.xcframework.zip"

if [[ "$(read_field "$candidate" REPOSITORY)" != "$repository" \
    || "$(read_field "$candidate" WORKFLOW_RUN_ID)" != "$run_id" \
    || "$(read_field "$candidate" SDK_SOURCE_SHA)" != "$expected_source_sha" \
    || "$(read_field "$candidate" LIBRUSTZCASH_REVISION)" != "$expected_rust_revision" \
    || "$(read_field "$candidate" LIBRUSTZCASH_PUBLICATION_REF)" != "$expected_publication_ref" ]]
then
    echo "Error: candidate manifest differs from the requested GitHub run/source lineage" >&2
    exit 1
fi
publication_tip=$(read_field "$candidate" LIBRUSTZCASH_PUBLICATION_TIP)
if [[ ! "$publication_tip" =~ ^[0-9a-f]{40}$ \
    || ! "$(read_field "$candidate" WORKFLOW_RUN_ATTEMPT)" =~ ^[1-9][0-9]*$ ]]
then
    echo "Error: candidate manifest has invalid run or publication evidence" >&2
    exit 1
fi

verify_file_hash() {
    local expected="$1" file="$2"
    local actual
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ || "$actual" != "$expected" ]]; then
        echo "Error: candidate hash mismatch for $file" >&2
        exit 1
    fi
}
verify_file_hash "$(read_field "$candidate" XCFRAMEWORK_ZIP_SHA256)" "$archive"
verify_file_hash "$(read_field "$candidate" PROVENANCE_SHA256)" "$provenance"
verify_file_hash "$(read_field "$candidate" BUILD_RECIPE_SHA256)" "$recipe"

for record in "$provenance" "$recipe"; do
    if [[ "$(read_field "$record" SDK_FFI_SOURCE_REVISION)" != "$expected_source_sha" \
        || "$(read_field "$record" SDK_FFI_SOURCE_TREE)" != "$(git rev-parse 'HEAD^{tree}')" \
        || "$(read_field "$record" SDK_IRONWOOD_IMPLEMENTATION_REVISION)" != "$expected_source_sha" \
        || "$(read_field "$record" LIBRUSTZCASH_REPOSITORY)" != "https://github.com/just-zend/librustzcash" \
        || "$(read_field "$record" LIBRUSTZCASH_REVISION)" != "$expected_rust_revision" ]]
    then
        echo "Error: candidate build record differs from the exact SDK/Rust source" >&2
        exit 1
    fi
done
if [[ "$(read_field "$provenance" LIBRUSTZCASH_PUBLICATION_REF_AT_BUILD)" != "$expected_publication_ref" \
    || "$(read_field "$provenance" LIBRUSTZCASH_PUBLICATION_TIP_AT_BUILD)" != "$publication_tip" ]]
then
    echo "Error: candidate provenance differs from the authenticated public Rust lineage" >&2
    exit 1
fi

extraction="$temp_root/extracted"
mkdir -p "$extraction"
/usr/bin/unzip -q "$archive" -d "$extraction"
xcframework="$extraction/libzcashlc.xcframework"
top_level=$(find "$extraction" -mindepth 1 -maxdepth 1 -print)
if [[ "$top_level" != "$xcframework" || ! -d "$xcframework" || -L "$xcframework" ]]; then
    echo "Error: candidate archive must extract exactly one real XCFramework directory" >&2
    exit 1
fi
./Scripts/verify-ironwood-ffi-layout.sh "$xcframework" >/dev/null
./Scripts/verify-ironwood-xcframework-metadata.sh "$xcframework" >/dev/null
verify_file_hash "$(read_field "$provenance" IOS_ARM64_SHA256)" \
    "$xcframework/ios-arm64/libzcashlc.framework/libzcashlc"
verify_file_hash "$(read_field "$provenance" IOS_SIMULATOR_UNIVERSAL_SHA256)" \
    "$xcframework/ios-arm64_x86_64-simulator/libzcashlc.framework/libzcashlc"
verify_file_hash "$(read_field "$provenance" MACOS_UNIVERSAL_SHA256)" \
    "$xcframework/macos-arm64_x86_64/libzcashlc.framework/libzcashlc"
verify_file_hash "$(read_field "$provenance" XCFRAMEWORK_INFO_SHA256)" "$xcframework/Info.plist"
if [[ "$(read_field "$provenance" XCFRAMEWORK_MANIFEST_SHA256)" \
    != "$(./Scripts/hash-ironwood-xcframework.sh "$xcframework")" ]]
then
    echo "Error: candidate XCFramework manifest differs from provenance" >&2
    exit 1
fi

mkdir -p "$temp_root/backup"
cp -R -P LocalPackages/libzcashlc.xcframework "$temp_root/backup/"
cp BuildSupport/IRONWOOD_FFI_BUILD.env "$temp_root/backup/"
cp LocalPackages/IRONWOOD_FFI_PROVENANCE.env "$temp_root/backup/"
replacement_started=true
rm -rf LocalPackages/libzcashlc.xcframework
mv "$xcframework" LocalPackages/
cp "$recipe" BuildSupport/IRONWOOD_FFI_BUILD.env
cp "$provenance" LocalPackages/IRONWOOD_FFI_PROVENANCE.env

./Scripts/verify-ironwood-ffi-layout.sh LocalPackages/libzcashlc.xcframework >/dev/null
./Scripts/verify-ironwood-xcframework-metadata.sh LocalPackages/libzcashlc.xcframework >/dev/null
if [[ "$(./Scripts/hash-ironwood-ffi-sources.sh)" != "$(read_field "$provenance" SDK_FFI_SOURCE_SHA256)" \
    || "$(./Scripts/verify-ironwood-cargo-pins.sh --print-revision)" != "$expected_rust_revision" ]]
then
    echo "Error: installed candidate differs from the exact committed source graph" >&2
    exit 1
fi
./Scripts/verify-ironwood-static-release-inputs.sh >/dev/null

while IFS= read -r status_line; do
    path=${status_line:3}
    case "$path" in
        BuildSupport/IRONWOOD_FFI_BUILD.env | \
        LocalPackages/IRONWOOD_FFI_PROVENANCE.env | \
        LocalPackages/libzcashlc.xcframework/*) ;;
        *)
            echo "Error: candidate import changed a non-artifact path: $path" >&2
            exit 1
            ;;
    esac
done < <(git -c status.renames=false status --porcelain=v1 --untracked-files=all)
git diff --check

if [[ "${IRONWOOD_IMPORT_RUN_FULL_VERIFIER:-0}" == "1" ]]; then
    ./Scripts/verify-ironwood-ffi-artifact.sh
else
    echo "Portable import checks passed; full exact-tool verification already passed in GitHub run $run_id."
    echo "Set IRONWOOD_IMPORT_RUN_FULL_VERIFIER=1 to repeat it on an identically provisioned host."
fi
success=true
echo "Installed verified Ironwood FFI candidate from GitHub run $run_id."
