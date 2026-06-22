# Zcash Upstream Merge Guide for Zend Fork

This document tracks how to safely sync `just-zend/zcash-swift-wallet-sdk-zend` with `zcash/zcash-swift-wallet-sdk`.

Last reviewed: 2026-06-22

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

## Zend divergence notes (as of 2026-06-22)

Current relationship after Zend PR `#14` merged `codex/zcash-upstream-sync-2026-06-17` into `origin/main`:

- `origin/main...upstream/main`: `57 0` after fetching both remotes on 2026-06-22.
- Fork-specific Zend commits remain ahead of `upstream/main`.
- `upstream/main` currently points at `dd7329eb` (`#1765` trailing-whitespace cleanup); those upstream SDK fixes and cleanup commits are present in `origin/main`.
- `git merge-base --is-ancestor upstream/main origin/main` succeeds, so the fork default branch contains the upstream default branch.

Notable fork-ahead work currently preserved includes:

- Zend-specific XCFramework release wiring in `Package.swift`; the `2.6.3` package pin is a Zend-hosted artifact built from `libzcashlc` `2.6.0-alpha.4` sources so the local consensus branch ID matches NU6.2 lightwalletd servers.
- Upstream's new multi-server broadcaster submission model from `#1757`, which supersedes Zend's earlier pending-submit-plan carry.
- Upstream's follow-up resubmission and enhancement fixes from `#1760` and `#1761`: the first sync-cycle resubmit throttle now starts from wall-clock time, enhancement post-fetch writes are retried consistently, and structured `BlockEnhancer` diagnostics are available without logging transaction IDs, addresses, or other user-identifying data.
- Upstream's repository-wide trailing-whitespace cleanup from `#1765`, adopted as a low-risk parity merge with no Zend-specific behavior changes.
- New-wallet birthday behavior from the `[#1673]` lineage, now reconciled with upstream's reorg-safe follow-up.
- Voting-related Zend SDK additions that remain ahead of upstream.
- Zend release-helper fixes in `Scripts/prepare-release.sh`, `Scripts/release.sh`, and `Scripts/init-local-ffi.sh` that publish and consume fork-local artifacts from `just-zend/zcash-swift-wallet-sdk-zend`.

Implication: no default-branch parity PR is needed while the right-side count remains `0` on `origin/main`. Zend contains upstream `main` through `dd7329eb`. Zend SDK release numbering remains separate from upstream and FFI artifact numbering: the fork tag `2.6.3` points at the Zend SDK release while the bundled Rust crate version remains `2.6.0-alpha.4`.

## Conflict resolution heuristics

When conflicts occur:

- Keep upstream protocol/consensus correctness changes unless Zend has an audited override.
- Keep Zend-facing naming/branding and integration points where they intentionally differ.
- Prefer upstream tests and safety checks unless they break known Zend constraints.
- If uncertain, open draft PR with precise file-level blocker notes instead of forcing merge.

## Bleeding-edge snapshot (2026-06-22)

Merged upstream default-branch delta pending in Zend fork default branch:

- None. `git rev-list --left-right --count origin/main...upstream/main` returns `57 0`.
- Zend PR `#14` merged the prior parity branch into `origin/main` on 2026-06-22.

Zend parity branch note:

- `codex/zcash-upstream-sync-2026-06-17` merged upstream `main` through `dd7329eb`.
- The original June 17 merge conflict was `CHANGELOG.md`; resolve by keeping Zend's `2.6.3` release section and placing the upstream `Unreleased` diagnostics/resubmission notes above it.
- The June 19 refresh merged `#1765` without conflicts and required no Zend-specific code adaptation.
- Zend PR `#14` is merged. Its final checks were green: GitHub build/offline-test, SwiftLint, and zizmor all succeeded for commit `48347a08`.

Open upstream PRs assessed as not ready to carry right now:

- `#1766` (`dw/setup-dependabot`): non-draft but `BLOCKED` with review required; dependency automation configuration is not worth carrying before upstream accepts the exact policy.
- `#1767` (`dw/remove-useless-deadcode-annotations`): non-draft but `BLOCKED` with review required; Rust annotation cleanup is low-risk but should wait for upstream review rather than being carried independently.
- `#1763` (`michal/MOB-1389-fetch-usd-rate-tor-crash`): draft, `BLOCKED`, and touches Tor/exchange-rate concurrency with explicit remaining lifecycle-race scope; wait for upstream to finish review and device confirmation.
- `#1758` (`dependabot/swift/github.com/apple/swift-nio-2.101.0`): non-draft dependency bump, but `BLOCKED` with review required; not worth carrying independently before upstream acceptance.
- `#1746` (`kris/1745-finish-release-workflow`): non-draft but `DIRTY`, review required, and CI/release-workflow heavy.
- `#1733` (`main` -> `release/2.6.0`): explicit `[DO NOT MERGE]` draft stabilization preview, so wait for upstream release sequencing rather than carrying it independently.
- `#1700`, `#1638`, `#1637`, `#1592`, `#1579`, `#1443`: draft/WIP FFI and behavior changes with broad impact; several are also `DIRTY` or have requested changes.
- `#1692`: non-draft but `BLOCKED` and still review required.
- `#1570`: non-draft and approved, but still `DIRTY` and old enough that carrying it ahead of upstream would be a higher-risk behavioral fork.
- `#1505`: tiny spelling fix, but still `DIRTY` and review required, so not worth carrying independently.

No candidate currently meets all carry criteria (ready + useful + low risk) for Zend ahead-of-upstream adoption.

Unmerged upstream branches (not carried):

- `adam/broadcaster-submit-plan`: 14 commits ahead and 70 behind `upstream/main`; no upstream PR, and the commits are already contained in `origin/main` from Zend PR `#2` before being superseded by upstream's `SubmitPlanStore` work in `#1757`.
- `adam/update-zcash-voting-0.9.1-policy`: 1 commit ahead and 66 behind `upstream/main`; voting feature scope with no upstream PR/review thread yet.
- `adam/voting-round-recovery-ffi`: 1 commit ahead and 175 behind `upstream/main`; voting recovery FFI with no upstream PR/review thread yet.
- `adam/voting-rust-lint-workflow`: 1 commit ahead and 176 behind `upstream/main`; workflow/lint only and limited direct Zend runtime value.
- `dependabot/swift/github.com/apple/swift-nio-2.101.0`: 1 commit ahead and 36 behind `upstream/main`; covered by open upstream PR `#1758`, so wait for upstream review.
- `dw/remove-useless-deadcode-annotations`: 1 commit ahead and 2 behind `upstream/main`; covered by open upstream PR `#1767`, so wait for upstream review.
- `dw/setup-dependabot`: 1 commit ahead and 2 behind `upstream/main`; covered by open upstream PR `#1766`, so wait for upstream review.
- `feature/ffi_database_handle`: 10 commits ahead and 276 behind `upstream/main`; broad FFI database-handle work covered by draft upstream PR `#1637`, so do not carry early.
- `feature/typesafe_db_handles`: 11 commits ahead and 276 behind `upstream/main`; broad type-safe handle work covered by draft upstream PR `#1638`, so do not carry early.
- `ffi-0.18.0-part-2`: 5 commits ahead and 797 behind `upstream/main`; stale WIP transaction policy work covered by draft upstream PR `#1592`.
- `ignore_worktrees`: 1 commit ahead and 70 behind `upstream/main`; housekeeping-only change.
- `kris/1745-finish-release-workflow`: 9 commits ahead and 70 behind `upstream/main`; covered by open upstream PR `#1746`, which is still dirty and review-required.
- `michal/MOB-1389-fetch-usd-rate-tor-crash`: 1 commit ahead and 36 behind `upstream/main`; covered by draft upstream PR `#1763`, so wait for upstream completion.
- `maint/v2.5.x`: 0 commits ahead and 156 behind `upstream/main`; maintenance line, no standalone carry.
- `release-ci`: 4 commits ahead and 148 behind `upstream/main`; release branch integration artifact, not a clear standalone carry target.
- `release/2.6.0`: 0 commits ahead and 159 behind `upstream/main`; upstream release stabilization branch, wait for upstream release sequencing.
- `roman/voting-delegation-workflow-swift-wrappers`: 0 commits ahead and 135 behind `upstream/main`; voting wrapper branch without an upstream PR/review thread yet.
- `rust-build-plugin`: 2 commits ahead and 1097 behind `upstream/main`; stale draft build-plugin work covered by upstream PR `#1443`.
- `shielded-vote-2.4.10`: 1 commit ahead and 93 behind `upstream/main`; specialized voting branch with unclear Zend product priority.
- `testing/note_spendability_improvements`: 6 commits ahead and 206 behind `upstream/main`; draft test-only branch covered by upstream PR `#1700`.
