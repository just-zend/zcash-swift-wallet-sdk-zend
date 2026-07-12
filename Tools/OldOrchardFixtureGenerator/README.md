# Old Orchard wallet fixture generator

This standalone tool generates the pre-Ironwood wallet database used by
`OldOrchardDatabaseMigrationTests`. Its dependency versions exactly match the Rust graph shipped
by Zend's previous SDK baseline, `zcash-swift-wallet-sdk` commit
`4303068e9282bb8b03bd94807b7d8ad268de75bf` (`2.6.0-alpha.6`):

- `zcash_client_backend` 0.23.0
- `zcash_client_sqlite` 0.21.1
- `zcash_keys` 0.14.0
- `zcash_protocol` 0.9.0

The tool uses librustzcash's own deterministic wallet testing backend. It creates a real
seed-derived account, scans a cryptographically valid Orchard compact output worth 123,456,789
zatoshi, and advances the old wallet's scanned range across testnet NU6.3 activation height
4,134,000. The upstream harness uses a local-consensus network with the test coin type, so the
generator re-encodes that account's unchanged UFVK/UIVK key material with TestNetwork prefixes,
matching the released iOS FFI entry point. It does not hand-create or imitate a wallet schema.

Regenerate the checked-in fixture from the repository root with:

```sh
cargo run --locked --manifest-path Tools/OldOrchardFixtureGenerator/Cargo.toml -- \
  Tests/TestUtils/Resources/zend_2_6_0_alpha_6_orchard.sqlite
```

The generator is intentionally separate from the SDK's root Cargo graph. Updating its pinned
versions would change the fixture's provenance and requires choosing a new fixture name and
updating the migration regression's baseline assertions.

The checked-in artifact's exact hash, privacy classification, and the one limitation of using the
old backend crates instead of the old binary FFI are recorded in
`Tests/TestUtils/Resources/zend_2_6_0_alpha_6_orchard.provenance.md`.
