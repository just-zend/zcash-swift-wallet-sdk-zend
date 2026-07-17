//! C FFI for the voting functionality.
//!
//! Implementation is split into submodules for navigation. Exported FFI functions
//! keep their stable C symbols with `#[unsafe(no_mangle)]`.
//!
//! [IW-PORT] On the ironwood-support graph, zcash_voting resolves to its 1.0
//! (ironwood-aligned) line, which redesigned the proving/delegation/recovery
//! APIs. The affected extern fns keep their C symbols but return honest
//! "port pending" errors; tree-sync, round listing, and DB open/free remain
//! live. The dead_code allow below covers the 0.11-shaped scaffolding
//! (constants, ProgressBridge, validators, JSON types) kept for that port —
//! remove it when the port lands (census: voting row).
#![allow(dead_code)]

mod constants;
pub mod db;
pub mod delegation;
pub mod ffi_types;
pub mod helpers;
pub mod json;
pub mod notes;
pub mod progress;
pub mod recovery;
pub mod rounds;
pub mod share_tracking;
#[cfg(test)]
pub(crate) mod test_helpers;
pub mod tree;
pub mod util;
pub mod vote;
