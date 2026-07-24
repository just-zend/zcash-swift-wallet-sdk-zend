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

use std::collections::HashSet;

use schemerz_rusqlite::RusqliteMigration;
use uuid::Uuid;
use zcash_client_sqlite::wallet::init::{
    WalletMigrationError, migrations::CURRENT_LEAF_MIGRATIONS,
};

/// The SDK's external migrations, in the form [`WalletMigrator::with_external_migrations`]
/// accepts.
///
/// [`WalletMigrator::with_external_migrations`]: zcash_client_sqlite::wallet::init::WalletMigrator::with_external_migrations
pub(crate) fn external_migrations() -> Vec<Box<dyn RusqliteMigration<Error = WalletMigrationError>>>
{
    vec![Box::new(AddInvalidTransferMarksTable)]
}

const ADD_INVALID_TRANSFER_MARKS_TABLE_ID: Uuid =
    Uuid::from_u128(0x0e1fd980_5cad_41c5_a6db_183dab527dcc);

/// Adds `ext_zcashlc_orchard_ironwood_migration_invalid_marks`, the table recording
/// terminal rejection classifications for Orchard -> Ironwood pool-migration transfers.
///
/// The engine has no failure states (a rejected broadcast leaves the transaction re-offered),
/// so the platform's rejection classifier records terminal rejections here, keyed by account
/// and the engine's per-run transaction id; see the accessors in [`crate::migration`]. The
/// account is stored as raw uuid bytes rather than a foreign key into `accounts`, per the
/// extension contract's warning against depending on wallet-internal ids.
struct AddInvalidTransferMarksTable;

impl schemerz::Migration<Uuid> for AddInvalidTransferMarksTable {
    fn id(&self) -> Uuid {
        ADD_INVALID_TRANSFER_MARKS_TABLE_ID
    }

    fn dependencies(&self) -> HashSet<Uuid> {
        // The marks annotate the engine's pool-migration transactions, whose tables are
        // registered in the wallet's own migration graph; anchoring on the wallet's leaf
        // frontier guarantees they exist first.
        CURRENT_LEAF_MIGRATIONS.iter().copied().collect()
    }

    fn description(&self) -> &'static str {
        "Adds the SDK's invalid-transfer marks table for Orchard -> Ironwood pool migrations."
    }
}

impl RusqliteMigration for AddInvalidTransferMarksTable {
    type Error = WalletMigrationError;

    fn up(&self, transaction: &rusqlite::Transaction) -> Result<(), Self::Error> {
        transaction.execute_batch(
            "CREATE TABLE ext_zcashlc_orchard_ironwood_migration_invalid_marks (
                account_uuid BLOB NOT NULL,
                tx_id INTEGER NOT NULL,
                reason TEXT NOT NULL,
                PRIMARY KEY (account_uuid, tx_id)
            )",
        )?;
        Ok(())
    }

    fn down(&self, _transaction: &rusqlite::Transaction) -> Result<(), Self::Error> {
        Err(WalletMigrationError::CannotRevert(
            ADD_INVALID_TRANSFER_MARKS_TABLE_ID,
        ))
    }
}
