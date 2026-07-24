#!/bin/bash

# Fail closed unless the live sdk-release environment requires independent approval and only
# accepts protected branches. Release jobs call the authenticated API immediately before they
# create a tag or draft release. The fixture mode exists only for the network-free negative suite.

set -euo pipefail

expected_repository="just-zend/zcash-swift-wallet-sdk-zend"
expected_environment="sdk-release"

usage() {
    echo "Usage: $0 EXPECTED_MAIN_SHA" >&2
    echo "       $0 --fixture ENVIRONMENT_JSON BRANCH_JSON EXPECTED_MAIN_SHA" >&2
}

if [[ "${1:-}" == "--fixture" ]]; then
    if [[ $# -ne 4 ]]; then
        usage
        exit 1
    fi
    environment_json="$2"
    branch_json="$3"
    expected_main_sha="$4"
    for fixture in "$environment_json" "$branch_json"; do
        if [[ ! -f "$fixture" || -L "$fixture" ]]; then
            echo "Release-policy fixture must be a regular file: $fixture" >&2
            exit 1
        fi
    done
else
    if [[ $# -ne 1 ]]; then
        usage
        exit 1
    fi
    expected_main_sha="$1"
    if [[ "${GITHUB_REPOSITORY:-}" != "$expected_repository" ]]; then
        echo "Release-policy preflight must run for $expected_repository" >&2
        exit 1
    fi
    if [[ -z "${GH_TOKEN:-}" ]]; then
        echo "GH_TOKEN is required for the authenticated release-policy preflight" >&2
        exit 1
    fi
    if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        echo "The authenticated release-policy preflight requires gh and jq" >&2
        exit 1
    fi

    response_root=$(mktemp -d)
    cleanup() { rm -rf "$response_root"; }
    trap cleanup EXIT
    environment_json="$response_root/environment.json"
    branch_json="$response_root/main-branch.json"
    api_headers=(
        -H 'Accept: application/vnd.github+json'
        -H 'X-GitHub-Api-Version: 2022-11-28'
    )
    if ! gh api "${api_headers[@]}" \
        "repos/${expected_repository}/environments/${expected_environment}" \
        > "$environment_json"
    then
        echo "The $expected_environment environment is absent or unreadable; release is forbidden" >&2
        exit 1
    fi
    if ! gh api "${api_headers[@]}" \
        "repos/${expected_repository}/branches/main" \
        > "$branch_json"
    then
        echo "The protected main branch policy is absent or unreadable; release is forbidden" >&2
        exit 1
    fi
fi

if [[ ! "$expected_main_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Expected main revision must be a lowercase 40-character Git SHA" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "The release-policy verifier requires jq" >&2
    exit 1
fi

if ! jq -e --arg environment "$expected_environment" '
    .name == $environment
    and (.protection_rules | type == "array")
    and ([
        .protection_rules[]
        | select(
            .type == "required_reviewers"
            and .prevent_self_review == true
            and (.reviewers | type == "array")
            and (.reviewers | length >= 1)
            and all(
                .reviewers[];
                (.type == "User" or .type == "Team")
                and (.reviewer.id | type == "number")
            )
        )
    ] | length == 1)
    and .deployment_branch_policy.protected_branches == true
    and .deployment_branch_policy.custom_branch_policies == false
' "$environment_json" >/dev/null
then
    echo "The sdk-release environment must require a reviewer, prevent self-review, and allow only protected branches" >&2
    exit 1
fi

if ! jq -e --arg revision "$expected_main_sha" '
    .name == "main"
    and .protected == true
    and .commit.sha == $revision
' "$branch_json" >/dev/null
then
    echo "The release source must still be the exact tip of protected main" >&2
    exit 1
fi

echo "The sdk-release environment and protected-main deployment policy are enforced."
