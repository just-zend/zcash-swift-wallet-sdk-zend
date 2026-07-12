# Old Orchard wallet fixture generator

This standalone tool generates the pre-Ironwood wallet database used by
`OldOrchardDatabaseMigrationTests`. It also writes a same-basename `.compactblocks` companion:
one lowercase-hex protobuf compact block per line, prefixed by its decimal height. The regression
uses those exact blocks to complete the Historic rescan queued by the Ironwood schema migration.
Its dependency versions exactly match the Rust graph shipped by Zend's previous SDK baseline,
`zcash-swift-wallet-sdk` commit
`4303068e9282bb8b03bd94807b7d8ad268de75bf` (`2.6.0-alpha.6`):

- `zcash_client_backend` 0.23.0
- `zcash_client_sqlite` 0.21.1
- `zcash_keys` 0.14.0
- `zcash_protocol` 0.9.0

The tool uses librustzcash's own deterministic wallet testing backend. It creates a real
seed-derived account, scans a cryptographically valid Orchard compact output worth 123,456,789
zatoshi, and advances the old wallet's scanned range across the selected network's NU6.3
activation. The wallet database is created with the exact TestNetwork or MainNetwork consensus
type, so ZIP-32 coin type, viewing keys, cached unified addresses, transparent receivers, and scan
queue all match the released iOS FFI entry point. The local-consensus test harness supplies only
deterministic compact blocks. It does not hand-create or imitate a wallet schema.

Regenerate the checked-in fixture from the repository root with:

```sh
cargo run --locked --manifest-path Tools/OldOrchardFixtureGenerator/Cargo.toml -- \
  Tests/TestUtils/Resources/zend_2_6_0_alpha_6_orchard.sqlite testnet

cargo run --locked --manifest-path Tools/OldOrchardFixtureGenerator/Cargo.toml -- \
  Tests/TestUtils/Resources/zend_2_6_0_alpha_6_orchard_mainnet.sqlite mainnet
```

After regeneration, update the database and compact-block provenance hashes and the expected
hashes in `Scripts/verify-old-orchard-fixtures.sh`, then run that script before the Swift
regression.

The compact-block companions are byte-deterministic. The pinned upstream wallet migrator uses
unordered sets while scheduling independent schema migrations, so a regenerated SQLite file can
have identical logical content but a different byte hash solely because `sqlite_schema` rows were
created in a different order. Do not rewrite schema objects to hide that upstream behavior.
Review the logical invariants, freeze one generated database instance, and record its exact hash.

The generator is intentionally separate from the SDK's root Cargo graph. Updating its pinned
versions would change the fixture's provenance and requires choosing a new fixture name and
updating the migration regression's baseline assertions.

Each checked-in artifact's exact hash, network, privacy classification, and the one limitation of
using the old backend crates instead of the old binary FFI are recorded beside that artifact in
`Tests/TestUtils/Resources/`.
