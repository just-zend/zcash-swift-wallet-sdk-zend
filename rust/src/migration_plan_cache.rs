//! In-process cache of the most recent [`MigrationPlan`] per `(database, account)`, bridging the
//! gap between `plan_migration()` (a pure, unpersisted preview) and the commit functions
//! (`commit_preparation`/`build_preparation_unsigned`) that must sign that exact plan value later.
//!
//! This is deliberately NOT persisted: the engine's `MigrationPlan` (and its `NoteSplitPlan`/
//! `PreparationPlan` fields) has no `serde` support and no public constructor — the only way to
//! obtain one is calling `plan_migration()` itself — so it cannot round-trip through our own
//! storage. It lives in a process-lifetime static instead, which matches the app's flow: the
//! whole "review a migration proposal, then confirm it" sequence happens in one app-process
//! lifetime. If the process is killed between propose and confirm, the commit path surfaces the
//! stable `MIGRATION_PLAN_STALE` error (mapped to `ZcashError.migrationPlanStale` in Swift) so
//! the app re-proposes, rather than silently recomputing a fresh, differently-randomized plan the
//! user never saw or approved (ZIP 318's scheduling draws fresh randomness on every
//! `plan_migration()` call).
//!
//! The cached entry is also what the commit path verifies the platform's echoed consent values
//! (F4) against: the values the user approved must match the exact plan that gets signed.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use zcash_pool_migration_backend::engine::MigrationPlan;
use zcash_protocol::consensus::BlockHeight;

/// A cached preview.
#[derive(Clone)]
pub(crate) struct CachedPlan {
    pub plan: MigrationPlan,
    /// The chain tip at propose time — the `now` stamped into the encoded schedule
    /// (`FfiTransferProposal::anchor_height`, and, since #1806, the base of
    /// `estimated_duration_hours`). Recorded so a later commit can reproduce byte-for-byte the
    /// schedule DTO the platform actually saw when validating the platform's echoed consent
    /// values — re-reading the wallet's CURRENT tip instead could disagree with what was
    /// previewed if blocks landed between propose and confirm, without the plan itself having
    /// gone stale.
    pub reference_height: BlockHeight,
}

type Key = (PathBuf, [u8; 16]);

fn store() -> &'static Mutex<HashMap<Key, CachedPlan>> {
    static STORE: OnceLock<Mutex<HashMap<Key, CachedPlan>>> = OnceLock::new();
    STORE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Records the most recently previewed plan for `(db_path, account)`, replacing any previous one
/// (each propose call replaces any prior unconsumed proposal).
pub(crate) fn set(
    db_path: PathBuf,
    account: [u8; 16],
    plan: MigrationPlan,
    reference_height: BlockHeight,
) {
    store().lock().unwrap_or_else(|e| e.into_inner()).insert(
        (db_path, account),
        CachedPlan {
            plan,
            reference_height,
        },
    );
}

/// Returns a clone of the cached plan for `(db_path, account)`, if any.
pub(crate) fn get(db_path: &PathBuf, account: [u8; 16]) -> Option<CachedPlan> {
    store()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&(db_path.clone(), account))
        .cloned()
}

/// Drops the cached plan for `(db_path, account)` — called once it has been committed, since the
/// durable, authoritative copy from that point on is what the migration store persists.
pub(crate) fn clear(db_path: &PathBuf, account: [u8; 16]) {
    store()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&(db_path.clone(), account));
}
