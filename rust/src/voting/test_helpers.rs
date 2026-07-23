use super::db::{VotingDatabaseHandle, zcashlc_voting_db_open, zcashlc_voting_set_wallet_id};

pub(crate) fn open_memory_db() -> *mut VotingDatabaseHandle {
    let path = b":memory:";
    let db = unsafe { zcashlc_voting_db_open(path.as_ptr(), path.len(), 1) };
    assert!(!db.is_null());

    let wallet = b"wallet";
    let code = unsafe { zcashlc_voting_set_wallet_id(db, wallet.as_ptr(), wallet.len()) };
    assert_eq!(code, 0);

    db
}
