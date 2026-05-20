use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use serde::{Deserialize, Serialize};
use zcash_voting as voting;

use crate::unwrap_exc_or_null;

use super::helpers::{bytes_from_ptr, json_to_boxed_slice};
use super::share_tracking::{JsonShareDelegationRecord, decode_share_nullifier_hex};

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
struct JsonShareSubmissionRandomBytesRequired {
    submit_at_random_bytes: u64,
    server_random_bytes: u64,
}

impl TryFrom<voting::share_policy::ShareSubmissionRandomBytesRequired>
    for JsonShareSubmissionRandomBytesRequired
{
    type Error = anyhow::Error;

    fn try_from(
        value: voting::share_policy::ShareSubmissionRandomBytesRequired,
    ) -> Result<Self, Self::Error> {
        Ok(Self {
            submit_at_random_bytes: usize_to_u64(value.submit_at_random_bytes)?,
            server_random_bytes: usize_to_u64(value.server_random_bytes)?,
        })
    }
}

fn usize_to_u64(value: usize) -> anyhow::Result<u64> {
    u64::try_from(value).map_err(|_| anyhow!("random byte count does not fit in u64"))
}

fn optional_buffer(buffer_seconds: u64) -> Option<u64> {
    if buffer_seconds == 0 {
        None
    } else {
        Some(buffer_seconds)
    }
}

unsafe fn json_vec_from_ptr(ptr: *const u8, len: usize) -> anyhow::Result<Vec<String>> {
    let bytes = unsafe { bytes_from_ptr(ptr, len) }?;
    Ok(serde_json::from_slice(bytes)?)
}

fn share_record_from_json(
    record: JsonShareDelegationRecord,
) -> anyhow::Result<voting::ShareDelegationRecord> {
    let nullifier = decode_share_nullifier_hex(&record.nullifier)?.to_vec();
    Ok(voting::ShareDelegationRecord {
        round_id: record.round_id,
        bundle_index: record.bundle_index,
        proposal_id: record.proposal_id,
        share_index: record.share_index,
        sent_to_urls: record.sent_to_urls,
        nullifier,
        confirmed: record.confirmed,
        submit_at: record.submit_at,
        created_at: record.created_at,
    })
}

unsafe fn share_records_from_ptr(
    ptr: *const u8,
    len: usize,
) -> anyhow::Result<Vec<voting::ShareDelegationRecord>> {
    let bytes = unsafe { bytes_from_ptr(ptr, len) }?;
    let records: Vec<JsonShareDelegationRecord> = serde_json::from_slice(bytes)?;
    records.into_iter().map(share_record_from_json).collect()
}

/// Return random byte counts required to plan independent share submissions.
///
/// Returns JSON-encoded `ShareSubmissionRandomBytesRequired`, or null on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_share_submission_random_bytes_required(
    share_count: usize,
    server_count: usize,
    now_seconds: u64,
    vote_end_time_seconds: u64,
    last_moment_buffer_seconds: u64,
    single_share: u8,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let required = voting::share_policy::share_submission_random_bytes_required(
            share_count,
            server_count,
            now_seconds,
            vote_end_time_seconds,
            optional_buffer(last_moment_buffer_seconds),
            single_share != 0,
        );
        let json_required = JsonShareSubmissionRandomBytesRequired::try_from(required)?;
        json_to_boxed_slice(&json_required)
    });
    unwrap_exc_or_null(res)
}

/// Plan independent timing and initial helper targets for share submissions.
///
/// `server_urls_json` must be a JSON array of strings. Random byte slices must
/// contain the counts returned by
/// `zcashlc_voting_share_submission_random_bytes_required`.
///
/// Returns JSON-encoded `Vec<ShareSubmissionPlan>`, or null on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_plan_share_submissions(
    share_count: usize,
    server_urls_json: *const u8,
    server_urls_json_len: usize,
    now_seconds: u64,
    vote_end_time_seconds: u64,
    last_moment_buffer_seconds: u64,
    single_share: u8,
    submit_at_random_bytes: *const u8,
    submit_at_random_bytes_len: usize,
    server_random_bytes: *const u8,
    server_random_bytes_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let server_urls = unsafe { json_vec_from_ptr(server_urls_json, server_urls_json_len) }?;
        let submit_at_random_bytes =
            unsafe { bytes_from_ptr(submit_at_random_bytes, submit_at_random_bytes_len) }?;
        let server_random_bytes =
            unsafe { bytes_from_ptr(server_random_bytes, server_random_bytes_len) }?;

        let plans = voting::share_policy::plan_share_submissions(
            share_count,
            &server_urls,
            now_seconds,
            vote_end_time_seconds,
            optional_buffer(last_moment_buffer_seconds),
            single_share != 0,
            submit_at_random_bytes,
            server_random_bytes,
        )
        .map_err(|e| anyhow!("plan_share_submissions failed: {}", e))?;
        json_to_boxed_slice(&plans)
    });
    unwrap_exc_or_null(res)
}

/// Return random bytes required for a resubmission helper order.
///
/// Returns a JSON-encoded unsigned integer, or null on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_resubmission_server_order_random_bytes_required(
    configured_server_urls_json: *const u8,
    configured_server_urls_json_len: usize,
    sent_to_urls_json: *const u8,
    sent_to_urls_json_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let configured = unsafe {
            json_vec_from_ptr(configured_server_urls_json, configured_server_urls_json_len)
        }?;
        let sent = unsafe { json_vec_from_ptr(sent_to_urls_json, sent_to_urls_json_len) }?;
        let required = voting::share_policy::resubmission_server_order_random_bytes_required(
            &configured,
            &sent,
        );
        json_to_boxed_slice(&usize_to_u64(required)?)
    });
    unwrap_exc_or_null(res)
}

/// Return randomized resubmission helper order with untried helpers first.
///
/// Returns JSON-encoded `Vec<String>`, or null on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_resubmission_server_order(
    configured_server_urls_json: *const u8,
    configured_server_urls_json_len: usize,
    sent_to_urls_json: *const u8,
    sent_to_urls_json_len: usize,
    server_random_bytes: *const u8,
    server_random_bytes_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let configured = unsafe {
            json_vec_from_ptr(configured_server_urls_json, configured_server_urls_json_len)
        }?;
        let sent = unsafe { json_vec_from_ptr(sent_to_urls_json, sent_to_urls_json_len) }?;
        let server_random_bytes =
            unsafe { bytes_from_ptr(server_random_bytes, server_random_bytes_len) }?;
        let order = voting::share_policy::resubmission_server_order(
            &configured,
            &sent,
            server_random_bytes,
        )
        .map_err(|e| anyhow!("resubmission_server_order failed: {}", e))?;
        json_to_boxed_slice(&order)
    });
    unwrap_exc_or_null(res)
}

/// Return the next delay for share recovery polling.
///
/// Returns JSON `u64` or `null` when all shares are confirmed. Returns null on
/// error as well; callers can distinguish errors by reading the last Rust error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_next_tracking_delay_seconds(
    shares_json: *const u8,
    shares_json_len: usize,
    now_seconds: u64,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let shares = unsafe { share_records_from_ptr(shares_json, shares_json_len) }?;
        let delay = voting::share_policy::next_tracking_delay_seconds(
            &shares,
            now_seconds,
            voting::share_policy::ShareTimingPolicy::default(),
        );
        json_to_boxed_slice(&delay)
    });
    unwrap_exc_or_null(res)
}

/// Summarize share recovery state with confirmed / overdue / ready / waiting counts.
///
/// Returns JSON-encoded `ShareTrackingSummary`, or null on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_summarize_share_tracking(
    shares_json: *const u8,
    shares_json_len: usize,
    now_seconds: u64,
    vote_end_time_seconds: u64,
    has_vote_end_time: u8,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let shares = unsafe { share_records_from_ptr(shares_json, shares_json_len) }?;
        let vote_end = (has_vote_end_time != 0).then_some(vote_end_time_seconds);
        let summary = voting::share_policy::summarize_share_tracking(
            &shares,
            now_seconds,
            vote_end,
            voting::share_policy::ShareTimingPolicy::default(),
        );
        json_to_boxed_slice(&summary)
    });
    unwrap_exc_or_null(res)
}

#[cfg(test)]
mod tests {
    use serde::de::DeserializeOwned;

    use super::*;

    fn decode_boxed_json<T: DeserializeOwned>(ptr: *mut crate::ffi::BoxedSlice) -> T {
        assert!(!ptr.is_null(), "expected non-null BoxedSlice");
        let slice = unsafe { (*ptr).as_slice() };
        let value = serde_json::from_slice(slice).expect("json");
        unsafe { crate::ffi::zcashlc_free_boxed_slice(ptr) };
        value
    }

    fn json_bytes<T: Serialize>(value: &T) -> Vec<u8> {
        serde_json::to_vec(value).expect("json")
    }

    fn random_bytes(samples: &[u64]) -> Vec<u8> {
        samples
            .iter()
            .flat_map(|sample| sample.to_le_bytes())
            .collect()
    }

    fn share_record(submit_at: u64, created_at: u64, confirmed: bool) -> JsonShareDelegationRecord {
        JsonShareDelegationRecord {
            round_id: "round".to_string(),
            bundle_index: 0,
            proposal_id: 1,
            share_index: 0,
            sent_to_urls: vec!["https://helper-a.example".to_string()],
            nullifier: "aa".repeat(32),
            confirmed,
            submit_at,
            created_at,
        }
    }

    #[test]
    fn share_submission_policy_plans_with_independent_entropy() {
        let required: JsonShareSubmissionRandomBytesRequired = decode_boxed_json(unsafe {
            zcashlc_voting_share_submission_random_bytes_required(2, 3, 100, 1000, 100, 0)
        });
        assert_eq!(required.submit_at_random_bytes, 16);
        assert_eq!(required.server_random_bytes, 32);

        let servers = json_bytes(&vec![
            "https://helper-a.example",
            "https://helper-b.example",
            "https://helper-c.example",
        ]);
        let submit_at_random_bytes = random_bytes(&[0, u64::MAX]);
        let server_random_bytes = random_bytes(&[0, 0, 0, 0]);
        let plans: Vec<voting::share_policy::ShareSubmissionPlan> = decode_boxed_json(unsafe {
            zcashlc_voting_plan_share_submissions(
                2,
                servers.as_ptr(),
                servers.len(),
                100,
                1000,
                100,
                0,
                submit_at_random_bytes.as_ptr(),
                submit_at_random_bytes.len(),
                server_random_bytes.as_ptr(),
                server_random_bytes.len(),
            )
        });

        assert_eq!(plans.len(), 2);
        assert_eq!(plans[0].submit_at, 100);
        assert_eq!(plans[1].submit_at, 899);
        assert_eq!(plans[0].target_count, 2);
        assert_eq!(
            plans[0].target_servers,
            vec![
                "https://helper-b.example".to_string(),
                "https://helper-c.example".to_string()
            ]
        );
    }

    #[test]
    fn share_submission_policy_rejects_missing_entropy() {
        let servers = json_bytes(&vec![
            "https://helper-a.example",
            "https://helper-b.example",
        ]);
        let plans = unsafe {
            zcashlc_voting_plan_share_submissions(
                1,
                servers.as_ptr(),
                servers.len(),
                100,
                1000,
                100,
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
            )
        };
        assert!(plans.is_null());
    }

    #[test]
    fn resubmission_order_uses_untried_helpers_first() {
        let configured = json_bytes(&vec![
            "https://helper-a.example",
            "https://helper-b.example",
            "https://helper-c.example",
        ]);
        let sent = json_bytes(&vec!["https://helper-b.example"]);

        let required: u64 = decode_boxed_json(unsafe {
            zcashlc_voting_resubmission_server_order_random_bytes_required(
                configured.as_ptr(),
                configured.len(),
                sent.as_ptr(),
                sent.len(),
            )
        });
        assert_eq!(required, 8);

        let server_random_bytes = random_bytes(&[0]);
        let order: Vec<String> = decode_boxed_json(unsafe {
            zcashlc_voting_resubmission_server_order(
                configured.as_ptr(),
                configured.len(),
                sent.as_ptr(),
                sent.len(),
                server_random_bytes.as_ptr(),
                server_random_bytes.len(),
            )
        });
        assert_eq!(
            order,
            vec![
                "https://helper-c.example".to_string(),
                "https://helper-a.example".to_string(),
                "https://helper-b.example".to_string()
            ]
        );
    }

    #[test]
    fn tracking_policy_summarizes_and_delays_with_default_policy() {
        let shares = json_bytes(&vec![share_record(0, 100, false)]);

        let delay: Option<u64> = decode_boxed_json(unsafe {
            zcashlc_voting_next_tracking_delay_seconds(shares.as_ptr(), shares.len(), 112)
        });
        assert_eq!(delay, Some(15));

        let summary: voting::share_policy::ShareTrackingSummary = decode_boxed_json(unsafe {
            zcashlc_voting_summarize_share_tracking(shares.as_ptr(), shares.len(), 112, 1000, 1)
        });
        assert_eq!(summary.total, 1);
        assert_eq!(summary.ready, 1);
        assert_eq!(summary.waiting, 0);
        assert_eq!(summary.overdue, 0);
    }
}
