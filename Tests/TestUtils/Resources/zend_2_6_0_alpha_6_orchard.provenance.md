# Zend 2.6.0-alpha.6 Orchard fixture provenance

- Fixture: `zend_2_6_0_alpha_6_orchard.sqlite`
- SHA-256: `81da74d8ad77ed4a73ee12203041a3c30857eb5d27be84227f581dc1d49fd080`
- Production SDK source pin: `zcash-swift-wallet-sdk` commit
  `4303068e9282bb8b03bd94807b7d8ad268de75bf`, release `2.6.0-alpha.6`
- Canonical wallet backend from that commit's locked graph:
  `zcash_client_backend` 0.23.0 and `zcash_client_sqlite` 0.21.1
- Generator: `Tools/OldOrchardFixtureGenerator` with its checked-in `Cargo.lock`

The released SDK's Swift/FFI test surface can initialize an account but cannot synthesize and scan
an Orchard compact output. To retain real note and scan data, the generator links the exact
upstream backend crate versions and checksums locked by the production SDK commit and invokes
librustzcash's own wallet test backend. This produces the same canonical SQLite schema that the
old FFI initializes; no table or migration marker is hand-authored. The only post-generation data
normalization is:

1. re-encoding the unchanged test-coin UFVK/UIVK bytes from the harness's local-consensus prefix
   to TestNetwork prefixes, matching the old iOS FFI invocation;
2. replacing the randomly assigned account UUID with a fixed test UUID; and
3. sorting the applied-migration marker rows before `VACUUM` so repeated generation is byte-for-byte
   deterministic.

The fixture has one seed-derived account, one cryptographically valid Orchard note worth
123,456,789 zatoshi, and a scanned range crossing testnet NU6.3 activation height 4,134,000. It has
the canonical Orchard-only wallet schema and deliberately contains no Ironwood or
`ext_ironwood_migration_*` objects.

All data is synthetic and public test data. The generator input is the fixed all-zero 32-byte test
seed; the database does not store that seed or any spending-key bytes. It contains only derived
viewing/address data, a synthetic compact transaction identity and received-note payload, and no
raw transaction. It contains no device, endpoint, production-wallet, or user data.
