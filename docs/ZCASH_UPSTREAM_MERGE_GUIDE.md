# Zcash Upstream Merge Guide for Zend Fork

This document tracks how to safely sync `just-zend/zcash-swift-wallet-sdk-zend` with `zcash/zcash-swift-wallet-sdk`.

Last reviewed: 2026-06-15

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

## Zend divergence notes (as of 2026-06-15)

Current relationship from git graph after the June 14 parity and release-helper PRs landed:

- `upstream/main` commits missing in fork default branch: `0`
- Fork default branch commits not present in `upstream/main`: `43`

Notable fork-ahead work currently on `origin/main` includes:

- Zend-specific `2.6.0-alpha.3` XCFramework release wiring in `Package.swift`; keep this fork artifact until Zend publishes a newer forked XCFramework.
- Broadcaster submit-plan recovery behavior carried from the prior Zend branch lineage.
- New-wallet birthday behavior from the `[#1673]` lineage, now reconciled with upstream's reorg-safe follow-up.
- Voting-related Zend SDK additions that remain ahead of upstream.
- Zend release-helper fixes in `Scripts/prepare-release.sh`, `Scripts/release.sh`, and `Scripts/init-local-ffi.sh` that publish and consume fork-local artifacts from `just-zend/zcash-swift-wallet-sdk-zend`.

Implication: no parity branch is needed for upstream default-branch commits as of this review. `origin/main` contains `upstream/main` through `4dded75b` (`#1756`) and includes the merged June 14 Zend parity and release-helper work. Zend SDK release numbering remains separate from upstream and FFI artifact numbering: the fork tag `2.6.2` does not imply that `libzcashlc` or the binary artifact URL should be remapped to `2.6.2`.

## Conflict resolution heuristics

When conflicts occur:

- Keep upstream protocol/consensus correctness changes unless Zend has an audited override.
- Keep Zend-facing naming/branding and integration points where they intentionally differ.
- Prefer upstream tests and safety checks unless they break known Zend constraints.
- If uncertain, open draft PR with precise file-level blocker notes instead of forcing merge.

## Bleeding-edge snapshot (2026-06-15)

Merged upstream default-branch delta pending in Zend fork default branch:

- None. `git rev-list --left-right --count origin/main...upstream/main` returned `43 0`.

Zend parity branch note:

- `codex/zcash-upstream-sync-2026-06-14` and the stacked release-helper fix have landed on `origin/main` through PRs `#9` and `#10`.
- `Package.swift` still downloads Zend's fork-specific `2.6.0-alpha.3` XCFramework release. Do not infer the binary artifact version from the Zend SDK tag.

Open upstream PRs assessed as not ready to carry right now:

- `#1763` (`michal/MOB-1389-fetch-usd-rate-tor-crash`): draft, `BLOCKED`, and touches Tor/exchange-rate concurrency with explicit remaining lifecycle-race scope; wait for upstream to finish review and device confirmation.
- `#1761` (`harry/enhance-failure-backoff`): non-draft and relevant to stuck transaction enhancement, but `BLOCKED` with changes requested; wait for upstream review/merge.
- `#1760` (`harry/fix-resubmit-race-on-first-sync`): non-draft and relevant to resubmission behavior, and CI is green after a force-push, but it is still `BLOCKED` with changes requested; wait for upstream review/merge.
- `#1759` (`harry/treat-already-in-mempool-as-success`): non-draft and related to submit handling, but `BLOCKED` with changes requested; wait for upstream review/merge.
- `#1758` (`dependabot/swift/github.com/apple/swift-nio-2.101.0`): non-draft dependency bump, but `BLOCKED` with review required; not worth carrying independently before upstream acceptance.
- `#1757` (`michal/mob-1039-multiserver-submission`): draft, `DIRTY`, large breaking broadcaster/submit-plan redesign.
- `#1746` (`kris/1745-finish-release-workflow`): non-draft but `DIRTY`, review required, and CI/release-workflow heavy.
- `#1737` (`adam/broadcaster-submit-plan`): non-draft but `DIRTY`, review required, and high-impact transaction-submit behavior now superseded by `#1757`.
- `#1733` (`main` -> `release/2.6.0`): explicit `[DO NOT MERGE]` draft stabilization preview.
- `#1700`, `#1638`, `#1637`, `#1592`, `#1579`, `#1443`: draft/WIP FFI and behavior changes with broad impact; several are also `DIRTY` or have requested changes.
- `#1692`: non-draft but `BLOCKED` and still review required.
- `#1570`: non-draft and approved, but still `DIRTY` and old enough that carrying it ahead of upstream would be a higher-risk behavioral fork.
- `#1505`: tiny spelling fix, but still `DIRTY` and review required, so not worth carrying independently.

No candidate currently meets all carry criteria (ready + useful + low risk) for Zend ahead-of-upstream adoption.

Unmerged upstream branches without open PRs (not carried):

- `adam/update-zcash-voting-0.9.1-policy`: 1 commit ahead and 30 behind `upstream/main`; voting feature scope with no upstream PR/review thread yet.
- `adam/voting-round-recovery-ffi`: 1 commit ahead and 139 behind `upstream/main`; voting recovery FFI with no upstream PR/review thread yet.
- `adam/voting-rust-lint-workflow`: 1 commit ahead and 140 behind `upstream/main`; workflow/lint only and limited direct Zend runtime value.
- `ignore_worktrees`: 1 commit ahead and 34 behind `upstream/main`; housekeeping-only change.
- `maint/v2.5.x`: 0 commits ahead and 120 behind `upstream/main`; maintenance line, no standalone carry.
- `release-ci`: 4 commits ahead and 112 behind `upstream/main`; release branch integration artifact, not a clear standalone carry target.
- `release/2.6.0`: 0 commits ahead and 123 behind `upstream/main`; upstream release stabilization branch, wait for upstream release sequencing.
- `roman/voting-delegation-workflow-swift-wrappers`: 0 commits ahead and 99 behind `upstream/main`; voting wrapper branch without an upstream PR/review thread yet.
- `shielded-vote-2.4.10`: 1 commit ahead and 57 behind `upstream/main`; specialized voting branch with unclear Zend product priority.
