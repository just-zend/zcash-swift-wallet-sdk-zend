# Zend Ironwood migration consolidation

This note records the boundary for retiring both copies of
`ZODLIronwoodMigrationRust` (`just-zend` and `Chlup`) and moving the production stack to the
canonical pool-migration implementation in `librustzcash`.

## Canonical lineage

- Rust source of truth: `zcash/librustzcash`, carried through `just-zend/librustzcash` only for
  Zend improvements that are not upstream yet.
- Swift schema and API source of truth: the upstream migration work from SDK PRs #1807, #1812,
  and its included FFI PR #1813. The consolidation branch includes #1807 at `61be7e00` (merged to
  `release/2.6.0` as `ef6c3142`), #1812 at `daf1aa1b`, and #1813 at `adfe9ca7`.
- The upstream migration work is now split across exact FFI and Swift heads. The FFI lineage is
  `93ed4ed957df3c1962bad283cd588dc385f955a0` (#1825 proposal handles) ->
  `5960351ab1effc488009b426d441f67530f015f3` (Keystone codec) ->
  `e1fdd10eec9c97cdbee4e944d571ee38fa748ae9` (request-ID/firmware tests) ->
  `90306346725d2e45e9cc4d25cef62732c7e7fd09` (latest balance-reporting fix). The separate Swift
  line is reviewed at `37b03692c089c5cccd0ff5b5feafe1dcaaf4b312`, including surface commit
  `3c9d6cb9a00649489f7740abea608eae8ea8630e`. Zend preserves these as three exact two-parent
  merges (`ddcd9eca`, `98294cb7`, `d7047c50`); this does not imply upstream-main landing.
- #1825's exact schema is retained: a Rust-minted nonzero `PlanHandle` keys the latest preview for
  one database/account, a newer preview supersedes the former handle, and fresh commit/terminal
  rollover send only the handle across FFI. No caller-authored plan fields cross inward.
- SDK PR #1818 remains a draft. Preserve its non-conflicting canonical planner and transaction
  semantics underneath the Zend delivery runtime, but do not claim API parity: this branch does not
  expose #1818's raw-PCZT or ordinary-immediate orchestration as public migration authority.
- Upstream's dedicated Keystone Slipstream head `97d3dcea6205eb710dd8805154e131636535ccf0`
  is intentionally deferred. It includes a separate sync-engine/support dependency stack that the
  current Zend runtime does not use; importing it here would be an independent engine migration,
  not completion of the librustzcash consolidation. Reassess when upstream lands or scopes it.
- SDK PR #1823 was closed unmerged at head `450fda4f`. Its exact ordinary single-signer use of
  `zcash_client_backend::wallet::redact_pczt_for_signer` is retained as a Zend-only alignment and
  safety delta, not an active upstream carry. Migration batch signing instead keeps the exact
  upstream `5960351a` codec and FFI, including batch redaction, retained originals, ordered
  response correlation, request-ID validation, decoder reset, and firmware passthrough.
- The staging pin is immutable `just-zend/librustzcash`
  `1d63c9c07b0b40b3de633c8396008ff543464a01`, with Orchard 0.15.4. Every direct and patched
  librustzcash-family dependency exact-pins that reviewed commit, and the clean five-architecture
  XCFramework records it in provenance. That fork head contains current upstream
  `718610837e77d84449f0572dc0b4afe23429decb` plus Zend's reviewed delivery/runtime deltas.
- The upstream Keystone envelope graph is immutable in Zend releases: `ur` pins the exact commit
  `81b8bb3b6b3a823128489c81ffee5bb4001ba2ae` resolved by upstream's 0.3.3 tag, and `ur-registry`
  pins `7c90bf1ae504720c3f4b44ff26f996836d8b1553`. Both revisions are release-gated and recorded in
  artifact provenance; a moved tag or substitute Git source fails closed.
- Zend adds one versioned Keystone wrapper on top of the unchanged upstream bridge:
  `zcashlc_migration_keystone_build_sign_batch_qr_parts_v2` derives account ZIP 32 metadata in
  Rust and annotates only transient QR-input copies. Durable staged PCZTs stay byte-for-byte
  canonical, and the exact upstream batch combiner applies returned signatures to those originals.
  Swift keeps upstream's byte-oriented compatibility surface and adds a scheduled batch-of-one
  adapter: QR construction accepts only the request's private opaque claim, while signature apply
  uses the exact canonical PCZT retained by that same request before the existing claim-checked
  submit path consumes it.
- Upstream librustzcash PR #2751 released `pczt 0.8.0`, `zcash_primitives 0.30.0`, and
  `zcash_proofs 0.30.0`. Upstream `zcash_voting` has not yet advanced its 0.29 primitive
  requirement, so Zend carries a dependency-only bridge in `just-zend/zcash_voting`; it changes
  no voting source and is required to keep one PCZT/primitive type graph.
- `ZODLIronwoodMigrationRust` is no longer a dependency, schema authority, or release artifact.
  Archive both repositories only after all SDK/app consumers are repinned to the provenance-locked
  librustzcash build.

## Legacy-to-canonical mapping

| Legacy private contract | Canonical replacement or disposition |
| --- | --- |
| `MigrationSnapshot`, `runId`, `revision`, SDK snapshot validation | The standalone snapshot schema is retired, but its crash-safety capability is retained as an additive Rust-owned delivery snapshot. Upstream `MigrationState` remains the only planner/schedule/lifecycle authority. Rust mints the full 32-byte run identity with an OS CSPRNG, binds each delivery revision to the exact canonical-state fingerprint, and exposes both only through one account-explicit atomic runtime aggregate. Swift never composes a runtime snapshot from separate state, claim, finality, or cutover reads. Public state/progress/status reads first acquire that runtime snapshot, use the opaque scheduled-run handle for canonical chain reconciliation when present, and only then call the side-effect-free projection FFI. |
| SDK CAS over a shadow runtime row | Replaced by Rust delivery CAS layered on the canonical store, without a second planner or lifecycle row. Every control/claim mutation compares the exact canonical-state fingerprint, Rust run identity, semantic delivery revision and, after binding, exact policy fingerprint in the same SQLite transaction. A stale caller cannot overwrite a newer canonical or delivery transition. |
| `pause`, `resume`, `abandon`, and retry phases | Retained only as additive delivery control (`active`, `paused`, `abandoning`, `abandoned`) over the exact canonical run. They never rewrite the upstream schedule or transaction state machine. Abandonment is two-phase and may finish only after every potentially exposed artifact is mined or positively expired; the finishing write atomically applies the canonical failed/cancelled disposition and releases only the run's reservations. |
| SDK worker leases, claim tokens, and ownership rows | Retained in Rust, not in an SDK side table. Materialization, submission and outcome-resolution claims use Rust-minted 32-byte capability tokens and expiring leases bound to one exact canonical PCZT, canonical transaction fingerprint, run, revision and submission policy. Runtime snapshots contain only sanitized lease summaries; secret tokens and exact bytes are returned only to the worker that acquired/resumed the claim. |
| Durable `outcomeUnknown` phase | Retained and fail-closed. Once a transport call begins and its result is ambiguous, Rust persists `outcomeUnknown` for the exact transaction and permits only an outcome-resolution claim. The SDK must not resubmit or replace those bytes. Mining/current-chain lookup or positive consensus expiry resolves the record; only a proven known-unsent path may release a submission claim for later reacquisition of the same exact bytes. Wallet ingestion and duplicate-server responses remain useful reconciliation evidence, but idempotent database writes do not make an unknown network outcome safe to retry. |
| Persisted submission-policy fingerprint | Retained in Rust. The public call-level input stays the exact upstream `MigrationNetworkPrivacyOptions`; Rust owns the typed policy version, normalization, canonical encoding, validation, fingerprint and immutable binding before artifact materialization or submission. Direct canonical public-DNS TLS, public-DNS TLS through an isolated Tor proxy, canonical v3 onion transport, and explicit loopback development are distinct variants; literal and legacy numeric-IP spellings fail closed. Public TLS over Tor is never mislabeled as onion or silently downgraded to direct transport. Every later artifact/claim CAS matches the Rust fingerprint. |
| Private planner, denominations, schedule/timer schema | Dropped. `zcash_pool_migration` and `zcash_client_sqlite::pool_migration` own the plan, randomized heights, expiry, proving boundary, persistence, per-attempt rebuild, and progress schema. The host only displays canonical schedules and arms delivery from their heights. |
| Caller-field schedule validation | Replaced by upstream #1825's opaque `PlanHandle`. It is pre-commit, process-local, one-current-preview authority only. Zend keeps the exact upstream handle/cache semantics and adds a non-persistence rule: `MigrationSchedule.encode` omits the handle and every decode resets it to `0`, including payloads produced by prerelease builds that contained a nonzero value. A restored schedule must be re-proposed. Durable post-commit authority remains the separate Rust run/revision/claim capability and is never inferred from the plan handle. |
| SDK-owned immediate-run table | Dropped as authority. The upstream immediate proposal remains the transaction/economics source, while Rust creates the additive `immediate` delivery lane and reserves its exact inputs before any signing or network exposure. Rust derives the proposal's exact gross Orchard input value and rejects it above the caller's explicit ceiling before any authority write. Delivery schema v2 persists that ceiling as versioned authority in the same transaction. A prerelease v1 pre-exposure row has no numeric authorization evidence and is projected as `missingSpendAuthorization` recovery; Swift must not manufacture a ceiling from balance, total supply, or legacy consent. An exact unexposed known-unsent failure may be reauthorized only through a recovery-only API with the opaque capability issued by the snapshot that rendered the action and a newly supplied sufficient ceiling. The capability has a stable hidden account/artifact/signer/revision seal for fresh-clone comparison and retains the exact Rust claim handle for final CAS. A fresh read gates state but cannot mint replacement recovery intent; same account/signer/display state is insufficient. Generic create/resume entry points reject `materializationFailed` and never fall through to fresh reservation. Already exposed legacy rows retain outcome/finality reconciliation but receive no new submission power. The same claim, policy, recovery and finality rules apply; Swift does not infer immediate state after broadcast or use a side row to mask canonical `Complete`. |
| SDK invalid/rejection marks | Dropped as authority. Exact canonical transaction state plus Rust delivery failure/outcome records drive recovery. Any retired SDK table is read only as strict cutover evidence and is never consulted as live state. |
| Wallet ingestion before exposure | Retained additively inside claim-backed Rust finalization. Rust atomically extracts, stores, and binds the exact transaction and txid before Swift can create a network transport; Swift can copy only the exact bytes and identity carried by the opaque claim. A storage or binding failure is pre-submit and fail-closed. |
| Sync/broadcast separation | Canonical wallet-scope overdue/post-broadcast gate blocks `start()`, and broadcast entry points reject an already-syncing synchronizer. The app's `TransactionGuard` owns session sequencing. The SDK check is still point-in-time, not an atomic session permit. |
| Reorg/finality lifecycle | Upstream `MigrationState.complete` is preserved verbatim: it means every transaction in the stored run is mined, not that destination value is spendable and not that source reservations may be released. Rust adds separate destination-spendability and source-reservation projections. Once the Ironwood output is scanned and normally spendable, ordinary sends may proceed while the exact Orchard source reservations remain locked through the fixed 101-confirmation horizon. Rust supplies the release height; Swift never recalculates it. A rewind before or beyond that boundary reopens delivery or enters explicit fail-closed recovery, and a deep rewind after finality blocks ordinary spending rather than silently recreating value. |
| Retired standalone schema | No legacy plan, reservation, PCZT or transaction is imported. Absence of exact `ext_ironwood_migration_*` objects is `fresh`; any such object is immutable recovery evidence and makes runtime/new-run/ordinary-spend authorization fail closed until explicit recovery. There is no automatic `restartEligible` path. |
| Residual lock lifecycle | Residual locks remain a distinct deterministic owner and can be removed only by exact owner-scoped output references in one wallet transaction. Migration, ordinary-PCZT and foreign-owner locks survive. Residual operations must honor the atomic runtime recovery/finality verdict; canonical `Complete` by itself is not permission to release a migration source reservation. |

### Swift and Zend iOS call-site mapping

| Retired SDK/app call | Claim-backed replacement |
| --- | --- |
| `migrationSnapshot(for:)` | `migrationRuntimeSnapshot(accountUUID:)`. Map the canonical summary, runtime availability, delivery phase/finality and sanitized claims; never persist or synthesize an authority token. |
| `previewImmediateMigration(for:)` | Removed without a fake adapter. Immediate selection/economics become authoritative only inside atomic reservation. Gradual UX may continue to display `proposeMigrationTransfers`; immediate confirmation proceeds directly to the signer-specific submit flow. |
| `proposeImmediateMigrationIntent` then `commitMigrationIntents` | New work starts with `submitImmediateMigration` and an explicit maximum gross amount for an SDK-held key, or `prepareImmediateMigrationForExternalSigning` with that ceiling then `submitExternallySignedImmediateMigration` for hardware signing. A displayed exact known-unsent materialization failure instead uses its snapshot-issued `ImmediateMigrationRecoveryCapability` with the signer-specific `recoverFailedImmediateMigration...` API; these recovery calls cannot reserve a new run. |
| Scheduled `commitMigrationIntents` | `signAndStoreMigrationSchedule` for the SDK signer. For an external signer, call `commitMigrationScheduleForExternalSigning`, then round-trip each opaque request through `prepareNextMigrationTransactionForExternalSigning` and `submitExternallySignedMigrationTransaction`. The public schedule supplies only its opaque pre-commit `proposalHandle` to Rust; ids, amounts, heights, and duration stay display-only. No raw-PCZT array API remains public. |
| `executeNextMigrationAction` with app-held `runId`/revision | `executeNextPendingMigrationTransfer(accountUUID:options:)`, bracketed by fresh runtime snapshots. Rust selects the due canonical transaction, binds policy, claims/proves exact bytes, submits once, and records the typed outcome. |
| App handling of `outcomeUnknown` by retry | No resubmission. The runtime exposes the sanitized unknown state and Rust grants only an outcome-resolution claim until scan evidence settles it. |

There is deliberately no compatibility adapter that recreates `MigrationSnapshot`,
`MigrationIntentSchedule`, or numeric revision CAS from the new runtime. Such an adapter would
invent authority outside Rust and could not truthfully reproduce a read-only immediate proposal.

## Retained Zend deltas

The Zend fork should keep only deltas that layer on the upstream representation:

1. Rust-owned exact-PCZT input locking plus canonical-state-fingerprint/run/revision/policy CAS for
   every delivery control, claim, lock/release and whole-state persistence operation, including
   exact expired-attempt rebuild and two-phase abandonment ownership cleanup.
2. The ordinary-spend pool boundary: before NU6.3, Sapling and Orchard may fund ordinary sends;
   after NU6.3, Sapling and Ironwood may fund them, with target-boundary failures closed.
3. Finalization-time ordinary-PCZT reservation validation. Proposal-time filtering is
   insufficient: a PCZT built before a migration acquires a note lock must fail before
   combine/extract/store if its exact Orchard input is now actively locked. Because transaction
   ingestion automatically clears spent-input locks, the same validator also rejects a different
   current-chain or unexpired pending spender after that transition while admitting the exact
   same-txid retry. It derives the candidate txid; ordinary validation and wallet ingestion share
   one SQLite transaction, while migration extraction admits only its durable owner and uses the
   same active-spend guard. Locks remain advisory after commit, so supported app paths retain the
   SDK's `@DBActor` serialization.
4. Rust-owned destination completion and source finality. The account-scoped runtime aggregate
   derives exact output identity/value from canonical PCZTs/state, checks current-main-chain
   receive/spend status and normal wallet spendability, and keeps source reservations through the
   fixed 101-confirmation horizon. It exposes the Rust-computed release height and deep-rewind
   recovery without redefining upstream `MigrationState.complete`.
5. Swift wallet ingestion and txid consistency before migration broadcast.
6. Residual-lock isolation. Permanent Orchard residual locks use a deterministic per-account owner;
   they can be acquired only under a clean atomic runtime verdict and are released by exact
   owner-scoped output references in one wallet transaction, never by clearing every account lock.
7. Strict legacy cutover, Rust-owned immediate pre-exposure reservation, atomic maximum-gross
   authorization, exact known-unsent materialization reacquisition, durable claim leases,
   resolution-only unknown outcomes and immutable typed policy binding, including distinct direct
   TLS, public-TLS-over-Tor, onion, and development transports.
8. Exact single-signer `redact_pczt_for_signer` alignment from closed-unmerged SDK PR #1823 remains
   isolated from the exact upstream Keystone batch bridge. Zend's v2 builder adds only
   account-derived annotation on transient QR copies; it does not alter the upstream wire codec,
   decoder, signature combiner, retained-original ordering, or durable delivery evidence.
9. Nonpersistent proposal authority on top of upstream #1825: preserve its exact `PlanHandle`
   cache/FFI schema, while ensuring Swift encoding omits the handle and decoding always yields the
   zero sentinel. This prevents a process-local capability from becoming durable app state without
   inventing a competing plan schema.

None of these introduces a second planner, timer, canonical migration state table, or competing
lifecycle schema.

## Upstream contribution notes

- Delivery revision/CAS, typed policy binding, strict cutover, immediate pre-exposure reservation,
  maximum-gross authorization, exact known-unsent claim reacquisition, capability leases,
  unknown-outcome resolution and the 101-confirmation reservation horizon are additive crash-safety
  capabilities, not a competing migration engine. Keep their rationale and invariant tests
  adjacent to the implementation for later upstream review.
- The SDK still benefits from one wallet-scoped sync/broadcast permit if multiple independent app
  session owners are introduced. Until then, retain the app `TransactionGuard` and the existing
  privacy gate in addition to Rust delivery claims; neither substitutes for the other.

## Review and release gates

1. Exact-pin the final reviewed `just-zend/librustzcash` commit across the entire Rust dependency
   family and verify one resolved source per crate.
2. Remove `sdk_invalid_marks` and `sdk_immediate_runs` as runtime authorities. Wire SDK
   `rust/src/migration.rs` to one account-explicit atomic Rust runtime aggregate and typed delivery
   CAS/claim APIs; test strict cutover, pre-exposure immediate reservation, maximum-gross rejection
   before authority writes, exact known-unsent materialization reacquisition, policy binding,
   known-unsent release, unknown-outcome non-resubmission, exact expired-attempt rebuild,
   two-phase abandonment cleanup,
   destination spendability, the 101-confirmation source horizon and deep-rewind recovery.
3. Rebuild the XCFramework with the clean five-architecture builder; reject incremental artifacts
   with duplicate simulator slices.
4. Record the canonical Rust repository/commit/tree (without branch coupling), exact SDK source
   revision/tree and merge-or-semantic-port implementation revision, reviewed SDK lineage,
   exact included upstream `#1821`/`#1822`/`#1825` heads, integrated FFI and Swift feature heads,
   Keystone introduction commits, and Zend merge or semantic-port revisions, including
   `INCLUDED_UPSTREAM_1825_REVISION`, `INCLUDED_UPSTREAM_KEYSTONE_REVISION`,
   `INCLUDED_UPSTREAM_KEYSTONE_SWIFT_REVISION`, `UPSTREAM_MIGRATION_FEATURE_REVISION`,
   `UPSTREAM_MIGRATION_FEATURE_MERGE_REVISION`, `UPSTREAM_MIGRATION_FFI_REVISION`,
   `UPSTREAM_MIGRATION_FFI_MERGE_REVISION`, `UPSTREAM_MIGRATION_SWIFT_REVISION`,
   `UPSTREAM_MIGRATION_SWIFT_MERGE_REVISION`, and `SDK_PR_1825_SEMANTIC_PORT_REVISION`,
   toolchain, hermetic environment policy, targets, per-slice checksums, and the complete
   XCFramework file/symlink manifest in provenance. Before packaging a release, require that Rust
   commit/tree on `just-zend/librustzcash` `main` and bind the release tag to the exact SDK workflow
   SHA; pin the reviewed SDK commit in the app branch based on Zend iOS PR #132.
5. Run Rust tests, Swift offline tests, concrete arm64 simulator builds, and funded public-testnet
   migration/reorg/relaunch scenarios before merging the app branch or deploying TestFlight.
