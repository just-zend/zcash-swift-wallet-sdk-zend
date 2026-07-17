use std::panic::AssertUnwindSafe;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use zcash_voting as voting;

use crate::{unwrap_exc_or, unwrap_exc_or_null};

use super::db::VotingDatabaseHandle;
use super::helpers::{bytes_from_ptr, json_to_boxed_slice, str_from_ptr};
use super::json::{JsonSharePayload, JsonVoteCommitmentBundle, JsonWireEncryptedShare};

/// Encrypt voting shares for a round.
///
/// `shares_json` is a JSON-encoded `Vec<u64>`.
///
/// Returns JSON-encoded `Vec<WireEncryptedShare>` as `*mut FfiBoxedSlice`, or null on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - For every `(ptr, len)` byte argument, if `len > 0` then `ptr` must be
///   non-null and valid for reads for `len` bytes; if `len == 0`, `ptr` is ignored.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_encrypt_shares(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    shares_json: *const u8,
    shares_json_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| -> anyhow::Result<*mut crate::ffi::BoxedSlice> {
        // Superseded: shares are split and encrypted inside the vote commit
        // flow so the ciphertexts always match the proof; externally encrypted
        // shares can no longer be injected. The commit result carries the
        // encrypted shares (`enc_shares`) and helper payloads.
        let _ = (&db, round_id, round_id_len, shares_json, shares_json_len);
        Err(anyhow!(
            "voting: encrypt_shares is superseded — shares are encrypted inside the vote commit flow"
        ))
    });
    unwrap_exc_or_null(res)
}

/// Build a vote commitment proof for a proposal.
///
/// `van_auth_path_json` is a JSON-encoded `Vec<Vec<u8>>`, where each element is 32 bytes.
///
/// Returns JSON-encoded `VoteCommitmentBundle` as `*mut FfiBoxedSlice`, or null on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - For every `(ptr, len)` byte argument, if `len > 0` then `ptr` must be
///   non-null and valid for reads for `len` bytes; if `len == 0`, `ptr` is ignored.
/// - `progress_callback` must be a valid function pointer, or null to skip
///   progress. If provided, it must remain callable until this function returns.
///   It must be thread-safe and reentrant; callers must not assume it runs on
///   the main thread, because progress may be reported from proving worker threads.
/// - `progress_context` is passed to `progress_callback` unchanged. If non-null,
///   it must point to state that remains valid until this function returns. The
///   callback must not store `progress_context` or use it after this function returns.
/// - The callback must not call back into this voting database handle or perform
///   work that can deadlock or reenter the active proof operation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_build_vote_commitment(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    hotkey_seed: *const u8,
    hotkey_seed_len: usize,
    network_id: u32,
    proposal_id: u32,
    choice: u32,
    num_options: u32,
    van_auth_path_json: *const u8,
    van_auth_path_json_len: usize,
    van_position: u32,
    anchor_height: u32,
    progress_callback: Option<unsafe extern "C" fn(f64, *mut std::ffi::c_void)>,
    progress_context: *mut std::ffi::c_void,
    single_share: u8,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let progress_context = AssertUnwindSafe(progress_context);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        // The network rides the database handle since 1.0; the parameter stays
        // for ABI compatibility.
        let _ = network_id;
        let secret = unsafe { bytes_from_ptr(hotkey_seed, hotkey_seed_len) }?;
        let auth_path_bytes =
            unsafe { bytes_from_ptr(van_auth_path_json, van_auth_path_json_len) }?;
        let auth_path_vecs: Vec<Vec<u8>> = serde_json::from_slice(auth_path_bytes)?;

        let hotkey = voting::types::VotingHotkey::from_stored_secret(secret, handle.network)
            .map_err(|e| anyhow!("invalid voting hotkey material: {}", e))?;
        let witness =
            voting::vote::VanWitness::from_wire(&auth_path_vecs, van_position, anchor_height)
                .map_err(|e| anyhow!("invalid VAN witness: {}", e))?;
        let draft = voting::wire::DraftVote {
            proposal_id,
            choice,
            num_options,
            vc_tree_position: 0,
            single_share: single_share != 0,
        };

        let stages: Box<dyn voting::types::VoteCommitStageReporter> = match progress_callback {
            Some(cb) => Box::new(VoteStageBridge {
                callback: cb,
                context: *progress_context,
            }),
            None => Box::new(NoopVoteStages),
        };

        // One-shot in zcash_voting 1.0: builds ZKP #2 (share split + encryption
        // happen inside so ciphertexts match the proof), signs the cast vote
        // with the hotkey, builds helper-share payloads, and persists recovery
        // state. The legacy JSON contract is preserved, enriched with the
        // signature and share payloads the old multi-step flow fetched
        // separately.
        let committed = voting::vote::CommittedVote::commit(
            &handle.db,
            &round_id_str,
            bundle_index,
            &draft,
            &witness,
            voting::vote::VoteSigner::hotkey(&hotkey),
            stages.as_ref(),
        )
        .map_err(|e| anyhow!("build_vote_commitment failed: {}", e))?;
        let signed = committed
            .signed_commitment(&handle.db)
            .map_err(|e| anyhow!("failed to read committed vote: {}", e))?;

        json_to_boxed_slice(&committed_vote_json(&signed))
    });
    unwrap_exc_or_null(res)
}

/// Build share payloads for delegated share submission.
///
/// `commitment_json` is the JSON-encoded `VoteCommitmentBundle` returned by
/// `zcashlc_voting_build_vote_commitment`. Its `enc_shares` field is extracted
/// to wire-share form before reconstructing the core commitment, ensuring
/// helper payloads are built from the ciphertexts committed by the vote proof.
///
/// Returns JSON-encoded `Vec<SharePayload>` as `*mut FfiBoxedSlice`, or null on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - For every `(ptr, len)` byte argument, if `len > 0` then `ptr` must be
///   non-null and valid for reads for `len` bytes; if `len == 0`, `ptr` is ignored.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_build_share_payloads(
    db: *mut VotingDatabaseHandle,
    commitment_json: *const u8,
    commitment_json_len: usize,
    vote_decision: u32,
    num_options: u32,
    vc_tree_position: u64,
    single_share: u8,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;

        let commitment_bytes = unsafe { bytes_from_ptr(commitment_json, commitment_json_len) }?;
        let json_commitment: JsonVoteCommitmentBundle = serde_json::from_slice(commitment_bytes)?;
        if json_commitment.enc_shares.is_empty() {
            return Err(anyhow!("commitment enc_shares must not be empty"));
        }
        let wire_shares: Vec<voting::WireEncryptedShare> = json_commitment
            .enc_shares
            .iter()
            .cloned()
            .map(Into::into)
            .collect();
        let core_commitment = json_commitment.into_core_without_encrypted_shares();

        let payloads = handle
            .db
            .build_share_payloads(
                &wire_shares,
                &core_commitment,
                vote_decision,
                num_options,
                vc_tree_position,
                single_share != 0,
            )
            .map_err(|e| anyhow!("build_share_payloads failed: {}", e))?;

        let json_payloads: Vec<JsonSharePayload> = payloads.into_iter().map(Into::into).collect();
        json_to_boxed_slice(&json_payloads)
    });
    unwrap_exc_or_null(res)
}

/// Mark a vote as submitted for a specific proposal and bundle.
///
/// Returns 0 on success, or -1 on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - For the `(round_id, round_id_len)` byte argument, if `round_id_len > 0`
///   then `round_id` must be non-null and valid for reads for `round_id_len`
///   bytes; if `round_id_len == 0`, `round_id` is ignored.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_mark_vote_submitted(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    proposal_id: u32,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;

        // zcash_voting 1.0 records submission and tx hash atomically; re-mark
        // with the stored hash (idempotent, conflicting hashes rejected).
        // Propagate lookup failures (missing vote row, locked/corrupt DB) with
        // their real cause instead of collapsing every non-`Some` outcome into
        // the "call store_vote_tx_hash first" message; that guidance only holds
        // when the vote exists but has no stored hash yet (`Ok(None)`).
        let tx_hash = handle
            .db
            .get_vote_tx_hash(&round_id_str, bundle_index, proposal_id)
            .map_err(|e| anyhow!("failed to look up stored vote tx hash: {}", e))?
            .ok_or_else(|| {
                anyhow!("mark_vote_submitted requires a stored vote tx hash — call store_vote_tx_hash first")
            })?;
        handle
            .db
            .mark_vote_submitted(&round_id_str, bundle_index, proposal_id, &tx_hash)
            .map_err(|e| anyhow!("mark_vote_submitted failed: {}", e))?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Sign a cast-vote transaction.
///
/// Takes fields from `VoteCommitmentBundle` plus the hotkey seed and computes
/// the spend authorization signature.
/// `vote_round_id_hex` must encode exactly 32 bytes as ASCII hex. `r_vpk_bytes`,
/// `van_nullifier`, `vote_authority_note_new`, `vote_commitment`, and
/// `alpha_v` must each be exactly 32 bytes.
///
/// Returns JSON-encoded `CastVoteSignature` as `*mut FfiBoxedSlice`, or null on error.
///
/// # Safety
///
/// - For every `(ptr, len)` byte argument, if `len > 0` then `ptr` must be
///   non-null and valid for reads for `len` bytes; if `len == 0`, `ptr` is ignored.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_sign_cast_vote(
    hotkey_seed: *const u8,
    hotkey_seed_len: usize,
    network_id: u32,
    vote_round_id_hex: *const u8,
    vote_round_id_hex_len: usize,
    r_vpk_bytes: *const u8,
    r_vpk_bytes_len: usize,
    van_nullifier: *const u8,
    van_nullifier_len: usize,
    vote_authority_note_new: *const u8,
    vote_authority_note_new_len: usize,
    vote_commitment: *const u8,
    vote_commitment_len: usize,
    proposal_id: u32,
    anchor_height: u32,
    alpha_v: *const u8,
    alpha_v_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| -> anyhow::Result<*mut crate::ffi::BoxedSlice> {
        // Superseded: the cast-vote spend-authorization signature is produced
        // inside the vote commit flow (VoteSigner) and returned with the
        // commitment bundle (`vote_auth_sig`); a detached signing entry point
        // no longer exists in zcash_voting.
        let _ = (
            hotkey_seed,
            hotkey_seed_len,
            network_id,
            vote_round_id_hex,
            vote_round_id_hex_len,
            r_vpk_bytes,
            r_vpk_bytes_len,
            van_nullifier,
            van_nullifier_len,
            vote_authority_note_new,
            vote_authority_note_new_len,
            vote_commitment,
            vote_commitment_len,
            proposal_id,
            anchor_height,
            alpha_v,
            alpha_v_len,
        );
        Err(anyhow!(
            "voting: sign_cast_vote is superseded — the signature is produced by the vote commit flow and returned as vote_auth_sig"
        ))
    });
    unwrap_exc_or_null(res)
}

/// Bridges the C progress callback onto the crate's vote-commit stage reporter.
struct VoteStageBridge {
    callback: unsafe extern "C" fn(f64, *mut std::ffi::c_void),
    context: *mut std::ffi::c_void,
}

unsafe impl Send for VoteStageBridge {}
unsafe impl Sync for VoteStageBridge {}

impl voting::types::VoteCommitStageReporter for VoteStageBridge {
    fn on_stage(&self, stage: voting::vote::VoteCommitStage) {
        if let voting::vote::VoteCommitStage::ProofProgress { progress, .. } = stage {
            unsafe { (self.callback)(progress, self.context) }
        }
    }
}

struct NoopVoteStages;

impl voting::types::VoteCommitStageReporter for NoopVoteStages {
    fn on_stage(&self, _stage: voting::vote::VoteCommitStage) {}
}

/// The legacy commitment-bundle JSON enriched with the fields the one-shot
/// commit flow now produces up front (old decoders ignore the additions).
#[derive(serde::Serialize)]
pub(super) struct JsonCommittedVoteBundle {
    #[serde(flatten)]
    bundle: JsonVoteCommitmentBundle,
    vote_auth_sig: Vec<u8>,
    share_payloads: Vec<JsonSharePayload>,
}

/// Build the enriched committed-vote JSON from a signed commitment.
///
/// The share blinds and alpha_v secrets stay inside the crate in 1.0 (they
/// only served the superseded detached share/sign entry points), so the
/// legacy fields are emitted empty.
pub(super) fn committed_vote_json(
    signed: &voting::vote::SignedVoteCommitment,
) -> JsonCommittedVoteBundle {
    JsonCommittedVoteBundle {
        bundle: JsonVoteCommitmentBundle {
            van_nullifier: signed.van_nullifier.to_vec(),
            vote_authority_note_new: signed.vote_authority_note_new.to_vec(),
            vote_commitment: signed.vote_commitment.to_vec(),
            proposal_id: signed.proposal_id,
            proof: signed.proof.clone(),
            enc_shares: signed
                .encrypted_shares
                .iter()
                .map(|w| JsonWireEncryptedShare {
                    c1: w.c1.to_vec(),
                    c2: w.c2.to_vec(),
                    share_index: w.share_index,
                })
                .collect(),
            anchor_height: signed.anchor_height,
            vote_round_id: signed.vote_round_id.clone(),
            shares_hash: signed.shares_hash.to_vec(),
            share_blinds: Vec::new(),
            share_comms: signed.share_comms.iter().map(|c| c.to_vec()).collect(),
            r_vpk_bytes: signed.r_vpk.to_vec(),
            alpha_v: Vec::new(),
        },
        vote_auth_sig: signed.vote_auth_sig.to_vec(),
        share_payloads: signed
            .share_payloads
            .iter()
            .cloned()
            .map(Into::into)
            .collect(),
    }
}
