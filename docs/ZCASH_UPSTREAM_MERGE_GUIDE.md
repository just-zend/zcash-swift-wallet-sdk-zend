# Zcash Upstream Merge Guide for Zend Fork

This document tracks how to safely sync `just-zend/zcash-swift-wallet-sdk-zend` with `zcash/zcash-swift-wallet-sdk`.

Last reviewed: 2026-07-02

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

## Zend divergence notes (as of 2026-07-02)

Current relationship after Zend PR `#14` merged `codex/zcash-upstream-sync-2026-06-17` into `origin/main`, before the current PR `#15` lands:

- `origin/main...upstream/main`: `57 12` after fetching both remotes on 2026-07-02.
- Fork-specific Zend commits remain ahead of `upstream/main`.
- `upstream/main` currently points at `89f994b5` (`#1795`); it also includes `#1790` / tag `2.6.0-alpha.6`, `#1789` checkpoint refresh, `#1786` for the Keystone/cross-account `deleteAccount` fix, and `#1766` Dependabot setup.
- `git merge-base --is-ancestor upstream/main origin/main` fails until PR `#15` lands.
- From the active parity branch `codex/zcash-upstream-sync-2026-06-22`, `git rev-list --left-right --count HEAD...upstream/main` returns `72 0` after this guide refresh and `git merge-base --is-ancestor upstream/main HEAD` succeeds, so the existing PR covers upstream `main`.

Notable fork-ahead work currently preserved includes:

- Zend-specific XCFramework release wiring in `Package.swift`; the `2.6.3` package pin is a Zend-hosted artifact built from `libzcashlc` `2.6.0-alpha.4` sources so the local consensus branch ID matches NU6.2 lightwalletd servers.
- Upstream's new multi-server broadcaster submission model from `#1757`, which supersedes Zend's earlier pending-submit-plan carry.
- Upstream's follow-up resubmission and enhancement fixes from `#1760` and `#1761`: the first sync-cycle resubmit throttle now starts from wall-clock time, enhancement post-fetch writes are retried consistently, and structured `BlockEnhancer` diagnostics are available without logging transaction IDs, addresses, or other user-identifying data.
- Upstream's repository-wide trailing-whitespace cleanup from `#1765`, adopted as a low-risk parity merge with no Zend-specific behavior changes.
- Upstream's Dependabot configuration from `#1766`, adopted as repository automation parity with no Zend-specific source changes.
- Upstream's Keystone/cross-account `deleteAccount` fix from `#1786`, adopted through the bundled Rust dependency lockfile update.
- Upstream's checkpoint refresh and `.claude/skills/update-checkpoints` helper from `#1789`, adopted without Zend-specific behavior changes.
- Upstream's `2.6.0-alpha.6` release tag from `#1790`, adopted as Git history parity while preserving Zend's `Package.swift` binary target URL and checksum for the existing Zend-hosted `2.6.3` artifact.
- Upstream's local FFI build flag update from `#1795`, adopted without conflicts. This adds arm64-only helper modes for Apple Silicon local FFI iteration and keeps Zend's fork-local release artifact workflow intact.
- New-wallet birthday behavior from the `[#1673]` lineage, now reconciled with upstream's reorg-safe follow-up.
- Voting-related Zend SDK additions that remain ahead of upstream.
- Zend release-helper fixes in `Scripts/prepare-release.sh`, `Scripts/release.sh`, and `Scripts/init-local-ffi.sh` that publish and consume fork-local artifacts from `just-zend/zcash-swift-wallet-sdk-zend`.

Implication: PR `#15` is the active default-branch parity PR. As of the 2026-07-02 monitor it is open, no longer draft, mergeable with `mergeStateStatus: CLEAN`, and its GitHub `build`, `Run zizmor`, and `zizmor` checks were all passing on `fb886370` before this source merge and guide refresh. After it lands, Zend will contain upstream `main` through `89f994b5`. Zend SDK release numbering remains separate from upstream and FFI artifact numbering: the fork tag `2.6.3` points at the Zend SDK release while upstream `2.6.0-alpha.6` points at the upstream SDK release artifact.

## Conflict resolution heuristics

When conflicts occur:

- Keep upstream protocol/consensus correctness changes unless Zend has an audited override.
- Keep Zend-facing naming/branding and integration points where they intentionally differ.
- Prefer upstream tests and safety checks unless they break known Zend constraints.
- If uncertain, open draft PR with precise file-level blocker notes instead of forcing merge.

Zend parity branch note:

- `codex/zcash-upstream-sync-2026-06-17` merged upstream `main` through `dd7329eb`.
- The original June 17 merge conflict was `CHANGELOG.md`; resolve by keeping Zend's `2.6.3` release section and placing the upstream `Unreleased` diagnostics/resubmission notes above it.
- The June 19 refresh merged `#1765` without conflicts and required no Zend-specific code adaptation.
- Zend PR `#14` is merged. Its final checks were green: GitHub build/offline-test, SwiftLint, and zizmor all succeeded for commit `48347a08`.
- `codex/zcash-upstream-sync-2026-06-22` now merges upstream `#1766` cleanly. The only upstream file addition is `.github/dependabot.yml`; no source conflicts occurred and no Zend-specific behavior changed.
- The June 26 refresh merged upstream through `8bbc0b7f` with one conflict in `CHANGELOG.md`. Resolve by keeping upstream `2.6.0-alpha.6` checkpoint notes above Zend `2.6.3`, preserving Zend `2.6.3` and `2.6.2`, and retaining upstream `2.6.0-alpha.5` release notes separately.
- The June 27 refresh merged upstream through `4303068e` with one conflict in `Package.swift`. Resolve by keeping Zend's `https://github.com/just-zend/zcash-swift-wallet-sdk-zend/releases/download/2.6.3/libzcashlc.xcframework.zip` URL and checksum, rather than replacing it with upstream's `2.6.0-alpha.6` artifact.
- The July 2 refresh merged upstream through `89f994b5` with no conflicts. The upstream `#1795` changes touch `CLAUDE.md`, `Scripts/init-local-ffi.sh`, and `docs/LOCAL_DEVELOPMENT.md`; no Zend-specific artifact URL, checksum, branding, or release behavior changed.

## Bleeding-edge snapshot (2026-07-02)

Merged upstream default-branch delta pending in Zend fork default branch:

- `#1766`: Dependabot setup merged upstream. Adds `.github/dependabot.yml` with weekly Cargo, Swift, and GitHub Actions update schedules plus cooldowns.
- `#1786`: fixes `Synchronizer.deleteAccount(_:)` for cross-account transaction references by taking upstream `zcash_client_sqlite` 0.21.1 / librustzcash `#2426`.
- `#1789`: adds the checkpoint update skill and refreshes mainnet/testnet checkpoints through mainnet `3390000` and testnet `4090000`.
- `#1790`: tags upstream SDK release `2.6.0-alpha.6`; Zend adopts the upstream merge history but keeps Zend's existing `2.6.3` binary artifact wiring in `Package.swift`.
- `#1795`: adds arm64-only local FFI build modes to `Scripts/init-local-ffi.sh`, plus related `CLAUDE.md` and `docs/LOCAL_DEVELOPMENT.md` updates. The merge was clean and did not affect Zend's hosted artifact wiring.
- Upstream-only commits before PR `#15` lands:
  - `89f994b5`: merge PR `#1795`.
  - `53c71ccf`: add arm64 subset build flags to `init-local-ffi.sh`.
  - `4303068e`: merge PR `#1790`.
  - `0a59a5b0`: release zcash-swift-wallet-sdk version `2.6.0-alpha.6`.
  - `8bbc0b7f`: merge PR `#1789`.
  - `8816e136`: checkpoint refresh.
  - `93675ce3`: add update-checkpoints skill.
  - `2626e86d`: merge PR `#1786`.
  - `33cb30d9`: fix deleteAccount failure for accounts with cross-account transactions.
  - `e0bf7ca3`: merge PR `#1766`.
  - `86870b40`: add cooldown to Dependabot updates.
  - `8023c752`: add Dependabot configuration.
- Zend PR `#15` remains the active parity PR and now merges upstream `main` through `89f994b5`; the 2026-07-02 monitor reports `57 12` for `origin/main...upstream/main` and `72 0` for the PR branch against `upstream/main` after this guide refresh.

Open upstream PRs assessed as not ready to carry right now:

- `#1798` (`michal/MOB-1455-5-final-fixes` -> `michal/MOB-1455-4-set-activation-height`): draft, `UNSTABLE`, and its build check is failing. It is the latest layer in the Ironwood migration stack, so it should wait for upstream review and green CI.
- `#1797` (`michal/MOB-1455-4-set-activation-height` -> `michal/MOB-1455-3-ironwood-sdk-support`): draft, `UNSTABLE`, and its build check is failing. It changes activation-height handling in the Ironwood stack and is not ready for Zend to carry early.
- `#1796` (`michal/MOB-1455-3-ironwood-sdk-support` -> `michal/MOB-1455-2-ironwood-migration-sdk-impl`): draft, `UNSTABLE`, and its build check is failing. It adds Ironwood SDK support on top of the still-draft migration implementation.
- `#1794` (`michal/MOB-1455-2-ironwood-migration-sdk-impl` -> `michal/MOB-1455-ironwood-migration-prototype-ffi`): draft, `UNSTABLE`, and its build check is failing. It layers migration orchestration and public SDK API work on top of the in-flight FFI branch, so it is not ready for a Zend carry.
- `#1793` (`michal/MOB-1455-ironwood-migration-prototype-ffi`): draft, `BLOCKED`, review-required, and its build check is failing. It updates the FFI/welding layer for Ironwood migration; this is protocol-facing work and should wait for upstream review, green CI, and API stabilization.
- Closed unmerged on 2026-07-01: `#1792` (`harry/ironwood-nu6.3-deps` -> `harry/ironwood-migration-sdk-interface`) and `#1791` (`harry/ironwood-migration-sdk-interface`). Their branches still exist, but the closed draft PRs do not provide a readiness signal for Zend.
- `#1787` and `#1788`: Swift NIO / NIO Extras Dependabot PRs; non-draft with passing checks, but still `BLOCKED` and review-required, so wait for upstream dependency review.
- `#1770` through `#1785`: Dependabot PRs for Cargo, Swift, and GitHub Actions dependencies. They remain review-required and `BLOCKED`; several still have failed build or zizmor checks, so wait for upstream review and CI policy before carrying individual dependency bumps.
- `#1767` (`dw/remove-useless-deadcode-annotations`): non-draft but `BLOCKED` and review-required; Rust annotation cleanup should wait for upstream review rather than being carried independently.
- `#1763` (`michal/MOB-1389-fetch-usd-rate-tor-crash`): draft, `DIRTY`, and review-required; touches Tor/exchange-rate concurrency, so wait for upstream completion.
- `#1746` (`kris/1745-finish-release-workflow`): non-draft but `DIRTY`, review-required, and release-workflow heavy.
- `#1733` (`main` -> `release/2.6.0`): explicit `[DO NOT MERGE]` draft stabilization preview, so wait for upstream release sequencing rather than carrying it independently.
- `#1700`, `#1638`, `#1637`, `#1592`, `#1579`, and `#1443`: draft/WIP FFI, testing, send-max, or build-plugin changes with broad impact; several also have requested changes or stale unknown merge state.
- `#1692`: non-draft but `BLOCKED` and review-required.
- `#1570`: non-draft and approved, but still `DIRTY` and an old broad behavioral fork; carrying it ahead of upstream remains higher risk.
- `#1505`: tiny spelling fix, but still `DIRTY` and review-required, so not worth carrying independently.

No candidate currently meets all carry criteria (ready + useful + low risk) for Zend ahead-of-upstream adoption.

Unmerged upstream branches (not carried):

- `adam/broadcaster-submit-plan`: 14 commits ahead and 82 behind `upstream/main`; no upstream PR, and the commits are already contained in `origin/main` from Zend PR `#2` before being superseded by upstream's `SubmitPlanStore` work in `#1757`.
- `adam/update-zcash-voting-0.9.1-policy`: 1 commit ahead and 78 behind `upstream/main`; voting feature scope with no upstream PR/review thread yet.
- `adam/voting-round-recovery-ffi`: 1 commit ahead and 187 behind `upstream/main`; voting recovery FFI with no upstream PR/review thread yet.
- `adam/voting-rust-lint-workflow`: 1 commit ahead and 188 behind `upstream/main`; workflow/lint only and limited direct Zend runtime value.
- Dependabot branches for Cargo, Swift, and GitHub Actions updates are each 1 commit ahead and 7-9 behind `upstream/main`; all are covered by open upstream PRs `#1770` through `#1788`, so wait for upstream review and CI completion.
- `dw/remove-useless-deadcode-annotations`: 1 commit ahead and 14 behind `upstream/main`; covered by open upstream PR `#1767`, so wait for upstream review.
- `feature/ffi_database_handle`: 10 commits ahead and 288 behind `upstream/main`; broad FFI database-handle work covered by draft upstream PR `#1637`, so do not carry early.
- `feature/typesafe_db_handles`: 11 commits ahead and 288 behind `upstream/main`; broad type-safe handle work covered by draft upstream PR `#1638`, so do not carry early.
- `ffi-0.18.0-part-2`: 5 commits ahead and 809 behind `upstream/main`; stale WIP transaction policy work covered by draft upstream PR `#1592`.
- `harry/ironwood-migration-sdk-interface`: 4 commits ahead and 2 behind `upstream/main`; formerly covered by draft upstream PR `#1791`, protocol-facing Ironwood migration API work, so wait for upstream review.
- `harry/ironwood-nu6.3-deps`: 5 commits ahead and 2 behind `upstream/main`; formerly covered by draft upstream PR `#1792`, depends on `harry/ironwood-migration-sdk-interface`, and had a failing build check.
- `ignore_worktrees`: 1 commit ahead and 82 behind `upstream/main`; housekeeping-only change.
- `kris/1745-finish-release-workflow`: 9 commits ahead and 82 behind `upstream/main`; covered by open upstream PR `#1746`, which is release-workflow heavy and review-required.
- `michal/MOB-1389-fetch-usd-rate-tor-crash`: 1 commit ahead and 48 behind `upstream/main`; covered by draft upstream PR `#1763`, so wait for upstream completion.
- `michal/MOB-1455-2-ironwood-migration-sdk-impl`: 15 commits ahead and 2 behind `upstream/main`; covered by draft upstream PR `#1794`, build-failing, and layered on the prototype FFI branch, so wait for upstream review and API stabilization.
- `michal/MOB-1455-3-ironwood-sdk-support`: 22 commits ahead and 2 behind `upstream/main`; covered by draft upstream PR `#1796`, build-failing, and part of the Ironwood stack.
- `michal/MOB-1455-4-set-activation-height`: 29 commits ahead and 2 behind `upstream/main`; covered by draft upstream PR `#1797`, build-failing, and part of the Ironwood stack.
- `michal/MOB-1455-5-final-fixes`: 35 commits ahead and 2 behind `upstream/main`; covered by draft upstream PR `#1798`, build-failing, and part of the Ironwood stack.
- `michal/MOB-1455-ironwood-migration-prototype-ffi`: 11 commits ahead and 2 behind `upstream/main`; covered by draft upstream PR `#1793`, build-failing, and still protocol-facing FFI work, so wait for upstream review and green CI.
- `maint/v2.5.x`: 0 commits ahead and 168 behind `upstream/main`; maintenance line, no standalone carry.
- `release-ci`: 4 commits ahead and 160 behind `upstream/main`; release branch integration artifact, not a clear standalone carry target.
- `release/2.6.0`: 0 commits ahead and 171 behind `upstream/main`; upstream release stabilization branch, wait for upstream release sequencing.
- `roman/voting-delegation-workflow-swift-wrappers`: 0 commits ahead and 147 behind `upstream/main`; voting wrapper branch without an upstream PR/review thread yet.
- `rust-build-plugin`: 2 commits ahead and 1109 behind `upstream/main`; stale draft build-plugin work covered by upstream PR `#1443`.
- `shielded-vote-2.4.10`: 1 commit ahead and 105 behind `upstream/main`; specialized voting branch with unclear Zend product priority.
- `testing/note_spendability_improvements`: 6 commits ahead and 218 behind `upstream/main`; draft test-only branch covered by upstream PR `#1700`.
