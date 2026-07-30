# Changelog
All notable changes to this library will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this library adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- Pool-migration (Orchard→Ironwood) FFI: 24 `zcashlc_migration_*` entry points with their
  `#[repr(C)]` return types and `zcashlc_free_migration_*` destructors, plus
  `zcashlc_ironwood_activation_height`. Each call takes the wallet-db path, a 16-byte account uuid
  and a network id, opens the wallet database and the account-keyed migration store, and reports
  failure through the thread-local last-error channel with `NULL` / `false` / `-1` sentinels. Two
  stable message prefixes name the actionable conditions: `MIGRATION_PLAN_STALE` and
  `MIGRATION_PROVING_UNAVAILABLE`.
  - State: `zcashlc_migration_state`, `_progress`, `_is_note_split_needed`,
    `_has_overdue_transfers`, `_has_invalid_transfers`, `_pending_transfer_proposal`.
  - Note split: `zcashlc_migration_prepare_note_split`, `_sign_note_split`.
  - Proposal and commit: `zcashlc_migration_residual_after_migration`, `_propose_transfers`,
    `_sign_and_store_schedule`.
  - Proving: `zcashlc_migration_prove_pending` proves everything currently provable and returns the
    count proved (`-1` = error), skipping rather than failing on a row whose anchor is not yet
    scanned or retained. Call it from the sync path.
  - Delivery: `zcashlc_migration_next_due_transfer` never proves, and its
    `FfiPreparedTransfer.status` separates `MigrationNothingDue` from `MigrationAwaitingProof` and
    `MigrationReady`; then `_extract_broadcast_tx`, `_record_transfer_result`, and
    `_record_immediate_run`, which records a send-max sweep built outside the engine.
  - Recovery: `zcashlc_migration_restart_step`, and `_refresh_stale_transfers`, which rebuilds every
    expired transfer of the stored run and returns the full stored schedule, persisting
    all-or-nothing (NULL on any error).
  - External signer: `zcashlc_migration_create_unsigned_note_split_pczts`,
    `_store_signed_note_split_pczts`, `_create_unsigned_transfer_pczts`,
    `_store_signed_schedule_pczts`.
  - Residual locking: `zcashlc_migration_lock_residual` returns the total locked zatoshi (`0` is a
    valid "nothing was spendable"); `_unlock_residual` returns the cleared-output count.
  - Estimation: `zcashlc_migration_estimate_runs` returns `FfiMigrationRunEstimate` (a per-run
    `FfiRunEstimate` plus the final residual), freed by `zcashlc_free_migration_run_estimate`. A
    zero balance is the zero-run estimate, not an error.
  - Status: `zcashlc_migration_transaction_statuses` returns one row per committed migration
    transaction — stable id, kind, lifecycle state, scheduled/expiry/mined heights, the broadcast
    txid while in mempool, readiness, next action, blocking reason — freed by
    `zcashlc_free_migration_transaction_statuses`. No stored run yields an empty container.
- The echo parameters on the commit calls (`ids`, `amounts`, heights and duration on the schedule
  commits; `output_values` and `fee` on the note-split commit) are verified consent echoes, checked
  against the previewed plan or, once committed, the stored state. A mismatch surfaces
  `MIGRATION_PLAN_STALE`, so a stale or tampered display cannot sign values the user did not
  approve. Next-executable heights are compared only against the previewed plan; anchor heights are
  display-only.
- Every transfer amount the FFI reports is the value that CROSSES into Ironwood — one of the round
  `{1,2,5}×10ⁿ` denominations the run was planned in, and the amount the destination balance grows
  by — not the larger spend-side note value.
- Keystone batch-signing UR bridge:
  `zcashlc_migration_keystone_build_sign_batch_qr_parts` redacts each PCZT for the batch-signer role
  and returns animated `"zcash-sign-batch"` UR frames in `FfiKeystoneQrParts` (freed by
  `zcashlc_free_migration_keystone_qr_parts`), taking one ordered PCZT array with preparations first;
  `_keystone_reset_sign_batch_decoder` (void, infallible) and `_keystone_decode_sign_batch_part`
  (`FfiKeystoneBatchDecodeResult`, freed by
  `zcashlc_free_migration_keystone_batch_decode_result`) drive the multi-frame scan session and
  report the device's firmware version on completion, erroring on a request-id mismatch; and
  `_keystone_apply_batch_signatures` applies the response's signatures positionally to the caller's
  unsigned PCZTs, erroring if the counts disagree.
- `zcashlc_migration_create_unsigned_note_split_pczts` and `_create_unsigned_transfer_pczts` annotate
  every returned PCZT with the account's ZIP 32 seed fingerprint and account index. Without it
  Keystone rejects the batch with "None of inputs belongs to the provided account".
- `Balance` (inside `FfiAccountBalance` / `FfiWalletSummary`) gains a trailing `locked_value` field,
  keeping "the sum of the fields is the account's total" true.

### Changed
- `zcashlc_migration_state` / `_progress`: a mined immediate (send-max) run is consumed. It derives
  no migration state and masks a stale engine `Complete`, so a host goes quiet once the sweep mines
  instead of reporting a per-run completion. An unmined, unexpired immediate run still derives
  `InProgress`. `FfiMigrationProgress` gains a trailing `is_immediate` boolean.
- The anchor bucket interval is selected per network: mainnet keeps the ZIP 318 144-block grid, while
  testnet and custom-parameter networks retain anchors every 12 blocks and compress the transfer and
  preparation delays by the same factor, so a migration crosses enough boundaries to be exercised in
  a test run. Nothing crosses the FFI for this — each wallet handle is opened with the interval its
  `network_id` selects — and a migration already in flight keeps the interval it was committed under.
- Note locks are owner-keyed: the residual lock is keyed to a deterministic per-account owner, which
  makes re-locking idempotent, and `zcashlc_migration_unlock_residual` still clears the account's
  locks wholesale.
- The migration store connection uses the same 15 s `busy_timeout` as the wallet handle, so a
  `zcashlc_migration_*` call racing an engine write waits for the lock instead of surfacing
  `database is locked` early.

### Fixed
- `zcashlc_get_memo` accepts the Ironwood output pool code (4); an Ironwood note id was rejected as
  an unrecognized shielded protocol.
- Due-ness and expiry are evaluated on the engine's target-height contract (`chain tip + 1`) in every
  read path, with the "never expires" case honoured. Transfers now become due and expire one block
  earlier, consistently, and a doomed transfer is no longer served for broadcast.
- `FfiMigrationProgress.next_transfer_ready_at_height` reports the next transfer still awaiting
  broadcast rather than one already in the mempool.
- Transfer amounts are read from the engine's `crossing_values()` instead of being re-derived at
  three marshal sites. The values are identical by construction, so no reported number changes.
- `zcashlc_slipstream_start` sets the engine's anchor-retention floor to the NU6.3 activation height,
  so a scheduled transfer's boundary anchor survives checkpoint pruning. Delivery previously stalled
  in a permanent `AnchorNotFound` retry until the transfer expired.
- Overlapping `zcashlc_slipstream_start` passes on one handle are serialized, fixing the panic
  (`SyncState::Error(2)`, surfaced as `rustSlipstreamSyncFailed`) when an `importAccount`-triggered
  restart ran two sessions against the same database.
- `zcashlc_slipstream_wallet_summary` no longer returns the empty sentinel during the ~30 s gap after
  a restore completes, and once NU6.3 is active reports the collapsed recovery balance in the
  Ironwood pool rather than Orchard.

## 2.8.0-rc.2 - 2026-07-28

### Changed
- Migrated to `zcash_protocol 0.10.2`, `zcash_client_backend 0.24.0-rc.5`,
  `zcash_client_sqlite 0.22.0-rc.5`.
- `zcashlc_propose_transfer` and `zcashlc_propose_transfer_from_uri`: once NU6.3 is active, a single
  payment of a canonical ZIP 318 denomination crossing the Orchard turnstile is proposed as a
  canonical crossing — one fewer ZIP 317 marginal-fee action, and up to two anchor-bucket intervals of
  additional confirmations on its inputs beyond `confirmations_policy`. A payment that cannot be
  funded that way is proposed as an ordinary transaction.
- `zcashlc_init_data_database` applies new migrations that repair the data described under Fixed
  below. No rescan is required.

### Fixed
- Ironwood notes received on an account's internal address are classified as change, so
  `v_transactions.has_change` and `v_tx_outputs.is_change` no longer present an account's own change
  as a recipient of its transaction. Balances were unaffected.
- An address that had received only Ironwood notes is treated as used, so
  `zcashlc_get_next_available_address` no longer hands it out again and the receiving account is
  reported as involved in the transaction that paid it.
- The funding account recorded for a transparent output counts value spent from the Ironwood pool, so
  an output funded entirely from Ironwood is attributed to the funding account and one funded from
  several pools to its largest contributor.
- `zcashlc_transaction_data_requests` derives status requests from durable observation intent: a sent
  transaction is queried by txid when the wallet cannot observe one of its shielded spends or outputs,
  intent sleeps while a transaction is mined and revives after a rewind, and redundant requests for
  wallet-observable transactions are no longer produced.
- The Tor HTTP and gRPC transports bound each network operation, so `zcashlc_get_exchange_rate_usd`,
  `zcashlc_tor_http_get` / `_post` and the `zcashlc_tor_lwd_conn_*` calls fail with an error instead
  of hanging against a server that accepts a connection and then never responds. They also reject a
  URL whose scheme is neither `http` nor `https`, which was previously treated as plaintext HTTP.

## 2.7.0-rc.3 - 2026-07-28

### Changed
- Migrated to `zcash_protocol 0.10.2`, `zcash_client_backend 0.24.0-rc.5`,
  `zcash_client_sqlite 0.22.0-rc.5`.
- `zcashlc_propose_transfer` and `zcashlc_propose_transfer_from_uri`: once NU6.3 is active, a single
  payment of a canonical ZIP 318 denomination crossing the Orchard turnstile is proposed as a
  canonical crossing — one fewer ZIP 317 marginal-fee action, and up to two anchor-bucket intervals of
  additional confirmations on its inputs beyond `confirmations_policy`. A payment that cannot be
  funded that way is proposed as an ordinary transaction.
- `zcashlc_init_data_database` applies new migrations that repair the data described under Fixed
  below. No rescan is required.

### Fixed
- Ironwood notes received on an account's internal address are classified as change, so
  `v_transactions.has_change` and `v_tx_outputs.is_change` no longer present an account's own change
  as a recipient of its transaction. Balances were unaffected.
- An address that had received only Ironwood notes is treated as used, so
  `zcashlc_get_next_available_address` no longer hands it out again and the receiving account is
  reported as involved in the transaction that paid it.
- The funding account recorded for a transparent output counts value spent from the Ironwood pool, so
  an output funded entirely from Ironwood is attributed to the funding account and one funded from
  several pools to its largest contributor.
- `zcashlc_transaction_data_requests` derives status requests from durable observation intent: a sent
  transaction is queried by txid when the wallet cannot observe one of its shielded spends or outputs,
  intent sleeps while a transaction is mined and revives after a rewind, and redundant requests for
  wallet-observable transactions are no longer produced.
- The Tor HTTP and gRPC transports bound each network operation, so `zcashlc_get_exchange_rate_usd`,
  `zcashlc_tor_http_get` / `_post` and the `zcashlc_tor_lwd_conn_*` calls fail with an error instead
  of hanging against a server that accepts a connection and then never responds. They also reject a
  URL whose scheme is neither `http` nor `https`, which was previously treated as plaintext HTTP.

## 2.7.0-rc.2 - 2026-07-26

### Changed
- Migrated to `zcash_client_backend 0.24.0-rc.4`,
  `zcash_client_sqlite 0.22.0-rc.4`, `pczt 0.9.1`.
- `zcashlc_redact_pczt_for_signer` requests `zcash_client_backend`'s full
  (non-compacted) signer view rather than the compact one, and the PCZT it
  returns is serialized at the minimal encoding version capable of
  representing its content (v1 for a v5 transaction) rather than always v2.
  Deployed hardware signers do not provide the receiver capabilities the
  compact view and v2 encoding require. The full view also clears Ironwood
  spend witnesses and output metadata alongside the other bundles.
- `zcashlc_add_proofs_to_pczt` reuses a cached Orchard-family proving key
  across the Orchard and Ironwood proofs (both use the same PostNu6_3 circuit
  after NU6.3) instead of rebuilding it for each, and derives the Ironwood
  circuit version from the PCZT's consensus branch id rather than hardcoding
  it. The resulting proofs are unchanged.

### Fixed
- `zcashlc_propose_send_max_transfer` now spends from the Ironwood pool in
  addition to Sapling and Orchard, so a post-NU6.3 wallet's Ironwood funds are
  no longer silently excluded from a send-max. This affects only the general
  send-max proposal; the spend set used by
  `zcashlc_propose_orchard_to_ironwood_migration` is unchanged. There is no
  Swift API for the general send-max proposal; `zcashlc_propose_send_max_transfer`
  is reachable only through the C FFI.
- PCZTs created by `zcashlc_create_pczt_from_proposal` for post-NU6.3 (v6)
  transactions carry ZIP 32 derivation metadata on the wallet-controlled
  zero-value Orchard spends that pad them (via
  `zcash_client_backend 0.24.0-rc.4`), so external Signers can identify and
  sign them. Previously those actions were unsignable and extraction failed
  with a missing spend-auth signature.

## 2.7.0-rc.1 - 2026-07-25

### Added
- `zcashlc_put_ironwood_subtree_roots`: Store Ironwood subtree roots in the
  wallet database, mirroring the Sapling and Orchard entry points.
- `zcashlc_propose_orchard_to_ironwood_migration`: Propose migrating an
  account's entire Orchard balance into the Ironwood pool.
- The wallet-summary FFI structs gained `ironwood_balance` on the per-account
  balance and `next_ironwood_subtree_index` on the summary.

### Changed
- Migrated to the Ironwood (NU6.3) releases: `orchard` 0.14→0.15,
  `zcash_client_backend` 0.23→0.24.0-rc.2, `zcash_client_sqlite`
  0.21→0.22.0-rc.2, `zcash_primitives`/`zcash_proofs` 0.28→0.30,
  `zcash_protocol` 0.9→0.10, `zcash_address` 0.12→0.13, `zcash_transparent`
  0.8→0.10, `pczt` 0.7→0.8, `zcash_keys` 0.14→0.16; the `[patch.crates-io]`
  git overrides were dropped.
- `zcashlc_add_proofs_to_pczt` also proves Ironwood bundles.
- Once NU6.3 activates, a payment to an Orchard receiver is delivered through
  the Ironwood bundle of a version 6 transaction: proposals returned by
  `zcashlc_propose_transfer` report such payments and the change from Ironwood
  spends as Ironwood-pool outputs, and `zcashlc_create_proposed_transactions`
  and `zcashlc_create_pczt_from_proposal` build the version 6 transaction.
  Fee and change calculation derive the Orchard bundle version from the
  proposal's target height, charging one ZIP 317 action per Orchard spend or
  output at or beyond activation rather than `max(spends, outputs)`, with
  Ironwood spends, outputs and change charged against the Ironwood bundle.

### Removed
- The `zcashlc_voting_*` FFI is no longer compiled. `zcash_voting` cannot
  resolve against the Ironwood (NU6.3) `orchard` release, so the `voting`
  module is gated behind `#[cfg(zcash_voting)]` and the
  `zcash_voting`/`zcash_keys` dependencies are commented out in `Cargo.toml`.
  The module sources are retained so the surface can be reinstated once the
  voting crates support the Ironwood dependency stack.

### Fixed
- `zcashlc_delete_account` no longer fails with a rusqlite
  `InvalidParameterName(":address")` error when the account being deleted is
  recorded as the recipient of one of its own sent outputs. Wallets on the 2.6
  line received this fix in 2.6.0-alpha.6.

## 2.6.0-alpha.6 - 2026-06-26

### Fixed
- Updated `zcash_client_sqlite` to 0.21.1, fixing an `InvalidParameterName` error in `delete_account` when the account being deleted is referenced by a `sent_notes` row via its `to_account_id` column (i.e. an account involved in a cross-account transfer) ([librustzcash#2426](https://github.com/zcash/librustzcash/pull/2426)).

## 2.6.0-alpha.4 - 2026-06-04

### Changed
- Migrated to the released crates.io versions listed under 2.5.2 below,
  including `zcash_protocol` 0.9, which sets the NU6.2 activation heights
  (mainnet 3364600, testnet 4052000). The FFI surface is unchanged.

## 2.5.2 - 2026-06-03

### Changed
- Migrated to released crates.io versions of the Zcash crates: `orchard`
  0.13.1→0.14, `zcash_client_backend` 0.22→0.23, `zcash_client_sqlite`
  0.20.2→0.21, `zcash_keys` 0.13→0.14, `zcash_primitives`/`zcash_proofs`
  0.27→0.28, `zcash_protocol` 0.8→0.9, `zcash_address` 0.11→0.12,
  `zcash_transparent` 0.7→0.8, `pczt` 0.6→0.7. `zcash_protocol` 0.9 carries
  the NU6.2 activation heights (mainnet 3364600, testnet 4052000), so
  transactions targeting those heights and above are built against the NU6.2
  consensus branch id. The FFI surface is unchanged.

## 2.6.0-alpha.3 - 2026-05-27

### Changed
- Updated `zcash_voting` to 0.10.1, taken from the released crate rather than a
  git revision. No `zcashlc_voting_*` entry points were added or removed.

## 2.6.0-alpha.2 - 2026-05-18

### Changed
- Updated `zcash_voting` to 0.8.1 (from 0.6.0). No `zcashlc_voting_*` entry
  points were added or removed.

## 2.5.1 - 2026-05-15

### Changed
- Replaced the `[patch.crates-io]` git pin on the librustzcash crates with
  their published releases: `zcash_client_backend 0.22.0`,
  `zcash_client_sqlite 0.20.2`, `zcash_keys 0.13.0`, `pczt 0.6.0`,
  `zcash_primitives`/`zcash_proofs 0.27.1`, `zcash_protocol 0.8.0`,
  `zcash_address 0.11.0`, `zcash_transparent 0.7.0`.

### Fixed
- Proposing a transaction that shields more than 150 transparent P2PKH inputs
  no longer fails from an incorrect fee computation.

## 2.6.0-alpha.1 - 2026-05-12

### Added
- The `zcashlc_voting_*` surface grew from the 11 entry points added in 2.5.0
  to 59, covering the voting-database handle, round setup and state, vote
  commitment and share-payload construction, share encryption, delegation PIR
  precomputation, vote-tree sync, VAN and note witness generation, and the
  vote/delegation transaction-hash store. All of them were removed again in
  2.7.0-rc.1.

## 2.5.0 - 2026-05-11

### Added
- `zcashlc_voting_compute_share_nullifier`: Compute the 32-byte share-reveal
  nullifier from a vote commitment, primary blind, and share index. Returns
  the nullifier as a 64-character hex C-string; the caller must free the
  returned pointer via `zcashlc_string_free`. Returns `NULL` on error or
  panic. Pure-function FFI: no wallet DB, voting DB, network, randomness,
  or secret material involved.
- `zcashlc_voting_validate_pir_proof`: Validate a PIR-fetched IMT
  non-membership proof against an expected root.
- `zcashlc_voting_db_open`, `zcashlc_voting_db_free`, and
  `zcashlc_voting_set_wallet_id`: Manage the voting database handle used by
  stateful voting FFI calls.
- `zcashlc_voting_precompute_delegation_pir`: Precompute and cache delegation
  PIR IMT proofs for a voting bundle using the configured voting database and
  caller-supplied PIR endpoint.
- `zcashlc_voting_sync_vote_tree`: Sync the vote commitment tree for a round
  from a chain node URL, returning the latest synced block height (>= 0) on
  success, or -1 on error.
- `zcashlc_voting_generate_van_witness`: Generate a vote authority note Merkle witness for
  the second voting ZKP and return it as a JSON-encoded `VanWitness`
  (`auth_path`, `position`, `anchor_height`) in a `*mut FfiBoxedSlice`.
- `zcashlc_voting_reset_tree_client`: Drop the in-memory tree client for a
  round so the next `zcashlc_voting_sync_vote_tree` call creates a fresh one.
- `zcashlc_voting_warm_proving_caches`, `zcashlc_voting_decompose_weight`,
  `zcashlc_voting_generate_delegation_inputs`,
  `zcashlc_voting_generate_delegation_inputs_with_fvk`,
  `zcashlc_voting_extract_pczt_sighash`,
  `zcashlc_voting_extract_spend_auth_sig`,
  `zcashlc_voting_extract_nc_root`, and `zcashlc_voting_verify_witness`:
  Utility FFI for voting proof setup, PCZT/signature extraction,
  note-commitment root extraction, and witness verification.
- `FfiRoundState`, `FfiVotingHotkey`, `FfiBundleSetupResult`,
  `FfiRoundSummaries`, and `FfiVoteRecords`, plus their
  `zcashlc_voting_free_*` helpers, for C-compatible voting return values.
- `zcashlc_voting_generate_note_witnesses`: Generate Orchard Merkle inclusion
  witnesses for the notes in a voting bundle, anchored at the round's snapshot
  height.
- `VotingDatabaseHandle` now also carries a
  `zcash_voting::tree_sync::VoteTreeSync`, constructed in
  `zcashlc_voting_db_open` and consumed by the tree-sync FFI above.
- `zcashlc_voting_init_round`, `zcashlc_voting_get_round_state`,
  `zcashlc_voting_list_rounds`, `zcashlc_voting_get_votes`,
  `zcashlc_voting_clear_round`, `zcashlc_voting_delete_skipped_bundles`,
  recovery-state transaction/hash/signature helpers, and share-delegation
  tracking helpers for persisted voting round state.
- `zcashlc_voting_generate_hotkey`, `zcashlc_voting_setup_bundles`,
  `zcashlc_voting_get_bundle_count`, `zcashlc_voting_build_pczt`,
  `zcashlc_voting_store_tree_state`,
  `zcashlc_voting_build_and_prove_delegation`,
  `zcashlc_voting_get_delegation_submission`,
  `zcashlc_voting_get_delegation_submission_with_keystone_sig`, and
  `zcashlc_voting_store_van_position` for the delegation workflow FFI.
- `zcashlc_voting_encrypt_shares`, `zcashlc_voting_build_vote_commitment`,
  `zcashlc_voting_build_share_payloads`, `zcashlc_voting_mark_vote_submitted`,
  and `zcashlc_voting_sign_cast_vote` for the vote-casting FFI.
- `zcashlc_voting_get_wallet_notes`: Load unspent Orchard notes for a wallet
  account at a snapshot height and return them as JSON-encoded
  `Vec<NoteInfo>` in a `*mut FfiBoxedSlice`. `account_uuid` must be a non-null
  pointer to exactly 16 bytes (binary account UUID). Returns `NULL` on error
  or panic. Output is suitable as the `notes_json` input to
  `zcashlc_voting_precompute_delegation_pir`.
- `zcashlc_voting_extract_orchard_fvk_from_ufvk`: Decode a UFVK string and
  return the raw 96-byte Orchard full viewing key in a
  `*mut FfiBoxedSlice`. Returns `NULL` on missing Orchard component,
  malformed UFVK, or invalid `network_id`.
- Added `zcash_voting 0.5.7` (`default-features = false`, `client-pir`,
  `client-tree-sync`) as a Rust dependency.
- Added `zcash_keys 0.13` (`orchard` feature) as a Rust dependency, used by
  the new wallet-notes and key-utility FFI for voting to decode UFVKs and derive
  Orchard FVKs.
- Added `incrementalmerkletree 0.8` (`default-features = false`) as a direct
  Rust dependency, used by `zcashlc_voting_generate_note_witnesses` for
  `Position` and the `MerklePath` returned by the wallet DB.

### Changed
- Pinned `orchard` to `=0.13.1` and enabled its `unstable-voting-circuits`
  feature (required transitively by `zcash_voting`).
- Enabled the `client-tree-sync` feature on `zcash_voting`, required by the
  new tree-sync FFI symbols and by the `VoteTreeSync` field on
  `VotingDatabaseHandle`.

## 2.4.6 - 2026-03-12

### Changed
- This is the first release using Github artifact-based deployment. Users should 
  obtain releases from <TBD>

## 0.19.2 - 2026-03-02

### Fixed
- Updated to `shardtree 0.6.2, zcash_client_sqlite 0.19.4` to fix a note
  commitment tree corruption bug.

## 0.19.1 - 2025-11-26

### Added
- `ffi::ZecUsdExchange`
- `zcashlc_get_exchange_rate_usd_from`

### Changed
- Reduced the number of exchanges queried for ZEC/USD back to the number we had
  in 0.18 and earlier, to reduce power consumption.

## 0.19.0 - 2025-11-04

### Added
- `ffi::AddressCheckResult`
- `ffi::SingleUseTaddr`
- `zcashlc_get_single_use_taddr`
- `zcashlc_free_single_use_taddr`
- `zcashlc_tor_lwd_conn_check_single_use_taddr`
- `zcashlc_free_address_check_result`
- `zcashlc_propose_send_max_transfer`
- `zcashlc_tor_lwd_conn_update_transparent_address_transactions`
- `zcashlc_tor_lwd_conn_fetch_utxos_by_address`
- `zcashlc_delete_account`

### Changed
- MSRV is now 1.90.
- Migrated to `zcash_client_backend 0.21`, `zcash_client_sqlite 0.19`, `pczt-0.5`.

## 0.18.5 - 2025-10-23

### Changed
- Updated to `zcash_client_sqlite-0.18.9` to fix problems in transparent UTXO
  selection for shielding, including incorrect handling of outputs received at
  ephemeral addresses and selection of dust transparent outputs for shielding.

## 0.18.4 - 2025-10-16

### Changed
- Updated to `zcash_client_sqlite-0.18.7` to improve consistency of spentness
  determination, reliability of transaction status request generation,
  and fix removal of already-fulfilled transaction enhancement requests.

## 0.18.3 - 2025-10-08

### Fixed
- Updated to `zcash_client_sqlite-0.18.4` to fix a problem with balance calculation
  related to detection of spends of outputs received by the wallet's ephemeral
  addresses.

## 0.18.2 - 2025-10-01

### Fixed
- Updated to `zcash_client_sqlite-0.18.3` to fix a problem with display of
  zero-conf-shielded fully transparent transactions.

## 0.18.1 - 2025-09-29

### Fixed
- Updated to `zcash_client_sqlite-0.18.2` to fix a problem with zero-conf shielding.

## 0.18.0 - 2025-09-26

### Added

- `ConfirmationsPolicy`

### Changed

- Updated to `zcash_client_backend 0.20`, `zcash_client_sqlite 0.18`.
- functions now take `confirmations_policy: ConfirmationsPolicy` instead of `min_confirmations: u32`:

  * `zcashlc_get_wallet_summary`
  * `zcashlc_get_verified_transparent_balance`
  * `zcashlc_get_verified_transparent_balance_for_account`
  * `zcashlc_propose_transfer`
  * `zcashlc_propose_send_max_transfer`
  * `zcashlc_propose_transfer_from_uri`
  * `zcashlc_propose_shielding`

## 0.17.1 - 2025-08-29

### Changed
- Updated to `zcash_client_sqlite 0.17.3` (hotfix release).

### Fixed
- This release fixes a potential false-positive in the `expired_unmined` column
  of the `v_transactions` view.

## 0.17.0 - 2025-06-04

### Added
- `FfiHttpRequestHeader`
- `FfiHttpResponseBytes`
- `FfiHttpResponseHeader`
- `TorDormantMode`
- `zcashlc_free_http_response_bytes`
- `zcashlc_tor_http_get`
- `zcashlc_tor_http_post`
- `zcashlc_tor_set_dormant`

### Changed
- MSRV is now 1.87.
- Updated to `zcash_client_backend 0.19`, `zcash_client_sqlite 0.17`.

## 0.16.0 - 2025-05-13

### Added
- `OutputStatusFilter`
- `TransactionStatusFilter`

### Changed
- `zcashlc_get_next_available_address` now takes an additional `receiver_flags`
  argument that permits the caller to specify which receivers should be
  included in the generated unified address.
- `FfiTransactionDataRequest` variant `SpendsFromAddress` has been renamed to
  `TransactionsInvolvingAddress` and has new fields.

## 0.15.0 - 2025-04-24

### Added
- `zcashlc_tor_lwd_conn_get_info`
- `zcashlc_tor_lwd_conn_get_tree_state`
- `zcashlc_tor_lwd_conn_latest_block`

### Changed
- `FfiWalletSummary` has a new field `recovery_progress`.
- `FfiWalletSummary.scan_progress` now only tracks the progress of making
  existing wallet balance spendable. In some cases (depending on how long a
  wallet was offline since its last sync) it may also happen to include progress
  of discovering new notes, but in general `FfiWalletSummary.recovery_progress`
  now covers the discovery of historic wallet information.

### Fixed
- `zcashlc_tor_lwd_conn_fetch_transaction` now correctly returns `null` as the
  error sentinel instead of a "none" `FfiBoxedSlice`.

## 0.14.2 - 2025-04-02

### Fixed
- This fixes an error in the `transparent_gap_limit_handling` migration,
  whereby wallets having received transparent outputs at child indices below
  the index of the default address could cause the migration to fail.

## 0.14.1 - 2025-03-27

### Fixed
- This fixes an error in the `transparent_gap_limit_handling` migration,
  whereby wallets that received Orchard outputs at diversifier indices for
  which no Sapling receivers could exist would incorrectly attempt to
  derive UAs containing sapling receivers at those indices.

## 0.14.0 - 2025-03-21

### Added
- `zcashlc_fix_witnesses`

### Changed
- MSRV is now 1.85.
- Updated to `zcash_client_backend 0.18`, `zcash_client_sqlite 0.16`.
- Added support for gap-limit-based discovery of transparent wallet addresses.

## 0.13.0 - 2025-03-04

### Added
- `FfiAccountMetadataKey`
- `FfiSymmetricKeys`
- `zcashlc_account_metadata_key_from_parts`
- `zcashlc_derive_account_metadata_key`
- `zcashlc_derive_private_use_metadata_key`
- `zcashlc_free_account_metadata_key`
- `zcashlc_free_symmetric_keys`
- `zcashlc_free_tor_lwd_conn`
- `zcashlc_pczt_requires_sapling_proofs`
- `zcashlc_redact_pczt_for_signer`
- `zcashlc_tor_connect_to_lightwalletd`
- `zcashlc_tor_isolated_client`
- `zcashlc_tor_lwd_conn_fetch_transaction`
- `zcashlc_tor_lwd_conn_submit_transaction`

### Changed
- MSRV is now 1.84.
- `FfiAccount` now has a `ufvk` string field.

## 0.12.0 - 2024-12-16

### Added
- `FfiUuid`
- `zcashlc_free_ffi_uuid`
- `zcashlc_get_account`
- `zcashlc_free_account`
- `FfiAddress`
- `zcashlc_free_ffi_address`
- `zcashlc_derive_address_from_ufvk`
- `zcashlc_derive_address_from_uivk`
- `zcashlc_create_pczt_from_proposal`
- `zcashlc_add_proofs_to_pczt`
- `zcashlc_extract_and_store_from_pczt`

### Changed
- Updated dependencies:
  - `sapling-crypto 0.4`
  - `orchard 0.10.1`
  - `zcash_primitives 0.21`
  - `zcash_proofs 0.21`
  - `zcash_keys 0.6`
  - `zcash_client_backend 0.16`
  - `zcash_client_sqlite 0.14`
- `FfiAccounts` now contains `FfiUuid`s instead of `FfiAccount`s.
- `FfiAccount` has changed:
  - It must now be freed with `zcashlc_free_account`.
  - Added fields `uuid_bytes`, `account_name`, `key_source`.
  - Renamed `account_index` field to `hd_account_index`.
- The following structs now have an `account_uuid` field instead of an
  `account_id` field:
  - `FFIBinaryKey`
  - `FFIEncodedKey`
  - `FfiAccountBalance`
- The following functions now have additional arguments `account_name` (which
  must be set) and `key_source` (which may be null):
  - `zcashlc_create_account`
  - `zcashlc_import_account_ufvk`
- `zcashlc_import_account_ufvk` now has additional arguments `seed_fingerprint`
  and `hd_account_index_raw`, which must either both be set or both be "null"
  values.
- `zcashlc_import_account_ufvk` now returns `*mut FfiUuid` instead of `i32`.
- The following functions now take an `account_uuid_bytes` pointer to a byte
  array, instead of an `i32`:
  - `zcashlc_get_current_address`
  - `zcashlc_get_next_available_address`
  - `zcashlc_list_transparent_receivers`
  - `zcashlc_get_verified_transparent_balance_for_account`
  - `zcashlc_get_total_transparent_balance_for_account`
  - `zcashlc_propose_transfer`
  - `zcashlc_propose_transfer_from_uri`
  - `zcashlc_propose_shielding`
- `zcashlc_derive_spending_key` now returns `*mut FfiBoxedSlice` instead of
  `*mut FFIBinaryKey`.

### Removed
- `zcashlc_get_memo_as_utf8`

## 0.11.0 - 2024-11-15

### Added
- `zcashlc_derive_arbitrary_wallet_key`
- `zcashlc_derive_arbitrary_account_key`

### Changed
- Updated `librustzcash` dependencies:
  - `zcash_primitives 0.20`
  - `zcash_proofs 0.20`
  - `zcash_keys 0.5`
  - `zcash_client_backend 0.15`
  - `zcash_client_sqlite 0.13`
- Updated to `rusqlite` version `0.32`
- Updated to `tor-rtcompat` version `0.23`
- `zcashlc_propose_transfer`, `zcashlc_propose_transfer_from_uri` and
  `zcashlc_propose_shielding` no longer accpt a `use_zip317_fees` parameter;
  ZIP 317 standard fees are now always used and are not configurable.

## 0.10.2 - 2024-10-22

### Changed
- Updated to `zcash_client_sqlite` version `0.12.2`

### Fixed
- This release fixes an error in wallet rewind that could cause a crash in the
  wallet backend in certain circumstances.

### Changed
- Updated to `zcash_client_sqlite` version `0.12.1`

## 0.10.1 - 2024-10-10

### Changed
- Updated to `zcash_client_sqlite` version `0.12.1`

### Fixed
- This release fixes an error in scan progress computation that could, under
  certain circumstances, result in scan progress values greater than 100% being
  reported.

## 0.10.0 - 2024-10-04

### Changed
- `zcashlc_rewind_to_height` now returns an `i64` value instead of a boolean. The
  value `-1` indicates failure; any other height indicates the height to which the
  data store was actually truncated. Also, this procedure now takes an additional
  `safe_rewind_ret` parameter that, on failure to rewind, will be set to the
  minimum height for which the rewind would succeed, or to -1 if
  no such height can be determined.

### Removed
- `zcashlc_get_nearest_rewind_height` has been removed. The return value of
  `zcashlc_rewind_to_height`, or in the case of rewind failure the value of its
  `safe_rewind_ret` return parameter should be used instead.

### Fixed
- This release fixes a potential source of corruption in wallet note commitment
  trees related to incorrect handling of chain reorgs. It includes a database
  migration that will repair the corrupted database state of any wallet
  affected by this corner case.

## 0.9.1 - 2024-08-21

### Fixed
- A database migration misconfiguration that could results in problems with wallet
  initialization was fixed.

## 0.9.0 - 2024-08-20

### Added
- `zcashlc_create_tor_runtime`
- `zcashlc_free_tor_runtime`
- `zcashlc_get_exchange_rate_usd`
- `zcashlc_set_transaction_status`
- `zcashlc_transaction_data_requests`
- `zcashlc_free_transaction_data_requests`
- `FfiTransactionStatus_Tag`
- `FfiTransactionStatus`
- `FfiTransactionDataRequest_Tag`
- `SpendsFromAddress_Body`
- `FfiTransactionDataRequest`
- `FfiTransactionDataRequests`
- `Decimal`

### Changed
- MSRV is now 1.80.
- Migrated to `zcash_client_sqlite 0.11`.
- `zcashlc_init_on_load` now takes a log level filter as a UTF-8 C string, instead of
  a boolean.
- The following methods now support ZIP 320 (TEX) addresses:
  - `zcashlc_get_address_metadata`
  - `zcashlc_propose_transfer`
- `zcashlc_decrypt_and_store_transaction` now takes its `mined_height` argument
  as `int64_t`. This allows callers to pass the value of `mined_height` as
  returned by the zcashd `getrawtransaction` RPC method.

### Removed
- `zcashlc_is_valid_sapling_address`, `zcashlc_is_valid_transparent_address`,
  `zcashlc_is_valid_unified_address` (use `zcashlc_get_address_metadata` instead).

## 0.8.1 - 2024-06-14

### Fixed
- Further changes for compatibility with XCode 15.3 and above.

## 0.8.0 - 2024-04-17

### Added
- `zcashlc_is_valid_sapling_address`

### Changed
- Updates to `zcash_client_sqlite` version `0.10.3` to add migrations that ensure the
  wallet's default Unified address contains an Orchard receiver.
- `zcashlc_get_memo` now takes an additional `output_pool` parameter. This fixes a problem
  with the retrieval of Orchard memos.

### Removed
- `zcashlc_is_valid_shielded_address` - use `zcashlc_is_valid_sapling_address` instead.

## 0.7.4 - 2024-03-28

### Added
- `zcashlc_put_orchard_subtree_roots`

## 0.7.3 - 2024-03-27

- Updates to `zcash_client_backend 0.12.1` to fix a bug in note selection
  when sending to a transparent recipient.

## 0.7.2 - 2024-03-27

- Updates to `zcash_client_sqlite 0.10.2` to fix a bug in an SQL query
  that prevented shielding of transparent funds.

## 0.7.1 - 2024-03-25

- Updates to `zcash_client_sqlite` version 0.10.1 to fix an incorrect
  constraint on the `sent_notes` table. Databases built or upgraded
  using version 0.7.0 will need to be deleted and restored from seed.

## 0.7.0 - 2024-03-25

This version has been yanked due to a bug in zcash_client_sqlite version 0.10.0

## Notable Changes
- Adds Orchard support.

### Added
- Structs and functions for listing accounts in the wallet:
  - `zcashlc_list_accounts`
  - `zcashlc_free_accounts`
  - `FfiAccounts`
  - `FfiAccount`
- `zcashlc_is_seed_relevant_to_any_derived_account`

### Changed
- Update to zcash_client_backend version 0.12.0 and zcash_client_sqlite version
  0.10.0.
- `zcashlc_scan_blocks` now takes a `TreeState` protobuf object that provides
  the frontiers of the note commitment trees as of the end of the block prior to
  the range being scanned.

## 0.6.0 - 2024-03-07

### Added
- `zcashlc_create_proposed_transactions`

### Changed
- Migrated to `zcash_client_sqlite 0.9`.

- `zcashlc_propose_shielding` now raises an error if more than one transparent
  receiver has funds that require shielding, to avoid creating transactions that
  link these receivers on chain. It also now takes a `transparent_receiver`
  argument that can be used to select a specific receiver for which to shield
  funds.
- `zcashlc_propose_shielding` now returns a "none" `FfiBoxedSlice` (with its
  `ptr` field set to `null`) if there are no funds to shield, or if the funds
  are below `shielding_threshold`.

### Removed
- `zcashlc_create_proposed_transaction`
  (use `zcashlc_create_proposed_transactions` instead).

## 0.5.1 - 2024-01-30

Update to `librustzcash` tag `ecc_sdk-20240130a`.

### Fixes
This release fixes a problem in the serialization of transaction proposals having
empty transaction requests (shielding transactions are change-only and contain
no payments.)

## 0.5.0 - 2024-01-29

## Notable Changes

This release updates the `librustzcash` dependencies to the stable interim tag
`ecc_sdk-20240129`. This provides improvements to wallet query performance that
have not yet been released in a published version of the `zcash_client_sqlite`
crate, as well as numerous unreleased changes to the `zcash_client_backend` and
`zcash_primitives` crates.

### Added
- FFI data structures:
  - `FfiBalance`
  - `FfiAccountBalance`
  - `FfiWalletSummary`
  - `FfiScanSummary`
  - `FfiBoxedSlice`
- FFI methods:
  - `zcashlc_propose_transfer`
  - `zcashlc_propose_transfer_from_uri`
  - `zcashlc_propose_shielding`
  - `zcashlc_create_proposed_transaction`
  - `zcashlc_get_wallet_summary`
  - `zcashlc_free_wallet_summary`
  - `zcashlc_free_boxed_slice`
  - `zcashlc_free_scan_summary`

### Changed
- `zcashlc_scan_blocks` now returns a `FfiScanSummary` value.

### Removed
- `zcashlc_get_balance` (use `zcashlc_get_wallet_summary` instead)
- `zcashlc_get_scan_progress` (use `zcashlc_get_wallet_summary` instead)
- `zcashlc_get_verified_balance` (use `zcashlc_get_wallet_summary` instead)
- `zcashlc_create_to_address` (use `zcashlc_propose_transfer`  and
  `zcashlc_create_proposed_transaction` instead)
- `zcashlc_shield_funds` (use `zcashlc_propose_shielding`  and
  `zcashlc_create_proposed_transaction` instead)

## 0.4.1 - 2023-10-20

### Issues Resolved
- [#103] Update to `zcash_client_sqlite` with a fix for
  [incorrect note deduplication in `v_transactions`](https://github.com/zcash/librustzcash/pull/1020).

Updated dependencies:
  - `zcash_client_sqlite 0.8.1`

## 0.4.0 - 2023-09-25

### Notable Changes

This release overhauls the FFI library to provide support for allowing wallets to
spend funds without fully syncing the blockchain. This results in significant
changes to much of the API; it is recommended that users review the changes
from the previous release carefully.

### Changed
- `anyhow` is now used for error management

### Issues Resolved
- [#95] Update to `zcash_client_backend` and `zcash_client_sqlite` with fast sync support

Updated dependencies:
  - `zcash_address 0.3`
  - `zcash_client_backend 0.10.0`
  - `zcash_client_sqlite 0.8.0`
  - `zcash_primitives 0.13.0`
  - `zcash_proofs 0.13.0`

  - `orchard 0.6`
  - `ffi_helpers 0.3`
  - `secp256k1 0.26`

Added dependencies:
  - `anyhow 0.1`
  - `prost 0.12`
  - `cfg-if 1.0`
  - `rayon 1.7`
  - `log-panics 2.0`
  - `once_cell 1.0`
  - `sharded-slab 0.1`
  - `tracing 0.1`
  - `tracing-subscriber 0.3`

## 0.3.1
- [#88] unmined transaction shows note value spent instead of tx value

Fixes an issue where a sent transaction would show the whole note spent value
instead of the value of that the user meant to transfer until it was mined.

## 0.3.0

- [#87] Outbound transactions show the wrong amount on v_transactions

removes `v_tx_received` and `v_tx_sent`.

`v_transactions` now shows the `account_balance_delta` column where the clients can
query the effect of a given transaction in the account balance. If fee was paid from
the account that's being queried, the delta will include it. Transactions where funds
are received into the queried account, will show the amount that the acount is receiving
and won't include the transaction fee since it does not change the balance of the account.

Creates `v_tx_outputs` that allows clients to know the outputs involved in a transaction.

## 0.2.0

- [#34] Fix SwiftPackageManager deprecation Warning
We had to change the name of the package to make it match the name
of the github repository due to Swift Package Manager conventions.

please see README.md for more information on how to import this package
going forward.

### FsBlock Db implementation and removal of BlockBb cache.

Implements `zcashlc_init_block_metadata_db`, `zcashlc_write_block_metadata`,
`zcashlc_free_block_meta`, `zcashlc_free_blocks_meta`

Declare `repr(C)` structs for FFI:
 - `FFIBlockMeta`: a block metadata row
 - `FFIBlocksMeta`: a structure that holds an array of `FFIBlockMeta`


expose shielding threshold for `shield_funds`

- [#81] Adopt latest crate versions
Bumped dependencies to `zcash_primitives 0.10`, `zcash_client_backend 0.7`,
`zcash_proofs 0.10`, `zcash_client_sqlite 0.5.0`

this adds support for `min_confirmations` on `shield_funds` and `shielding_threshold`.
- [#78] removing cocoapods support

## 0.1.1

Updating:
````
 - zcash_client_backend v0.6.0 -> v0.6.1
 - zcash_client_sqlite v0.4.0 -> v0.4.2
 - zcash_primitives v0.9.0 -> v0.9.1
````
This fixes the following issue
- [#72] fixes get_transparent_balance() fails when no UTXOs

## 0.1.0

Unified spending keys are now used in all places where spending authority
is required, both for performing spends of shielded funds and for shielding
transparent funds. Unified spending keys are represented as opaque arrays
of bytes, and FFI methods are provided to permit derivation of viewing keys
from the binary unified spending key representation.

IMPORTANT NOTE: the binary representation of a unified spending key may be
cached, but may become invalid and require re-derivation from seed to use as
input to any of the relevant APIs in the future, in the case that the
representation of the spending key changes or new types of spending authority
are recognized.  Spending keys give irrevocable spend authority over
a specific account.  Clients that choose to store the binary representation
of unified spending keys locally on device, should handle them with the
same level of care and secure storage policies as the wallet seed itself.

### Added
- `zcashlc_create_account` provides new account creation functionality.
  This is now the preferred API for the creation of new spend authorities
  within the wallet; `zcashlc_init_accounts_table_with_keys` remains available
  but should only be used if it is necessary to add multiple accounts at once,
  such as when restoring a wallet from seed where multiple accounts had been
  previously derived.

Key derivation API:
- `zcashlc_derive_spending_key`
- `zcashlc_spending_key_to_full_viewing_key`

Address retrieval, derivation, and verification API:
- `zcashlc_get_current_address`
- `zcashlc_get_next_available_address`
- `zcashlc_get_sapling_receiver_for_unified_address`
- `zcashlc_get_transparent_receiver_for_unified_address`
- `zcashlc_is_valid_unified_address`
- `zcashlc_is_valid_unified_full_viewing_key`
- `zcashlc_list_transparent_receivers`
- `zcashlc_get_typecodes_for_unified_address_receivers`
- `zcashlc_free_typecodes`
- `zcashlc_get_address_metadata`
Balance API:
- `zcashlc_get_verified_transparent_balance_for_account`
- `zcashlc_get_total_transparent_balance_for_account`

New memo access API:
- `zcashlc_get_received_memo`
- `zcashlc_get_sent_memo`

### Changed
- `zcashlc_create_to_address` now has been changed as follows:
  - it no longer takes the string encoding of a Sapling extended spending key
    as spend authority; instead, it takes the binary encoded form of a unified
    spending key as returned by `zcashlc_create_account` or
    `zcashlc_derive_spending_key`. See the note above.
  - it now takes the minimum number of confirmations used to filter notes to
    spend as an argument.
  - the memo argument is now passed as a potentially-null pointer to an
    `[u8; 512]` instead of a C string.
- `zcashlc_shield_funds` has been changed as follows:
  - it no longer takes the transparent spending key for a single P2PKH address
    as spend authority; instead, it takes the binary encoded form of a unified
    spending key as returned by `zcashlc_create_account`
    or `zcashlc_derive_spending_key`. See the note above.
  - the memo argument is now passed as a potentially-null pointer to an
    `[u8; 512]` instead of a C string.
  - it no longer takes a destination address; instead, the internal shielding
    address is automatically derived from the account ID.
- Various changes have been made to correctly implement ZIP 316:
  - `FFIUnifiedViewingKey` now stores an account ID and the encoding of a
    ZIP 316 Unified Full Viewing Key.
  - `zcashlc_init_accounts_table_with_keys` now takes a slice of ZIP 316 UFVKs.
- `zcashlc_put_utxo` no longer has an `address_str` argument (the address is
  instead inferred from the script).
- `zcashlc_get_verified_balance` now takes the minimum number of confirmations
  used to filter received notes as an argument.
- `zcashlc_get_verified_transparent_balance` now takes the minimum number of
  confirmations used to filter received notes as an argument.
- `zcashlc_get_total_transparent_balance` now returns a balance that includes
  all UTXOs including those only in the mempool (i.e. those with 0
  confirmations).

### Removed

The following spending key derivation APIs have been removed and replaced by
`zcashlc_derive_spending_key`:
- `zcashlc_derive_extended_spending_key`
- `zcashlc_derive_transparent_private_key_from_seed`
- `zcashlc_derive_transparent_account_private_key_from_seed`

The following viewing key APIs have been removed and replaced by
`zcashlc_spending_key_to_full_viewing_key`:
- `zcashlc_derive_extended_full_viewing_key`
- `zcashlc_derive_shielded_address_from_viewing_key`
- `zcashlc_derive_unified_viewing_keys_from_seed`

The following address derivation APIs have been removed in favor of
`zcashlc_get_current_address` and `zcashlc_get_next_available_address`:
- `zcashlc_get_address`
- `zcashlc_derive_shielded_address_from_seed`
- `zcashlc_derive_transparent_address_from_secret_key`
- `zcashlc_derive_transparent_address_from_seed`
- `zcashlc_derive_transparent_address_from_public_key`

- `zcashlc_init_accounts_table` has been removed in favor of
  `zcashlc_create_account`

## 0.0.3
- [#13] Migrate to `zcash/librustzcash` revision with NU5 awareness (#20)
  This enables mobile wallets to send transactions after NU5 activation.
