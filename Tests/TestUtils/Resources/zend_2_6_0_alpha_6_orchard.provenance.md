# Zend 2.6.0-alpha.6 Orchard fixture provenance

- Fixture: `zend_2_6_0_alpha_6_orchard.sqlite`
- Network: Zcash TestNetwork
- SHA-256: `d06a9aeed38380a063857f481e6766ff73417fe4f7bb41ff25b7954c2088f2d9`
- Compact blocks: `zend_2_6_0_alpha_6_orchard.compactblocks`
- Compact blocks SHA-256: `b8505a5aba88658fa3e327189ecd5d78794f7dfc9e9c513fba086a97af095827`
- Production SDK source pin: `zcash-swift-wallet-sdk` commit
  `4303068e9282bb8b03bd94807b7d8ad268de75bf`, release `2.6.0-alpha.6`
- Canonical wallet backend from that commit's locked graph:
  `zcash_client_backend` 0.23.0 and `zcash_client_sqlite` 0.21.1
- Generator: `Tools/OldOrchardFixtureGenerator` with its checked-in `Cargo.lock`

The released SDK's Swift/FFI test surface can initialize an account but cannot synthesize and scan
an Orchard compact output. To retain real note and scan data, the generator links the exact
upstream backend crate versions and checksums locked by the production SDK commit and invokes
librustzcash's own wallet test backend. The wallet database itself is parameterized by the exact
TestNetwork consensus type, while the testing harness supplies only deterministic compact blocks.
The account therefore uses the TestNetwork ZIP-32 coin type, and every cached unified and
transparent address is derived and encoded for TestNetwork by the same backend as the old FFI.
This produces the same canonical SQLite schema that the old FFI initializes; no table or migration
marker is hand-authored. The only post-generation normalization is:

1. decoding and canonically re-encoding every cached address for TestNetwork as a fail-closed
   validation step;
2. replacing the randomly assigned account UUID with a fixed test UUID; and
3. sorting the applied-migration marker rows before `VACUUM` so their logical order is stable.

The pinned upstream migrator can create independent schema objects in different orders because
its migration graph uses unordered sets. A regeneration can therefore have identical tables,
rows, indexes, and companion blocks but a different raw SQLite SHA-256 due only to `sqlite_schema`
row order. The hash above freezes and authenticates this reviewed checked-in instance; validate
logical invariants and the byte-stable compact-block companion before accepting a regenerated
database hash.

The fixture has one seed-derived account, one cryptographically valid Orchard note worth
123,456,789 zatoshi, and a scanned range crossing testnet NU6.3 activation height 4,134,000. It has
the canonical Orchard-only wallet schema and deliberately contains no Ironwood or
`ext_ironwood_migration_*` objects.

The compact-block companion contains the exact 21 protobuf blocks at heights 4,133,990 through
4,134,010 that the old backend generated and scanned into the database. Each line is
`decimal-height:lowercase-protobuf-hex`. The current SDK regression writes these blocks through its
real filesystem cache and scans them from the known empty state at height 4,133,989, proving that
the Historic range queued by the Ironwood schema migration restores Orchard spendability.

All data is synthetic and public test data. The generator input is the fixed all-zero 32-byte test
seed; the database does not store that seed or any spending-key bytes. It contains only derived
viewing/address data, a synthetic compact transaction identity and received-note payload, and no
raw transaction. The companion contains only those same synthetic compact blocks. Neither file
contains device, endpoint, production-wallet, or user data.
