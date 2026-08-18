# Zcash Upstream Merge Guide for Zend Fork

This document tracks how to safely sync `just-zend/zcash-swift-wallet-sdk-zend` with `zcash/zcash-swift-wallet-sdk`.

Last reviewed: 2026-08-17

## Remote and branch invariants

- `origin` must point to `git@github.com:just-zend/zcash-swift-wallet-sdk-zend.git`.
- `upstream` must point to `git@github.com:zcash/zcash-swift-wallet-sdk.git`.
- Default branch for both repositories is `main`.

## Parity and bleeding-edge refresh (2026-08-17)

- Fresh fetches confirm the remote and default-branch invariants, with
  `origin/main=4497fe9e` and `upstream/main=02e04161`; divergence is `174 418`.
  Zend draft [#34](https://github.com/just-zend/zcash-swift-wallet-sdk-zend/pull/34)
  was refreshed at `04602365` and contains the exact upstream tip (`181 0` against
  `upstream/main`). It remains the sole full-parity vehicle; do not create a duplicate
  sync branch or PR.
- Upstream [#1979](https://github.com/zcash/zcash-swift-wallet-sdk/pull/1979) merged the
  Ironwood/Slipstream integration sequence containing #1978 and #1973. The Zend parity merge
  applied with no conflicts, retaining Zend's existing private-engine provenance and fork-hosted
  XCFramework release wiring. The delta extracts `TxResubmitter`, uses it for legacy and
  Slipstream background resubmission, and makes `SlipstreamSynchronizer.wipe()` clear
  submit-plan state.
- `git diff --check` passes on the parity merge. `swift build` reaches compilation but fails
  before tests because the released Zend XCFramework lacks the required migration, transaction
  readback, custom-network, and Slipstream declarations, including `FfiTransactionData`,
  `FfiMigrationProgress`, `FfiSlipstreamSnapshot`, and `zcashlc_set_custom_network`.
  Do not run OfflineTests until the exact private `librustzcash` / `slipstream-internal`
  provenance is frozen, the matching committed arm64 artifact and generated headers are rebuilt
  and verified, release wiring is reviewed, and funded-device migration evidence exists.
- No newly active unmerged branch is an early Zend carry. #1972 is a clean voting dependency
  bump but changes `zcash_voting` and the Ironwood migration graph; #1961 (send max) and #1962
  (voting restoration) are dirty; #1960 is only their Cargo.lock repair; #1968 is dirty and
  stacked on a database reproduction; and #1893/#1964 remain blocked migration or ZODL
  licensing/artifact work. Dependabot and maintenance branches remain review- or merge-blocked.
  No Zend labels apply to upstream parity work, and no source-independent carry is justified.
- This tracker update is documentation-only. `git diff --check` is sufficient; source builds and
  tests are recorded on #34 instead.

## Parity and bleeding-edge refresh (2026-08-16)

- Fresh fetches confirm the remote and default-branch invariants, with
  `origin/main=4497fe9e` and `upstream/main=785c7618`; divergence remains
  `174 410`. Zend draft [#34](https://github.com/just-zend/zcash-swift-wallet-sdk-zend/pull/34)
  at `ee24ba3e` contains the exact upstream tip (`180 0` against `upstream/main`).
  Reuse it as the sole full-parity vehicle; do not create a duplicate sync branch or PR.
- New upstream [#1978](https://github.com/zcash/zcash-swift-wallet-sdk/pull/1978)
  (`slipstream-parity-gaps`) has green CI but remains blocked and review-required. Its three
  commits change five files (+556/-150) to share transaction resubmission with the legacy
  pipeline and to make `SlipstreamSynchronizer.wipe()` remove submit-plan state. Those changes
  alter Slipstream polling, cancellation, wallet-wipe ordering, and persistent-state behavior.
  They are coupled to the Ironwood/Slipstream source and matching XCFramework artifact gate
  already blocking #34, so they are not an independently ready, useful, low-risk early Zend carry.
- Upstream [#1962](https://github.com/zcash/zcash-swift-wallet-sdk/pull/1962) is now clean and
  approved, but still adds eight commits across 19 files (+3,248/-1,891) spanning
  `zcash_voting`, Rust and Swift FFI, public migration constants, and new voting tests. It remains
  coupled to the Ironwood artifact/provenance gate and has no independently verifiable Zend
  release path, so do not carry it ahead of upstream. The post-merge `Cargo.lock` repair #1960
  is likewise only meaningful with that integration sequence.
- Upstream #1973/#1974 change the upstream-only `make ffi-macos` timeout from 30 to 60 minutes;
  #1974 is stacked on the voting bump. Zend's workflow instead runs `swift test --filter
  OfflineTests` with a 15-minute cap and has no observed timeout, so the patch neither applies
  cleanly nor establishes a Zend-specific need. Keep CI timeout changes out of this monitor until
  a Zend job provides evidence. The remaining readback, ZODL licensing/artifact, migration,
  release, and dependency branches are blocked, dirty, review-required, or coupled. No Zend
  labels apply to this upstream parity decision.
- This is a documentation-only monitor record. No Zend SDK source or artifact changed, so
  `swift build` and `swift test --filter OfflineTests` were intentionally not rerun.

## Parity and bleeding-edge refresh (2026-08-14)

- Fresh fetches confirm `origin/main=4497fe9e` and `upstream/main=785c7618`, with
  divergence `174 410`. The upstream default advanced through merge PR
  [#1971](https://github.com/zcash/zcash-swift-wallet-sdk/pull/1971), which incorporates
  the created-transaction readback and resubmission repair sequence. Existing Zend draft
  [#34](https://github.com/just-zend/zcash-swift-wallet-sdk-zend/pull/34) was refreshed at
  `ee24ba3e` and contains the exact upstream tip; it remains the sole parity vehicle.
- The merge was clean and preserves Zend identity and release wiring. The 24-file upstream
  delta adds the readback/rebroadcast handling and test coverage, plus the matching Rust FFI
  surface. `cargo fmt` completed with no changes and `git diff --check HEAD^1..HEAD` passed.
  The broader branch still carries pre-existing trailing-whitespace differences from the
  already-open parity range; they are not introduced by this upstream refresh.
- `swift build` fails before tests against Zend's released XCFramework because its header and
  binary lack the required migration and Slipstream FFI surface, including
  `FfiTransactionData`, `FfiMigrationProgress`, `FfiSlipstreamSnapshot`, and
  `zcashlc_slipstream_open`. Do not run `swift test --filter OfflineTests` until exact
  `librustzcash`/`slipstream-internal` provenance is reconciled, a matching arm64 artifact is
  built and verified, release wiring is updated, and funded-device migration evidence exists.
- No bleeding-edge carry is appropriate. Open #1962 is clean but is a large voting/FFI and
  dependency migration; #1968 is dirty and stacked on a non-main reproduction branch; #1964
  is blocked ZODL-specific dual MIT/AGPL artifact work; #1973 is blocked CI-timeout tuning;
  and #1974 is only its stacked backport. The `chp-*`, readback, vendoring, and private
  Slipstream branches remain coupled to migration, artifact, licensing, or release gates.
  No Zend labels are applied to upstream parity work.

## Parity and bleeding-edge refresh (2026-08-12)

- Fresh fetches confirm `origin/main=4497fe9e` and `upstream/main=ee7b05c9`, with
  divergence `174 398`. `upstream/main` is not an ancestor of Zend `main`, but Zend
  draft [#34](https://github.com/just-zend/zcash-swift-wallet-sdk-zend/pull/34) at
  `013a024d` contains the exact upstream tip (`179 0` against `upstream/main`). Reuse
  #34 as the sole full-parity vehicle; do not open another default-branch sync PR.
- Keep #34 draft: its Ironwood/Slipstream source surface requires a matching
  provenance-verified arm64 `libzcashlc` XCFramework. The current released framework
  lacks `FfiMigrationProgress`, `zcashlc_slipstream_open`, and related declarations,
  so source parity is not a release-ready Zend artifact. The remaining gates are exact
  `librustzcash`/`slipstream-internal` provenance, artifact rebuild and release wiring,
  and funded-device migration evidence.
- Newly fetched `chp-re-enable` is not a safe early carry. It is a seven-commit,
  19-file voting/FFI migration branch (including `Cargo.lock`, `Cargo.toml`,
  `MIGRATING.md`, Rust voting serialization, Swift voting bindings, and new Offline
  Tests) that is still based on the Ironwood transition. Its 2,733 additions and 1,890
  deletions require the same source/FFI/artifact and device-validation reconciliation.
  Do not split the snapshot-validation fix from that graph. Open #1961 (send-max),
  #1960 (post-merge `Cargo.lock` repair), #1944, #1895, #1893, and Dependabot work are
  likewise feature, artifact-coupled, maintenance-line-only, draft/dirty, or broad
  dependency changes; none is independently ready, useful, and low-risk for Zend.
- This is a documentation-only monitor record. `git diff --check` passed; `swift build`
  and `swift test --filter OfflineTests` were not rerun because no SDK source or FFI
  artifact changed in Zend during this review.

## Parity and bleeding-edge refresh (2026-08-07)

- Fresh fetches leave the default-branch refs unchanged: `origin/main=4497fe9e` and
  `upstream/main=468d1e9f`, with divergence `174 111`. `upstream/main` is not yet an ancestor of
  `origin/main`, but Zend draft [#34](https://github.com/just-zend/zcash-swift-wallet-sdk-zend/pull/34)
  (`codex/zcash-upstream-sync-2026-08-01`) already contains that exact tip (`177 0` against
  `upstream/main`). Reuse #34 as the only full-parity vehicle; do not open a duplicate sync branch.
- Upstream [#1953](https://github.com/zcash/zcash-swift-wallet-sdk/pull/1953) is clean and its
  checks are green, but it is still a draft against `feature/ironwood-slipstream`. Its 21-file
  migration/FFI change advances the private `librustzcash` pin, changes batch proving and migration
  outlook APIs, and rewrites the wallet adapter. It is coupled to the same artifact provenance and
  funded-device migration gates as the broader Slipstream line, so it is not a safe standalone Zend
  carry. Draft [#1957](https://github.com/zcash/zcash-swift-wallet-sdk/pull/1957) and blocked
  [#1954](https://github.com/zcash/zcash-swift-wallet-sdk/pull/1954) confirm that the stack is still
  in integration rather than release-ready state; #1954's build is currently failing.
- The newly merged upstream maintenance-only work remains wait-for-upstream: #1956 adds Rust test
  gating only to `maint/v2.7.x`, and #1925 unifies release scripts on that same line. Keep Zend's
  SHA-pinned actions, read-only permissions, and private-engine verification policy until a
  Zend-compatible mainline or release artifact exists. The narrow XCFramework packaging fix #1944,
  stale-sync-state fix #1900, and Tor-off submission change #1898 are respectively
  maintenance-line-only, draft/dirty, or draft/dirty; none clears the ready, useful, low-risk gate.
- This is a documentation-only monitoring record. No SDK source or FFI artifact changed, so local
  `swift build` and `swift test --filter OfflineTests` were intentionally not rerun.

## Parity and bleeding-edge refresh (2026-08-05)

- Fresh fetches confirm that both defaults remain `main`, with
  `origin/main=4497fe9e` and `upstream/main=468d1e9f`. The default-branch
  divergence remains `174 111`; `upstream/main` is not yet contained in
  `origin/main`, but Zend draft [#34](https://github.com/just-zend/zcash-swift-wallet-sdk-zend/pull/34)
  at `3a7e9ee0` already contains that exact upstream tip. It is therefore the
  single parity vehicle, rather than a reason to create a duplicate sync branch.
- PR #34 remains draft and clean. Its GitHub `build`, `SwiftLint`, and both
  `zizmor` checks are successful. Product/migration-owner approval and
  funded-device migration evidence remain separate merge gates.
- The newly active upstream stack (`#1946` through `#1951`) is draft, blocked,
  and chained through Ironwood migration selection plus interim `librustzcash`
  pins. It is coupled to the private-engine/artifact reconciliation surface and
  is not a safe early Zend carry. Existing upstream release, Darkside-test,
  Tor, dependency, and migration branches are either maintenance-line-only,
  blocked/dirty, or lack a Zend-specific low-risk use case. The focused
  decrypt-and-store sentinel repair remains separately tracked by Zend draft #35.

## Parity and bleeding-edge refresh (2026-08-04)

- Fresh fetches confirm `origin/main=4497fe9e` and `upstream/main=468d1e9f`; the
  default-branch divergence is `174 111`. The upstream delta adds the 2.7.0-rc.3
  and 2.8.0-rc.2 release line, including the current FFI artifact, Rust dependency,
  build-support, and changelog graph.
- Zend draft PR [#34](https://github.com/just-zend/zcash-swift-wallet-sdk-zend/pull/34)
  remains the sole full-parity vehicle. It now merges upstream through `468d1e9f`
  with no conflict resolution; its SDK source and release graph match `upstream/main`, while Zend
  retains SHA-pinned, least-privilege SwiftLint workflow controls.
  `swift build` and `swift test --filter OfflineTests` both pass against the
  upstream release framework, resolving the prior voting Swift/FFI source mismatch.
  Keep it draft until product owners approve replacing Zend's divergent migration
  path and funded-device migration evidence is recorded.
- No additional early carry is justified. Upstream [#1946](https://github.com/zcash/zcash-swift-wallet-sdk/pull/1946)
  is draft, blocked, and coupled to the Slipstream/private-engine stack; #1944 is
  review-required maintenance tooling against `maint/v2.7.x`; #1942 removes the
  Darkside test suite and is not a Zend improvement; and the remaining open
  migration, Tor, release, FFI, and dependency PRs remain draft, blocked,
  review-required, stale, or too broad. The focused #1896 sentinel repair remains
  independently carried in Zend draft [#35](https://github.com/just-zend/zcash-swift-wallet-sdk-zend/pull/35).

## Bleeding-edge refresh (2026-08-03)

- Fresh fetches leave `origin/main=4497fe9e` and `upstream/main=f51ed74a`, with the same
  `174 87` divergence. Zend draft PR [#34](https://github.com/just-zend/zcash-swift-wallet-sdk-zend/pull/34)
  remains the only full-default-branch source-parity vehicle; it is still blocked on the voting
  FFI/source mismatch, provenance review, and funded-device migration evidence.
- Upstream [#1896](https://github.com/zcash/zcash-swift-wallet-sdk/pull/1896) was retargeted to
  `feature/ironwood-slipstream` and is therefore dirty and review-required there. Its three-file
  `decrypt-and-store` FFI sentinel fix was independently verified against Zend's current ABI
  (`1` success, `-1` failure) and carried as Zend draft
  [#35](https://github.com/just-zend/zcash-swift-wallet-sdk-zend/pull/35). The carry deliberately
  excludes the migration/release line and does not change the FFI artifact.
- The active Slipstream branch now includes the broad migration-parity stack, so #1895 and all
  remaining migration/FFI candidates stay wait-for-upstream. New maintenance PR #1933 is a
  review-required, blocked Makefile-only change against `maint/v2.7.x`; do not carry it before
  upstream integrates it into a Zend-compatible release line.

## Bleeding-edge refresh (2026-08-02)

- Fresh fetches leave `origin/main=4497fe9e` and `upstream/main=f51ed74a`, with
  merge base `769809a2` and the same `174 87` divergence. Zend draft PR
  [#34](https://github.com/just-zend/zcash-swift-wallet-sdk-zend/pull/34) now
  contains a conflict-resolved merge through `f51ed74a`; its build, SwiftLint,
  and workflow zizmor checks succeeded. It remains a draft pending review of the
  19 conflict resolutions, exact FFI/provenance reconciliation, and funded-device
  migration evidence. Do not create a competing default-branch parity vehicle.
- Upstream PR [#1923](https://github.com/zcash/zcash-swift-wallet-sdk/pull/1923)
  advanced to `ffda00dd`; it is clean and its build, SwiftLint, and zizmor checks
  are green. It is nevertheless not an early Zend carry: 40 files (+8,587/-2,197)
  replace migration-state logic and modify Rust/Swift FFI, private-engine and
  librustzcash pins, persistence, scheduling, generated mocks, and tests atop the
  unmerged `feature/ironwood-slipstream` line. Treat it as part of the full
  artifact-provenance and funded-device reconciliation.
- No other active upstream PR or branch clears the ready, useful, and low-risk
  gate: #1914 is an approved release-line merge awaiting upstream integration;
  #1925-#1927 are dirty, blocked, or draft; #1893 and #1900 remain draft and
  dependency-coupled; and #1895-#1898 are not clean against their maintenance or
  Ironwood bases. Wait for upstream integration or a scoped Zend-specific need.
- This is a documentation-only monitor record. No SDK source or FFI artifact
  changed, so local `swift build` and `swift test --filter OfflineTests` were not
  rerun.

## Bleeding-edge refresh (2026-08-01)

- Fresh fetches leave `origin/main=4497fe9e` and `upstream/main=f51ed74a`; the
  merge base remains `769809a2` and the parity relationship remains `174 87`.
  Draft Zend PR `#33` at `13121500` is still the sole clean reconciliation tracker;
  it deliberately contains only the decision record, not the upstream source range.
- PR `#1923` advanced and its build, SwiftLint, zizmor, and proto checks are now
  green, but it remains changes-requested. Its 17-commit, 39-file review branch is
  still the broad RC/Ironwood migration-state-machine and FFI reconciliation line,
  so green CI does not make an isolated Zend carry safe.
- PR `#1914` is approved, clean, and green, but it would bring the 23-commit v2.8
  maintenance/release line to upstream `main`, including `Cargo`, `Package.swift`,
  and FFI release changes. Wait for upstream to land that release line and fold it
  into the same provenance-verified reconciliation rather than carrying it early.
- PRs `#1926` and `#1927` remain blocked/draft on the RC `Proposal` schema and
  generated-proto line; `#1925` remains conflicting release-script work; and
  draft PR `#1898` remains conflicting despite green checks. None clears the ready,
  useful, and low-risk early-carry gate.
- This is a documentation-only monitor record. No SDK source or FFI artifact changed,
  so `swift build` and `swift test --filter OfflineTests` were intentionally not run.

## Bleeding-edge refresh (2026-07-31)

- Fresh fetches leave `origin/main=4497fe9e` and `upstream/main=f51ed74a`; the
  merge base remains `769809a2` and the parity relationship remains `174 87`.
  Draft Zend PR `#33` at `7a7936d2` is still the sole clean reconciliation tracker;
  it deliberately contains only the decision record, not the upstream source range.
- No newly active upstream PR or branch clears the ready, useful, and low-risk
  early-carry gate. PR `#1923` is changes-requested with a failed build and rewrites
  the migration state machine across the RC.5/Ironwood/FFI family. Its branch is
  162 commits and 120 files ahead of its merge base with `upstream/main`; wait for
  upstream stabilization and a Zend source/artifact reconciliation.
- PR `#1926` (`Proposal.spendsLegacyOrchardFunds`) is blocked and review-required.
  Although its endpoint is only ten files, it is stacked on the 2.7/2.8 RC dependency,
  FFI, and `Proposal` schema line. Draft PR `#1927` likewise carries a temporary
  librustzcash pin and generated proposal-proto changes. Neither can be isolated from
  Zend's provenance-locked engine and XCFramework contract.
- PR `#1925` is dirty and review-required while unifying release scripts across 36
  files. Merged maintenance-line work `#1905` and `#1922` remains unmerged into
  upstream `main`, so it is not a safe substitute for the release/FFI reconciliation.
  Draft PR `#1898` remains dirty despite approval and green checks; its Tor-off
  submission semantics should wait for its upstream release-line decision.
- This is a documentation-only monitor record. No SDK source or FFI artifact changed,
  so `swift build` and `swift test --filter OfflineTests` were intentionally not run.

## Bleeding-edge refresh (2026-07-30)

- Fresh fetches leave the default branches unchanged: `origin/main=4497fe9e` and
  `upstream/main=f51ed74a`. The parity relationship remains `174 87` at merge base
  `769809a2`; `upstream/main` is not an ancestor of Zend `main`. Draft Zend PR `#33`
  remains the sole clean reconciliation tracker and deliberately does not claim to
  carry the 87 upstream-only commits.
- Upstream published `2.7.0-rc.4` and `2.8.0-rc.3` release/FFI branches and advanced
  `maint/v2.7.x`, `maint/v2.8.x`, and `feature/ironwood-slipstream`. These versioned
  lines remain part of the blocked migration/FFI reconciliation, not a compatible
  Zend source or artifact update. Upstream PR `#1914`, which would merge the v2.8
  maintenance line to `main`, is still blocked and review-required despite green
  checks.
- No early carry meets the ready, useful, and low-risk gate. Upstream PR `#1923` is a
  32-file migration-state-machine rewrite with a failing build, atop the 154-commit
  Ironwood/Slipstream branch. PR `#1922` is clean and green but stacked on 24 commits
  of the `2.7.0-rc.3` and Ironwood/FFI family; its apparently small change exposes
  `v_transactions` fields (`poolCrossingValue`, `isTrusted`, and Ironwood) that must
  be supplied by the reconciled Rust schema and FFI artifact, so it cannot safely be
  cherry-picked into Zend's provenance-locked baseline.
- The related AGENTS.md/CLAUDE.md stacked PRs `#1917` through `#1919` are blocked or
  changes-requested, while the older maintenance fixes (`#1896`, `#1897`, `#1900`, and
  draft/dirty `#1898`) remain unsuitable in isolation. PR `#1895` is dirty on the
  Ironwood branch and draft `#1893` remains the broad, blocked Slipstream migration
  stack. Preserve Zend's exact engine revision and committed XCFramework until the
  combined source/artifact reconstruction and funded-device migration proof are done.
- This is a documentation-only decision record. No SDK source or artifact changed, so
  `swift build` and `swift test --filter OfflineTests` were intentionally not rerun.

## Current monitor status (2026-07-27)

- Fresh fetches confirm both defaults are `main`; `origin/main` is `4497fe9e` and
  `upstream/main` is `f51ed74a`. The parity count is `174 87`: Zend is 174 commits
  ahead, while upstream is 87 commits ahead, with merge base `769809a2`. No Zend
  parity PR currently covers this newer upstream line.
- The upstream delta is a broad `2.5.x`/`2.7.x`/`2.8.0-rc.1` release-and-Ironwood
  lineage. It adds the lightwallet-protocol v0.5.0 subtree, replaces major Rust
  migration and voting surfaces, updates generated gRPC code, and includes the
  released RC FFI workflow. It cannot be treated as a routine source-only sync
  because Zend's default branch has a separately reviewed, provenance-locked
  Ironwood migration engine and committed three-slice XCFramework.
- A no-commit merge into `codex/zcash-upstream-sync-2026-07-27` was intentionally
  aborted after it exposed 19 conflicts: `Cargo.toml`, `Cargo.lock`, `Package.swift`,
  `rust/src/lib.rs`, `rust/src/migration.rs`, `rust/src/tor.rs`, generated gRPC
  sources/protos, generated errors/mocks, and the Zend Ironwood checkpoint, wallet,
  and welding surfaces. Do not resolve these by choosing upstream or Zend wholesale.
  First produce a provenance-verified FFI artifact that reconciles the exact migration
  engine, librustzcash graph, public API, fixtures, and funded-device migration proof;
  then re-run this merge with an explicit compatibility design.
- No bleeding-edge early carry is safe. Upstream PR `#1885` is a draft, dirty,
  81-file Ironwood/protocol/proving/voting stack; `#1818` is a clean but 49-file
  Slipstream layer atop its own evolving base; and `#1872`/`#1853` are dirty child
  branches of that migration family. Dependabot PRs remain blocked/review-required.
  Wait for upstream convergence and Zend artifact reconciliation rather than splitting
  individual fixes out of these coupled stacks.

## Bleeding-edge refresh (2026-07-29)

- Fresh fetches leave the default branches unchanged: `origin/main=4497fe9e` and
  `upstream/main=f51ed74a`, with `174 87` commits in `origin/main...upstream/main`
  and merge base `769809a2`. `upstream/main` is still not an ancestor of Zend's
  default branch. Draft Zend PR `#33` remains the single clean reconciliation tracker;
  it does not claim to contain the 87 upstream-only commits.
- Upstream's release and maintenance lines advanced to `2.7.0-rc.3` and
  `2.8.0-rc.2`, including `release/ffi-2.8.0-rc.2`, while `upstream/main` did not
  advance. These branches are part of the same versioned Ironwood/FFI release family,
  not a substitute for a Zend-compatible source or artifact reconciliation.
- No newly reviewed early carry meets the ready, useful, and low-risk gate. `#1905`
  is dirty with changes requested against `maint/v2.7.x`; `#1896` and `#1897` are
  likewise dirty and review-required. Draft `#1900` remains review-required, and
  draft `#1898` is dirty despite approval and green checks; its Tor-off sequential
  submission change alters multi-endpoint submission semantics on `maint/v2.8.x`.
- The Ironwood line is still explicitly out of scope for an isolated carry: `#1895`
  is dirty atop `feature/ironwood-slipstream`, while draft `#1893` is blocked and
  review-required for the Orchard-to-Ironwood/Slipstream stack. Blocked Dependabot,
  Tor/privacy, release, and older FFI branches also lack the required upstream
  stabilization or narrow Zend-compatible surface. Preserve the provenance-locked
  migration engine and committed XCFramework until upstream convergence, a compatible
  artifact rebuild, and funded-device migration proof are available.
- This update is documentation-only. It deliberately does not rerun `swift build` or
  `swift test --filter OfflineTests`; no SDK source or FFI artifact changed.

## Bleeding-edge refresh (2026-07-28)

- Default-branch heads remain `origin/main=4497fe9e` and `upstream/main=f51ed74a`;
  the `174 87` parity gap and the reconciliation gate above are unchanged. Zend draft PR
  `#33` remains the single clean documentation vehicle for that blocker.
- New upstream maintenance-line fixes are not early carries. `#1896` (decrypt-and-store
  FFI error sentinel) and `#1897` (witnesses-fix version gate) are each dirty and
  review-required against `maint/v2.7.x`; `#1904` explicitly must not merge, is blocked,
  and its build fails while pinning a different `librustzcash` revision. `#1905` is also
  dirty and review-required against `maint/v2.7.x`.
- `#1898` (sequential submissions with Tor off) is clean, approved, and green, but is
  still a draft against `maint/v2.8.x` and changes multi-endpoint submission semantics.
  Wait for its upstream release-line decision and a compatibility review rather than
  cherry-picking it into Zend's provenance-locked Ironwood baseline. Draft `#1900` is
  likewise dirty despite green checks, and `#1895` is dirty atop the Slipstream/Ironwood
  branch. None satisfies the ready, useful, and low-risk early-carry threshold.

## Current monitor status (2026-07-26)

- After fetching both remotes, both default branches remain `main`; `origin/main` is
  `203473ba` and `upstream/main` is `769809a2`. The parity count is `173 0`, and
  `upstream/main` is an ancestor of `origin/main`: Zend PR `#32` merged the six-commit upstream
  delta, including `InitializationResult.seedNotRelevant` and upstream's new security guidance.
- PR `#32` resolved documentation-only conflicts while preserving the Zend-specific guidance in
  `AGENTS.md`; its Build and Run Offline Tests and SwiftLint checks passed. It also means Zend iOS
  callers that exhaustively switch over initialization results need a `seedNotRelevant` arm when
  they adopt this SDK revision. This documentation-only monitor refresh did not rerun local Swift.
- The refreshed early-carry scan still has no safe candidate. PR `#1872` is clean but adopts the
  published migration engine RCs and crossing-value accessors (54 commits / 81 files); its coupled
  `#1812` Synchronizer and `#1813` FFI stack remains dirty or blocked/review-required. The approved
  `#1853` opportunistic-proving branch is still dirty and carries the same migration family.
- The active PCZT-v6 wallet-spend branch is 46 commits / 57 files ahead and explicitly tracks the
  full RC.4 stack for device verification; do not split a derivation fix from its release, engine,
  and device-validation dependencies. `michal/slipstream-support` is 119 commits / 123 files ahead.
  These candidates change public API, Rust/FFI, persistence, privacy gates, generated mocks, or the
  engine family, so wait for an upstream merge plus Zend artifact/provenance reconciliation.
- Release branches are also wait-for-upstream: draft `#1854` is blocked with checks in progress and
  `#1856` is blocked/review-required with its build in progress. Draft `#1848` remains blocked with
  a failing SwiftLint check. Existing protocol, dependency, release, and older migration PRs remain
  in their draft, blocked/review-required, dirty, failed, or broad-scope wait-for-upstream classes.

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

### Upstream refresh (2026-07-17)

- Fresh refs showed `origin/main...upstream/main` at `160 2`; upstream `main` advanced from
  `d92a7940` to `7744bcec` through upstream PR `#1811`.
- The two newly reachable commits are `7f5a266c` and merge commit `7744bcec`; together they add
  one `CLAUDE.md` instruction to run `cargo fmt` before Rust changes are committed.
- Zend branch `codex/zcash-upstream-sync-2026-07-17` merged `upstream/main` automatically with
  no conflicts and no Zend-specific code or branding adaptation. It preserves Zend's existing
  release artifacts, private-engine provenance controls, and Ironwood hardening behavior.
- Run the Swift build and offline tests on the Zend merge branch before merging the parity PR.

### Upstream refresh (2026-07-20)

- Fresh refs show fork/upstream defaults remain `main`. `origin/main` is `ee3abea2` and
  `upstream/main` is `89d85c49`; `git rev-list --left-right --count origin/main...upstream/main`
  returns `160 4`.
- Existing draft Zend PR `#26` remains the single parity vehicle. Its branch merged upstream through
  `89d85c49` with no manual conflict resolution, preserving Zend artifact URLs, private-engine
  provenance controls, branding, and Ironwood behavior. The newly adopted upstream PR `#1815`
  changes `LICENSE` to the Znewco, Inc. copyright holder and removes `LICENSE` from the Swift
  workflow's ignored paths so license-only changes run the required build check.
- Verification on the parity branch passed: `git diff --check origin/main...HEAD`, `swift build`,
  and `swift test --filter OfflineTests` (546 tests, 0 failures). The shared workspace has about
  9 GiB free; the prior SwiftPM dependency-resolution failure was caused by disk exhaustion.

### Upstream refresh (2026-07-21)

- Zend PR `#26` merged at `8f85838b`, so `origin/main` now contains upstream `main` through
  `89d85c49` / upstream PR `#1815`; fetched parity is `168 0` and no default-branch merge is due.
- The only fresh upstream branch activity is a force-pushed final-engine migration stack:
  `michal/MOB-1455/MOB-1495-sdk-pool-migration` is 36 commits ahead / 93 files,
  `...-ffi` is 26 commits ahead / 79 files, and the unscoped `michal/slipstream-support` is
  45 commits ahead / 117 files. None is a low-risk early Zend carry because it replaces the
  protocol-facing migration, FFI, persistence, and generated-test surface that Zend currently
  validates against committed, provenance-locked artifacts.
- This documentation-only monitor update did not rerun local Swift commands. Reuse the successful
  PR `#26` build and OfflineTests result above; run the full artifact/provenance and funded-wallet
  validation before considering any future migration-stack adoption.

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

- On 2026-08-10, upstream `main` advanced from `468d1e9f` to `a1234039` by merging the
  Ironwood/Slipstream stack (upstream PR `#1954`) and its migration, FFI, generated-code, and
  CI dependencies. Zend draft PR `#34` reuses `codex/zcash-upstream-sync-2026-08-01` and merges
  this range cleanly at `93b4a858`; do not create a competing parity branch. The source requires
  the corresponding Ironwood/Slipstream `libzcashlc` header and XCFramework. Zend's current
  released binary lacks the new migration and Slipstream declarations, so `swift build` fails on
  symbols including `FfiMigrationProgress` and `zcashlc_slipstream_open`. Keep PR `#34` draft
  until the exact `librustzcash` / `slipstream-internal` provenance is reconciled with Zend's
  private-engine policy, all required arm64 artifacts are rebuilt and verified, and funded-device
  migration evidence is available.
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

## Bleeding-edge snapshot (2026-07-16; refreshed 2026-07-20)

Current carry decisions:

- Upstream PR `#1813` (pool-migration FFI/welding) and PR `#1812` (pool-migration Synchronizer
  surface) are non-draft, clean, and currently green, but are one coupled Orchard-to-Ironwood
  migration stack. Relative to `upstream/main`, `#1813` spans 76 files (+7,946/-4,338) and `#1812`
  spans 90 files (+13,767/-4,378), including Rust FFI, a `librustzcash` family-pin advance,
  generated protobuf/mocks, public Synchronizer APIs, persistence, privacy gates, and migration
  orchestration. Zend's existing committed-artifact/private-engine contract needs an explicit
  reconciliation plan and artifact verification first; do not carry either ahead of upstream.
- The unreviewed `michal/slipstream-support` branch was force-pushed to `22633349`; it is 37
  commits ahead and 4 behind `upstream/main`, with 114 files changed (+20,706/-4,589). It layers
  Slipstream on the migration stack and has no scoped upstream PR, so it is not an early-carry
  candidate.
- `#1810` remains draft, blocked, and review-required; `#1807` remains blocked and
  review-required. Dependabot, Dandelion++, older FFI, and release-workflow branches continue to
  lack the combined readiness, narrow scope, and Zend roadmap value required for an early carry.

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
  and PR `#21` merged as `02f9a78e`; `origin/main` remains through upstream `d92a7940` / PR `#1802`
  plus the current Ironwood SDK baseline and Swift CI optimization.
- Upstream advanced through `7744bcec` / PR `#1811` (a one-line `CLAUDE.md` pre-commit-formatting
  instruction). Draft Zend PR `#26` (`codex/zcash-upstream-sync-2026-07-17`) cleanly merges those
  two upstream commits; its GitHub `build` check passed. As of this review,
  `git rev-list --left-right --count origin/main...upstream/main` returns `160 2`, so leave PR `#26`
  as the parity vehicle until it is reviewed and merged.

Open upstream PRs assessed as not ready to carry right now:

- `#1813` and `#1812` (`michal/MOB-1455/MOB-1495-sdk-pool-migration-*`): non-draft, clean, and
  green, but jointly a 90-file Orchard-to-Ironwood migration stack. They change the public
  `Synchronizer` API, Rust dependency family and FFI, migration privacy gates, persistence,
  generated mocks, and OfflineTests. Zend already has a separately reviewed Ironwood baseline, so
  wait for an upstream merge plus an explicit artifact/reconciliation plan rather than carry this
  protocol-facing stack early.
- `#1810` (`kris/lwd-network-privacy`): draft, `BLOCKED`, and review-required, despite green
  build and zizmor checks. It replaces the Tor wrapper with the Rust network-privacy layer, so it
  has runtime and dependency impact; wait for upstream API stabilization and review before Zend
  considers it.
- `#1807` (`michal/ironwood-support-2.6.0`): non-draft, `BLOCKED`, review-required, and green,
  but it is an 18-commit Ironwood receive/sync, custom-network, FFI, and voting stack. Zend already
  has an independently validated private-engine/FFI baseline; wait for upstream review and a
  reconciliation plan instead of carrying this broad stack early.
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
- `michal/MOB-1455/MOB-1495-sdk-pool-migration`: 4 commits ahead and 29 behind `upstream/main`;
  covered by upstream PR `#1812`, now clean and green but still broad across public `Synchronizer`,
  FFI, Rust dependency, migration privacy, and persistence surfaces. Wait for upstream merge, a
  released FFI artifact, and a Zend reconciliation plan.
- `michal/slipstream-support`: 37 commits ahead and 4 behind `upstream/main` after a force-push; no
  upstream PR is open for this active branch. It is unreviewed Slipstream integration work, so do
  not carry it until a scoped PR, review thread, and stable public artifact direction exist.
- `michal/ironwood-support-2.6.0`: 18 commits ahead and 2 behind `upstream/main`; covered by open
  upstream PR `#1807`, which is green but review-required and broad across protocol, FFI, and
  voting surfaces. Wait for upstream merge/reconciliation rather than carrying it ahead.
- `kris/lwd-network-privacy`: 5 commits ahead and 173 behind `upstream/main`; covered by draft
  upstream PR `#1810`, so wait for its runtime/network-privacy API to stabilize.
- `michal/MOB-1455-ironwood-migration-prototype-ffi`: 11 commits ahead and 7 behind `upstream/main`; covered by draft upstream PR `#1793`, build-failing, and still protocol-facing FFI work, so wait for upstream review and green CI.
- `release-ci`: 4 commits ahead and 165 behind `upstream/main`; release branch integration artifact, not a clear standalone carry target.
- `rust-build-plugin`: 2 commits ahead and 1114 behind `upstream/main`; stale draft build-plugin work covered by upstream PR `#1443`.
- `shielded-vote-2.4.10`: 1 commit ahead and 110 behind `upstream/main`; specialized voting branch with unclear Zend product priority.
- `testing/note_spendability_improvements`: 6 commits ahead and 223 behind `upstream/main`; draft test-only branch covered by upstream PR `#1700`.

## Bleeding-edge refresh (2026-08-06)

- Default branches remain `origin/main` at `4497fe9e` and `upstream/main` at `468d1e9f`.
  The default-branch range remains `174 111`; Zend draft PR `#34`
  (`codex/zcash-upstream-sync-2026-08-01`) already contains `upstream/main`, so it remains the
  only full-parity vehicle. Do not open a duplicate sync branch.
- Upstream PR `#1955` is clean and approved, but its one-file Keystone batch-signing redaction test
  changes `rust/src/migration_keystone.rs`, which Zend's provenance-locked migration engine does
  not carry. It is not independently applicable; wait for the coherent upstream migration stack
  and artifact reconciliation.
- Upstream PR `#1956` adds Rust unit-test gating in `swift.yml` and `Makefile`, but is blocked and
  review-required on the `maint/v2.7.x` line. It needs upstream approval plus a Zend-specific CI
  and private-engine test-cost review before any adaptation; retain Zend's SHA-pinned actions,
  read-only permissions, and disabled persisted credentials if it is later carried.
- Upstream PR `#1957` and active `feature/ironwood-slipstream` descendants remain a blocked,
  review-required migration/librustzcash stack. The current PR spans Swift migration APIs, FFI
  welding, generated mocks, Rust migration logic, and locked dependencies, so it cannot be
  cherry-picked ahead of upstream. Upstream PR `#1942` deletes Darkside coverage and has no Zend
  testing benefit.

No newly active upstream PR or branch is simultaneously ready, useful, and low-risk for an early
Zend carry. Continue to route the focused decrypt sentinel fix through Zend PR `#35`, and retain
funded-device migration evidence as a prerequisite for the full-parity PR `#34`.

## Bleeding-edge refresh (2026-08-08)

- Default branches remain `origin/main` at `4497fe9e` and `upstream/main` at `468d1e9f` after a
  fresh fetch. Their divergence remains `174 111`; Zend draft PR `#34`
  (`codex/zcash-upstream-sync-2026-08-01`) contains the upstream tip (`177 0` against
  `upstream/main`) and remains the sole parity vehicle.
- Upstream PR `#1953` is draft, even though it is clean and approved. It repins `librustzcash` and
  changes batch-prove/outlook and adapter behavior on top of `feature/ironwood-slipstream`; Zend's
  provenance-locked migration engine and artifact do not make it independently applicable.
- Upstream PR `#1954` remains blocked and review-required while proposing the full
  `feature/ironwood-slipstream` merge to `main`. Upstream PR `#1957` is also blocked and
  review-required, and advances the same migration lanes and dependency graph. Do not carry either
  ahead of upstream.
- Newly advertised `fable/f1-span-rate-estimator`, `fable/gardening-test`, and force-updated
  `kris/advance-driven-migration` all contain the large Ironwood/Slipstream migration, FFI,
  generated-code, and `librustzcash` graph. They are neither narrow nor independently verifiable
  against Zend's committed private-engine artifact; wait for upstream integration, provenance
  reconciliation, and funded-device migration evidence.
- Upstream PR `#1956` is now approved but targets the `maint/v2.7.x` maintenance line. Its Rust
  test-gate workflow change is not a Zend early-carry candidate; any later adaptation must retain
  Zend's SHA-pinned actions, read-only permissions, and disabled persisted credentials.

No new upstream-main commit or carry-worthy bleeding-edge work was found. Do not create another
parity branch or run Swift validation for this documentation-only tracker update.

## Bleeding-edge refresh (2026-08-11)

- After a fresh fetch, both defaults remain `main`: `origin/main=4497fe9e` and
  `upstream/main=ee7b05c9`; their divergence is `174 398`. Existing Zend draft PR `#34`
  (`codex/zcash-upstream-sync-2026-08-01`) now contains the exact upstream tip at
  `013a024d`. It remains the sole full-parity vehicle; do not create a duplicate.
- The upstream `#1955`, `#1957`, `#1958`, and `#1959` integration sequence updated the
  Ironwood/Slipstream migration and released `librustzcash` graph. The parity merge had one
  `Cargo.toml` conflict; it takes upstream's released `13ce6c4e` pin instead of retaining
  Zend's superseded interim pin. Zend's private-engine artifact and release gate remain intact.
- `swift build` on `#34` still fails before tests because Zend's released XCFramework header and
  binary lack the new migration and Slipstream FFI declarations, including
  `FfiMigrationProgress`, `zcashlc_slipstream_open`, and `zcashlc_slipstream_snapshot`.
  Do not run OfflineTests until a provenance-verified matching arm64 XCFramework is built,
  release wiring is updated, and funded-device migration evidence is captured.
- Open PRs `#1961` (send-max), `#1960` (post-merge Cargo.lock repair), `#1944`, `#1895`,
  `#1893`, and the Dependabot set are not independent Zend carries. They are feature work,
  maintenance-line-only, migration/artifact-coupled, draft or review-required, or broad
  dependency updates. No candidate is ready, useful, and low-risk enough to carry early.

## Bleeding-edge refresh (2026-08-13)

- Fresh fetch confirms both defaults remain `main`: `origin/main=4497fe9e` and
  `upstream/main=ee7b05c9`, with divergence `174 398`. Zend draft PR `#34`
  (`codex/zcash-upstream-sync-2026-08-01`) remains `179 0` against `upstream/main`, and
  ancestry confirms it contains the exact upstream tip. It is still the only full-parity
  vehicle; do not create a duplicate.
- New upstream PR `#1968` is `DIRTY` and is stacked on `dw/missing-entity-repro`, not `main`.
  Its submit-plan staleness fix depends on a database-level missing-transaction reproduction;
  wait for the upstream stack to land and for the Zend migration/artifact reconciliation.
- New upstream PR `#1964` is clean but is an explicit ZODL Slipstream vendoring and dual
  MIT/AGPL artifact design. It changes release tooling, CI, Rust FFI, a separate
  `ZODLSlipstream` product, and licensing documentation. It is neither a Zend-original
  improvement nor a safe SDK parity carry; do not import it or apply a Zend label.
- Active `chp-re-enable` / PR `#1962` is 10 commits ahead of `main`, `BLOCKED`, and changes
  voting, Rust/Swift FFI, dependency pins, and public migration constants. `#1961` remains
  blocked send-max API work, while the active readback/send-error branches are descendants of
  the non-default Ironwood stack. None is independently ready or low-risk.
- The still-active `feature/ironwood-slipstream`, `pacu/zodl-slipstream-vendoring`, and
  private Slipstream branches remain coupled to the same private-engine, FFI artifact,
  licensing, and funded-device migration gates. Dependabot and maintenance-line branches stay
  review- or merge-blocked. No early carry is appropriate, and no label changes are needed.
