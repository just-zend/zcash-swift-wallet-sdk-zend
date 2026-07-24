#!/bin/bash

# Validates the release tag accepted by the manual XCFramework packaging workflow. Keep this
# deliberately narrower than full SemVer: release tags in this repository do not use a leading `v`
# or build metadata, and excluding those forms keeps the value safe for Git refs and env records.

set -euo pipefail

version="${1:-}"
numeric_identifier='(0|[1-9][0-9]*)'
prerelease_identifier='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
semver="^${numeric_identifier}\\.${numeric_identifier}\\.${numeric_identifier}(-${prerelease_identifier}(\\.${prerelease_identifier})*)?$"
if [[ ! "$version" =~ $semver ]]; then
    echo "Error: release version must be strict SemVer without a leading v or build metadata" >&2
    exit 1
fi

printf '%s\n' "$version"
