/// Canonical byte length for Pallas field elements used at the voting FFI boundary.
pub(super) const CANONICAL_FIELD_LEN: usize = 32;

/// Binary account UUID length passed across the voting FFI boundary.
pub(super) const ACCOUNT_UUID_BYTE_LEN: usize = 16;

/// Byte length of Keystone / RedPallas signatures at the voting FFI boundary.
pub(super) const KEYSTONE_SIGNATURE_LEN: usize = 64;

/// Byte length of ZIP-244 PCZT sighashes at the voting FFI boundary.
pub(super) const PCZT_SIGHASH_LEN: usize = 32;

/// Byte length of randomized verification keys at the voting FFI boundary.
pub(super) const RANDOMIZED_KEY_LEN: usize = 32;

/// Byte length of share reveal nullifiers.
pub(super) const SHARE_NULLIFIER_LEN: usize = 32;

/// Hex string length for share reveal nullifiers.
pub(super) const SHARE_NULLIFIER_HEX_LEN: usize = SHARE_NULLIFIER_LEN * 2;

/// Byte length of root elements in PIR-fetched IMT non-membership proofs.
pub(super) const PIR_ROOT_LEN: usize = 32;

/// Byte length of `ImtProofData::nf_bounds`.
pub(super) const PIR_NULLIFIER_BOUNDS_LEN: usize = PIR_ROOT_LEN * 3;

/// Number of authentication path siblings in a PIR-fetched IMT proof.
///
/// Matches `zcash_voting::ImtProofData::path` and
/// `voting_circuits::delegation::imt::IMT_DEPTH` (29). Kept local because
/// `voting-circuits` is not a direct dependency of this crate and
/// `zcash_voting` does not currently re-export the constant.
pub(super) const PIR_PATH_ELEMENT_COUNT: usize = 29;

/// Byte length of `ImtProofData::path`.
pub(super) const PIR_PATH_LEN: usize = PIR_PATH_ELEMENT_COUNT * PIR_ROOT_LEN;

/// Byte length of PIR nullifier field elements.
pub(super) const PIR_NULLIFIER_LEN: usize = 32;
