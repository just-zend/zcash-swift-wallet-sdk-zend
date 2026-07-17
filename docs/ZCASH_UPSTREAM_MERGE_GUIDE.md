# Zcash Upstream Merge Guide for Zend Fork

This document tracks how to safely sync `just-zend/zcash-swift-wallet-sdk-zend` with `zcash/zcash-swift-wallet-sdk`.

Last reviewed: 2026-07-16

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

## Zend divergence notes

### CI runner divergence (as of 2026-07-16)

Zend CI intentionally diverges from upstream's native GitHub-hosted runners:

- `warp-macos-15-arm64-12x` runs the manual committed-XCFramework packaging job, the Swift PR build and offline tests, and the Swift CodeQL matrix row.
- `warp-ubuntu-latest-x64-16x` runs the CodeQL `actions`, `c-cpp`, and `rust` matrix rows.
- `warp-ubuntu-latest-x64-8x` runs SwiftLint and zizmor.
- Public Swift and CodeQL jobs verify the reviewed, committed three-slice FFI artifact; they do not build Rust or require credentials for the private migration engine. Authenticated source rebuilds use `Scripts/build-ironwood-ffi-artifact.sh` outside public CI.
- Swift, SwiftLint, and zizmor PR workflows cancel superseded work for the same pull request.
- A newer CodeQL push to the same ref cancels the older push scan. Scheduled and manually dispatched CodeQL scans remain independent, and manual FFI release runs do not cancel.

The first committed-artifact Swift control completed in 3m10s ([run `29467560549`](https://github.com/just-zend/zcash-swift-wallet-sdk-zend/actions/runs/29467560549)): checkout 16s, artifact verification 10s, fixture verification 1s, Swift build 1m23s, and offline tests 1m14s. The prior GitHub-hosted warm median was 5m54s, so use roughly 3m10s as the PR regression baseline. There is no longer a separate cold Rust-FFI build path in public SDK CI.

Moving the `contents: write` draft-release publisher to WarpBuild expands the trusted computing base for SDK releases. The following controls are required:

- The live `sdk-release` GitHub environment must exist before the manual FFI release workflow is used. It must require an independent reviewer, prevent self-approval and administrator bypass where GitHub makes those controls available, and restrict deployment branches and tags to protected, reviewed release refs.
- WarpBuild GitHub App access must be limited to this repository and the minimum permissions required for these jobs.
- The environment reviewer must verify and approve the exact commit SHA shown by the workflow run.
- The workflow output must remain a draft release.
- A second maintainer must download the draft XCFramework zip, independently run `shasum -a 256`, compare the result with both the workflow output and the checksum proposed for `Package.swift`, confirm that the draft asset came from the approved workflow SHA, and only then publish the release.

Zend PR `#19` merged the runner changes into `origin/main`, but the live `sdk-release`
environment is still not configured. Do not dispatch the manual FFI release workflow until the
environment protections and WarpBuild GitHub App controls above are verified.

### Ironwood integration and upstream parity snapshot (as of 2026-07-16)

Current relationship after Zend PRs `#18`, `#17`, `#20`, and `#21` merged into `origin/main`:

- `origin/main...upstream/main`: `152 0` after fetching both remotes on 2026-07-16.
- Fork-specific Zend commits remain ahead of `upstream/main`.
- `upstream/main` currently points at `d92a7940` (`#1802`); it also includes `#1799` for Tor retry classification, `#1795` for local FFI build flags, `#1790` / tag `2.6.0-alpha.6`, `#1789` checkpoint refresh, `#1786` for the Keystone/cross-account `deleteAccount` fix, and `#1766` Dependabot setup.
- `git merge-base --is-ancestor upstream/main origin/main` succeeds.
- PR `#17` merged as `1bbc35a6`; PR `#20` then optimized the WarpBuild Swift CI lane, and PR
  `#21` merged the spendable-completion Ironwood FFI rebuild as `02f9a78e`.
- Current `origin/main` contains the upstream parity line, the reviewed Ironwood migration SDK stack,
  the spendable-completion FFI gate, and the WarpBuild Swift CI optimization.

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
- Upstream's Tor retry classification fix from `#1799`, adopted without conflicts. It treats Rust-layer Tor failures as retryable service errors in `CompactBlockProcessor`, so transient Tor circuit and stream errors use the existing reset-and-retry path instead of immediately becoming fatal sync failures.
- Upstream's release-script pre-release detection from `#1802`, adopted without conflicts. It marks SemVer pre-release tags as GitHub pre-releases in `Scripts/prepare-release.sh` and `Scripts/release.sh`, and documents the behavior in `docs/ci.md`.
- New-wallet birthday behavior from the `[#1673]` lineage, now reconciled with upstream's reorg-safe follow-up.
- Voting-related Zend SDK additions that remain ahead of upstream.
- Zend release-helper fixes in `Scripts/prepare-release.sh`, `Scripts/release.sh`, and `Scripts/init-local-ffi.sh` that publish and consume fork-local artifacts from `just-zend/zcash-swift-wallet-sdk-zend`.

Implication: Zend PRs `#18`, `#17`, `#20`, and `#21` have landed. `origin/main` contains upstream
`main` through `d92a7940` / PR `#1802` plus the Zend-original Ironwood SDK hardening stack,
spendable-completion FFI rebuild, and WarpBuild Swift CI optimization. PR `#17` replaced the
sibling-path/private-CI blocker with an exact private-engine revision plus a committed, three-slice,
provenance-verified XCFramework; PR `#21` extended that line with a spendable-completion gate. Future
updates must continue to freeze the private revision, artifact hashes, Swift/offline tests, and GitHub
checks together. Zend SDK release numbering remains separate from upstream and FFI artifact numbering.

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
- The July 3 refresh merged upstream through `018253d8` with no conflicts. The upstream `#1799` changes touch `CHANGELOG.md` and `Sources/ZcashLightClientKit/Block/CompactBlockProcessor.swift`; no Zend-specific artifact URL, checksum, branding, or release behavior changed.
- The July 7 refresh merged upstream through `d92a7940` with no conflicts. The upstream `#1802` changes touch `Scripts/prepare-release.sh`, `Scripts/release.sh`, and `docs/ci.md`; no Zend-specific artifact URL, checksum, branding, or support surface changed.

## Bleeding-edge snapshot (2026-07-16)

Zend Ironwood hardening line:

- PR `#17` (`codex/zcash-pr-or-branch-ironwood-nu63-2026-07-04`) merged as `1bbc35a6` and is the
  current Zend-original Ironwood SDK hardening baseline.
- PR `#21` (`codex/ironwood-spendability`) merged as `02f9a78e` after pinning merged private-engine
  `main` commit `58f9c9936bcae603afe2c728a5b17184b9d5d861` (PR `#3`, atop merged PR `#2`). Terminal
  completion requires the exact Ironwood value received from every confirmed migration transaction to
  be upstream-spendable; unrelated account funds cannot satisfy the gate.
- Draft PR `#22` (`codex/ironwood-immediate-first-sdk`) pins private-engine commit
  `0720dff797de212fec8da532cf08a81ba5123be9`, rebuilds all committed arm64 FFI slices with locked
  provenance, and makes the first software migration transfer due immediately while preserving
  randomized timing for later transfers and external signers. It is labeled `zend-improvement`, is
  clean/mergeable, and its `Build and Run Offline Tests` check passed, but it remains draft pending
  the Zend iOS testnet app chain validation.
- The graph continues to pin exact upstream
  `zcash/librustzcash@266a75ae3af076bbe9437088947fddb1add8bd99`.
- The public migration contract is snapshot-driven, revision-CAS-bound, and JIT: it atomically
  binds submission policy, materializes only one due intent, resumes exact staged external-signer
  bytes after process death, and fail-closes ordinary spending only for the affected account.
- Public CI never receives private Rust credentials. Authenticated local tooling builds the exact
  arm64 iOS device/simulator and macOS artifact, while public CI verifies its
  source/provenance/slice hashes and production migration symbol set.

Default-branch parity:

- Zend PR `#18` merged as `b3569196`, PR `#17` merged as `1bbc35a6`, PR `#20` merged as `2e6d8a27`,
  and PR `#21` merged as `02f9a78e`, so `origin/main` contains upstream `main` through `d92a7940` /
  upstream PR `#1802` plus the current Ironwood SDK baseline and Swift CI optimization.
- `git rev-list --left-right --count origin/main...upstream/main` returns `152 0`, and
  `git merge-base --is-ancestor upstream/main origin/main` succeeds.

Open upstream PRs assessed as not ready to carry right now:

- `#1805` (`dependabot/swift/github.com/apple/swift-nio-http2-1.44.0`): non-draft,
  `mergeable=MERGEABLE`, green on `Build and Run Offline Tests` and zizmor, but still `BLOCKED` /
  review-required. It is a dependency bump, so wait for upstream dependency review and policy instead
  of carrying it independently.
- `#1804` (`feat/dandelion-p2p-submit` from `zodl-inc/zcash-swift-wallet-sdk`): non-draft,
  `mergeable=MERGEABLE`, and potentially useful for future privacy work, but `BLOCKED` /
  review-required with failing `Build and Run Offline Tests` and `SwiftLint`. It adds an opt-in
  Dandelion++ direct P2P transaction submission path, new submitter/configuration types, fallback
  submission behavior, and protocol-level peer interaction, so Zend should wait for upstream review,
  green CI, and clear product adoption direction before carrying it. If carried later, it originates
  from a Zodl repo and should use the `zodl` label.
- `#1803` (`slipstream-sdk-private`): non-draft, `mergeable=MERGEABLE`, blocked/review-required,
  and green on `Build and Run Offline Tests`, `SwiftLint`, and `GitHub Actions Security Analysis with
  zizmor`, but still too broad/high-risk for an early Zend carry. It supersedes `#1801` with the same
  broad opt-in high-performance sync engine plus optional private binary packaging, FULL/STUB FFI
  modes, private release scripts, `SlipstreamSynchronizer`, source-compatibility shims, and a new
  `allTransactions()` protocol requirement. Zend should wait for upstream review, public tag-consumer
  artifact guidance, and adoption direction before carrying it.
- `#1801` (`slipstream-sdk`): closed unmerged on 2026-07-08 and superseded by `#1803`, so it is not a carry target.
- `#1800` (`slipstream`): closed unmerged on 2026-07-06 and superseded by later Slipstream PRs, so it is not a carry target.
- `#1798` (`michal/MOB-1455-5-final-fixes` -> `michal/MOB-1455-4-set-activation-height`): draft, `UNSTABLE`, and its build check is failing. It is the latest layer in the Ironwood migration stack, so it should wait for upstream review and green CI.
- `#1797` (`michal/MOB-1455-4-set-activation-height` -> `michal/MOB-1455-3-ironwood-sdk-support`): draft, `UNSTABLE`, and its build check is failing. It changes activation-height handling in the Ironwood stack and is not ready for Zend to carry early.
- `#1796` (`michal/MOB-1455-3-ironwood-sdk-support` -> `michal/MOB-1455-2-ironwood-migration-sdk-impl`): draft, `UNSTABLE`, and its build check is failing. It adds Ironwood SDK support on top of the still-draft migration implementation.
- `#1794` (`michal/MOB-1455-2-ironwood-migration-sdk-impl` -> `michal/MOB-1455-ironwood-migration-prototype-ffi`): draft, `UNSTABLE`, and its build check is failing. It layers migration orchestration and public SDK API work on top of the in-flight FFI branch, so it is not ready for a Zend carry.
- `#1793` (`michal/MOB-1455-ironwood-migration-prototype-ffi`): draft, `DIRTY`, review-required, and its build check is failing. It updates the FFI/welding layer for Ironwood migration; this is protocol-facing work and should wait for upstream review, green CI, and API stabilization.
- Closed unmerged on 2026-07-01: `#1792` (`harry/ironwood-nu6.3-deps` -> `harry/ironwood-migration-sdk-interface`) and `#1791` (`harry/ironwood-migration-sdk-interface`). Their branches still exist, but the closed draft PRs do not provide a readiness signal for Zend.
- `#1787` and `#1788`: Swift NIO / NIO Extras Dependabot PRs; non-draft with passing checks, but
  still `BLOCKED` and review-required, so wait for upstream dependency review.
- `#1770` through `#1785`: Dependabot PRs for Cargo, Swift, and GitHub Actions dependencies. They remain `BLOCKED` and review-required; several still have failed build or zizmor checks, so wait for upstream review and CI policy before carrying individual dependency bumps.
- `#1767` (`dw/remove-useless-deadcode-annotations`): non-draft and clean/mergeable, but still an unmerged Rust annotation cleanup with limited direct Zend value; wait for upstream to land it rather than carrying it independently.
- `#1763` (`michal/MOB-1389-fetch-usd-rate-tor-crash`): draft, `DIRTY`, and review-required; touches Tor/exchange-rate concurrency, so wait for upstream completion despite current checks passing.
- `#1746` (`kris/1745-finish-release-workflow`): non-draft, `DIRTY`, review-required, and release-workflow heavy. Upstream `#1802` has already landed the focused pre-release flag subset, so the broader release-workflow PR should still wait for upstream completion.
- `#1733` (`main` -> `release/2.6.0`): explicit `[DO NOT MERGE]` draft stabilization preview with green checks, so wait for upstream release sequencing rather than carrying it independently.
- `#1700`, `#1638`, `#1637`, `#1592`, `#1579`, and `#1443`: draft/WIP FFI, testing, send-max, or build-plugin changes with broad impact; several also have requested changes or stale unknown merge state.
- `#1692`: non-draft, `BLOCKED`, review-required, and has no current check signal.
- `#1570`: non-draft and approved, but still `DIRTY` and represents an old broad behavioral fork; carrying it ahead of upstream remains higher risk.
- `#1505`: tiny spelling fix, but still `DIRTY` and review-required, so not worth carrying independently.

No candidate currently meets all carry criteria (ready + useful + low risk) for Zend ahead-of-upstream adoption.

Unmerged upstream branches (not carried):

- `adam/broadcaster-submit-plan`: 14 commits ahead and 87 behind `upstream/main`; no upstream PR, and the commits are already contained in `origin/main` from Zend PR `#2` before being superseded by upstream's `SubmitPlanStore` work in `#1757`.
- `adam/update-zcash-voting-0.9.1-policy`: 1 commit ahead and 83 behind `upstream/main`; voting feature scope with no upstream PR/review thread yet.
- `adam/voting-round-recovery-ffi`: 1 commit ahead and 192 behind `upstream/main`; voting recovery FFI with no upstream PR/review thread yet.
- `adam/voting-rust-lint-workflow`: 1 commit ahead and 193 behind `upstream/main`; workflow/lint only and limited direct Zend runtime value.
- Older Dependabot branches for Cargo, Swift, and GitHub Actions updates are each 1 commit ahead and
  12-14 behind `upstream/main`; all are covered by open upstream PRs `#1770` through `#1788`, so wait
  for upstream review and CI completion.
- `dependabot/swift/github.com/apple/swift-nio-http2-1.44.0`: 1 commit ahead and 3 behind
  `upstream/main`; covered by open upstream PR `#1805`, so wait for upstream dependency review.
- `dw/remove-useless-deadcode-annotations`: 1 commit ahead and 19 behind `upstream/main`; covered by open upstream PR `#1767`, so wait for upstream review.
- `feature/ffi_database_handle`: 10 commits ahead and 293 behind `upstream/main`; broad FFI database-handle work covered by draft upstream PR `#1637`, so do not carry early.
- `feature/typesafe_db_handles`: 11 commits ahead and 293 behind `upstream/main`; broad type-safe handle work covered by draft upstream PR `#1638`, so do not carry early.
- `ffi-0.18.0-part-2`: 5 commits ahead and 814 behind `upstream/main`; stale WIP transaction policy work covered by draft upstream PR `#1592`.
- `harry/ironwood-migration-sdk-interface`: 4 commits ahead and 7 behind `upstream/main`; formerly covered by draft upstream PR `#1791`, protocol-facing Ironwood migration API work, so wait for upstream review.
- `harry/ironwood-nu6.3-deps`: 5 commits ahead and 7 behind `upstream/main`; formerly covered by draft upstream PR `#1792`, depends on `harry/ironwood-migration-sdk-interface`, and had a failing build check.
- `ignore_worktrees`: 1 commit ahead and 87 behind `upstream/main`; housekeeping-only change.
- `kris/1745-finish-release-workflow`: 9 commits ahead and 87 behind `upstream/main`; covered by open upstream PR `#1746`, which is release-workflow heavy and review-required.
- `michal/MOB-1389-fetch-usd-rate-tor-crash`: 1 commit ahead and 53 behind `upstream/main`; covered by draft upstream PR `#1763`, so wait for upstream completion.
- `michal/MOB-1455-2-ironwood-migration-sdk-impl`: 15 commits ahead and 7 behind `upstream/main`; covered by draft upstream PR `#1794`, build-failing, and layered on the prototype FFI branch, so wait for upstream review and API stabilization.
- `michal/MOB-1455-3-ironwood-sdk-support`: 22 commits ahead and 7 behind `upstream/main`; covered by draft upstream PR `#1796`, build-failing, and part of the Ironwood stack.
- `michal/MOB-1455-4-set-activation-height`: 29 commits ahead and 7 behind `upstream/main`; covered by draft upstream PR `#1797`, build-failing, and part of the Ironwood stack.
- `michal/MOB-1455-5-final-fixes`: 35 commits ahead and 7 behind `upstream/main`; covered by draft upstream PR `#1798`, build-failing, and part of the Ironwood stack.
- `michal/MOB-1455-6-integration-with-final-zodl`: 38 commits ahead and 7 behind `upstream/main`; no upstream PR exists yet, and the branch layers Keystone PCZT and final Zodl integration work on top of the draft build-failing Ironwood stack, so do not carry it until upstream opens/reviews it and the stack turns green.
- `michal/MOB-1455-ironwood-migration-prototype-ffi`: 11 commits ahead and 7 behind `upstream/main`; covered by draft upstream PR `#1793`, build-failing, and still protocol-facing FFI work, so wait for upstream review and green CI.
- `release-ci`: 4 commits ahead and 165 behind `upstream/main`; release branch integration artifact, not a clear standalone carry target.
- `rust-build-plugin`: 2 commits ahead and 1114 behind `upstream/main`; stale draft build-plugin work covered by upstream PR `#1443`.
- `shielded-vote-2.4.10`: 1 commit ahead and 110 behind `upstream/main`; specialized voting branch with unclear Zend product priority.
- `testing/note_spendability_improvements`: 6 commits ahead and 223 behind `upstream/main`; draft test-only branch covered by upstream PR `#1700`.
