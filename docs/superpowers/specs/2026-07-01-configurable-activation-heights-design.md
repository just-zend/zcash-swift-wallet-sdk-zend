# Design — Configurable NU activation heights (regtest / custom-network support)

**Date:** 2026-07-01
**Branch:** current branch `michal/MOB-1455-4-set-activation-height`. Work lands as small, logically-scoped
commits (see §9).
**Ticket:** MOB-1455 (Ironwood).

## 1. Context & findings (verified)

The SDK hardcodes Zcash network-upgrade (NU) activation heights, so it cannot connect to a lightwalletd
backed by a **custom-parameter (regtest-style) network** — e.g. the Ironwood testing backend where NU5,
NU6.3 ("Ironwood"), etc. activate at arbitrary low heights. A colleague's testing backend has
**NU6.3 height = 5000**; the canonical example is "NU5 at height 100, Ironwood at height 700, Sapling
near 1." Connecting a normal SDK to such a server fails.

The heights are hardcoded in **two coupled layers**:

**Swift layer** — `ValidateServerAction` runs every sync and enforces two relevant guards:
- **Sapling guard:** `config.saplingActivation == info.saplingActivationHeight`
  (`280_000`/`419_200` vs the server's value). First failure.
  ([`ValidateServerAction.swift:43`](../../../Sources/ZcashLightClientKit/Block/Actions/ValidateServerAction.swift))
- **Branch-ID guard:** `remoteBranchID == rustBackend.consensusBranchIdFor(height:)`, where the local
  branch ID is computed by **Rust from its own hardcoded params**. Second failure — and the reason a
  Swift-only fix is insufficient. ([`ValidateServerAction.swift:48`](../../../Sources/ZcashLightClientKit/Block/Actions/ValidateServerAction.swift))

Swift's `NetworkConstants.saplingActivationHeight` is a **type-level `static`**
([`ZcashSDK.swift:158`](../../../Sources/ZcashLightClientKit/Constants/ZcashSDK.swift)), read in ~6
places (`Initializer`, `TransactionEntity`, `SDKSynchronizer`, `CompactBlockProcessor`,
`BundleCheckpointSource`). The Swift layer needs **only Sapling** at runtime; it does **not** reference
an Ironwood height directly (migration scheduling is Rust-single-sourced).

**Rust layer (`rust/src/`)** — every FFI call takes `network_id: u32` →
`parse_network()` → `Network::{MainNetwork, TestNetwork}`, both with heights baked into librustzcash.
([`lib.rs:4214`](../../../rust/src/lib.rs)) Rust needs the **full** NU set to scan correctly and to
compute the branch ID the Swift branch-ID guard checks.

**The enabling discovery:** the pinned valargroup `librustzcash` fork already ships
**`LocalNetwork`** — a `Parameters` impl carrying per-NU activation heights up to `Nu6_3`/`Nu7`, whose
`network_type()` returns `Regtest`
([`zcash_protocol/src/local_consensus.rs:41`](file:///Users/chlup/.cargo/git/checkouts/librustzcash-5d5cec06bd56a35c/0c3ad73/components/zcash_protocol/src/local_consensus.rs)).
It is exactly "regtest mode like zebra"; it is simply **not wired through our FFI**. So the Rust work is
"thread `LocalNetwork` through the FFI," not "invent custom consensus."

**Rust churn is small and contained.** `Network` appears in only 7 lines of `lib.rs`: the import, the
single `wallet_db(...)` helper (param + return type), and `parse_network`. Every other FFI function just
forwards whatever `parse_network` returns. `migration.rs` has its **own** height→network mapper
(`migration_network`, [`migration.rs:27`](../../../rust/src/migration.rs)) over the migration crate's
separate `Network` enum. `derivation.rs` and `ffi.rs` consume `parse_network`/`impl Parameters`
generically.

## 2. Goal & scope

**Goal:** let the SDK **connect to and correctly sync** a custom-parameter (regtest) lightwalletd by
supplying arbitrary NU activation heights — so the Ironwood testing backend can be exercised.

**In scope:**
- A public way to construct a custom-height `ZcashNetwork` (builder), heights carried on the instance.
- Threading those heights into the Rust core via `LocalNetwork`, so scanning, branch-ID, tree logic,
  and address encoding all use the custom params.
- Making `ValidateServerAction` accept a matching custom-height server (Sapling + branch-ID guards pass).
- Minimal regtest birthday/checkpoint handling so a fresh regtest wallet can start syncing.
- `CHANGELOG.md` + `MIGRATING.md` entries per repo conventions (additive public API).

**Out of scope (explicit):**
- **Running the Orchard→Ironwood migration on regtest.** The migration crate
  (`zodl_ironwood_migration`, a `../ZODLIronwoodMigrationRust` path dep) has its own `Network` enum with
  only Test/Main; `migration_network(2)` errors. Enabling migration on regtest is a **follow-up in the
  sibling crate** (§10). This branch delivers *connect + sync*.
- **Bundled regtest checkpoints** — none exist; regtest starts from a synthesized empty-tree floor (§6.7).
- **Standalone `DerivationTool(networkType:)` on regtest** without an `Initializer`/sync context — the
  regtest params are registered on the sync path; standalone derivation is a documented limitation (§10).
- **Production/mainnet exposure** — the feature is clearly labeled for custom/regtest networks only.

**Decisions locked in (from brainstorming):**
1. **Scope:** test/dev-scoped but clean (Swift + FFI; minimal public surface; still CHANGELOG/MIGRATING).
2. **API shape:** custom `ZcashNetwork` via a **builder**; heights live on the instance;
   `Initializer(network:)` is untouched.
3. **Identity:** regtest network identity (Regtest address HRPs, `chainName` "regtest") is acceptable.

## 3. Approach (overview)

Introduce a third network identity, **regtest**, that flows through the *existing* single identity
channel (`networkType.networkId` → FFI → `parse_network`). Selection is via a new builder that attaches
a full `NetworkActivationHeights` value to the `ZcashNetwork` instance. On the sync path those heights
are registered once with the Rust core (a new setter FFI); Rust's `parse_network` then returns a
`LocalNetwork`-backed params object for the regtest id, so **all ~40 existing FFI calls work unchanged**.

Rationale for a third `NetworkType` case (vs. keeping two): `networkType` is the SDK's one address/
derivation/DB identity, threaded into `ZcashRustBackend`, `ZcashKeyDerivationBackend`, `DerivationTool`,
`UnifiedAddress`, etc. A distinct `network_id` is **required** anyway (regtest must not be confused with
testnet in Rust), and giving regtest a real identity keeps Swift and Rust address encoding consistent
for free. This does **not** contradict decision #2: clients still *select* via the builder and never
hand-construct `NetworkType`; the enum case is internal plumbing. The exhaustive-switch cost is ~5 small,
mechanical arms.

## 4. Public API surface (additive)

```swift
// New: full NU activation-height set, mirroring the fork's LocalNetwork (nil = "not activated").
public struct NetworkActivationHeights: Equatable, Sendable {
    public var overwinter: BlockHeight?
    public var sapling: BlockHeight?
    public var blossom: BlockHeight?
    public var heartwood: BlockHeight?
    public var canopy: BlockHeight?
    public var nu5: BlockHeight?
    public var nu6: BlockHeight?
    public var nu6_1: BlockHeight?
    public var nu6_2: BlockHeight?
    public var nu6_3: BlockHeight?   // Ironwood
    public init( ... all params, each defaulting to nil ... )
}

// New builder entry point (existing .network(for:) is unchanged for main/test).
public extension ZcashNetworkBuilder {
    static func regtest(activationHeights: NetworkActivationHeights) -> ZcashNetwork
}

// New enum case (internal identity; clients use the builder, not this case directly).
public enum NetworkType { case mainnet, testnet, regtest }
```

`ZcashNetwork` gains two instance members (default-implemented, so existing conformers are unaffected):
```swift
public protocol ZcashNetwork {
    var networkType: NetworkType { get }
    var constants: NetworkConstants.Type { get }
    var saplingActivationHeight: BlockHeight { get }         // default: constants.saplingActivationHeight
    var customActivationHeights: NetworkActivationHeights? { get } // default: nil
}
```

Clients use it via the already-untouched `Initializer(network:)`:
```swift
let network = ZcashNetworkBuilder.regtest(activationHeights: .init(
    sapling: 1, nu5: 100, nu6: 700, nu6_3: 700 /* Ironwood */))
let initializer = Initializer(/* … */, network: network, /* … */)
```

## 5. Detailed design — Swift

**5.1 `NetworkType.regtest`** ([`ZcashSDK.swift`](../../../Sources/ZcashLightClientKit/Constants/ZcashSDK.swift))
- `networkId = 2`; `chainName = "regtest"`; `forChainName("regtest") = .regtest`;
  `forNetworkId(2) = .regtest`.
- `ZcashNetworkBuilder.network(for: .regtest)` returns a `ZcashRegtest` with a **default all-at-height-1**
  height set (keeps the switch total + harmless); real use goes through `.regtest(activationHeights:)`.

**5.2 `ZcashRegtest: ZcashNetwork`** — `networkType = .regtest`; `constants = ZcashSDKRegtestConstants.self`
(new; `defaultDbNamePrefix = "ZcashSdk_regtest_"` to avoid colliding with testnet DBs; other members mirror
testnet); stores the provided `NetworkActivationHeights` and returns it from `customActivationHeights`;
`saplingActivationHeight` returns `customActivationHeights.sapling ?? 1` (regtest Sapling is at/near
genesis; `1` is the safe floor if a caller omits it).

**5.3 Migrate the 6 Sapling read-sites** from type-level `constants.saplingActivationHeight` /
hardcoded `ZcashMainnet()/ZcashTestnet()` lookups to the **injected instance** `network.saplingActivationHeight`:
`Initializer.swift:470`, `TransactionEntity.swift:237,242`, `SDKSynchronizer.swift:827-829`,
`CompactBlockProcessor.swift:139`, and `BundleCheckpointSource` (§6.7). This is the change that makes the
Swift **Sapling guard** honor the custom height.

**5.4 Register heights with Rust on the sync path.** `Dependencies` builds the object graph from
`network`. Where `customActivationHeights != nil`, call the new setter FFI **once** (before backends are
used) so the process-global regtest params are populated. Thread `network` (or the heights) into
`ZcashRustBackend`/`ZcashKeyDerivationBackend` construction so both the DB and key-derivation FFI use the
regtest id consistently. ([`Dependencies.swift:29,80,193`](../../../Sources/ZcashLightClientKit/Synchronizer/Dependencies.swift))

**5.5 `ValidateServerAction`** needs no structural change: once `config.saplingActivation` is the regtest
instance height and Rust computes the branch ID from `LocalNetwork`, both guards pass. The only new
requirement is `chainName` mapping (5.1). *Assumption:* the backend reports `chainName == "regtest"` —
**verify against the live server** (§11); adjust the mapping if it differs.

## 6. Detailed design — Rust FFI

**6.1 `NetworkParams` enum** (new, in `lib.rs`):
```rust
#[derive(Clone, Copy)]
pub(crate) enum NetworkParams { Standard(Network), Regtest(LocalNetwork) }
impl zcash_protocol::consensus::Parameters for NetworkParams {
    fn network_type(&self) -> NetworkType { /* delegate */ }
    fn activation_height(&self, nu: NetworkUpgrade) -> Option<BlockHeight> { /* delegate */ }
}
```
`NetworkParams: Parameters + Copy`, so it is a drop-in for the concrete `Network`.

**6.2 Process-global regtest params + setter FFI:**
```rust
static REGTEST_PARAMS: LazyLock<RwLock<Option<LocalNetwork>>> = /* None */;

#[no_mangle] pub extern "C" fn zcashlc_set_regtest_activation_heights(
    overwinter: i64, sapling: i64, blossom: i64, heartwood: i64, canopy: i64,
    nu5: i64, nu6: i64, nu6_1: i64, nu6_2: i64, nu6_3: i64) -> bool
// i64 with -1 = None; builds a LocalNetwork and stores it. Idempotent.
```
(Declared in `rust/wrapper.h`; surfaced through the generated `libzcashlc` header.)

**6.3 `parse_network`** → returns `NetworkParams`:
`NETWORK_ID_TESTNET → Standard(TestNetwork)`, `NETWORK_ID_MAINNET → Standard(MainNetwork)`,
`NETWORK_ID_REGTEST (2) → Regtest(*REGTEST_PARAMS.read()…)` (error if unset).

**6.4 `wallet_db(...)`** helper: `network: NetworkParams`, returning
`WalletDb<Connection, NetworkParams, SystemClock, OsRng>`. This + `parse_network` + the import are the
**only** signature edits; the ~40 FFI functions forward `NetworkParams` unchanged.

**6.5 `migration.rs`** — out of scope to *enable*, but `migration_network(2)` must fail cleanly with a
clear "regtest not supported by the migration engine yet" error rather than a generic one (§10 follow-up).

## 7. Checkpoints & birthday for regtest (§6.7)

`BundleCheckpointSource` switches mainnet/testnet and reads bundled JSON; regtest has none.
`CheckpointSourceFactory.fromBundle(for:)` ([`Dependencies.swift:30`](../../../Sources/ZcashLightClientKit/Synchronizer/Dependencies.swift))
will, for regtest, produce a source whose `saplingActivation` floor is a **synthesized empty-tree
checkpoint** at the regtest Sapling height:
`Checkpoint(height: saplingHeight, hash: <zeroed/placeholder>, time: <placeholder>, saplingTree: "000000",
orchardTree: nil, ironwoodTree: nil)` — mirroring `Checkpoint.testnetMin`
([`Checkpoint+testnet.swift`](../../../Sources/ZcashLightClientKit/Constants/Checkpoint+testnet.swift)).
With no bundle directory, `Checkpoint.birthday(with:…)` finds nothing and falls back to this floor, so a
regtest wallet starts from Sapling activation with empty trees (correct for a chain scanned from near
genesis). Clients needing a higher birthday can seed tree state via the existing public
`getTreeState(height:)` ([`SDKSynchronizer.swift:1214`](../../../Sources/ZcashLightClientKit/Synchronizer/SDKSynchronizer.swift)).
The floor's `hash`/`time` are load-bearing only for reorg-continuity from genesis; verified during
implementation (§11).

## 8. Testing strategy

Prefer TDD where the unit is offline-testable.

**Offline (CI `OfflineTests`) — the bulk of coverage:**
- `NetworkActivationHeights` + `ZcashNetworkBuilder.regtest`: instance carries heights;
  `saplingActivationHeight`/`customActivationHeights` correct; `networkId == 2`; `chainName`/`forChainName`
  round-trip.
- The 6 migrated Sapling read-sites return the regtest instance height.
- A `ValidateServerAction` unit test with a mocked service (`LightWalletServiceMock`, regenerated
  `AutoMockable`) reporting `chainName "regtest"`, matching `saplingActivationHeight`, and a matching
  branch ID → passes; mismatches → the existing typed errors.
- Regtest checkpoint floor: `birthday(for:)` returns the synthesized empty-tree checkpoint.
- Rust unit tests: `NetworkParams` delegates `activation_height`/`network_type` correctly;
  `parse_network(2)` errors when unset and yields the `LocalNetwork` when set.

**Requires the local FFI build** (Rust changed): rebuild via `./Scripts/rebuild-local-ffi.sh macos`
(and full `./Scripts/init-local-ffi.sh` before PR); verify `OfflineTests` via the Xcode MCP
(`RunSomeTests`/`RunAllTests`), not `swift build` (can't resolve `libzcashlc` in local-FFI mode).

**Live (manual, needs the backend) — owned by the user (decided).** Implementation is **offline-complete**:
all `OfflineTests` + Rust unit tests pass and the local FFI is rebuilt before the work is called done. The
**live sync against the Ironwood testing backend is run by the user.** The final report will state exactly
what was verified offline, the outstanding `chainName` assumption (§11), and the precise steps for the
live check (build a `regtest` network with the real heights → `Initializer(network:)` → confirm
`ValidateServerAction` passes and sync progresses).

## 9. Commit plan (small, logically-scoped)

1. **Swift models:** `NetworkActivationHeights`, `NetworkType.regtest` + `networkId`/`chainName`/
   mappers, `ZcashSDKRegtestConstants`, `ZcashRegtest`, `ZcashNetworkBuilder.regtest`, `ZcashNetwork`
   instance members. + offline tests.
2. **Swift read-site migration:** the 6 Sapling sites → `network.saplingActivationHeight`. + tests.
3. **Rust FFI:** `NetworkParams`, `REGTEST_PARAMS` + setter, `parse_network`/`wallet_db` swap,
   `NETWORK_ID_REGTEST`, `migration_network` clean error, header/wrapper. + Rust unit tests.
4. **Swift↔FFI wiring:** register heights in `Dependencies`; thread `network` into the backends;
   welding surface for the setter. + marshalling test.
5. **Checkpoints:** regtest floor + `CheckpointSourceFactory` regtest arm. + test.
6. **Docs + ZODL handoff:** `CHANGELOG.md`, `MIGRATING.md` (additive API + how to build a regtest
   network), and the **ZODL handoff document** at
   `docs/handoffs/ZODL-regtest-activation-heights.md` describing every app-facing change — contents
   specified in §12.

## 10. Known follow-ups / non-blocking gaps (for the final report)

- **Migration on regtest:** `zodl_ironwood_migration::Network` (sibling crate `../ZODLIronwoodMigrationRust`)
  supports only Test/Main; `migration_network(2)` will error by design. Enabling the actual Orchard→Ironwood
  migration against the testing backend requires that crate to accept regtest/`LocalNetwork` params.
- **Standalone `DerivationTool(networkType: .regtest)`** without an `Initializer` won't have regtest params
  registered (they're set on the sync path). Document; consider a register-on-demand hook later.
- **Checkpoint `hash`/`time` fidelity** for non-genesis regtest birthdays — MVP relies on the empty-tree
  floor / `getTreeState`; a fuller regtest checkpoint story is deferred.

## 11. Risks & assumptions

- **`chainName` value** from the backend is assumed `"regtest"`; if it differs, the network-type guard
  needs a matching mapping. **Verify live.**
- **Global regtest params** ⇒ one regtest config per process (fine for test/dev; parallel offline tests
  must not assert two different regtest configs simultaneously).
- **Regtest address HRPs** differ from testnet (accepted, decision #3); any tooling comparing addresses
  must expect regtest encodings.
- Requires a **local FFI rebuild**; reviewers must run `init-local-ffi.sh` (Rust changed vs. the release
  binary).

## 12. ZODL handoff document (deliverable)

A handoff is produced at `docs/handoffs/ZODL-regtest-activation-heights.md`, matching the style of the
existing `docs/handoffs/ZODL-*` notes (audience → driver → TL;DR → API → usage → caveats). It is the
single source the ZODL app team needs to point the app at the Ironwood testing backend. It **must**
cover:

1. **Audience & driver.** Whoever runs the ZODL app against a custom-parameter (regtest) lightwalletd;
   driver = SDK gained configurable NU activation heights on branch `michal/MOB-1455-4-set-activation-height`
   (MOB-1455).

2. **TL;DR.** The change is **additive and opt-in**: mainnet/testnet users and existing code are
   completely unaffected. A new builder lets the app construct a `regtest` network with arbitrary NU
   activation heights and hand it to the existing `Initializer(network:)`.

3. **New public API** (verbatim signatures, kept in sync with what actually ships):
   `NetworkActivationHeights`, `ZcashNetworkBuilder.regtest(activationHeights:)`, the `NetworkType.regtest`
   case (noting clients select via the builder, never by constructing the case), and the additive
   `ZcashNetwork` instance members.

4. **Usage example.** Building the network from the backend's real heights (e.g. NU6.3 = 5000; the
   NU5=100/Ironwood=700 example) and passing it to `Initializer`:
   ```swift
   let network = ZcashNetworkBuilder.regtest(activationHeights: .init(
       sapling: 1, nu5: 100, /* … */ nu6_3: 5000))
   let initializer = Initializer(/* … */, network: network, /* … */)
   ```

5. **Behavioral implications the app must know:**
   - **Regtest address HRPs** — unified/sapling/transparent addresses are **regtest-encoded**, not
     testnet; any address display/validation/tooling must expect that.
   - **Separate on-disk namespace** — regtest uses DB prefix `ZcashSdk_regtest_`, so it will not collide
     with existing testnet/mainnet wallet data.
   - **Birthday/checkpoints** — no bundled checkpoints; a fresh regtest wallet starts from an empty-tree
     floor at the Sapling height (scan from near genesis), or supply an explicit birthday and seed tree
     state via `getTreeState(height:)`.
   - **Server `chainName`** — the SDK expects the backend to identify as `"regtest"`; if the testing
     server reports otherwise, flag it (the SDK mapping needs the actual value).

6. **Limitations / not-yet (set expectations clearly):**
   - **Migration on regtest is not supported yet.** The app can **connect, sync, and read balances**
     against the backend, but running the Orchard→Ironwood **migration** there is a follow-up (needs the
     `zodl_ironwood_migration` crate to accept regtest params). See §10.
   - **Standalone `DerivationTool(networkType: .regtest)`** without an `Initializer` won't have regtest
     params registered.

7. **How to consume it pre-release.** Clients normally depend on published tags; this lands on
   `michal/MOB-1455-4-set-activation-height` and (because Rust changed) needs the fork/local-FFI build —
   state how the app should pin it until a tagged release.
