use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use prost::Message;
use zcash_client_backend::proto::service::TreeState;
use zcash_keys::keys::UnifiedFullViewingKey;
use zcash_voting as voting;

use crate::{unwrap_exc_or, unwrap_exc_or_null};

use super::helpers::{bytes_from_ptr, str_from_ptr};
use super::json::JsonWitnessData;

// =============================================================================
// Free functions (no VotingDatabase needed)
// =============================================================================

/// Warm process-lifetime proving-key caches used by voting proofs.
///
/// Returns 0 on success, -1 on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_warm_proving_caches() -> i32 {
    let res = catch_panic(|| {
        voting::warm_proving_caches();
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Decompose a weight into power-of-two components.
///
/// Returns JSON-encoded `Vec<u64>` as `*mut FfiBoxedSlice`, or null on error.
///
/// # Safety
///
/// No pointer parameters.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_decompose_weight(
    weight: u64,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| -> anyhow::Result<*mut crate::ffi::BoxedSlice> {
        // Superseded: the share split is denomination-based, PRF-keyed, and
        // shuffled inside the vote proof builder (voting-circuits 0.9
        // SHARE_SPLITTING.md) — it depends on the spending key and round
        // context, so a standalone weight decomposition can no longer describe
        // the real split (and a binary decomposition would fingerprint voter
        // balances).
        let _ = weight;
        Err(anyhow!(
            "voting: decompose_weight is superseded — shares are split inside the vote commit flow"
        ))
    });
    unwrap_exc_or_null(res)
}

/// Superseded: zcash_voting 1.0 derives delegation inputs from the wallet database
/// inside the delegation lanes (`build_pczt` / `build_and_prove_delegation` /
/// `get_delegation_submission`); seed-derived side inputs no longer exist.
/// Always returns null with a "superseded" error (C symbol preserved).
///
/// # Safety
///
/// - The pointer arguments are not read.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_generate_delegation_inputs(
    _sender_seed: *const u8,
    _sender_seed_len: usize,
    _hotkey_seed: *const u8,
    _hotkey_seed_len: usize,
    _network_id: u32,
    _account_index: u32,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        Err(anyhow!(
            "voting: generate_delegation_inputs is superseded — the delegation lanes derive inputs from the wallet database"
        ))
    });
    unwrap_exc_or_null(res)
}

/// Superseded: zcash_voting 1.0 derives delegation inputs from the wallet database
/// inside the delegation lanes; see `zcashlc_voting_generate_delegation_inputs`.
/// Always returns null with a "superseded" error (C symbol preserved).
///
/// # Safety
///
/// - The pointer arguments are not read.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_generate_delegation_inputs_with_fvk(
    _fvk_bytes: *const u8,
    _fvk_bytes_len: usize,
    _hotkey_seed: *const u8,
    _hotkey_seed_len: usize,
    _network_id: u32,
    _seed_fingerprint: *const u8,
    _seed_fingerprint_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        Err(anyhow!(
            "voting: generate_delegation_inputs_with_fvk is superseded — the delegation lanes derive inputs from the wallet database"
        ))
    });
    unwrap_exc_or_null(res)
}

/// Extract the ZIP-244 shielded sighash from finalized PCZT bytes.
///
/// Returns the 32-byte sighash as `*mut FfiBoxedSlice`, or null on error.
///
/// # Safety
///
/// - `pczt_bytes` must be valid for reads of `pczt_bytes_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_extract_pczt_sighash(
    pczt_bytes: *const u8,
    pczt_bytes_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let bytes = unsafe { bytes_from_ptr(pczt_bytes, pczt_bytes_len) }?;
        let sighash = voting::action::extract_pczt_sighash(bytes)
            .map_err(|e| anyhow!("extract_pczt_sighash failed: {}", e))?;
        Ok(crate::ffi::BoxedSlice::some(sighash.to_vec()))
    });
    unwrap_exc_or_null(res)
}

/// Extract a spend auth signature from a signed PCZT.
///
/// Returns the signature bytes as `*mut FfiBoxedSlice`, or null on error.
///
/// # Safety
///
/// - `signed_pczt_bytes` must be valid for reads of `signed_pczt_bytes_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_extract_spend_auth_sig(
    signed_pczt_bytes: *const u8,
    signed_pczt_bytes_len: usize,
    action_index: u32,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let bytes = unsafe { bytes_from_ptr(signed_pczt_bytes, signed_pczt_bytes_len) }?;
        let sig = voting::action::extract_spend_auth_sig(bytes, action_index as usize)
            .map_err(|e| anyhow!("extract_spend_auth_sig failed: {}", e))?;
        Ok(crate::ffi::BoxedSlice::some(sig.to_vec()))
    });
    unwrap_exc_or_null(res)
}

/// Extract the 96-byte Orchard FVK from a UFVK string.
///
/// Returns the raw 96-byte Orchard FVK as `*mut FfiBoxedSlice`, or null on error.
///
/// # Safety
///
/// - `ufvk_str` must be valid for reads of `ufvk_str_len` bytes (UTF-8 encoded).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_extract_orchard_fvk_from_ufvk(
    ufvk_str: *const u8,
    ufvk_str_len: usize,
    network_id: u32,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ufvk_string = unsafe { str_from_ptr(ufvk_str, ufvk_str_len) }?;

        let network = crate::parse_network(network_id)?;
        let ufvk = UnifiedFullViewingKey::decode(&network, &ufvk_string)
            .map_err(|e| anyhow!("failed to decode UFVK string: {}", e))?;

        let orchard_fvk = ufvk
            .orchard()
            .ok_or_else(|| anyhow!("UFVK has no Orchard component"))?;
        Ok(crate::ffi::BoxedSlice::some(
            orchard_fvk.to_bytes().to_vec(),
        ))
    });
    unwrap_exc_or_null(res)
}

/// Extract the Ironwood note commitment tree root from a protobuf-encoded TreeState.
///
/// Voting rounds anchor to the Ironwood pool (zcash_voting 1.0), so the `nc_root`
/// comes from the Ironwood tree, not Orchard. Returns the 32-byte nc_root as
/// `*mut FfiBoxedSlice`, or null on error.
///
/// # Safety
///
/// - `tree_state_bytes` must be valid for reads of `tree_state_bytes_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_extract_nc_root(
    tree_state_bytes: *const u8,
    tree_state_bytes_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let bytes = unsafe { bytes_from_ptr(tree_state_bytes, tree_state_bytes_len) }?;
        let tree_state = TreeState::decode(bytes)
            .map_err(|e| anyhow!("failed to decode TreeState protobuf: {}", e))?;
        let ironwood_ct = tree_state
            .ironwood_tree()
            .map_err(|e| anyhow!("failed to parse ironwood tree from TreeState: {}", e))?;
        let nc_root = ironwood_ct.root().to_bytes().to_vec();
        Ok(crate::ffi::BoxedSlice::some(nc_root))
    });
    unwrap_exc_or_null(res)
}

/// Verify a Merkle witness.
///
/// `witness_json` is a JSON-encoded `WitnessData`.
///
/// Returns 1 if valid, 0 if invalid, -1 on error.
///
/// # Safety
///
/// - `witness_json` must be valid for reads of `witness_json_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_verify_witness(
    witness_json: *const u8,
    witness_json_len: usize,
) -> i32 {
    let res = catch_panic(|| {
        let bytes = unsafe { bytes_from_ptr(witness_json, witness_json_len) }?;
        let json_witness: JsonWitnessData = serde_json::from_slice(bytes)?;
        let core_witness: voting::WitnessData = json_witness.into();

        let valid = voting::witness::verify_witness(&core_witness)
            .map_err(|e| anyhow!("verify_witness failed: {}", e))?;
        Ok(if valid { 1 } else { 0 })
    });
    unwrap_exc_or(res, -1)
}

#[cfg(test)]
mod tests {
    use orchard::tree::Anchor;
    use prost::Message;
    use zcash_client_backend::proto::service::TreeState;
    use zcash_keys::keys::UnifiedSpendingKey;
    use zcash_protocol::consensus::Network;
    use zip32::AccountId;

    /// Raw Orchard FVK byte length — the extract lane's expected output size.
    const ORCHARD_FVK_LEN: usize = 96;

    use super::*;
    use crate::{NETWORK_ID_MAINNET, NETWORK_ID_TESTNET};

    fn free(ptr: *mut crate::ffi::BoxedSlice) {
        unsafe { crate::ffi::zcashlc_free_boxed_slice(ptr) };
    }

    fn boxed_slice_to_vec(ptr: *mut crate::ffi::BoxedSlice) -> Vec<u8> {
        assert!(!ptr.is_null(), "expected non-null BoxedSlice");
        let bytes = unsafe { (*ptr).as_slice() }.to_vec();
        free(ptr);
        bytes
    }

    fn derive_test_ufvk(network: Network) -> (String, [u8; ORCHARD_FVK_LEN]) {
        let seed = [0u8; 32];
        let account = AccountId::try_from(0).expect("account 0");
        let usk = UnifiedSpendingKey::from_seed(&network, &seed, account).expect("from_seed");
        let ufvk = usk.to_unified_full_viewing_key();
        let ufvk_str = ufvk.encode(&network);
        let orchard_bytes = ufvk.orchard().expect("orchard present").to_bytes();
        (ufvk_str, orchard_bytes)
    }

    #[test]
    fn extract_orchard_fvk_returns_orchard_bytes_for_valid_mainnet_ufvk() {
        let (ufvk_str, expected) = derive_test_ufvk(Network::MainNetwork);
        let result = unsafe {
            zcashlc_voting_extract_orchard_fvk_from_ufvk(
                ufvk_str.as_ptr(),
                ufvk_str.len(),
                NETWORK_ID_MAINNET,
            )
        };

        assert!(!result.is_null(), "expected non-null BoxedSlice");
        let actual = unsafe { (*result).as_slice() }.to_vec();
        free(result);

        assert_eq!(
            actual.len(),
            ORCHARD_FVK_LEN,
            "Orchard FVK must be {ORCHARD_FVK_LEN} bytes"
        );
        assert_eq!(actual, expected.to_vec(), "FVK bytes must match");
    }

    #[test]
    fn extract_orchard_fvk_returns_orchard_bytes_for_valid_testnet_ufvk() {
        let (ufvk_str, expected) = derive_test_ufvk(Network::TestNetwork);
        let result = unsafe {
            zcashlc_voting_extract_orchard_fvk_from_ufvk(
                ufvk_str.as_ptr(),
                ufvk_str.len(),
                NETWORK_ID_TESTNET,
            )
        };

        assert!(!result.is_null(), "expected non-null BoxedSlice");
        let actual = unsafe { (*result).as_slice() }.to_vec();
        free(result);

        assert_eq!(
            actual.len(),
            ORCHARD_FVK_LEN,
            "Orchard FVK must be {ORCHARD_FVK_LEN} bytes"
        );
        assert_eq!(actual, expected.to_vec(), "FVK bytes must match");
    }

    #[test]
    fn extract_orchard_fvk_rejects_mainnet_ufvk_with_testnet_network_id() {
        let (ufvk_str, _expected) = derive_test_ufvk(Network::MainNetwork);
        let result = unsafe {
            zcashlc_voting_extract_orchard_fvk_from_ufvk(
                ufvk_str.as_ptr(),
                ufvk_str.len(),
                NETWORK_ID_TESTNET,
            )
        };

        assert!(result.is_null());
    }

    #[test]
    fn extract_orchard_fvk_rejects_null_pointer_with_nonzero_len() {
        let result = unsafe {
            zcashlc_voting_extract_orchard_fvk_from_ufvk(std::ptr::null(), 5, NETWORK_ID_MAINNET)
        };

        assert!(result.is_null());
    }

    #[test]
    fn extract_orchard_fvk_rejects_invalid_network_id() {
        let (ufvk_str, _expected) = derive_test_ufvk(Network::MainNetwork);
        let result = unsafe {
            zcashlc_voting_extract_orchard_fvk_from_ufvk(ufvk_str.as_ptr(), ufvk_str.len(), 99)
        };

        assert!(result.is_null());
    }

    #[test]
    fn extract_orchard_fvk_rejects_non_ufvk_string() {
        let bogus = b"not a ufvk";
        let result = unsafe {
            zcashlc_voting_extract_orchard_fvk_from_ufvk(
                bogus.as_ptr(),
                bogus.len(),
                NETWORK_ID_MAINNET,
            )
        };

        assert!(result.is_null());
    }

    #[test]
    fn extract_orchard_fvk_rejects_empty_input() {
        let result = unsafe {
            zcashlc_voting_extract_orchard_fvk_from_ufvk(std::ptr::null(), 0, NETWORK_ID_MAINNET)
        };

        assert!(result.is_null());
    }

    #[test]
    fn extract_pczt_sighash_rejects_invalid_pczt_bytes() {
        let bogus = b"not a pczt";

        let result = unsafe { zcashlc_voting_extract_pczt_sighash(bogus.as_ptr(), bogus.len()) };

        assert!(result.is_null());
    }

    #[test]
    fn extract_spend_auth_sig_rejects_invalid_pczt_bytes() {
        let bogus = b"not a signed pczt";

        let result =
            unsafe { zcashlc_voting_extract_spend_auth_sig(bogus.as_ptr(), bogus.len(), 0) };

        assert!(result.is_null());
    }

    #[test]
    fn extract_nc_root_returns_empty_ironwood_root_for_empty_tree_state() {
        let tree_state = TreeState {
            network: "main".to_string(),
            height: 1,
            hash: "00".repeat(32),
            time: 0,
            sapling_tree: String::new(),
            orchard_tree: String::new(),
            ironwood_tree: String::new(),
        };
        let tree_state_bytes = tree_state.encode_to_vec();

        let result = unsafe {
            zcashlc_voting_extract_nc_root(tree_state_bytes.as_ptr(), tree_state_bytes.len())
        };

        let root = boxed_slice_to_vec(result);
        assert_eq!(root.len(), 32);
        assert_eq!(root, Anchor::empty_tree().to_bytes().to_vec());
    }

    /// Voting rounds are anchored to the **Ironwood** note commitment tree, so
    /// when the cached `TreeState` carries both pools the extracted `nc_root`
    /// must be the Ironwood root, not the Orchard one.
    #[test]
    fn extract_nc_root_returns_ironwood_root_when_both_trees_present() {
        use ff::PrimeField;
        use incrementalmerkletree::frontier::{CommitmentTree, Frontier};
        use orchard::tree::MerkleHashOrchard;
        use pasta_curves::pallas;
        use zcash_primitives::merkle_tree::write_commitment_tree;

        const TREE_DEPTH: u8 = orchard::NOTE_COMMITMENT_TREE_DEPTH as u8;

        fn merkle_hash(tag: u64) -> MerkleHashOrchard {
            let repr = pallas::Base::from(tag).to_repr();
            MerkleHashOrchard::from_bytes(&repr).expect("small field element is canonical")
        }

        fn frontier_with(tags: &[u64]) -> Frontier<MerkleHashOrchard, TREE_DEPTH> {
            let mut frontier = Frontier::empty();
            for tag in tags {
                assert!(frontier.append(merkle_hash(*tag)));
            }
            frontier
        }

        fn tree_hex(frontier: &Frontier<MerkleHashOrchard, TREE_DEPTH>) -> String {
            let commitment_tree = CommitmentTree::from_frontier(frontier);
            let mut tree_bytes = Vec::new();
            write_commitment_tree(&commitment_tree, &mut tree_bytes)
                .expect("serialize note commitment tree state");
            hex::encode(tree_bytes)
        }

        let orchard_frontier = frontier_with(&[1, 2, 3]);
        let ironwood_frontier = frontier_with(&[7, 8]);
        assert_ne!(
            orchard_frontier.root().to_bytes(),
            ironwood_frontier.root().to_bytes(),
            "test needs distinguishable roots"
        );
        let tree_state = TreeState {
            network: "test".to_string(),
            height: 100,
            hash: String::new(),
            time: 0,
            sapling_tree: String::new(),
            orchard_tree: tree_hex(&orchard_frontier),
            ironwood_tree: tree_hex(&ironwood_frontier),
        };
        let tree_state_bytes = tree_state.encode_to_vec();

        let result = unsafe {
            zcashlc_voting_extract_nc_root(tree_state_bytes.as_ptr(), tree_state_bytes.len())
        };

        let root = boxed_slice_to_vec(result);
        assert_eq!(
            root,
            ironwood_frontier.root().to_bytes().to_vec(),
            "nc_root must come from the Ironwood tree"
        );
    }

    #[test]
    fn verify_witness_returns_zero_for_wrong_root() {
        let witness = JsonWitnessData {
            note_commitment: vec![0; 32],
            position: 0,
            root: Anchor::empty_tree().to_bytes().to_vec(),
            auth_path: (0..32).map(|_| vec![0; 32]).collect(),
        };
        let witness_json = serde_json::to_vec(&witness).expect("witness json");

        let result =
            unsafe { zcashlc_voting_verify_witness(witness_json.as_ptr(), witness_json.len()) };

        assert_eq!(result, 0);
    }
}
