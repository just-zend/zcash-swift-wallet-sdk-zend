#!/usr/bin/env bash
#
# release.sh: tag and publish a release whose pull request has merged.
#
# This is the last step. Scripts/prepare-release.sh has already cut the
# branches, opened and readied the pull request, built the XCFramework, and
# pointed Package.swift at it; someone has merged that pull request into
# release/X.Y.Z. What is left is to sign the tag, push it, and take the GitHub
# release out of draft.
#
# Usage:
#   ./Scripts/release.sh [--dry-run] <remote> <version>
#
#   <remote>   git remote for the repository being released, e.g. upstream
#   <version>  the version to release, e.g. 2.7.1
#
# Prerequisites:
#   - run from release/X.Y.Z, with the pull request merged
#   - gh installed and authenticated
#   - a tag signing key configured
#
# Afterwards, merge release/X.Y.Z back into its maint/ branch and forward along
# the chain, as described in CONTRIBUTING.md.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=lib/release-lib.sh
. "Scripts/lib/release-lib.sh"

usage() {
    cat <<'EOF'
Usage: ./Scripts/release.sh [--dry-run] <remote> <version>

Tag and publish a release whose pull request has already merged into
release/X.Y.Z. Run it from that branch.

Options:
  --dry-run  print what would happen and change nothing
EOF
}

main() {
    local remote version release_branch declared_version declared_checksum
    local asset_checksum dir is_draft

    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) DRY_RUN=true; shift ;;
            -h|--help) usage; return 0 ;;
            --*)       usage >&2; die "unknown option '$1'" ;;
            *)         break ;;
        esac
    done

    if [ $# -lt 2 ]; then
        usage >&2
        die "release.sh needs a remote and a version."
    fi
    remote="$1"
    version="${2#v}"
    release_branch="release/${version}"

    step "Checking preconditions"
    require_clean_tree
    require_remote "$remote"
    require_gh_auth

    GH_REPO="$(repo_for_remote "$remote")"
    export GH_REPO
    echo "  repository: ${GH_REPO}"

    # The old script checked for `main`, which contradicts the branch model in
    # CONTRIBUTING.md: release/X.Y.Z is what gets tagged.
    if [ "$(git rev-parse --abbrev-ref HEAD)" != "$release_branch" ]; then
        die "release.sh must run from ${release_branch}." \
            "You are on $(git rev-parse --abbrev-ref HEAD)." \
            "Merge the release pull request, then check out ${release_branch}."
    fi

    echo "  fetching ${remote} ..."
    if ! git fetch --tags "$remote" >/dev/null 2>&1; then
        die "git fetch ${remote} failed." \
            "The already-tagged check below would otherwise run on stale tags."
    fi

    # A local tag with no remote counterpart is the signature of a previous run
    # that died between tagging and pushing, so say which case this is rather
    # than reporting the bare fact and leaving the operator to investigate.
    if git rev-parse -q --verify "refs/tags/${version}" >/dev/null; then
        if git ls-remote --tags --exit-code "$remote" "refs/tags/${version}" >/dev/null 2>&1; then
            die "${version} is already tagged on ${remote}; this release is out." \
                "If it still shows as a draft, publish it with:" \
                "  gh release edit ${version} --repo ${GH_REPO} --draft=false"
        fi
        die "${version} is tagged locally but not on ${remote}." \
            "A previous run probably stopped between tagging and pushing." \
            "Resume with:" \
            "  git push ${remote} ${release_branch} ${version}" \
            "  gh release edit ${version} --repo ${GH_REPO} --draft=false" \
            "Or discard the local tag and start over: git tag -d ${version}"
    fi

    if ! git config --get user.signingkey >/dev/null 2>&1; then
        die "no tag signing key is configured." \
            "Run: git config --global user.signingkey <your-key-id>"
    fi

    step "Verifying Package.swift against the uploaded artifact"

    declared_version="$(package_swift_url_version Package.swift)"
    if [ "$declared_version" != "$version" ]; then
        die "Package.swift points at ${declared_version}, not ${version}." \
            "The release pull request may not have merged into this branch."
    fi

    if ! gh release view "$version" --repo "$GH_REPO" >/dev/null 2>&1; then
        die "there is no ${version} release on ${GH_REPO}." \
            "Run 'prepare-release.sh build' first."
    fi

    is_draft="$(gh release view "$version" --repo "$GH_REPO" --json isDraft --jq .isDraft)"
    if [ "$is_draft" != "true" ]; then
        die "release ${version} on ${GH_REPO} is already published."
    fi

    # SwiftPM validates this checksum when it fetches the binary target, so a
    # mismatch does not fail here -- it fails in every consumer's build, after
    # the release is public. Verify against the asset itself, not release.env.
    declared_checksum="$(package_swift_checksum Package.swift)"
    dir="$(mktemp -d)"
    if ! gh release download "$version" --repo "$GH_REPO" \
            --pattern "$ZIP_FILE" --dir "$dir" >/dev/null; then
        rm -rf "$dir"
        die "could not download ${ZIP_FILE} from the ${version} release." \
            "The release exists but may carry no asset. Check" \
            "https://github.com/${GH_REPO}/releases/tag/${version}, or re-run" \
            "'prepare-release.sh build --rebuild' to rebuild and re-upload it."
    fi
    asset_checksum="$(shasum -a 256 "${dir}/${ZIP_FILE}" | awk '{print $1}')"
    rm -rf "$dir"

    if [ "$declared_checksum" != "$asset_checksum" ]; then
        die "checksum mismatch between Package.swift and the uploaded asset." \
            "Package.swift declares: ${declared_checksum}" \
            "${ZIP_FILE} hashes to:  ${asset_checksum}" \
            "Re-run 'prepare-release.sh build --rebuild' to reconcile them."
    fi
    echo "  checksum matches: ${asset_checksum}"

    # From here on the actions are effectively permanent: a pushed tag and a
    # published release are not things to retract quietly. Each step therefore
    # reports what has already happened if the next one fails, rather than
    # letting `set -e` abort with only the underlying tool's message.
    step "Creating the signed tag ${version}"
    run git tag -s "$version" -m "Release ${version}"

    step "Pushing ${release_branch} and ${version} to ${remote}"
    if ! run git push "$remote" "$release_branch" "$version"; then
        cat >&2 <<EOF

error: the push failed. The signed tag ${version} EXISTS LOCALLY but may not
have reached ${remote}, and the release is still a draft.

Check with:
  git ls-remote --tags ${remote} refs/tags/${version}

Then either retry:
  git push ${remote} ${release_branch} ${version}
  gh release edit ${version} --repo ${GH_REPO} --draft=false

or discard the local tag and start over:
  git tag -d ${version}
EOF
        exit 1
    fi

    step "Publishing the release"
    if ! run gh release edit "$version" --repo "$GH_REPO" --draft=false; then
        cat >&2 <<EOF

error: the release could not be published.

${release_branch} and the signed tag ${version} ARE already on ${remote}, and
the tag is public -- do not delete it. Only the draft release remains. Publish
it by hand with:

  gh release edit ${version} --repo ${GH_REPO} --draft=false

or from https://github.com/${GH_REPO}/releases/tag/${version}
EOF
        exit 1
    fi

    # Under --dry-run none of the three steps above ran, so the summary must
    # not claim the release is out.
    if [ "$DRY_RUN" = "true" ]; then
        cat <<EOF

Dry run: nothing was tagged, pushed or published. ${version} is not released.

A real run would sign and push the tag ${version}, publish
https://github.com/${GH_REPO}/releases/tag/${version}, and then need
${release_branch} merged back into its maint/ branch.
EOF
    else
        cat <<EOF

Release ${version} is out.

  https://github.com/${GH_REPO}/releases/tag/${version}

Now merge ${release_branch} back into its maint/ branch, then forward along the
chain to newer maint/ branches and finally to main, as described in
CONTRIBUTING.md. Skipping a forward merge is how a fix silently regresses.
EOF
    fi
}

main "$@"
