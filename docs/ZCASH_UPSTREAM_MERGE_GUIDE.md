# Zcash Upstream Merge Guide for Zend Fork

This document tracks how to safely sync `just-zend/zcash-swift-wallet-sdk-zend` with `zcash/zcash-swift-wallet-sdk`.

Last reviewed: 2026-06-19

## Remote and branch invariants

- `origin` must point to `git@github.com:just-zend/zcash-swift-wallet-sdk-zend.git`.
- `upstream` must point to `git@github.com:zcash/zcash-swift-wallet-sdk.git`.
- Default branch for both repositories is `main`.

## Parity sync workflow (upstream default branch)

Use this flow when `upstream/main` has commits not present in `origin/main`.

1. `git fetch --prune origin && git fetch --prune upstream`
2. Compute parity gap: `git log --oneline origin/main..upstream/main`
3. Create sync branch: `codex/zcash-upstream-sync-YYYY-MM-DD` (add `-2`, `-3`, ... if needed)
4. Start from fork default branch: `git switch -c <branch> origin/main`
5. Prefer `git merge --no-ff upstream/main` for low-risk parity adoption.
6. Resolve conflicts by preserving Zend-specific behavior/branding while adopting upstream SDK fixes.
7. Verify:
   - `swift build`
   - `swift test --filter OfflineTests`
8. Open a **draft PR** to `main` with:
   - upstream commit list,
   - conflict resolutions,
   - Zend-specific adaptations,
   - verification results.

## Bleeding-edge carry workflow (open upstream PRs / unmerged branches)

Treat non-merged upstream work as optional and higher risk. Carry only when all are true:

- Ready: non-draft or demonstrably stable, no unresolved structural conflicts.
- Useful: immediate Zend roadmap value.
- Low risk: scoped changes, manageable blast radius, and testable locally.

If carried early:

1. Branch from `origin/main` with `codex/zcash-pr-or-branch-<short-name>-YYYY-MM-DD`.
2. Cherry-pick or merge only the minimal required commits.
3. Run `swift build` and `swift test --filter OfflineTests` when feasible.
4. Open a **draft PR** linking the upstream PR/branch and documenting risks.

If not carried, record explicit reason (draft/WIP, dirty rebase state, blocked reviews, high risk, low Zend value).

## Zend divergence notes (as of 2026-06-19)

Current relationship from `codex/zcash-upstream-sync-2026-06-17` after merging upstream `main` through `dd7329eb`:

- Before the parity branch lands, `origin/main...upstream/main`: `50 13` after fetching both remotes on 2026-06-19.
- From the parity branch after the June 19 upstream merge, `git rev-list --left-right --count HEAD...upstream/main` returns `53 0`.
- Fork-specific Zend commits remain ahead of `upstream/main`.
- `upstream/main` currently points at `dd7329eb` (`#1765` trailing-whitespace cleanup); those upstream SDK fixes and cleanup commits are present in the parity branch.

Notable fork-ahead work currently preserved includes:

- Zend-specific XCFramework release wiring in `Package.swift`; the `2.6.3` package pin is a Zend-hosted artifact built from `libzcashlc` `2.6.0-alpha.4` sources so the local consensus branch ID matches NU6.2 lightwalletd servers.
- Upstream's new multi-server broadcaster submission model from `#1757`, which supersedes Zend's earlier pending-submit-plan carry.
- Upstream's follow-up resubmission and enhancement fixes from `#1760` and `#1761`: the first sync-cycle resubmit throttle now starts from wall-clock time, enhancement post-fetch writes are retried consistently, and structured `BlockEnhancer` diagnostics are available without logging transaction IDs, addresses, or other user-identifying data.
- Upstream's repository-wide trailing-whitespace cleanup from `#1765`, adopted as a low-risk parity merge with no Zend-specific behavior changes.
- New-wallet birthday behavior from the `[#1673]` lineage, now reconciled with upstream's reorg-safe follow-up.
- Voting-related Zend SDK additions that remain ahead of upstream.
- Zend release-helper fixes in `Scripts/prepare-release.sh`, `Scripts/release.sh`, and `Scripts/init-local-ffi.sh` that publish and consume fork-local artifacts from `just-zend/zcash-swift-wallet-sdk-zend`.

Implication: a default-branch parity PR is needed while the right-side count remains non-zero on `origin/main`. After `codex/zcash-upstream-sync-2026-06-17` lands, Zend will contain upstream `main` through `dd7329eb`. Zend SDK release numbering remains separate from upstream and FFI artifact numbering: the fork tag `2.6.3` points at the Zend SDK release while the bundled Rust crate version remains `2.6.0-alpha.4`.

## Conflict resolution heuristics

When conflicts occur:

- Keep upstream protocol/consensus correctness changes unless Zend has an audited override.
- Keep Zend-facing naming/branding and integration points where they intentionally differ.
- Prefer upstream tests and safety checks unless they break known Zend constraints.
- If uncertain, open draft PR with precise file-level blocker notes instead of forcing merge.

## Bleeding-edge snapshot (2026-06-19)

Merged upstream default-branch delta pending in Zend fork default branch:

- `#1764`: changelog follow-up for the multi-server submission work.
- `#1760`: first-sync resubmit race fix and test adaptation.
- `#1761`: enhancement retry/backoff hardening plus diagnostic logging.
- `#1765`: repository-wide trailing-whitespace cleanup.
- These are merged into `codex/zcash-upstream-sync-2026-06-17`. Before the branch lands on `main`, `git rev-list --left-right --count origin/main...upstream/main` returns `50 13`; from the parity branch after the June 19 upstream merge, `git rev-list --left-right --count HEAD...upstream/main` returns `53 0`.

Zend parity branch note:

- `codex/zcash-upstream-sync-2026-06-17` merges upstream `main` through `dd7329eb`.
- The original June 17 merge conflict was `CHANGELOG.md`; resolve by keeping Zend's `2.6.3` release section and placing the upstream `Unreleased` diagnostics/resubmission notes above it.
- The June 19 refresh merged `#1765` without conflicts and required no Zend-specific code adaptation.

Open upstream PRs assessed as not ready to carry right now:

- `#1766` (`dw/setup-dependabot`): non-draft but `BLOCKED` with review required; dependency automation configuration is not worth carrying before upstream accepts the exact policy.
- `#1767` (`dw/remove-useless-deadcode-annotations`): non-draft but `BLOCKED` with review required; Rust annotation cleanup is low-risk but should wait for upstream review rather than being carried independently.
- `#1763` (`michal/MOB-1389-fetch-usd-rate-tor-crash`): draft, `BLOCKED`, and touches Tor/exchange-rate concurrency with explicit remaining lifecycle-race scope; wait for upstream to finish review and device confirmation.
- `#1758` (`dependabot/swift/github.com/apple/swift-nio-2.101.0`): non-draft dependency bump, but `BLOCKED` with review required; not worth carrying independently before upstream acceptance.
- `#1746` (`kris/1745-finish-release-workflow`): non-draft but `DIRTY`, review required, and CI/release-workflow heavy.
- `#1733` (`main` -> `release/2.6.0`): explicit `[DO NOT MERGE]` draft stabilization preview; latest CodeQL run was still in progress during review.
- `#1700`, `#1638`, `#1637`, `#1592`, `#1579`, `#1443`: draft/WIP FFI and behavior changes with broad impact; several are also `DIRTY` or have requested changes.
- `#1692`: non-draft but `BLOCKED` and still review required.
- `#1570`: non-draft and approved, but still `DIRTY` and old enough that carrying it ahead of upstream would be a higher-risk behavioral fork.
- `#1505`: tiny spelling fix, but still `DIRTY` and review required, so not worth carrying independently.

No candidate currently meets all carry criteria (ready + useful + low risk) for Zend ahead-of-upstream adoption.

Unmerged upstream branches without open PRs (not carried):

- `adam/broadcaster-submit-plan`: 14 commits ahead and 70 behind `upstream/main`; no upstream PR, and the commits are already contained in `origin/main` from Zend PR `#2` before being superseded by upstream's `SubmitPlanStore` work in `#1757`.
- `adam/update-zcash-voting-0.9.1-policy`: 1 commit ahead and 66 behind `upstream/main`; voting feature scope with no upstream PR/review thread yet.
- `adam/voting-round-recovery-ffi`: 1 commit ahead and 175 behind `upstream/main`; voting recovery FFI with no upstream PR/review thread yet.
- `adam/voting-rust-lint-workflow`: 1 commit ahead and 176 behind `upstream/main`; workflow/lint only and limited direct Zend runtime value.
- `dw/remove-useless-deadcode-annotations`: 1 commit ahead and 2 behind `upstream/main`; covered by open upstream PR `#1767`, so wait for upstream review.
- `ignore_worktrees`: 1 commit ahead and 70 behind `upstream/main`; housekeeping-only change.
- `maint/v2.5.x`: 0 commits ahead and 156 behind `upstream/main`; maintenance line, no standalone carry.
- `release-ci`: 4 commits ahead and 148 behind `upstream/main`; release branch integration artifact, not a clear standalone carry target.
- `release/2.6.0`: 0 commits ahead and 159 behind `upstream/main`; upstream release stabilization branch, wait for upstream release sequencing.
- `roman/voting-delegation-workflow-swift-wrappers`: 0 commits ahead and 135 behind `upstream/main`; voting wrapper branch without an upstream PR/review thread yet.
- `shielded-vote-2.4.10`: 1 commit ahead and 93 behind `upstream/main`; specialized voting branch with unclear Zend product priority.
