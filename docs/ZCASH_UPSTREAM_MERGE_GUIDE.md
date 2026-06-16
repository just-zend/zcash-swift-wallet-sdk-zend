# Zcash Upstream Merge Guide for Zend Fork

This document tracks how to safely sync `just-zend/zcash-swift-wallet-sdk-zend` with `zcash/zcash-swift-wallet-sdk`.

Last reviewed: 2026-06-16

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

## Zend divergence notes (as of 2026-06-16)

Current relationship from the `codex/zcash-upstream-release-2.6.3` release branch after merging upstream `main` through `04383463` (`#1757`, `#1759`):

- `upstream/main` commits missing in release branch: `0`
- Fork-specific Zend commits remain ahead of `upstream/main`.

Notable fork-ahead work currently preserved includes:

- Zend-specific XCFramework release wiring in `Package.swift`; the `2.6.3` package pin is a Zend-hosted artifact built from `libzcashlc` `2.6.0-alpha.4` sources so the local consensus branch ID matches NU6.2 lightwalletd servers.
- Upstream's new multi-server broadcaster submission model from `#1757`, which supersedes Zend's earlier pending-submit-plan carry.
- New-wallet birthday behavior from the `[#1673]` lineage, now reconciled with upstream's reorg-safe follow-up.
- Voting-related Zend SDK additions that remain ahead of upstream.
- Zend release-helper fixes in `Scripts/prepare-release.sh`, `Scripts/release.sh`, and `Scripts/init-local-ffi.sh` that publish and consume fork-local artifacts from `just-zend/zcash-swift-wallet-sdk-zend`.

Implication: merge this release branch before cutting Zend SDK `2.6.3`; after merge, Zend will contain upstream `main` through `04383463` and will no longer reject reachable NU6.2 servers because of the stale `2.6.0-alpha.3` binary artifact. Zend SDK release numbering remains separate from upstream and FFI artifact numbering: the fork tag `2.6.3` points at the Zend SDK release while the bundled Rust crate version remains `2.6.0-alpha.4`.

## Conflict resolution heuristics

When conflicts occur:

- Keep upstream protocol/consensus correctness changes unless Zend has an audited override.
- Keep Zend-facing naming/branding and integration points where they intentionally differ.
- Prefer upstream tests and safety checks unless they break known Zend constraints.
- If uncertain, open draft PR with precise file-level blocker notes instead of forcing merge.

## Bleeding-edge snapshot (2026-06-16)

Merged upstream default-branch delta pending in Zend fork default branch:

- `#1759`: verify submit failures against the server and treat already-known transactions as accepted.
- `#1757`: multi-server transaction submission and persisted submit plans.
- These are merged into the `codex/zcash-upstream-release-2.6.3` release branch. Before the branch lands on `main`, `git rev-list --left-right --count origin/main...upstream/main` returns `45 23`; from the release branch, the right-side count against `upstream/main` is `0`.

Zend parity branch note:

- `codex/zcash-upstream-release-2.6.3` merges upstream `main` through `04383463`, removes stale Zend-only `PendingSubmitPlanStore` files that were superseded by upstream's `SubmitPlanStore`, and updates `Package.swift` to the Zend-hosted `2.6.3` XCFramework.
- The old `2.6.0-alpha.3` XCFramework returned local consensus branch `4dec4df0` at current mainnet/testnet heights while live lightwalletd servers report `5437f330`; do not reuse that binary for Zend iOS after NU6.2.

Open upstream PRs assessed as not ready to carry right now:

- `#1764` (`michal/MOB-1039-multiserver-changelog`): small changelog-only follow-up, approved but still `BLOCKED`; not required for Zend because the fork changelog documents the multi-server submission merge in `2.6.3`.
- `#1763` (`michal/MOB-1389-fetch-usd-rate-tor-crash`): draft, `BLOCKED`, and touches Tor/exchange-rate concurrency with explicit remaining lifecycle-race scope; wait for upstream to finish review and device confirmation.
- `#1761` (`harry/enhance-failure-backoff`): non-draft and relevant to stuck transaction enhancement, but `BLOCKED` with changes requested; wait for upstream review/merge.
- `#1760` (`harry/fix-resubmit-race-on-first-sync`): non-draft and relevant to resubmission behavior, and CI is green after a force-push, but it is still `BLOCKED` with changes requested; wait for upstream review/merge.
- `#1758` (`dependabot/swift/github.com/apple/swift-nio-2.101.0`): non-draft dependency bump, but `BLOCKED` with review required; not worth carrying independently before upstream acceptance.
- `#1746` (`kris/1745-finish-release-workflow`): non-draft but `DIRTY`, review required, and CI/release-workflow heavy.
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
