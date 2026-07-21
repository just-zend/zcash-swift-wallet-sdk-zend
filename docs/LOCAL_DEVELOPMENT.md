# Local FFI Development

This guide explains how to work on the Rust FFI code alongside the Swift SDK.

## Overview

The SDK uses a pre-built XCFramework (`libzcashlc`) for the Rust FFI layer. For most SDK development, you don't need to rebuild the FFI — SPM automatically downloads the pre-built binary from GitHub Releases.

However, if you need to modify the Rust code in `rust/`, you'll need to set up local FFI development.

## How It Works

`Package.swift` automatically detects `LocalPackages/libzcashlc.xcframework/Info.plist` (created by
the init script and committed on compatibility branches). When it exists, the SDK builds against
that path-based artifact instead of downloading the release binary.

This means switching modes is as simple as:
- **Enable local FFI:** `./Scripts/init-local-ffi.sh`
- **Disable local FFI:** `rm -rf LocalPackages/` (or `./Scripts/reset-local-ffi.sh`)

No manual `Package.swift` edits are needed.

## Prerequisites

1. **Rust toolchain** — Install via [rustup](https://rustup.rs/):
   ```bash
   curl --proto '=https' --tlsv1.3 -sSf https://sh.rustup.rs | sh
   ```

2. **Apple platform targets** — Install the required Rust targets:
   ```bash
   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
   rustup target add aarch64-apple-darwin x86_64-apple-darwin
   ```

## Frozen Ironwood toolchain and release artifact

Ironwood builds use Rust `1.96.1` and the public
`just-zend/librustzcash@5115cf26da590a3d610446f1d926ff7f2873c9d1` graph. The migration crate
and every patched librustzcash-family crate use that same immutable revision. Voting remains enabled
with exact pins for `voting-circuits`, `vote-nullifier-pir`, and `zcash_voting` recorded in
`Cargo.toml` and the artifact provenance.

For a release artifact build, use a clean checkout of the Zend librustzcash fork at the exact
compatibility revision:

```bash
export LIBRUSTZCASH_REPO=/absolute/path/to/just-zend-librustzcash
./Scripts/build-ironwood-ffi-artifact.sh
```

That command audits the dependency graph and builds iOS device arm64, iOS simulator arm64/x86_64,
and macOS arm64/x86_64 at the Swift package's deployment floors. It writes:

- `BuildSupport/IRONWOOD_FFI_BUILD.env` — exact SDK merge inputs, librustzcash revision/tree, voting
  pins, source epoch, platform floors, and Rust toolchain recipe;
- `LocalPackages/IRONWOOD_FFI_PROVENANCE.env` — recipe plus SDK source hash, Apple SDK/Xcode
  versions, architecture-complete slice hashes, and XCFramework manifest hash;
- `LocalPackages/libzcashlc.xcframework` — the full artifact consumed directly by SwiftPM.

Run `./Scripts/verify-ironwood-ffi-artifact.sh` before committing. It derives every production
`zcashlc_*` symbol from Swift, requires each symbol in every binary and generated header, verifies
source/toolchain/slice hashes, architecture coverage, Mach-O platform floors, and rejects local
build paths or Rust source material under `LocalPackages`. Public GitHub Actions packages only the
already committed, provenance-locked XCFramework and refuses to overwrite an existing release.

## Quick Start

### One-Time Setup

You **must** run `init-local-ffi.sh` before opening the project in Xcode. Without it, SPM will attempt to download the release binary, which may not exist for development branches.

```bash
# Clone the repository
git clone https://github.com/zcash/zcash-swift-wallet-sdk
cd zcash-swift-wallet-sdk

# Initialize local FFI (builds from source)
./Scripts/init-local-ffi.sh
```

The `--cached` flag downloads a pre-built release instead of building from source. This only works when `Package.swift` points to a published release:

```bash
./Scripts/init-local-ffi.sh --cached
```

**Warning:** Only use `--cached` if there have been no FFI changes on your branch since the last release. Using a stale pre-built binary with modified Swift bindings could cause silent data corruption and loss of funds. Additionally, `--cached` skips the Rust build entirely, so the first call to `rebuild-local-ffi.sh` will be a full (non-incremental) build.

For faster iteration on Apple Silicon you can build only the arm64 slices you need, skipping the x86_64 simulator/Mac slices you can't run there anyway:

```bash
./Scripts/init-local-ffi.sh --arm-macos # macOS (swift build / swift test on the Mac)
./Scripts/init-local-ffi.sh --arm-ios   # iOS simulator + device
./Scripts/init-local-ffi.sh --arm-all   # iOS simulator + device + macOS
```

Building for a slice you didn't include will fail until you build it (via `rebuild-local-ffi.sh` or a full `init-local-ffi.sh`).

### Opening in Xcode

You can open the project two ways:

- **Workspace** (recommended for FFI development) — includes the FFIBuilder target that automatically rebuilds the FFI when you build in Xcode:
  ```bash
  open ZcashSDK.xcworkspace
  ```
- **Package directly** — simpler, but you'll need to run `rebuild-local-ffi.sh` manually after Rust changes:
  ```bash
  open Package.swift
  ```

If Xcode was already open before you ran `init-local-ffi.sh`, reset package caches: File > Packages > Reset Package Caches.

### Development Loop

```bash
# 1. Edit Rust code
vim rust/src/lib.rs

# 2. Fast incremental rebuild (seconds, not minutes!)
./Scripts/rebuild-local-ffi.sh              # iOS Simulator (default)
./Scripts/rebuild-local-ffi.sh ios-device   # iOS Device
./Scripts/rebuild-local-ffi.sh macos        # macOS

# 3. Build/test in Xcode
#    Clean build folder if Xcode doesn't pick up changes: Cmd+Shift+K
```

### Switching Back to Release Binary

```bash
./Scripts/reset-local-ffi.sh
```

If using Xcode, you may also need to reset package caches: File > Packages > Reset Package Caches.

## Scripts Reference

### `init-local-ffi.sh`

One-time setup that creates the local development environment.

```bash
./Scripts/init-local-ffi.sh             # Build from source, all 5 architectures (recommended)
./Scripts/init-local-ffi.sh --arm-macos # arm64 macOS slice only
./Scripts/init-local-ffi.sh --arm-ios   # arm64 iOS simulator + device slices
./Scripts/init-local-ffi.sh --arm-all   # arm64 iOS simulator + device + macOS slices
./Scripts/init-local-ffi.sh --cached    # Download pre-built release
```

This script:
- Builds the full XCFramework (all 5 architectures), an arm64-only subset (`--arm-*`, faster on Apple Silicon since it skips the x86_64 slices), or downloads a pre-built one
- Creates `LocalPackages/` with an SPM wrapper package
- `Package.swift` automatically detects `LocalPackages/` and switches to local mode

The `--arm-*` flags always build the `aarch64-*` targets regardless of host architecture. They produce an XCFramework containing only the requested arm64 slices, so building for an x86_64 simulator/Mac (or a slice you didn't include) will fail until you build it — run `rebuild-local-ffi.sh <target>` or a full `init-local-ffi.sh` to add the missing slices. Any unrecognized flag prints usage and exits without building.

### `rebuild-local-ffi.sh`

Fast incremental rebuild for the current development target. Requires `init-local-ffi.sh` to have been run first.

```bash
./Scripts/rebuild-local-ffi.sh [target]
```

Targets:
- `ios-sim` (default) — iOS Simulator, auto-detects arm64 vs x86_64
- `ios-device` — iOS Device (arm64)
- `macos` — macOS, auto-detects arm64 vs x86_64

**Why it's fast:** Only builds ONE architecture, and Cargo's incremental compilation means small changes rebuild in seconds.

**Note:** This creates a single-architecture build. Run `init-local-ffi.sh` before submitting PRs to verify all architectures compile.

### `reset-local-ffi.sh`

Removes `LocalPackages/` and switches back to the release binary.

```bash
./Scripts/reset-local-ffi.sh
```

## Architecture Details

### XCFramework Structure

The XCFramework contains three platform slices, and each slice's
LibraryIdentifier names exactly the architectures its binary contains:

- Full 5-arch release build (`make xcframework`): `ios-arm64`,
  `ios-arm64_x86_64-simulator` (universal), `macos-arm64_x86_64` (universal).
- Single-arch builds (`init-local-ffi.sh --arm-*`, `rebuild-local-ffi.sh`, and
  the xcframework committed under `LocalPackages/` on the fork line):
  `ios-arm64`, `ios-arm64-simulator`, `macos-arm64` — or the `x86_64`
  spellings when built on an Intel host.

An identifier must never advertise an architecture the binary lacks: a
multi-arch consumer build (e.g. `-destination 'generic/platform=iOS
Simulator'`) then dies late at link time with missing `_zcashlc_*` symbols for
the absent architecture instead of an explicit unsupported-architecture error.
The committed fork-line xcframework stays arm64-only by design — one
architecture is ~52MB, so a fat slice would cross GitHub's 100MB file limit.

### Build Targets

| Development Target | Rust Target | XCFramework Slice |
|-------------------|-------------|-------------------|
| iOS Simulator (Apple Silicon) | `aarch64-apple-ios-sim` | `ios-arm64-simulator` |
| iOS Simulator (Intel) | `x86_64-apple-ios` | `ios-x86_64-simulator` |
| iOS Device | `aarch64-apple-ios` | `ios-arm64` |
| macOS (Apple Silicon) | `aarch64-apple-darwin` | `macos-arm64` |
| macOS (Intel) | `x86_64-apple-darwin` | `macos-x86_64` |

### Local Package Override

The `LocalPackages` directory contains a Swift package named `libzcashlc` with the same product name as the binary target in `Package.swift`. When `Package.swift` detects that `LocalPackages/Package.swift` exists, it adds `LocalPackages` as a path dependency and uses it instead of the `.binaryTarget` declaration. This switching is automatic — no manual edits to `Package.swift` are needed.

## Automatic FFI Rebuilds

The shared `ZcashLightClientKit` scheme in `ZcashSDK.xcworkspace` includes `FFIBuilder` as a build dependency. FFIBuilder runs `rebuild-local-ffi.sh` with the appropriate platform based on your selected destination, so Rust code is automatically recompiled when you build in Xcode.

**Note:** The FFIBuilder target requires `init-local-ffi.sh` to have been run first — it calls `rebuild-local-ffi.sh`, which expects `LocalPackages/` to exist.

| Approach | Best for |
|----------|----------|
| Manual script (`rebuild-local-ffi.sh`) | Occasional FFI changes, simple setup |
| FFIBuilder target in workspace | Frequent FFI changes, prefer staying in Xcode |

## Troubleshooting

### Xcode can't resolve packages / shows 404 error

This means `LocalPackages/` doesn't exist and SPM is trying to download the release binary. Run `./Scripts/init-local-ffi.sh` to set up local development, then reset package caches in Xcode: File > Packages > Reset Package Caches.

### Xcode doesn't pick up FFI changes

1. Clean the build folder: Cmd+Shift+K
2. If that doesn't work, reset package caches: File > Packages > Reset Package Caches
3. If that doesn't work, close Xcode and delete DerivedData:
   ```bash
   rm -rf ~/Library/Developer/Xcode/DerivedData
   ```

### Build fails with missing target

Ensure all Rust targets are installed:
```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

### Header changes not reflected

The headers are regenerated during cargo build. If you see stale headers:
```bash
rm -rf target/Headers
./Scripts/rebuild-local-ffi.sh
```

### Xcode uses wrong FFI after switching modes

After running `init-local-ffi.sh` or `reset-local-ffi.sh`, Xcode may need to re-resolve packages:
1. File > Packages > Reset Package Caches
2. If that doesn't help, close and reopen the workspace

### FFIBuilder fails on first workspace open

When opening `ZcashSDK.xcworkspace` for the first time after running `init-local-ffi.sh`, FFIBuilder may fail with "Command PhaseScriptExecution failed with a nonzero exit code". This is a timing issue -- Xcode may attempt to build FFIBuilder before package resolution has completed. Run "Product > Build For > Testing" manually and the build should succeed. Subsequent builds will work normally.

### FFI rebuilds from scratch despite no changes

The Makefile (used by `init-local-ffi.sh`) and `rebuild-local-ffi.sh` invoke `cargo` with slightly different environment variables, which can cause Cargo to invalidate its build cache. This means the first `rebuild-local-ffi.sh` after `init-local-ffi.sh` (or vice versa) may do a full rebuild. Subsequent incremental rebuilds within the same tool will be fast.

### `rustup: command not found` in Xcode build

The scripts source `~/.cargo/env` to find the Rust toolchain. If you installed Rust via a non-standard method (e.g., Homebrew, Nix), you may need to ensure `cargo` and `rustup` are on the default PATH or add the appropriate source/export to `~/.zprofile`.

## Full Rebuild

Before submitting a PR that modifies Rust code:

```bash
# Full rebuild to verify all architectures compile
./Scripts/init-local-ffi.sh

# Run tests
swift test
```
