# Zcash Upstream Merge Guide for Zend Fork

This document tracks how to safely sync `just-zend/zcash-swift-wallet-sdk-zend` with `zcash/zcash-swift-wallet-sdk`.

Last reviewed: 2026-06-14

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

## Zend divergence notes (as of 2026-06-14)

Current relationship from git graph before this parity branch lands:

- `upstream/main` commits missing in fork default branch: `12`
- Fork default branch commits not present in `upstream/main`: `35`

Notable fork-ahead work currently on `origin/main` includes:

- Zend-specific `2.6.0-alpha.3` XCFramework release wiring in `Package.swift`; keep this fork artifact until Zend publishes a newer forked XCFramework.
- Broadcaster submit-plan recovery behavior carried from the prior Zend branch lineage.
- New-wallet birthday behavior from the `[#1673]` lineage, now reconciled with upstream's reorg-safe follow-up on the June 14 parity branch.
- Voting-related Zend SDK additions that remain ahead of upstream.

Implication: `origin/main` trails upstream by the post-`2.6.0-alpha.4` release and transaction-state fixes. The active branch `codex/zcash-upstream-sync-2026-06-14` contains `upstream/main` through `4dded75b` while preserving Zend's binary target URL/checksum in `Package.swift`. Zend SDK release numbering remains separate from upstream and FFI artifact numbering: this branch prepares the next Zend SDK patch section (`2.6.2`) without remapping `libzcashlc` or the binary artifact URL to that SDK version.

## Conflict resolution heuristics

When conflicts occur:

- Keep upstream protocol/consensus correctness changes unless Zend has an audited override.
- Keep Zend-facing naming/branding and integration points where they intentionally differ.
- Prefer upstream tests and safety checks unless they break known Zend constraints.
- If uncertain, open draft PR with precise file-level blocker notes instead of forcing merge.

## Bleeding-edge snapshot (2026-06-14)

Merged upstream default-branch delta now pending in Zend fork default branch and carried by `codex/zcash-upstream-sync-2026-06-14`:

- `906064f7` (`[#1200] Use streaming-call timeout for server-streaming gRPC calls`)
- `381f2dee` (`Update CHANGELOG for 2.6.0-alpha.5 release.`)
- `ae44f97f` (`Use reorg-safe tree state for new wallet birthday`)
- `91c1e904` (`Merge branch 'main' into adam/zca-148-new-wallet-skip-sync`)
- `1c4cab61` (`Merge pull request #1753 from zcash/release/2.6.0-alpha.5`)
- `96c0d1f7` (`Merge branch 'main' into adam/zca-148-new-wallet-skip-sync`)
- `6d428c10` (`Merge pull request #1672 from valargroup/adam/zca-148-new-wallet-skip-sync`)
- `72649764` (`Small updates when creating new wallet on chain tip`)
- `9122dea6` (`Merge pull request #1754 from zcash/michal/new-wallet-skip-sync-updates`)
- `bc816f3c` (`Fail unmined sent tx whose expiry has passed when expired_unmined lags`)
- `4dded75b` (`Merge pull request #1756 from Cosmos-Harry/harry/fail-pending-tx-past-expiry`)
- `2394ab2f` (`Merge branch 'main' into adam/zca-148-new-wallet-skip-sync`)

Zend parity branch note:

- `codex/zcash-upstream-sync-2026-06-14` merges `upstream/main` through `4dded75b`.
- Conflict resolution was limited to `CHANGELOG.md`: moved the already-tagged Zend broadcaster retry note into `2.6.1`, added upstream new-wallet, streaming-timeout, and expired-transaction notes under the Zend SDK `2.6.2` patch section, and did not remap the upstream `2.6.0-alpha.5` SDK release number onto this fork.
- `Package.swift` has no diff from `origin/main`, so the SDK still downloads Zend's fork-specific `2.6.0-alpha.3` XCFramework release.

Open upstream PRs assessed as not ready to carry right now:

- `#1760` (`harry/fix-resubmit-race-on-first-sync`): non-draft and relevant to resubmission behavior, but `BLOCKED` with review required; wait for upstream review/merge.
- `#1759` (`harry/treat-already-in-mempool-as-success`): non-draft and related to submit handling, but `BLOCKED` with review required; wait for upstream review/merge.
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

- `adam/update-zcash-voting-0.9.1-policy`: voting feature scope; no upstream PR/review thread yet.
- `adam/voting-round-recovery-ffi`: voting recovery feature; no upstream PR/review thread yet.
- `adam/voting-rust-lint-workflow`: workflow/lint only; limited direct Zend runtime value.
- `ignore_worktrees`: housekeeping-only change; not urgent for Zend behavior.
- `maint/v2.5.x`: upstream maintenance branch; relevant release work is represented in merged upstream history or superseded by the parity branch.
- `release-ci`: release branch integration artifact; not a clear standalone carry target.
- `release/2.6.0`: upstream release stabilization branch; wait for upstream release sequencing.
- `roman/voting-delegation-workflow-swift-wrappers`: voting wrapper branch without an upstream PR/review thread yet.
- `shielded-vote-2.4.10`: specialized voting branch with unclear Zend product priority.
