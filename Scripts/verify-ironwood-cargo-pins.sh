#!/bin/bash

# Static, network-free proof that every canonical librustzcash-family package is exact-pinned to
# one public Zend revision in both Cargo.toml and Cargo.lock. This is shared by the source builder
# and the committed-artifact verifier so public CI cannot be bypassed with a hand-written lockfile
# or a same-count substitute dependency.

set -euo pipefail
cd "$(dirname "$0")/.."

manifest="${IRONWOOD_CARGO_MANIFEST:-Cargo.toml}"
lockfile="${IRONWOOD_CARGO_LOCKFILE:-Cargo.lock}"
expected_repository="https://github.com/just-zend/librustzcash"
expected_voting_repository="https://github.com/just-zend/zcash_voting.git"
expected_voting_revision="04d255628f1d56de0479e3fb6963409dbe44ec1f"

for file in "$manifest" "$lockfile"; do
    if [[ ! -f "$file" ]]; then
        echo "Error: missing Cargo pin input $file" >&2
        exit 1
    fi
done

# The consolidated delivery/runtime schema is deliberately opt-in in upstream-compatible
# librustzcash. A release artifact that omits this feature may still compile ordinary Orchard
# wallet code while silently dropping the migration store that the FFI requires.
if ! grep -Fxq \
    'zcash_client_sqlite = { version = "0.22.0-rc.1", features = ["migration-delivery", "orchard", "transparent-inputs", "unstable", "serde"] }' \
    "$manifest"
then
    echo "Error: zcash_client_sqlite must explicitly enable the migration-delivery feature" >&2
    exit 1
fi

librust_lines=$(mktemp)
all_git_lines=$(mktemp)
cleanup() {
    rm -f "$librust_lines" "$all_git_lines"
}
trap cleanup EXIT

# Require every git source to use the reviewed, single-line canonical form below. Searching for
# quoted and multiline TOML keys as well prevents an extra dependency from hiding outside the
# simple `name = { git = ... }` spelling used by the reviewed pins.
rg -N --no-heading --color never \
    '(?:^|[\s,{])(?:git|"git"|'"'"'git'"'"')\s*=' "$manifest" \
    | grep -Ev '^[[:space:]]*#' > "$all_git_lines" || true
grep -E '^[a-zA-Z0-9_-]+[[:space:]]*=.*git = ".*librustzcash"' "$manifest" \
    > "$librust_lines" || true

expected_names=$(printf '%s\n' \
    equihash \
    f4jumble \
    pczt \
    zcash_address \
    zcash_client_backend \
    zcash_client_sqlite \
    zcash_encoding \
    zcash_keys \
    zcash_pool_migration \
    zcash_primitives \
    zcash_proofs \
    zcash_protocol \
    zcash_transparent \
    zip321 | LC_ALL=C sort)
actual_names=$(sed -nE 's/^([a-zA-Z0-9_-]+)[[:space:]]*=.*$/\1/p' "$librust_lines" | LC_ALL=C sort)
if [[ "$actual_names" != "$expected_names" ]]; then
    echo "Error: Cargo.toml does not contain the exact 14 canonical librustzcash-family pins" >&2
    diff -u <(printf '%s\n' "$expected_names") <(printf '%s\n' "$actual_names") >&2 || true
    exit 1
fi

# No extra git or path dependency may hide beside the reviewed family. Registry dependencies are
# still locked by Cargo.lock and rebuilt by the reproducibility gate; every non-registry source is
# restricted here to the exact Zend librustzcash family plus the one reviewed voting repository.
unexpected_git_lines=$(grep -Ev \
    'git[[:space:]]*=[[:space:]]*"https://github.com/just-zend/(librustzcash|zcash_voting\.git)"' \
    "$all_git_lines" || true)
if [[ -n "$unexpected_git_lines" ]]; then
    echo "Error: Cargo.toml contains an unreviewed git dependency" >&2
    printf '%s\n' "$unexpected_git_lines" >&2
    exit 1
fi
git_dependency_count=$(wc -l < "$all_git_lines" | tr -d ' ')
if [[ "$git_dependency_count" != "15" ]]; then
    echo "Error: Cargo.toml must contain exactly 14 librustzcash pins and one voting pin" >&2
    exit 1
fi
# The package's own library target is the sole path key in the manifest. Reject inline, multiline,
# duplicate, and quoted path keys everywhere else, including target-specific dependency tables.
path_lines=$(rg -N --no-heading --color never \
    '(?:^|[\s,{])(?:path|"path"|'"'"'path'"'"')\s*=' "$manifest" \
    | grep -Ev '^[[:space:]]*#' || true)
path_key_count=$(printf '%s\n' "$path_lines" | sed '/^$/d' | wc -l | tr -d ' ')
if [[ "$path_key_count" != "1" || "$path_lines" != 'path = "rust/src/lib.rs"' ]] \
    || ! awk '
        /^\[[^[]/ { section = $0 }
        section == "[lib]" && $0 == "path = \"rust/src/lib.rs\"" { matches += 1 }
        END { exit !(matches == 1) }
    ' "$manifest"
then
    echo "Error: Cargo.toml contains an unreviewed path source" >&2
    printf '%s\n' "$path_lines" >&2
    exit 1
fi

revisions=""
while IFS= read -r name; do
    dependency_line=$(grep -E "^${name}[[:space:]]*=" "$librust_lines" || true)
    dependency_count=$(printf '%s\n' "$dependency_line" | sed '/^$/d' | wc -l | tr -d ' ')
    repository=$(printf '%s\n' "$dependency_line" \
        | sed -nE 's@^.*git = "([^"]+)".*$@\1@p')
    dependency_revision=$(printf '%s\n' "$dependency_line" \
        | sed -nE 's@^.*rev = "([0-9a-f]{40})".*$@\1@p')
    if [[ "$dependency_count" != "1" \
        || "$repository" != "$expected_repository" \
        || ! "$dependency_revision" =~ ^[0-9a-f]{40}$ ]]
    then
        echo "Error: $name must be exact-pinned once to the canonical just-zend repository" >&2
        exit 1
    fi
    revisions+="${dependency_revision}"$'\n'
done <<< "$expected_names"
revisions=$(printf '%s' "$revisions" | LC_ALL=C sort -u)
if [[ ! "$revisions" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Error: all 14 canonical librustzcash-family dependencies must use one exact revision" >&2
    exit 1
fi
revision="$revisions"
if [[ -n "${EXPECTED_LIBRUSTZCASH_REVISION:-}" \
    && "$revision" != "$EXPECTED_LIBRUSTZCASH_REVISION" ]]
then
    echo "Error: Cargo.toml librustzcash revision differs from the expected frozen revision" >&2
    exit 1
fi

assert_lock_package() {
    local crate="$1"
    local expected_version="$2"
    local expected_source="$3"
    if ! awk -v crate="$crate" -v version="$expected_version" -v source="$expected_source" '
        function finish_package() {
            if (name == crate) {
                total += 1
                if (found_version == version && found_source == source) matching += 1
            }
        }
        /^\[\[package\]\]$/ {
            if (in_package) finish_package()
            in_package = 1; name = ""; found_version = ""; found_source = ""; next
        }
        in_package && /^name = / { name = $0; sub(/^name = "/, "", name); sub(/"$/, "", name) }
        in_package && /^version = / { found_version = $0; sub(/^version = "/, "", found_version); sub(/"$/, "", found_version) }
        in_package && /^source = / { found_source = $0; sub(/^source = "/, "", found_source); sub(/"$/, "", found_source) }
        END {
            if (in_package) finish_package()
            exit !(total == 1 && matching == 1)
        }
    ' "$lockfile"
    then
        echo "Error: Cargo.lock must contain exactly one $crate $expected_version from $expected_source" >&2
        exit 1
    fi
}

librust_source="git+${expected_repository}?rev=${revision}#${revision}"
for crate_and_version in \
    "equihash 0.3.0" \
    "f4jumble 0.1.1" \
    "pczt 0.8.0" \
    "zcash_address 0.13.0" \
    "zcash_client_backend 0.24.0-rc.1" \
    "zcash_client_sqlite 0.22.0-rc.1" \
    "zcash_encoding 0.4.0" \
    "zcash_keys 0.15.0" \
    "zcash_pool_migration 0.1.0-alpha.1" \
    "zcash_primitives 0.30.0" \
    "zcash_proofs 0.30.0" \
    "zcash_protocol 0.10.1" \
    "zcash_transparent 0.10.0" \
    "zip321 0.9.0-rc.1"
do
    read -r crate version <<< "$crate_and_version"
    assert_lock_package "$crate" "$version" "$librust_source"
done

if ! grep -Fxq \
    "zcash_voting = { git = \"$expected_voting_repository\", rev = \"$expected_voting_revision\" }" \
    "$manifest"
then
    echo "Error: Cargo.toml does not contain the reviewed zcash_voting patch" >&2
    exit 1
fi
assert_lock_package \
    zcash_voting \
    1.0.0 \
    "git+${expected_voting_repository}?rev=${expected_voting_revision}#${expected_voting_revision}"

voting_source="git+${expected_voting_repository}?rev=${expected_voting_revision}#${expected_voting_revision}"
unexpected_lock_sources=$(awk -v librust_source="$librust_source" -v voting_source="$voting_source" '
    /^source = "/ {
        source = $0
        sub(/^source = "/, "", source)
        sub(/"$/, "", source)
        if (source !~ /^registry\+/ && source != librust_source && source != voting_source) {
            print source
        }
    }
' "$lockfile")
if [[ -n "$unexpected_lock_sources" ]]; then
    echo "Error: Cargo.lock contains an unreviewed non-registry dependency source" >&2
    printf '%s\n' "$unexpected_lock_sources" >&2
    exit 1
fi

assert_registry_lock() {
    local crate="$1"
    local version="$2"
    local checksum="$3"
    if ! awk -v crate="$crate" -v version="$version" -v checksum="$checksum" '
        function finish_package() {
            if (name == crate) {
                total += 1
                if (found_version == version && source ~ /^registry\+/ && found_checksum == checksum) matching += 1
            }
        }
        /^\[\[package\]\]$/ {
            if (in_package) finish_package()
            in_package = 1; name = ""; found_version = ""; source = ""; found_checksum = ""; next
        }
        in_package && /^name = / { name = $0; sub(/^name = "/, "", name); sub(/"$/, "", name) }
        in_package && /^version = / { found_version = $0; sub(/^version = "/, "", found_version); sub(/"$/, "", found_version) }
        in_package && /^source = / { source = $0; sub(/^source = "/, "", source); sub(/"$/, "", source) }
        in_package && /^checksum = / { found_checksum = $0; sub(/^checksum = "/, "", found_checksum); sub(/"$/, "", found_checksum) }
        END {
            if (in_package) finish_package()
            exit !(total == 1 && matching == 1)
        }
    ' "$lockfile"
    then
        echo "Error: Cargo.lock must contain exactly one reviewed registry package $crate $version" >&2
        exit 1
    fi
}

assert_registry_lock orchard 0.15.4 793e2e8c2323f35f082d1b3467ca8f576d646f9c93aef8c5168809d099245af8
assert_registry_lock voting-circuits 0.9.0-rc.3 1f116ea00a3fd0be51027a4d809953b88338020ac8f40ec9f5ec087b21a7a5c8
assert_registry_lock imt-tree 0.2.0 1d0a4887bb71d68b3d0c5db9d42bb76df38b0dff4d261b863dada6383b6c2012

if [[ "${1:-}" == "--print-revision" ]]; then
    printf '%s\n' "$revision"
elif [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--print-revision]" >&2
    exit 1
else
    echo "Cargo manifest and lockfile exact-pin all 14 canonical librustzcash packages at $revision."
fi
