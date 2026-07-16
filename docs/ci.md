# Continuous Integration

The project uses GitHub Actions for CI. Workflows are defined in `.github/workflows/`.

## PR Checks

When a PR is opened, the following checks run automatically:

- **SwiftLint** (`swiftlint.yml`) — checks Swift code style
- **Build and Run Offline Tests** (`swift.yml`) — builds the FFI from source (with caching), builds the Swift package, and runs the `OfflineTests` suite

## FFI Build Workflow

The **Build FFI XCFramework** workflow (`build-ffi.yml`) is triggered manually via `workflow_dispatch` and is used to prepare release artifacts. It builds the full XCFramework for all platforms, creates a zip archive with checksum, and uploads them as a draft GitHub Release.

## Manual Deployment

Prerequisites:
- Write permissions on the repo
- `gh` CLI installed and authenticated
- Rust toolchain with all Apple platform targets
- GPG key configured for tag signing

Steps:
- Use `./Scripts/release.sh <remote> <version>` for a fully automated release, or
- Use `./Scripts/prepare-release.sh <version>` for a semi-automated process with manual steps

Versions with a SemVer pre-release suffix (e.g. `2.6.0-alpha.1`) are detected automatically
and the GitHub release is marked as a pre-release.

See the scripts themselves for detailed usage instructions.
