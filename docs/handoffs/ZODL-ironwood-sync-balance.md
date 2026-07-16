# Handoff — ZODL app: Ironwood (NU6.3) sync/balance in the SDK

**Audience:** whoever maintains the ZODL app's balance UI against `ZcashLightClientKit`.
**Driver:** the SDK gained **Ironwood (NU6.3) receive/sync readiness** on branch
`michal/MOB-1455-ironwood-migration-prototype-ffi` (ticket MOB-1455). This handoff covers the only
app-facing consequence.

## TL;DR

There is **one** app-facing change, and it is **additive**:

```swift
public struct AccountBalance {
    public let saplingBalance: PoolBalance
    public let orchardBalance: PoolBalance
    public let ironwoodBalance: PoolBalance   // NEW
    public let unshielded: Zatoshi
    // …
}
```

`ironwoodBalance` is `.zero` for **every** wallet today and stays that way until NU6.3 activates and a
lightwalletd serves Ironwood data. **No action is required now.** Adopt it only when you want to show
Ironwood holdings.

## What Ironwood is (and isn't) for the app

- **Ironwood is Orchard note-version V3** — same circuit, same keys, **received at the account's
  existing Orchard receiver**. There is **no separate Ironwood address/receiver**; you do not generate
  or display a new address type.
- Everything else the SDK did for this — the compact-block `ironwoodActions` field, the Ironwood
  commitment tree / subtree roots, the scan wiring, the checkpoint `ironwoodTree` — is **internal
  plumbing** and entirely transparent to the app. You keep syncing exactly as before.

## How to treat `ironwoodBalance`

It's a `PoolBalance` just like `saplingBalance` / `orchardBalance` (`spendableValue`,
`changePendingConfirmation`, `valuePendingSpendability`, and `.total()`). Because Ironwood funds live
at the Orchard receiver and are conceptually "Orchard, upgraded," the natural presentations are:

- **Simplest:** fold it into the shielded total — e.g. `orchardBalance.total() + ironwoodBalance.total()`
  (or include it wherever you already sum shielded pools). Until NU6.3 it adds zero, so this is safe to
  ship now.
- **Explicit:** show an "Ironwood" line next to Orchard if/when you want to distinguish post-migration
  funds.

You read it from the same place you read the other balances — `SynchronizerState.accountsBalances`
(`AccountBalance` per `AccountUUID`).

## Status / caveats

- **Dormant until upstream catches up.** `ironwoodBalance` will remain `.zero` until (a) a lightwalletd
  serves Ironwood compact blocks and (b) NU6.3 is activated on the network (its consensus branch id is
  still a placeholder upstream). The SDK is wired and ready; nothing will surface Ironwood balance
  before then.
- **No breaking change.** This is a new field on a public struct. If you exhaustively construct
  `AccountBalance` anywhere (e.g. test fixtures), note the SDK's memberwise initializer defaults the
  optional pools, but the field itself is a new stored property to be aware of.
- **Spending Ironwood** (building transactions that spend received V3 notes) is **not** part of this
  change — it's a separate, later piece. The Orchard→Ironwood *migration* API (separate handoff) already
  covers moving funds into Ironwood.
