# Handoff — ZODL app: configurable NU activation heights (regtest / custom networks)

**Audience:** whoever runs the ZODL app against a custom-parameter (regtest) `lightwalletd` — e.g. the
Ironwood testing backend.
**Driver:** the SDK gained **configurable network-upgrade activation heights** on branch
`michal/MOB-1455-4-set-activation-height` (ticket MOB-1455), so it can connect to and sync a network
whose NUs activate at arbitrary heights instead of the hardcoded mainnet/testnet values.

## TL;DR

The change is **additive and opt-in**. Mainnet/testnet users and all existing code are unaffected. A new
builder produces a `ZcashNetwork` carrying custom per-NU activation heights, which you hand to the
existing `Initializer(network:)`:

```swift
let network = ZcashNetworkBuilder.regtest(activationHeights: NetworkActivationHeights(
    sapling: 1,
    nu5: 100,
    nu6: 200,
    nu6_3: 5000   // Ironwood (NU6.3); the testing backend's NU6.3 height
))

let initializer = Initializer(
    // … your usual URLs / endpoint / params …
    network: network
)
```

Set the heights to **mirror the `nuparams` of the node / `lightwalletd` you connect to**. A `nil` height
means "not activated on this network". You only need to set the upgrades your backend actually activates,
but if the backend stacks NU6.1/NU6.2 at specific heights, set those too (`nu6_1`, `nu6_2`) — otherwise the
SDK's consensus-branch check can disagree with the server between those heights.

## New public API

```swift
// Per-NU activation heights, mirroring the Rust core's LocalNetwork. nil = "not activated".
public struct NetworkActivationHeights: Equatable, Hashable, Sendable {
    public var overwinter, sapling, blossom, heartwood, canopy: BlockHeight?
    public var nu5, nu6, nu6_1, nu6_2, nu6_3: BlockHeight?   // nu6_3 == Ironwood
    public init(/* all params, each defaulting to nil */)
    public static let allActiveFromGenesis: NetworkActivationHeights   // everything at height 1
}

// Build a custom (regtest) ZcashNetwork. This is how you select regtest — you never construct the
// NetworkType case yourself.
public extension ZcashNetworkBuilder {
    static func regtest(activationHeights: NetworkActivationHeights) -> ZcashNetwork
}

// New identity case (internal plumbing; select via the builder above, not by constructing this).
public enum NetworkType { case mainnet, testnet, regtest }

// ZcashNetwork gains two additive, default-implemented members (existing conformers keep working):
//   var saplingActivationHeight: BlockHeight        // regtest returns its configured Sapling height
//   var customActivationHeights: NetworkActivationHeights?   // non-nil only for regtest
```

## Behavior you must know

- **Regtest addresses & chain identity.** A regtest network reports its type as **Regtest**: unified /
  Sapling / transparent addresses are **regtest-encoded** (different human-readable prefixes than
  testnet), and the SDK expects the server to report `chainName == "regtest"`. Any address display,
  validation, or comparison in the app must expect regtest encodings. *(If the testing backend reports a
  different `chainName`, tell the SDK team — the mapping needs the actual value.)*
- **Separate on-disk namespace.** Regtest databases use the prefix `ZcashSdk_regtest_`, so they will not
  collide with existing mainnet/testnet wallet data.
- **Birthday / checkpoints.** Regtest ships no bundled checkpoints. A fresh regtest wallet scans from the
  Sapling activation height with an empty note-commitment tree. For a **new wallet** the SDK fetches the
  birthday tree state from the server automatically. If you need a birthday above genesis with a known
  tree, seed it via `Synchronizer.getTreeState(height:)`.

## Limitations / not yet supported

- **Migration on regtest is not available yet.** You can **connect, sync, and read balances** against the
  custom backend, but running the **Orchard→Ironwood migration** there is a follow-up: the migration
  engine (`zodl_ironwood_migration`) has no custom-network variant, so the migration FFI returns a clear
  "regtest not supported yet (MOB-1455)" error.
- **Standalone `DerivationTool(networkType: .regtest)`** used *without* an `Initializer` won't have the
  regtest activation heights registered (they're registered when the `Initializer` is created). Derive
  through an SDK instance configured with the regtest network.

## Consuming it before a tagged release

This lands on `michal/MOB-1455-4-set-activation-height`. Because the Rust FFI changed, it is **not** in a
published `libzcashlc` release yet — depend on this SDK branch with a **local FFI build**
(`./Scripts/init-local-ffi.sh`) until a tagged release ships. Normal app releases must still pin a
published SDK tag.
