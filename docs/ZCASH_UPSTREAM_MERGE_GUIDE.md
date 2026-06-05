# Zcash Upstream Merge Guide for Zend Fork

This document tracks how to safely sync `just-zend/zcash-swift-wallet-sdk-zend` with `zcash/zcash-swift-wallet-sdk`.

Last reviewed: 2026-06-05

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

## Zend divergence notes (as of 2026-06-05)

Current relationship from git graph:

- `upstream/main` commits missing in fork default branch: `10`
- Fork default branch commits not present in `upstream/main`: `32`

Notable fork-ahead work currently on `origin/main` includes:

- Release carry: Zend-specific `2.6.0-alpha.3` XCFramework release wiring plus the in-flight parity branch for upstream `2.5.2` and `2.6.0-alpha.4`.
- Broadcaster submit-plan recovery series (`adam/broadcaster-submit-plan` lineage).
- New-wallet birthday chain-tip behavior (`[#1673]` lineage).

Implication: upstream advanced again on 2026-06-05 after the first draft parity PR. The existing draft parity branch (`codex/zcash-upstream-sync-2026-06-04`, PR `#8`) should be refreshed in place by merging the upstream `2.6.0-alpha.4` release series while preserving Zend's fork-specific FFI release artifact in `Package.swift`.

## Conflict resolution heuristics

When conflicts occur:

- Keep upstream protocol/consensus correctness changes unless Zend has an audited override.
- Keep Zend-facing naming/branding and integration points where they intentionally differ.
- Prefer upstream tests and safety checks unless they break known Zend constraints.
- If uncertain, open draft PR with precise file-level blocker notes instead of forcing merge.


## Bleeding-edge snapshot (2026-06-05)

Merged upstream default-branch delta now pending in Zend fork default branch:

- `e552ea90` (`Update to released versions of orchard and librustzcash crates.`)
- `e725a248` (`Release zcash-swift-wallet-sdk version 2.5.2`)
- `9074047a` (`Merge remote-tracking branch 'upstream/release/ffi-2.5.2' into release/2.6.0-alpha.4`)
- `051d69ea` (`Merge remote-tracking branch 'upstream/release/ffi-2.6.0-alpha.3' into release/2.6.0-alpha.4`)
- `4320c158` (`Update CHANGELOG and Cargo.toml for 2.6.0-alpha.4 release.`)
- `bf15b731` (`Merge pull request #1751 from zcash/release/2.6.0-alpha.4`)
- `99866479` (`Release zcash-swift-wallet-sdk version 2.6.0-alpha.4`)
- `b0b39616` (`Merge pull request #1752 from zcash/release/ffi-2.6.0-alpha.4`)
- `a5523282` (`Merge pull request #1750 from zcash/merge/2.5.2`)
- `af12e2c8` (`zcash-swift-wallet-sdk 2.5.2 post-release merge.`)

Zend parity branch note:

- `codex/zcash-upstream-sync-2026-06-04` / PR `#8` should absorb the upstream dependency/version updates through `b0b39616` (`Cargo.toml`, `Cargo.lock`, `CHANGELOG.md`) but preserve the Zend-specific binary target URL/checksum in `Package.swift` so the SDK continues to download the fork's `2.6.0-alpha.3` XCFramework release until Zend publishes a newer forked artifact.

Open upstream PRs assessed as not ready to carry right now:

- `#1746` (`kris/1745-finish-release-workflow`): non-draft, still review-pending, and CI/release workflow heavy.
- `#1737` (`adam/broadcaster-submit-plan`): non-draft but `DIRTY`; high-impact transaction-submit behavior.
- `#1733` (`main` -> `release/2.6.0`): explicit `[DO NOT MERGE]` draft stabilization preview.
- `#1700`, `#1638`, `#1637`, `#1592`, `#1579`, `#1443`: draft/WIP FFI and behavior changes with broad impact.
- `#1692`, `#1672`, `#1570`, `#1505`: non-draft but currently `UNKNOWN` or `DIRTY` in upstream, with no clear ready + low-risk carry signal.

No candidate currently meets all carry criteria (ready + useful + low risk) for Zend ahead-of-upstream adoption. The 2026-06-05 upstream PR list and unmerged-branch scan still did not surface any new ready-to-carry work beyond the merged `upstream/main` parity delta above.

Unmerged upstream branches without open PRs (not carried):

- `adam/update-zcash-voting-0.9.1-policy`: voting feature scope; no upstream PR/review thread yet.
- `adam/voting-round-recovery-ffi`: voting recovery feature; no upstream PR/review thread yet.
- `adam/voting-rust-lint-workflow`: workflow/lint only; limited direct Zend runtime value.
- `release/2.6.0-alpha.5`: new release-prep branch; not merged upstream yet and tied to upstream release sequencing.
- `roman/voting-delegation-workflow-swift-wrappers`: voting wrapper branch without an upstream PR/review thread yet.
- `ignore_worktrees`: housekeeping-only change; not urgent for Zend behavior.
- `release-ci`: release branch integration artifact; not a clear standalone carry target.
- `shielded-vote-2.4.10`: specialized voting branch with unclear Zend product priority.
