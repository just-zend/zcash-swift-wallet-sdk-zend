# Spec — Update SDK to latest `zodl_ironwood_migration` crate (`main` / issue-#1 PCZT pivot)

**Date:** 2026-06-30
**Branch:** `michal/MOB-1455-ironwood-migration-prototype-ffi` (FFI + welding tier)
**Status:** approved, implemented.

## Goal

Update the SDK's integration of the `zodl_ironwood_migration` crate to its `main` branch (issue #1:
PCZT pivot + canonical `zcash_protocol` types). Make the FFI + welding tier compile and pass offline
tests against the new crate. Hand off the broadcast/orchestration changes to the SDK-impl branch.

## Verified context

- Crate `main` = issue-#1 merged: PCZT pivot, `zcash_protocol` types in the public API,
  `raw_tx → raw_pczt`, richer non-serde `MigrationError` with `error_code()`.
- The crate is a **path dependency** (`../ZODLIronwoodMigrationRust`) already on `main`, so "update
  the version" = rebuild against the new code; `Cargo.lock` regenerates on build. No version string
  to bump.
- **No dependency-graph work:** the SDK's `[patch.crates-io]` already pins librustzcash to valargroup
  branch `adam/qleak-pr44-orchard-dummy-ciphertexts` and orchard to `adam/qleak-dummy-ciphertexts-on-pr505`,
  identical to the crate; `.cargo/config.toml` sets `zcash_unstable="nu6.3"`.
- Sourcery 2.3.0 installed (matches `generateMocks.sh` requirement).

## Changes (this branch)

1. **Rust FFI — `rust/src/migration.rs`**
   - `migration_network`: `Network::Test → Network::TestNetwork`, `Network::Main → Network::MainNetwork`.
   - Add `zcashlc_migration_extract_broadcast_tx` → wraps `extract_broadcast_tx`, returns **raw tx
     bytes** (not JSON).
   - Add `zcashlc_migration_refresh_stale_transfers` → wraps `refresh_stale_transfers`, returns JSON `u32`.
   - Module doc updated (`raw_tx` → `raw_pczt`; describe the extract step).
2. **Build tooling — `rust/build.rs`**: add `cargo:rerun-if-changed=rust/src/migration.rs` so editing
   the migration FFI regenerates the cbindgen header (latent bug: it was missing, so header went stale).
3. **Swift models — `Model/Migration.swift`** (3 renames; wire format unchanged):
   `PreparedTx.rawTx → rawPczt` (`raw_pczt`), `MigrationProgress.remainingOrchardZatoshi →
   remainingOrchard` (`remaining_orchard`), `TransferProposal.amountZatoshi → amount` (`amount`).
4. **Welding — `Rust/ZcashRustBackendWelding.swift` + `Rust/ZcashRustBackend.swift`**: add
   `migrationExtractBroadcastTx(pczt:for:) -> [UInt8]` (raw bytes) and
   `migrationRefreshStaleTransfers(usk:for:) -> UInt32` (JSON `u32`).
5. **Errors** — add `rustMigrationExtractBroadcastTx` (ZRUST0107) and `rustMigrationRefreshStaleTransfers`
   (ZRUST0108) to `ZcashErrorCodeDefinition.swift`; regenerate `ZcashError.swift`/`ZcashErrorCode.swift`.
6. **Mocks** — regenerate `AutoMockable.generated.swift` (Sourcery 2.3.0).
7. **Tests** — update `MigrationModelTests.swift` to the new JSON keys; add a negative-path
   `migrationExtractBroadcastTx` test to `MigrationFFITests.swift`.
8. **Rebuild** the macOS FFI slice; verify the 2 new symbols appear in `zcashlc.h`; `swift test --filter
   OfflineTests` green.
9. **CHANGELOG** — update the existing unreleased migration entry.
10. **Handoff** — `docs/handoffs/MOB-1455-2-ironwood-migration-sdk-impl.md` for the orchestration branch.

## Out of scope

Broadcast orchestration (→ handoff), the consuming app (separate repo), full multi-arch xcframework
(recommended `init-local-ffi.sh` before PR; macOS slice verified here).

## Decision

`refresh_stale_transfers` welding: **included** for 1:1 crate parity (16 crate ops ↔ 16 welded
methods). `extract_broadcast_tx` is required regardless.
