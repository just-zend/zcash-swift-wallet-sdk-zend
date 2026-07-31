//! The SDK's extension tables in the wallet database.
//!
//! Tables this SDK stores alongside `zcash_client_sqlite`'s own schema follow the wallet
//! database's extension contract (see `WalletMigrator::with_external_migrations`): every
//! name carries the `ext_zcashlc_` prefix (the wallet promises never to use `ext_`), and
//! the schema is created and evolved exclusively by the [`schemerz`] migrations registered
//! here — never ad hoc at call time — so extension tables share the wallet database's
//! schema versioning. Runtime writes go through
//! [`WalletDb::transactionally_with_extension`], whose authorizer confines them to the
//! `ext_` namespace.
//!
//! [`zcashlc_init_data_database`](crate::zcashlc_init_data_database) applies these
//! migrations alongside the wallet's own; every other entry point may assume the tables
//! exist, because the platform initializes the database before using it (the Swift
//! `Initializer` does this at startup).
//!
//! [`WalletDb::transactionally_with_extension`]: zcash_client_sqlite::WalletDb::transactionally_with_extension

use schemerz_rusqlite::RusqliteMigration;
use zcash_client_sqlite::wallet::init::WalletMigrationError;

/// The SDK's external migrations, in the form [`WalletMigrator::with_external_migrations`]
/// accepts. Currently EMPTY — the SDK keeps no extension tables — but the registration
/// point stays wired so a future table only has to add its migration here.
///
/// # Retired migrations
///
/// `AddInvalidTransferMarksTable` (id `0e1fd980-5cad-41c5-a6db-183dab527dcc` — reserved
/// forever, never reuse it) created `ext_zcashlc_orchard_ironwood_migration_invalid_marks`,
/// the side table that recorded terminal pool-migration rejection classifications back when
/// the engine had no failure states. The engine now records that evidence itself
/// (`MigrationTxState::Invalid` via `MigrationState::mark_invalid`), so the migration is no
/// longer registered: fresh wallets never create the table, and
/// `crate::migration::migrate_legacy_invalid_marks` folds any surviving rows into the
/// engine state on open and drops it. Removing (rather than keeping) the registration is
/// safe because `schemerz`'s `Migrator::up` walks REGISTERED migrations only and checks
/// each against the applied set — a recorded id it no longer knows is simply never
/// consulted, so wallets that already ran the migration keep its inert row in the
/// migrations table and are otherwise unaffected.
///
/// [`WalletMigrator::with_external_migrations`]: zcash_client_sqlite::wallet::init::WalletMigrator::with_external_migrations
pub(crate) fn external_migrations() -> Vec<Box<dyn RusqliteMigration<Error = WalletMigrationError>>>
{
    Vec::new()
}
