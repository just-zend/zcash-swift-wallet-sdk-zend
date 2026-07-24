#!/bin/bash

# Validates every object member in one thin Apple static archive. Each member must contain exactly
# one recognized deployment-target command: LC_BUILD_VERSION with the expected platform/minos, or
# the matching legacy LC_VERSION_MIN_* command. Missing, mixed, wrong-platform, and too-new members
# fail independently; state is reset at every archive-member header.

set -euo pipefail

if [[ "${1:-}" == "--otool-output" ]]; then
    if [[ $# -ne 5 ]]; then
        echo "Usage: $0 --otool-output <file> <platform-number> <maximum-minos> <legacy-command>" >&2
        exit 1
    fi
    input_file="$2"
    expected_platform="$3"
    maximum_minos="$4"
    expected_legacy_command="$5"
    producer=(cat "$input_file")
elif [[ $# -eq 4 ]]; then
    archive="$1"
    expected_platform="$2"
    maximum_minos="$3"
    expected_legacy_command="$4"
    producer=(otool -l "$archive")
else
    echo "Usage: $0 <thin-archive> <platform-number> <maximum-minos> <legacy-command>" >&2
    exit 1
fi

"${producer[@]}" 2>/dev/null | awk \
    -v expected_platform="$expected_platform" \
    -v maximum_minos="$maximum_minos" \
    -v expected_legacy_command="$expected_legacy_command" '
    function version_gt(found, maximum, f, m, i) {
        split(found, f, "."); split(maximum, m, ".")
        for (i = 1; i <= 3; i++) {
            if ((f[i] + 0) > (m[i] + 0)) return 1
            if ((f[i] + 0) < (m[i] + 0)) return 0
        }
        return 0
    }
    function finish_command() {
        if (active == "build") {
            if (platform_fields != 1 || minos_fields != 1 ||
                platform_value != expected_platform || version_gt(minos_value, maximum_minos)) {
                member_invalid = 1
            }
        } else if (active == "legacy") {
            if (legacy_command != expected_legacy_command || version_fields != 1 ||
                version_gt(version_value, maximum_minos)) {
                member_invalid = 1
            }
        }
        active = ""
    }
    function finish_member() {
        if (member == "") return
        finish_command()
        members += 1
        if (recognized_commands != 1 || member_invalid) {
            print "Error: invalid deployment-target load commands in archive member " member > "/dev/stderr"
            failures += 1
        }
    }
    /\([^)]*\):$/ {
        finish_member()
        member = $0
        recognized_commands = 0
        member_invalid = 0
        active = ""
        next
    }
    $1 == "cmd" {
        finish_command()
        platform_fields = 0; minos_fields = 0; version_fields = 0
        platform_value = ""; minos_value = ""; version_value = ""; legacy_command = ""
        if ($2 == "LC_BUILD_VERSION") {
            active = "build"
            recognized_commands += 1
        } else if ($2 ~ /^LC_VERSION_MIN_/) {
            active = "legacy"
            legacy_command = $2
            recognized_commands += 1
        }
        next
    }
    active == "build" && $1 == "platform" {
        platform_fields += 1; platform_value = $2; next
    }
    active == "build" && $1 == "minos" {
        minos_fields += 1; minos_value = $2; next
    }
    active == "legacy" && $1 == "version" {
        version_fields += 1; version_value = $2; next
    }
    END {
        finish_member()
        if (members == 0) {
            print "Error: no archive members were parsed" > "/dev/stderr"
            failures += 1
        }
        exit failures != 0
    }
'
