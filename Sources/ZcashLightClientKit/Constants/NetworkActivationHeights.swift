//
//  NetworkActivationHeights.swift
//  ZcashLightClientKit
//
//  Network-upgrade activation heights for a custom (regtest) network.
//

import Foundation

/// A Zcash consensus network upgrade whose activation height can be queried from the exact
/// librustzcash revision linked into the SDK. The raw values are a stable SDK/FFI contract; they do
/// not rely on Rust enum discriminants.
public enum NetworkUpgrade: UInt32, CaseIterable, Equatable, Hashable, Sendable {
    case overwinter = 0
    case sapling = 1
    case blossom = 2
    case heartwood = 3
    case canopy = 4
    case nu5 = 5
    case nu6 = 6
    case nu6_1 = 7
    case nu6_2 = 8
    case nu6_3 = 9
    /// Reserved stable SDK/FFI identity for upstream NU7. The pinned Rust revision leaves mainnet
    /// and testnet activation unset and compiles custom NU7 activation only under its upstream
    /// `zcash_unstable="nu7"` cfg.
    case nu7 = 10
}

/// An activation-height or consensus-configuration query could not be resolved by the linked Rust
/// consensus implementation. The associated message is suitable for diagnostics, not UI.
public enum ConsensusParametersError: Error, Equatable, Sendable {
    case unavailable(String)
}

enum ConsensusChainName {
    static func canonicalize(_ value: String) -> String? {
        let canonical = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (1 ... 255).contains(canonical.utf8.count), canonical.unicodeScalars.allSatisfy({ scalar in
            scalar.isASCII && (
                CharacterSet.lowercaseLetters.contains(scalar)
                    || CharacterSet.decimalDigits.contains(scalar)
                    || "._-".unicodeScalars.contains(scalar)
            )
        }) else {
            return nil
        }
        return canonical
    }
}

/// The activation heights of each Zcash network upgrade for a **custom / regtest** network, mirroring
/// the Rust core's `LocalNetwork`. A `nil` height means "not activated on this network".
///
/// Use this with ``ZcashNetworkBuilder/regtest(activationHeights:)`` to point the SDK at a
/// custom-parameter `lightwalletd` (for example an Ironwood testing backend) whose network upgrades
/// activate at arbitrary heights instead of the hardcoded mainnet/testnet values. See `MIGRATING.md`.
///
/// The heights are not validated by the SDK — set them to match the full node / `lightwalletd` you are
/// connecting to (mirroring that node's `nuparams`).
public struct NetworkActivationHeights: Equatable, Hashable, Sendable {
    public var overwinter: BlockHeight?
    public var sapling: BlockHeight?
    public var blossom: BlockHeight?
    public var heartwood: BlockHeight?
    public var canopy: BlockHeight?
    public var nu5: BlockHeight?
    public var nu6: BlockHeight?
    public var nu6_1: BlockHeight?
    public var nu6_2: BlockHeight?
    /// NU6.3 — the "Ironwood" (Orchard note-version V3) activation height.
    public var nu6_3: BlockHeight?
    /// NU7 activation height. Stable builds reject a non-`nil` custom value until upstream removes
    /// the `zcash_unstable="nu7"` gate; the absent value is still committed into the fingerprint.
    public var nu7: BlockHeight?

    public init(
        overwinter: BlockHeight? = nil,
        sapling: BlockHeight? = nil,
        blossom: BlockHeight? = nil,
        heartwood: BlockHeight? = nil,
        canopy: BlockHeight? = nil,
        nu5: BlockHeight? = nil,
        nu6: BlockHeight? = nil,
        nu6_1: BlockHeight? = nil,
        nu6_2: BlockHeight? = nil,
        nu6_3: BlockHeight? = nil,
        nu7: BlockHeight? = nil
    ) {
        self.overwinter = overwinter
        self.sapling = sapling
        self.blossom = blossom
        self.heartwood = heartwood
        self.canopy = canopy
        self.nu5 = nu5
        self.nu6 = nu6
        self.nu6_1 = nu6_1
        self.nu6_2 = nu6_2
        self.nu6_3 = nu6_3
        self.nu7 = nu7
    }

    /// Every network upgrade active from height 1 — the default set used when a regtest network is
    /// built without explicit heights (``ZcashNetworkBuilder/network(for:)`` with ``NetworkType/regtest``).
    public static let allActiveFromGenesis = NetworkActivationHeights(
        overwinter: 1,
        sapling: 1,
        blossom: 1,
        heartwood: 1,
        canopy: 1,
        nu5: 1,
        nu6: 1,
        nu6_1: 1,
        nu6_2: 1,
        nu6_3: 1,
        // NU7 remains gated in the pinned upstream Rust revision. Treat it as not activated rather
        // than enabling proposed consensus rules through an SDK convenience default.
        nu7: nil
    )
}
