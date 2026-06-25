# Zcash Upstream Merge Guide for Zend Fork

This document tracks how to safely sync `just-zend/zcash-swift-wallet-sdk-zend` with `zcash/zcash-swift-wallet-sdk`.

Last reviewed: 2026-06-25

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

## Zend divergence notes (as of 2026-06-25)

Current relationship after Zend PR `#14` merged `codex/zcash-upstream-sync-2026-06-17` into `origin/main`, before the current PR `#15` lands:

- `origin/main...upstream/main`: `57 3` after fetching both remotes on 2026-06-25.
- Fork-specific Zend commits remain ahead of `upstream/main`.
- `upstream/main` currently points at `e0bf7ca3` (`#1766` Dependabot setup); this adds `.github/dependabot.yml` with weekly Cargo, Swift, and GitHub Actions update schedules plus seven-day cooldowns.
- `git merge-base --is-ancestor upstream/main origin/main` fails until PR `#15` lands.
- From the active parity branch `codex/zcash-upstream-sync-2026-06-22`, `git rev-list --left-right --count HEAD...upstream/main` returns `61 0` and `git merge-base --is-ancestor upstream/main HEAD` succeeds, so the existing draft PR still covers upstream `main`.

Notable fork-ahead work currently preserved includes:

- Zend-specific XCFramework release wiring in `Package.swift`; the `2.6.3` package pin is a Zend-hosted artifact built from `libzcashlc` `2.6.0-alpha.4` sources so the local consensus branch ID matches NU6.2 lightwalletd servers.
- Upstream's new multi-server broadcaster submission model from `#1757`, which supersedes Zend's earlier pending-submit-plan carry.
- Upstream's follow-up resubmission and enhancement fixes from `#1760` and `#1761`: the first sync-cycle resubmit throttle now starts from wall-clock time, enhancement post-fetch writes are retried consistently, and structured `BlockEnhancer` diagnostics are available without logging transaction IDs, addresses, or other user-identifying data.
- Upstream's repository-wide trailing-whitespace cleanup from `#1765`, adopted as a low-risk parity merge with no Zend-specific behavior changes.
- Upstream's Dependabot configuration from `#1766`, adopted as repository automation parity with no Zend-specific source changes.
- New-wallet birthday behavior from the `[#1673]` lineage, now reconciled with upstream's reorg-safe follow-up.
- Voting-related Zend SDK additions that remain ahead of upstream.
- Zend release-helper fixes in `Scripts/prepare-release.sh`, `Scripts/release.sh`, and `Scripts/init-local-ffi.sh` that publish and consume fork-local artifacts from `just-zend/zcash-swift-wallet-sdk-zend`.

Implication: PR `#15` is the active default-branch parity PR. After it lands, Zend will contain upstream `main` through `e0bf7ca3`. Zend SDK release numbering remains separate from upstream and FFI artifact numbering: the fork tag `2.6.3` points at the Zend SDK release while the bundled Rust crate version remains `2.6.0-alpha.4`.

## Conflict resolution heuristics

When conflicts occur:

- Keep upstream protocol/consensus correctness changes unless Zend has an audited override.
- Keep Zend-facing naming/branding and integration points where they intentionally differ.
- Prefer upstream tests and safety checks unless they break known Zend constraints.
- If uncertain, open draft PR with precise file-level blocker notes instead of forcing merge.

## Bleeding-edge snapshot (2026-06-25)

Merged upstream default-branch delta pending in Zend fork default branch:

- `#1766`: Dependabot setup merged upstream. `git rev-list --left-right --count origin/main...upstream/main` returns `57 3`; draft PR `#15` already contains these upstream commits.
- Upstream-only commits before PR `#15` lands:
  - `e0bf7ca3`: merge PR `#1766`.
  - `86870b40`: add cooldown to Dependabot updates.
  - `8023c752`: add Dependabot configuration.
- Zend PR `#15` is reused as the active draft parity PR and now merges upstream `main` through `e0bf7ca3`.

Zend parity branch note:

- `codex/zcash-upstream-sync-2026-06-17` merged upstream `main` through `dd7329eb`.
- The original June 17 merge conflict was `CHANGELOG.md`; resolve by keeping Zend's `2.6.3` release section and placing the upstream `Unreleased` diagnostics/resubmission notes above it.
- The June 19 refresh merged `#1765` without conflicts and required no Zend-specific code adaptation.
- Zend PR `#14` is merged. Its final checks were green: GitHub build/offline-test, SwiftLint, and zizmor all succeeded for commit `48347a08`.
- `codex/zcash-upstream-sync-2026-06-22` now merges upstream `#1766` cleanly. The only upstream file addition is `.github/dependabot.yml`; no source conflicts occurred and no Zend-specific behavior changed.

Open upstream PRs assessed as not ready to carry right now:

- `#1770` through `#1785`: fresh Dependabot PRs for Cargo, Swift, and GitHub Actions dependencies. They are non-draft but `BLOCKED` and review-required; wait for upstream review and CI policy before carrying individual dependency bumps.
- `#1767` (`dw/remove-useless-deadcode-annotations`): non-draft but `BLOCKED` with review required; Rust annotation cleanup is low-risk but should wait for upstream review rather than being carried independently.
- `#1763` (`michal/MOB-1389-fetch-usd-rate-tor-crash`): draft, `DIRTY`, and touches Tor/exchange-rate concurrency with explicit remaining lifecycle-race scope; wait for upstream to finish review and device confirmation.
- `#1758` (`dependabot/swift/github.com/apple/swift-nio-2.101.0`): non-draft dependency bump, but `BLOCKED` and review required; not worth carrying independently before upstream acceptance.
- `#1746` (`kris/1745-finish-release-workflow`): non-draft but `DIRTY`, review required, and CI/release-workflow heavy.
- `#1733` (`main` -> `release/2.6.0`): explicit `[DO NOT MERGE]` draft stabilization preview, so wait for upstream release sequencing rather than carrying it independently.
- `#1700`, `#1638`, `#1637`, `#1592`, `#1579`, `#1443`: draft/WIP FFI and behavior changes with broad impact; several also have requested changes or stale unknown merge state.
- `#1692`: non-draft but `BLOCKED` and still review required.
- `#1570`: non-draft and approved, but still `DIRTY` and old enough that carrying it ahead of upstream would be a higher-risk behavioral fork.
- `#1505`: tiny spelling fix, but still `DIRTY` and review required, so not worth carrying independently.

No candidate currently meets all carry criteria (ready + useful + low risk) for Zend ahead-of-upstream adoption.

Unmerged upstream branches (not carried):

- `adam/broadcaster-submit-plan`: 14 commits ahead and 73 behind `upstream/main`; no upstream PR, and the commits are already contained in `origin/main` from Zend PR `#2` before being superseded by upstream's `SubmitPlanStore` work in `#1757`.
- `adam/update-zcash-voting-0.9.1-policy`: 1 commit ahead and 69 behind `upstream/main`; voting feature scope with no upstream PR/review thread yet.
- `adam/voting-round-recovery-ffi`: 1 commit ahead and 178 behind `upstream/main`; voting recovery FFI with no upstream PR/review thread yet.
- `adam/voting-rust-lint-workflow`: 1 commit ahead and 179 behind `upstream/main`; workflow/lint only and limited direct Zend runtime value.
- `dependabot/cargo/cc-1.2.64`, `dependabot/cargo/ff-0.14.0`, `dependabot/cargo/fs-mistrust-0.14.2`, `dependabot/cargo/http-1.4.2`, `dependabot/cargo/prost-0.14.4`, `dependabot/cargo/rand-0.9.4`, `dependabot/cargo/secrecy-0.10.3`, `dependabot/cargo/serde_json-1.0.150`, `dependabot/cargo/tor-rtcompat-0.43.0`, and `dependabot/cargo/zeroize-1.9.0`: each 1 commit ahead and 0 behind `upstream/main`; covered by open Dependabot PRs `#1772` through `#1785`, so wait for upstream review.
- `dependabot/github_actions/Swatinem/rust-cache-2.9.1`, `dependabot/github_actions/actions/cache-5.0.5`, `dependabot/github_actions/actions/checkout-7`, `dependabot/github_actions/github/codeql-action-4.36.2`, and `dependabot/github_actions/zizmorcore/zizmor-action-0.5.6`: each 1 commit ahead and 0 behind `upstream/main`; covered by open Dependabot PRs `#1770`, `#1771`, `#1775`, `#1776`, and `#1777`, so wait for upstream review.
- `dependabot/swift/github.com/apple/swift-nio-2.101.0`: 1 commit ahead and 39 behind `upstream/main`; covered by open upstream PR `#1758`, so wait for upstream review.
- `dependabot/swift/github.com/stephencelis/sqlite.swift-0.16.0`: 1 commit ahead and 0 behind `upstream/main`; covered by open upstream PR `#1784`, so wait for upstream review.
- `dw/remove-useless-deadcode-annotations`: 1 commit ahead and 5 behind `upstream/main`; covered by open upstream PR `#1767`, so wait for upstream review.
- `feature/ffi_database_handle`: 10 commits ahead and 279 behind `upstream/main`; broad FFI database-handle work covered by draft upstream PR `#1637`, so do not carry early.
- `feature/typesafe_db_handles`: 11 commits ahead and 279 behind `upstream/main`; broad type-safe handle work covered by draft upstream PR `#1638`, so do not carry early.
- `ffi-0.18.0-part-2`: 5 commits ahead and 800 behind `upstream/main`; stale WIP transaction policy work covered by draft upstream PR `#1592`.
- `ignore_worktrees`: 1 commit ahead and 73 behind `upstream/main`; housekeeping-only change.
- `kris/1745-finish-release-workflow`: 9 commits ahead and 73 behind `upstream/main`; covered by open upstream PR `#1746`, which is release-workflow heavy and review-required.
- `michal/MOB-1389-fetch-usd-rate-tor-crash`: 1 commit ahead and 39 behind `upstream/main`; covered by draft upstream PR `#1763`, so wait for upstream completion.
- `maint/v2.5.x`: 0 commits ahead and 159 behind `upstream/main`; maintenance line, no standalone carry.
- `release-ci`: 4 commits ahead and 151 behind `upstream/main`; release branch integration artifact, not a clear standalone carry target.
- `release/2.6.0`: 0 commits ahead and 162 behind `upstream/main`; upstream release stabilization branch, wait for upstream release sequencing.
- `roman/voting-delegation-workflow-swift-wrappers`: 0 commits ahead and 138 behind `upstream/main`; voting wrapper branch without an upstream PR/review thread yet.
- `rust-build-plugin`: 2 commits ahead and 1100 behind `upstream/main`; stale draft build-plugin work covered by upstream PR `#1443`.
- `shielded-vote-2.4.10`: 1 commit ahead and 96 behind `upstream/main`; specialized voting branch with unclear Zend product priority.
- `testing/note_spendability_improvements`: 6 commits ahead and 209 behind `upstream/main`; draft test-only branch covered by upstream PR `#1700`.
