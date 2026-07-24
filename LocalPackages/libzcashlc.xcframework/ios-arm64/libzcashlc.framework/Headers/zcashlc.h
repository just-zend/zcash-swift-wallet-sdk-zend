#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

/**
 * Version of the delivery/runtime C ABI and every opaque capability handle it creates.
 */
#define ZCASHLC_MIGRATION_DELIVERY_ABI_VERSION 1

/**
 * Specifies how a "spend max" request should be evaluated.
 */
typedef enum FfiMaxSpendMode {
  /**
   * `MaxSpendable` will target to spend all _currently_ spendable funds where it
   * could be the case that the wallet has received other funds that are not
   * confirmed and therefore not spendable yet and the caller evaluates that as
   * an acceptable scenario.
   */
  MaxSpendable,
  /**
   * `Everything` will target to spend **all funds** and will fail if there are
   * unspendable funds in the wallet or if the wallet is not yet synced.
   */
  Everything,
} FfiMaxSpendMode;

/**
 * A type describing the mined-ness of transactions that should be returned in response to a
 * [`TransactionDataRequest`].
 *
 */
typedef enum TransactionStatusFilter {
  /**
   * Only mined transactions should be returned.
   */
  TransactionStatusFilter_Mined,
  /**
   * Only mempool transactions should be returned.
   */
  TransactionStatusFilter_Mempool,
  /**
   * Both mined transactions and transactions in the mempool should be returned.
   */
  TransactionStatusFilter_All,
} TransactionStatusFilter;

/**
 * A type used to filter transactions to be returned in response to a [`TransactionDataRequest`],
 * in terms of the spentness of the transaction's transparent outputs.
 *
 */
typedef enum OutputStatusFilter {
  /**
   * Only transactions that have currently-unspent transparent outputs should be returned.
   */
  OutputStatusFilter_Unspent,
  /**
   * All transactions corresponding to the data request should be returned, irrespective of
   * whether or not those transactions produce transparent outputs that are currently unspent.
   */
  OutputStatusFilter_All,
} OutputStatusFilter;

/**
 * What level of sleep to put a Tor client into.
 */
typedef enum TorDormantMode {
  /**
   * The client functions as normal, and background tasks run periodically.
   */
  Normal,
  /**
   * Background tasks are suspended, conserving CPU usage. Attempts to use the client will
   * wake it back up again.
   */
  Soft,
} TorDormantMode;

/**
 * An exchange for which we know how to query the ZEC-USD exchange rate.
 */
typedef enum FfiZecUsdExchange {
  Binance,
  CoinEx,
  Coinbase,
  DigiFinex,
  Gemini,
  Kraken,
  KuCoin,
  Mexc,
  Xt,
} FfiZecUsdExchange;

/**
 * The type of an EIP-681 transaction request.
 *
 */
typedef enum FfiEip681TransactionRequestType {
  /**
   * A native ETH/chain token transfer (no function call).
   */
  FfiEip681TransactionRequestType_Native,
  /**
   * An ERC-20 token transfer via `transfer(address,uint256)`.
   */
  FfiEip681TransactionRequestType_Erc20,
  /**
   * A valid EIP-681 request that is not a recognized transfer pattern.
   */
  FfiEip681TransactionRequestType_Unrecognised,
} FfiEip681TransactionRequestType;

/**
 * A struct that contains a ZIP 325 Account Metadata Key.
 */
typedef struct FfiAccountMetadataKey FfiAccountMetadataKey;

/**
 * An opaque parsed EIP-681 transaction request.
 *
 * Obtain via [`zcashlc_eip681_parse_transaction_request`]. Free with
 * [`zcashlc_free_eip681_transaction_request`].
 */
typedef struct FfiEip681TransactionRequest FfiEip681TransactionRequest;

/**
 * Opaque immutable capability for one exact delivery artifact and, when present, its live
 * Rust-generated claim token. Exact proposal/PCZT/transaction bytes remain private and are copied
 * out only through owned accessors.
 */
typedef struct FfiMigrationClaimHandle FfiMigrationClaimHandle;

/**
 * Opaque immutable capability identifying one revision-consistent delivery run.
 *
 * The private fields are never part of the generated C layout. Obtain a pointer only from this
 * module and free each owned pointer once with [`zcashlc_migration_free_run_handle_v1`].
 */
typedef struct FfiMigrationRunHandle FfiMigrationRunHandle;

typedef struct LwdConn LwdConn;

typedef struct TorRuntime TorRuntime;

/**
 * Opaque handle wrapping the voting database and its tree-sync state.
 */
typedef struct VotingDatabaseHandle VotingDatabaseHandle;

/**
 * A struct that contains a 16-byte account uuid.
 */
typedef struct FfiUuid {
  uint8_t uuid_bytes[16];
} FfiUuid;

/**
 * A struct that contains a pointer to, and length information for, a heap-allocated
 * slice of [`Uuid`] values.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must be valid for reads for `len * mem::size_of::<Uuid>()`
 *   many bytes, and it must be properly aligned. This means in particular:
 *   - The entire memory range pointed to by `ptr` must be contained within a single allocated
 *     object. Slices can never span across multiple allocated objects.
 *   - `ptr` must be non-null and aligned even for zero-length slices.
 *   - `ptr` must point to `len` consecutive properly initialized values of type
 *     [`Uuid`].
 * - The total size `len * mem::size_of::<Uuid>()` of the slice pointed to
 *   by `ptr` must be no larger than isize::MAX. See the safety documentation of pointer::offset.
 */
typedef struct FfiAccounts {
  struct FfiUuid *ptr;
  uintptr_t len;
} FfiAccounts;

/**
 * A struct that contains a 16-byte account uuid along with key derivation metadata for that
 * account.
 *
 * A returned value containing the all-zeros seed fingerprint and/or u32::MAX for the
 * hd_account_index indicates that no derivation metadata is available.
 */
typedef struct FfiAccount {
  uint8_t uuid_bytes[16];
  char *account_name;
  char *key_source;
  uint8_t seed_fingerprint[32];
  uint32_t hd_account_index;
  char *ufvk;
  char *uivk;
} FfiAccount;

/**
 * A struct that contains an account identifier along with a pointer to the binary encoding
 * of an associated key.
 *
 * # Safety
 *
 * - `encoding` must be non-null and must point to an array of `encoding_len` bytes.
 */
typedef struct FFIBinaryKey {
  uint8_t account_uuid[16];
  uint8_t *encoding;
  uintptr_t encoding_len;
} FFIBinaryKey;

/**
 * A single-use transparent address, along with metadata about the address's use within the
 * wallet's ephemeral gap limit.
 */
typedef struct FfiSingleUseTaddr {
  char *address;
  uint32_t gap_position;
  uint32_t gap_limit;
} FfiSingleUseTaddr;

/**
 * A struct that contains an account identifier along with a pointer to the string encoding
 * of an associated key.
 *
 * # Safety
 *
 * - `encoding` must be non-null and must point to a null-terminated UTF-8 string.
 */
typedef struct FFIEncodedKey {
  uint8_t account_uuid[16];
  char *encoding;
} FFIEncodedKey;

/**
 * A struct that contains a pointer to, and length information for, a heap-allocated
 * slice of [`EncodedKey`] values.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must be valid for reads for `len * mem::size_of::<EncodedKey>()`
 *   many bytes, and it must be properly aligned. This means in particular:
 *   - The entire memory range pointed to by `ptr` must be contained within a single allocated
 *     object. Slices can never span across multiple allocated objects.
 *   - `ptr` must be non-null and aligned even for zero-length slices.
 *   - `ptr` must point to `len` consecutive properly initialized values of type
 *     [`EncodedKey`].
 * - The total size `len * mem::size_of::<EncodedKey>()` of the slice pointed to
 *   by `ptr` must be no larger than isize::MAX. See the safety documentation of pointer::offset.
 * - See the safety documentation of [`EncodedKey`]
 */
typedef struct FFIEncodedKeys {
  struct FFIEncodedKey *ptr;
  uintptr_t len;
} FFIEncodedKeys;

/**
 * A description of the policy that is used to determine what notes are available for spending,
 * based upon the number of confirmations (the number of blocks in the chain since and including
 * the block in which a note was produced.)
 *
 * See [`ZIP 315`] for details including the definitions of "trusted" and "untrusted" notes.
 *
 * # Note
 *
 * `trusted` and `untrusted` are both meant to be non-zero values.
 * `0` will be treated as a request for a default value.
 *
 * [`ZIP 315`]: https://zips.z.cash/zip-0315
 */
typedef struct ConfirmationsPolicy {
  /**
   * The number of confirmations required before trusted notes may be spent. NonZero, set this
   * and `untrusted` to zero to accept the default value for each.
   */
  uint32_t trusted;
  /**
   * The number of confirmations required before untrusted notes may be spent. NonZero, set this
   * and `trusted` both to zero to accept the default value for each.
   */
  uint32_t untrusted;
  /**
   * A flag that enables selection of zero-conf transparent UTXOs for spends in shielding
   * transactions.
   */
  bool allow_zero_conf_shielding;
} ConfirmationsPolicy;

/**
 * A struct that contains a subtree root.
 *
 * # Safety
 *
 * - `root_hash_ptr` must be non-null and must be valid for reads for `root_hash_ptr_len`
 *   bytes, and it must have an alignment of `1`.
 * - The total size `root_hash_ptr_len` of the slice pointed to by `root_hash_ptr` must
 *   be no larger than `isize::MAX`. See the safety documentation of `pointer::offset`.
 */
typedef struct FfiSubtreeRoot {
  uint8_t *root_hash_ptr;
  uintptr_t root_hash_ptr_len;
  uint32_t completing_block_height;
} FfiSubtreeRoot;

/**
 * A struct that contains a pointer to, and length information for, a heap-allocated
 * slice of [`SubtreeRoot`] values.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must be valid for reads for `len * mem::size_of::<SubtreeRoot>()`
 *   many bytes, and it must be properly aligned. This means in particular:
 *   - The entire memory range pointed to by `ptr` must be contained within a single
 *     allocated object. Slices can never span across multiple allocated objects.
 *   - `ptr` must be non-null and aligned even for zero-length slices.
 *   - `ptr` must point to `len` consecutive properly initialized values of type
 *     [`SubtreeRoot`].
 * - The total size `len * mem::size_of::<SubtreeRoot>()` of the slice pointed to
 *   by `ptr` must be no larger than isize::MAX. See the safety documentation of
 *   `pointer::offset`.
 * - See the safety documentation of [`SubtreeRoot`]
 */
typedef struct FfiSubtreeRoots {
  struct FfiSubtreeRoot *ptr;
  uintptr_t len;
} FfiSubtreeRoots;

/**
 * Balance information for a value within a single pool in an account.
 */
typedef struct FfiBalance {
  /**
   * The value in the account that may currently be spent; it is possible to compute witnesses
   * for all the notes that comprise this value, and all of this value is confirmed to the
   * required confirmation depth.
   */
  int64_t spendable_value;
  /**
   * The value in the account of shielded change notes that do not yet have sufficient
   * confirmations to be spendable.
   */
  int64_t change_pending_confirmation;
  /**
   * The value in the account of all remaining received notes that either do not have sufficient
   * confirmations to be spendable, or for which witnesses cannot yet be constructed without
   * additional scanning.
   */
  int64_t value_pending_spendability;
  /**
   * The value in the account that is currently locked by an explicit output lock (e.g. the
   * migration residual locked via `zcashlc_migration_lock_residual`) and therefore excluded
   * from `spendable_value`. Locked value still belongs to the account: it is part of the
   * account's total (the sum of this struct's fields), it just cannot be selected for spending
   * until it is unlocked.
   */
  int64_t locked_value;
} FfiBalance;

/**
 * Balance information for a single account.
 *
 * The sum of this struct's fields is the total balance of the account.
 */
typedef struct FfiAccountBalance {
  uint8_t account_uuid[16];
  /**
   * The value of unspent Sapling outputs belonging to the account.
   */
  struct FfiBalance sapling_balance;
  /**
   * The value of unspent Orchard outputs belonging to the account.
   */
  struct FfiBalance orchard_balance;
  /**
   * The value of unspent Ironwood (Orchard note-version V3) outputs belonging to the account.
   */
  struct FfiBalance ironwood_balance;
  /**
   * The value of all unspent transparent outputs belonging to the account,
   * irrespective of confirmation depth.
   *
   * Unshielded balances are not subject to confirmation-depth constraints, because the
   * only possible operation on a transparent balance is to shield it, it is possible
   * to create a zero-conf transaction to perform that shielding, and the resulting
   * shielded notes will be subject to normal confirmation rules.
   */
  int64_t unshielded;
} FfiAccountBalance;

/**
 * A struct that contains details about scan progress.
 *
 * When `denominator` is zero, the numerator encodes a non-progress indicator:
 * - 0: progress is unknown.
 * - 1: an error occurred.
 */
typedef struct FfiScanProgress {
  uint64_t numerator;
  uint64_t denominator;
} FfiScanProgress;

/**
 * A type representing the potentially-spendable value of unspent outputs in the wallet.
 *
 * The balances reported using this data structure may overestimate the total spendable
 * value of the wallet, in the case that the spend of a previously received shielded note
 * has not yet been detected by the process of scanning the chain. The balances reported
 * using this data structure can only be certain to be unspent in the case that
 * [`Self::is_synced`] is true, and even in this circumstance it is possible that a newly
 * created transaction could conflict with a not-yet-mined transaction in the mempool.
 *
 * # Safety
 *
 * - `account_balances` must be non-null and must be valid for reads for
 *   `account_balances_len * mem::size_of::<AccountBalance>()` many bytes, and it must
 *   be properly aligned. This means in particular:
 *   - The entire memory range pointed to by `account_balances` must be contained within
 *     a single allocated object. Slices can never span across multiple allocated objects.
 *   - `account_balances` must be non-null and aligned even for zero-length slices.
 *   - `account_balances` must point to `len` consecutive properly initialized values of
 *     type [`AccountBalance`].
 * - The total size `account_balances_len * mem::size_of::<AccountBalance>()` of the
 *   slice pointed to by `account_balances` must be no larger than `isize::MAX`. See the
 *   safety documentation of `pointer::offset`.
 * - `scan_progress` must, if non-null, point to a struct having the layout of
 *   [`ScanProgress`].
 * - `recovery_progress` must, if non-null, point to a struct having the layout of
 *   [`ScanProgress`].
 */
typedef struct FfiWalletSummary {
  struct FfiAccountBalance *account_balances;
  uintptr_t account_balances_len;
  int32_t chain_tip_height;
  int32_t fully_scanned_height;
  struct FfiScanProgress *scan_progress;
  struct FfiScanProgress *recovery_progress;
  uint64_t next_sapling_subtree_index;
  uint64_t next_orchard_subtree_index;
  uint64_t next_ironwood_subtree_index;
} FfiWalletSummary;

/**
 * A struct that contains the start (inclusive) and end (exclusive) of a range of blocks
 * to scan.
 */
typedef struct FfiScanRange {
  int32_t start;
  int32_t end;
  uint8_t priority;
} FfiScanRange;

/**
 * A struct that contains a pointer to, and length information for, a heap-allocated
 * slice of [`ScanRange`] values.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must be valid for reads for `len * mem::size_of::<ScanRange>()`
 *   many bytes, and it must be properly aligned. This means in particular:
 *   - The entire memory range pointed to by `ptr` must be contained within a single
 *     allocated object. Slices can never span across multiple allocated objects.
 *   - `ptr` must be non-null and aligned even for zero-length slices.
 *   - `ptr` must point to `len` consecutive properly initialized values of type
 *     [`ScanRange`].
 * - The total size `len * mem::size_of::<ScanRange>()` of the slice pointed to
 *   by `ptr` must be no larger than isize::MAX. See the safety documentation of
 *   `pointer::offset`.
 */
typedef struct FfiScanRanges {
  struct FfiScanRange *ptr;
  uintptr_t len;
} FfiScanRanges;

/**
 * Metadata about modifications to the wallet state made in the course of scanning a set
 * of blocks.
 */
typedef struct FfiScanSummary {
  int32_t scanned_start;
  int32_t scanned_end;
  uint64_t spent_sapling_note_count;
  uint64_t received_sapling_note_count;
} FfiScanSummary;

typedef struct FFIBlockMeta {
  uint32_t height;
  uint8_t *block_hash_ptr;
  uintptr_t block_hash_ptr_len;
  uint32_t block_time;
  uint32_t sapling_outputs_count;
  uint32_t orchard_actions_count;
} FFIBlockMeta;

typedef struct FFIBlocksMeta {
  struct FFIBlockMeta *ptr;
  uintptr_t len;
} FFIBlocksMeta;

/**
 * A struct that optionally contains a pointer to, and length information for, a
 * heap-allocated boxed slice.
 *
 * This is an FFI representation of `Option<Box<[u8]>>`.
 *
 * # Safety
 *
 * - If `ptr` is non-null, it must be valid for reads for `len` bytes, and it must have
 *   an alignment of `1`.
 * - The memory referenced by `ptr` must not be mutated for the lifetime of the struct
 *   (up until [`zcashlc_free_boxed_slice`] is called with it).
 * - The total size `len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 *   - When `ptr` is null, `len` should be zero.
 */
typedef struct FfiBoxedSlice {
  uint8_t *ptr;
  uintptr_t len;
} FfiBoxedSlice;

/**
 * A struct that contains a pointer to, and length information for, a heap-allocated
 * slice of `[u8; 32]` arrays.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must be valid for reads for `len * mem::size_of::<[u8; 32]>()`
 *   many bytes, and it must be properly aligned. This means in particular:
 *   - The entire memory range pointed to by `ptr` must be contained within a single
 *     allocated object. Slices can never span across multiple allocated objects.
 *   - `ptr` must be non-null and aligned even for zero-length slices.
 *   - `ptr` must point to `len` consecutive properly initialized values of type
 *     `[u8; 32]`.
 * - The total size `len * mem::size_of::<[u8; 32]>()` of the slice pointed to
 *   by `ptr` must be no larger than isize::MAX. See the safety documentation of
 *   `pointer::offset`.
 */
typedef struct FfiSymmetricKeys {
  uint8_t (*ptr)[32];
  uintptr_t len;
} FfiSymmetricKeys;

typedef struct FfiSymmetricKeys FfiTxIds;

/**
 * Metadata about the status of a transaction obtained by inspecting the chain state.
 */
enum FfiTransactionStatus_Tag
#if __STDC_VERSION__ >= 202311L
  : uint8_t
#endif // __STDC_VERSION__ >= 202311L
 {
  /**
   * The requested transaction ID was not recognized by the node.
   */
  TxidNotRecognized,
  /**
   * The requested transaction ID corresponds to a transaction that is recognized by the node,
   * but is in the mempool or is otherwise not mined in the main chain (but may have been mined
   * on a fork that was reorged away).
   */
  NotInMainChain,
  /**
   * The requested transaction ID corresponds to a transaction that has been included in the
   * block at the provided height.
   */
  Mined,
};
#if __STDC_VERSION__ >= 202311L
typedef enum FfiTransactionStatus_Tag FfiTransactionStatus_Tag;
#else
typedef uint8_t FfiTransactionStatus_Tag;
#endif // __STDC_VERSION__ >= 202311L

typedef struct FfiTransactionStatus {
  FfiTransactionStatus_Tag tag;
  union {
    struct {
      uint32_t mined;
    };
  };
} FfiTransactionStatus;

/**
 * A request for transaction data enhancement, spentness check, or discovery
 * of spends from a given transparent address within a specific block range.
 */
enum FfiTransactionDataRequest_Tag
#if __STDC_VERSION__ >= 202311L
  : uint8_t
#endif // __STDC_VERSION__ >= 202311L
 {
  /**
   * Information about the chain's view of a transaction is requested.
   *
   * The caller evaluating this request on behalf of the wallet backend should respond to this
   * request by determining the status of the specified transaction with respect to the main
   * chain; if using `lightwalletd` for access to chain data, this may be obtained by
   * interpreting the results of the [`GetTransaction`] RPC method. It should then call
   * [`WalletWrite::set_transaction_status`] to provide the resulting transaction status
   * information to the wallet backend.
   *
   * [`GetTransaction`]: crate::proto::service::compact_tx_streamer_client::CompactTxStreamerClient::get_transaction
   */
  GetStatus,
  /**
   * Transaction enhancement (download of complete raw transaction data) is requested.
   *
   * The caller evaluating this request on behalf of the wallet backend should respond to this
   * request by providing complete data for the specified transaction to
   * [`wallet::decrypt_and_store_transaction`]; if using `lightwalletd` for access to chain
   * state, this may be obtained via the [`GetTransaction`] RPC method. If no data is available
   * for the specified transaction, this should be reported to the backend using
   * [`WalletWrite::set_transaction_status`]. A [`TransactionDataRequest::Enhancement`] request
   * subsumes any previously existing [`TransactionDataRequest::GetStatus`] request.
   *
   * [`GetTransaction`]: crate::proto::service::compact_tx_streamer_client::CompactTxStreamerClient::get_transaction
   */
  Enhancement,
  /**
   * Information about transactions that receive or spend funds belonging to the specified
   * transparent address is requested.
   *
   * Fully transparent transactions, and transactions that do not contain either shielded inputs
   * or shielded outputs belonging to the wallet, may not be discovered by the process of chain
   * scanning; as a consequence, the wallet must actively query to find transactions that spend
   * such funds. Ideally we'd be able to query by [`OutPoint`] but this is not currently
   * functionality that is supported by the light wallet server.
   *
   * The caller evaluating this request on behalf of the wallet backend should respond to this
   * request by detecting transactions involving the specified address within the provided block
   * range; if using `lightwalletd` for access to chain data, this may be performed using the
   * [`GetTaddressTxids`] RPC method. It should then call [`wallet::decrypt_and_store_transaction`]
   * for each transaction so detected.
   *
   * [`GetTaddressTxids`]: crate::proto::service::compact_tx_streamer_client::CompactTxStreamerClient::get_taddress_txids
   */
  TransactionsInvolvingAddress,
};
#if __STDC_VERSION__ >= 202311L
typedef enum FfiTransactionDataRequest_Tag FfiTransactionDataRequest_Tag;
#else
typedef uint8_t FfiTransactionDataRequest_Tag;
#endif // __STDC_VERSION__ >= 202311L

typedef struct TransactionsInvolvingAddress_Body {
  /**
   * The address to request transactions and/or UTXOs for.
   */
  char *address;
  /**
   * Only transactions mined at heights greater than or equal to this height should be
   * returned.
   */
  uint32_t block_range_start;
  /**
   * Only transactions mined at heights less than this height should be returned.
   *
   * Either a `u32` value, or `-1` representing no end height.
   */
  int64_t block_range_end;
  /**
   * If `request_at` is non-negative, the caller evaluating this request should attempt to
   * retrieve transaction data related to the specified address at a time that is as close
   * as practical to the specified instant, and in a fashion that decorrelates this request
   * to a light wallet server from other requests made by the same caller.
   *
   * `-1` is the only negative value, meaning "unset".
   *
   * This may be ignored by callers that are able to satisfy the request without exposing
   * correlations between addresses to untrusted parties; for example, a wallet application
   * that uses a private, trusted-for-privacy supplier of chain data can safely ignore this
   * field.
   */
  int64_t request_at;
  /**
   * The caller should respond to this request only with transactions that conform to the
   * specified transaction status filter.
   */
  enum TransactionStatusFilter tx_status_filter;
  /**
   * The caller should respond to this request only with transactions containing outputs
   * that conform to the specified output status filter.
   */
  enum OutputStatusFilter output_status_filter;
} TransactionsInvolvingAddress_Body;

typedef struct FfiTransactionDataRequest {
  FfiTransactionDataRequest_Tag tag;
  union {
    struct {
      uint8_t get_status[32];
    };
    struct {
      uint8_t enhancement[32];
    };
    TransactionsInvolvingAddress_Body transactions_involving_address;
  };
} FfiTransactionDataRequest;

/**
 * A struct that contains a pointer to, and length information for, a heap-allocated
 * slice of [`TransactionDataRequest`] values.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must be valid for reads for `len * mem::size_of::<TransactionDataRequest>()`
 *   many bytes, and it must be properly aligned. This means in particular:
 *   - The entire memory range pointed to by `ptr` must be contained within a single allocated
 *     object. Slices can never span across multiple allocated objects.
 *   - `ptr` must be non-null and aligned even for zero-length slices.
 *   - `ptr` must point to `len` consecutive properly initialized values of type
 *     [`TransactionDataRequest`].
 * - The total size `len * mem::size_of::<TransactionDataRequest>()` of the slice pointed to
 *   by `ptr` must be no larger than isize::MAX. See the safety documentation of pointer::offset.
 * - See the safety documentation of [`TransactionDataRequest`]
 */
typedef struct FfiTransactionDataRequests {
  struct FfiTransactionDataRequest *ptr;
  uintptr_t len;
} FfiTransactionDataRequests;

/**
 * An HTTP header from a response.
 *
 * Memory is managed by Rust.
 */
typedef struct FfiHttpResponseHeader {
  /**
   * The header name as a C string.
   */
  char *name;
  /**
   * The header value as a C string.
   */
  char *value;
} FfiHttpResponseHeader;

/**
 * A struct that contains an HTTP response.
 */
typedef struct FfiHttpResponseBytes {
  /**
   * The response's status.
   */
  uint16_t status;
  /**
   * The response's version.
   */
  char *version;
  /**
   * A pointer to a list of the response's headers.
   */
  struct FfiHttpResponseHeader *headers_ptr;
  /**
   * The length of the data in `headers_ptr`.
   */
  uintptr_t headers_len;
  /**
   * A pointer to the HTTP body bytes.
   */
  uint8_t *body_ptr;
  /**
   * The length of the data in `body_ptr`.
   */
  uintptr_t body_len;
} FfiHttpResponseBytes;

/**
 * An HTTP header for a request.
 *
 * Memory is managed by Swift.
 */
typedef struct FfiHttpRequestHeader {
  /**
   * The header name as a C string.
   */
  const char *name;
  /**
   * The header value as a C string.
   */
  const char *value;
} FfiHttpRequestHeader;

/**
 * A decimal suitable for converting into an `NSDecimalNumber`.
 */
typedef struct Decimal {
  uint64_t mantissa;
  int16_t exponent;
  bool is_sign_negative;
} Decimal;

/**
 * The result of checking for UTXOs received by an ephemeral address.
 *
 */
enum FfiAddressCheckResult_Tag
#if __STDC_VERSION__ >= 202311L
  : uint8_t
#endif // __STDC_VERSION__ >= 202311L
 {
  /**
   * No UTXOs were found as a result of the check.
   */
  FfiAddressCheckResult_NotFound,
  /**
   * UTXOs were found for the given address.
   */
  FfiAddressCheckResult_Found,
};
#if __STDC_VERSION__ >= 202311L
typedef enum FfiAddressCheckResult_Tag FfiAddressCheckResult_Tag;
#else
typedef uint8_t FfiAddressCheckResult_Tag;
#endif // __STDC_VERSION__ >= 202311L

typedef struct FfiAddressCheckResult_Found_Body {
  char *address;
} FfiAddressCheckResult_Found_Body;

typedef struct FfiAddressCheckResult {
  FfiAddressCheckResult_Tag tag;
  union {
    FfiAddressCheckResult_Found_Body found;
  };
} FfiAddressCheckResult;

/**
 * A struct that contains a Zcash unified address, along with the diversifier index used to
 * generate that address.
 */
typedef struct FfiAddress {
  char *address;
  uint8_t diversifier_index_bytes[11];
} FfiAddress;

/**
 * A native ETH/chain token transfer extracted from a parsed EIP-681 request.
 *
 * All string fields are heap-allocated and must be freed by calling
 * [`zcashlc_free_eip681_native_request`].
 *
 * # Safety
 *
 * - `schema_prefix` and `recipient_address` are non-null, null-terminated UTF-8 strings.
 * - `value_hex`, `gas_limit_hex`, and `gas_price_hex` are either null (indicating the value
 *   was not present in the URI) or non-null, null-terminated UTF-8 strings containing a
 *   `0x`-prefixed hex-encoded `U256` value.
 */
typedef struct FfiEip681NativeRequest {
  /**
   * The URI schema prefix (e.g. "ethereum").
   */
  char *schema_prefix;
  /**
   * Whether the URI uses the "pay-" prefix after the schema (e.g. "ethereum:pay-").
   */
  bool has_pay;
  /**
   * Whether a chain ID was specified in the URI.
   */
  bool has_chain_id;
  /**
   * The chain ID, if `has_chain_id` is true. Undefined otherwise.
   */
  uint64_t chain_id;
  /**
   * The recipient address (ERC-55 checksummed hex or ENS name).
   */
  char *recipient_address;
  /**
   * The transfer value as a `0x`-prefixed hex string, or null if not specified.
   */
  char *value_hex;
  /**
   * The gas limit as a `0x`-prefixed hex string, or null if not specified.
   */
  char *gas_limit_hex;
  /**
   * The gas price as a `0x`-prefixed hex string, or null if not specified.
   */
  char *gas_price_hex;
} FfiEip681NativeRequest;

/**
 * An ERC-20 token transfer extracted from a parsed EIP-681 request.
 *
 * All string fields are heap-allocated and must be freed by calling
 * [`zcashlc_free_eip681_erc20_request`].
 *
 * # Safety
 *
 * - `schema_prefix`, `token_contract_address`, `recipient_address`, and `value_hex` are
 *   non-null, null-terminated UTF-8 strings.
 * - `value_hex` contains a `0x`-prefixed hex-encoded `U256` value.
 */
typedef struct FfiEip681Erc20Request {
  /**
   * The URI schema prefix (e.g. "ethereum").
   */
  char *schema_prefix;
  /**
   * Whether the URI uses the "pay-" prefix after the schema (e.g. "ethereum:pay-").
   */
  bool has_pay;
  /**
   * Whether a chain ID was specified in the URI.
   */
  bool has_chain_id;
  /**
   * The chain ID, if `has_chain_id` is true. Undefined otherwise.
   */
  uint64_t chain_id;
  /**
   * The ERC-20 token contract address (ERC-55 checksummed hex or ENS name).
   */
  char *token_contract_address;
  /**
   * The transfer recipient address (ERC-55 checksummed hex or ENS name).
   */
  char *recipient_address;
  /**
   * The transfer value in atomic units as a `0x`-prefixed hex string.
   */
  char *value_hex;
} FfiEip681Erc20Request;

/**
 * Sanitized summary of one exact artifact. It deliberately excludes capability tokens, exact
 * proposal/PCZT/transaction bytes, policy fingerprints, and clock-session identities.
 */
typedef struct FfiMigrationClaimSummaryV1 {
  /**
   * `0` = scheduled, `1` = immediate.
   */
  uint8_t artifact_lane;
  /**
   * Scheduled canonical transaction id, or `-1` for the immediate lane.
   */
  int64_t scheduled_transaction_id;
  /**
   * Immediate artifact identity; all-zero for the scheduled lane.
   */
  uint8_t immediate_artifact_identity[32];
  /**
   * `0` = SDK signer, `1` = external signer.
   */
  uint8_t signer_ownership;
  /**
   * `0` materializing, `1` materializationFailed, `2` awaitingExternalSignature, `3` staged,
   * `4` submitting, `5` outcomeUnknown, `6` broadcasted, `7` confirmed,
   * `8` expiredUnmined, `9` externalSigningExpiredUnmined.
   */
  uint8_t status;
  /**
   * `-1` = no live claim, `0` = materialization, `1` = submission,
   * `2` = outcome resolution.
   */
  int8_t claim_kind;
  /**
   * Exact external-signing bytes have crossed the cancellation-unsafe exposure boundary.
   */
  bool externally_exposed;
  bool has_signed_pczt;
  bool has_exact_transaction;
  uint32_t expiry_height;
  bool has_txid;
  uint8_t txid[32];
  /**
   * `-1` = none; otherwise the `DeliveryFailureReason` ordering documented by
   * `delivery_failure_tag` below.
   */
  int8_t last_error;
  /**
   * Opaque Rust-owned capability for this exact reconstructed claim.
   */
  struct FfiMigrationClaimHandle *claim_handle;
} FfiMigrationClaimSummaryV1;

/**
 * Sanitized owning projection of one retained predecessor. Rollover does not erase old ambiguous
 * or externally exposed artifacts; each retained entry therefore carries its own opaque run
 * handle and claim summaries so that exact predecessor remains resumable and reconcilable.
 */
typedef struct FfiRetainedMigrationRunV1 {
  bool has_canonical_state;
  int8_t canonical_status;
  uint32_t canonical_transaction_count;
  uint8_t destination_spendability;
  uint64_t delivery_revision;
  uint8_t delivery_lane;
  uint8_t delivery_phase;
  uint8_t storage_finality;
  int8_t storage_recovery_reason;
  int64_t delivery_release_height;
  uint64_t active_source_reservation_count;
  bool has_submission_policy;
  int8_t policy_validation_failure;
  bool safe_to_cancel;
  struct FfiMigrationClaimSummaryV1 *claims;
  uintptr_t claims_len;
  struct FfiMigrationRunHandle *run_handle;
} FfiRetainedMigrationRunV1;

/**
 * One owning, revision-consistent account runtime projection.
 */
typedef struct FfiMigrationRuntimeSnapshotV1 {
  uint32_t abi_version;
  uint8_t account_uuid[16];
  /**
   * `-1` none, `0` planning, `1` committed, `2` inProgress, `3` complete, `4` failed.
   */
  int8_t canonical_status;
  uint32_t canonical_transaction_count;
  /**
   * `0` compatible, `1` unavailable, `2` future, `3` corrupt.
   */
  uint8_t schema_provenance;
  /**
   * Compatible/future schema version, otherwise zero.
   */
  uint32_t schema_version;
  /**
   * `0` fresh, `1` recovery required.
   */
  uint8_t legacy_cutover;
  uint32_t legacy_object_count;
  /**
   * `0` not spendable, `1` spendable, `2` already spent, `3` not applicable (no run).
   */
  uint8_t destination_spendability;
  /**
   * `0` available, `1` unavailable.
   */
  uint8_t availability;
  /**
   * `-1` none; otherwise `runtime_unavailable_tag`.
   */
  int8_t unavailable_reason;
  /**
   * Schema version, legacy object count, or storage-recovery tag carried by the reason.
   */
  uint32_t unavailable_detail;
  /**
   * `0` unrestricted, `1` excluding migration sources, `2` blocked.
   */
  uint8_t ordinary_spend_authorization;
  /**
   * `-1` for allowed; `0` migration active, `1` destination not spendable,
   * `2` runtime unavailable, `3` finality recovery.
   */
  int8_t ordinary_spend_block_reason;
  /**
   * Release height for `excluding migration sources`, otherwise `-1`.
   */
  int64_t ordinary_spend_release_height;
  /**
   * `0` allowed, `1` blocked.
   */
  uint8_t account_deletion_authorization;
  /**
   * `-1` allowed, `0` runtime unavailable, `1` unresolved delivery.
   */
  int8_t account_deletion_block_reason;
  /**
   * `0` allowed, `1` blocked.
   */
  uint8_t canonical_mutation_authorization;
  /**
   * `-1` allowed, `0` runtime unavailable, `1` delivery owned.
   */
  int8_t canonical_mutation_block_reason;
  bool has_delivery;
  uint64_t delivery_revision;
  /**
   * `-1` no delivery, `0` scheduled, `1` immediate.
   */
  int8_t delivery_lane;
  /**
   * `-1` no delivery, `0` active, `1` paused, `2` abandoning, `3` abandoned.
   */
  int8_t delivery_phase;
  /**
   * `-1` no delivery, `0` noRun, `1` active, `2` completePendingFinality,
   * `3` finalized, `4` recoveryRequired.
   */
  int8_t storage_finality;
  /**
   * `-1` none; otherwise `storage_recovery_tag`.
   */
  int8_t storage_recovery_reason;
  int64_t delivery_release_height;
  /**
   * Aggregate finality across the current run and every retained predecessor. Uses the same
   * tags as `storage_finality`, but remains meaningful when `has_delivery` is false.
   */
  int8_t aggregate_storage_finality;
  /**
   * Aggregate recovery reason across current and retained runs, or `-1`.
   */
  int8_t aggregate_storage_recovery_reason;
  /**
   * Aggregate release height across current and retained runs, or `-1`.
   */
  int64_t aggregate_delivery_release_height;
  /**
   * Exact live source-reservation rows owned by the current run.
   */
  uint64_t active_source_reservation_count;
  bool has_submission_policy;
  /**
   * `-1` none; otherwise `policy_failure_tag`.
   */
  int8_t policy_validation_failure;
  /**
   * Rust-derived cancellation verdict, including external-PCZT exposure.
   */
  bool safe_to_cancel;
  struct FfiMigrationClaimSummaryV1 *claims;
  uintptr_t claims_len;
  /**
   * Opaque immutable run capability owned by this DTO; null when no delivery run exists.
   */
  struct FfiMigrationRunHandle *run_handle;
  /**
   * Every predecessor whose reservations, finality, or exposed evidence remain authoritative.
   */
  struct FfiRetainedMigrationRunV1 *retained_runs;
  uintptr_t retained_runs_len;
} FfiMigrationRuntimeSnapshotV1;

/**
 * One atomic all-account runtime read.
 */
typedef struct FfiMigrationRuntimeBatchV1 {
  uint32_t abi_version;
  struct FfiMigrationRuntimeSnapshotV1 *accounts;
  uintptr_t accounts_len;
} FfiMigrationRuntimeBatchV1;

/**
 * Live migration progress. When returned standalone (`zcashlc_migration_progress`), `is_present`
 * is `false` when no migration is in progress; as the payload of
 * [`FfiMigrationState::InProgress`] it is always `true`.
 */
typedef struct FfiMigrationProgress {
  /**
   * Whether the remaining fields carry a real progress snapshot.
   */
  bool is_present;
  /**
   * The number of scheduled transfers confirmed on-chain so far.
   */
  uint32_t completed_transfers;
  /**
   * The total number of transfers in the current schedule.
   */
  uint32_t total_transfers;
  /**
   * The Orchard-pool value (zatoshi) not yet migrated to Ironwood — the account's live
   * spendable Orchard balance.
   */
  int64_t remaining_orchard_value;
  /**
   * The height at which the next transfer becomes broadcastable, or `-1` if none is scheduled.
   * Only transfers still AWAITING broadcast count (F6): one already `Broadcast` (in the
   * mempool, awaiting mining) has nothing left to prepare for, so it never sets this field,
   * even when its own scheduled height is lower than another transfer's.
   */
  int64_t next_transfer_ready_at_height;
  /**
   * Whether this progress belongs to the immediate (single-transaction) send-max migration lane
   * rather than an engine-tracked schedule. The app uses it to keep the immediate aftermath
   * quiet (no per-transfer UI). Engine-tracked runs report `false`.
   */
  bool is_immediate;
} FfiMigrationProgress;

/**
 * Why a migration requires user attention (payload of [`FfiMigrationState::RequiresAttention`]).
 */
enum FfiAttentionReason_Tag
#if __STDC_VERSION__ >= 202311L
  : uint8_t
#endif // __STDC_VERSION__ >= 202311L
 {
  /**
   * The transfer identified by `transfer_id` was terminally rejected at broadcast (its input
   * note was spent externally, or the network refused it as invalid). `transfer_id` is an owned
   * C string, freed by [`zcashlc_free_migration_state`].
   */
  InvalidTransfer,
  /**
   * A transaction's expiry elapsed before it could be broadcast (or mined).
   */
  TransferExpired,
};
#if __STDC_VERSION__ >= 202311L
typedef enum FfiAttentionReason_Tag FfiAttentionReason_Tag;
#else
typedef uint8_t FfiAttentionReason_Tag;
#endif // __STDC_VERSION__ >= 202311L

typedef struct InvalidTransfer_Body {
  char *transfer_id;
} InvalidTransfer_Body;

typedef struct FfiAttentionReason {
  FfiAttentionReason_Tag tag;
  union {
    InvalidTransfer_Body invalid_transfer;
  };
} FfiAttentionReason;

/**
 * The top-level migration state machine surfaced to the app.
 *
 * `#[allow(dead_code)]`: the data-carrying variants' payloads are read by the C consumer across
 * the FFI (cbindgen emits them into the header), which rustc cannot observe.
 */
enum FfiMigrationState_Tag
#if __STDC_VERSION__ >= 202311L
  : uint8_t
#endif // __STDC_VERSION__ >= 202311L
 {
  /**
   * No migration run is stored (none started, or a previous run was cancelled).
   */
  NotStarted,
  /**
   * The run is committed and its preparation (note-split) transactions are not yet all mined.
   */
  SplitPendingConfirmation,
  /**
   * Preparation is mined and the run's transfers are executing.
   */
  InProgress,
  /**
   * A transfer cannot proceed automatically; the app must act.
   */
  RequiresAttention,
  /**
   * Every transaction of the STORED RUN is mined. Per-run: whether anything remains to migrate
   * is answered by a fresh `zcashlc_migration_propose_transfers` (empty schedule = nothing).
   */
  Complete,
};
#if __STDC_VERSION__ >= 202311L
typedef enum FfiMigrationState_Tag FfiMigrationState_Tag;
#else
typedef uint8_t FfiMigrationState_Tag;
#endif // __STDC_VERSION__ >= 202311L

typedef struct FfiMigrationState {
  FfiMigrationState_Tag tag;
  union {
    struct {
      struct FfiMigrationProgress in_progress;
    };
    struct {
      struct FfiAttentionReason requires_attention;
    };
  };
} FfiMigrationState;

/**
 * A planned note split: the per-note output values (zatoshi) and the preparation fees.
 */
typedef struct FfiNoteSplitProposal {
  /**
   * Heap array of `output_values_len` output-note values (zatoshi).
   */
  int64_t *output_values;
  uintptr_t output_values_len;
  /**
   * The total fees (zatoshi) paid by the preparation (note-split) transactions.
   */
  int64_t fee;
  /**
   * Opaque identifier of the cached plan this proposal was rendered from. `0` means no live
   * cached plan backs the proposal.
   */
  uint64_t proposal_handle;
} FfiNoteSplitProposal;

/**
 * Legacy prepared-transfer DTO retained for C ABI compatibility with disabled unscoped migration
 * entry points. Current delivery APIs expose artifacts only through opaque claim handles.
 */
typedef struct FfiPreparedTransfer {
  /**
   * The transaction's id (the engine's decimal id), as an owned C string when populated by a
   * pre-capability implementation.
   */
  char *id;
  /**
   * The finalized transaction's id, as raw (internal-order) 32-byte value.
   */
  uint8_t txid[32];
  /**
   * Heap `pczt_len`-byte serialized PCZT when populated by a pre-capability implementation.
   */
  uint8_t *pczt;
  uintptr_t pczt_len;
} FfiPreparedTransfer;

/**
 * A single scheduled Orchard→Ironwood transfer (element of [`FfiMigrationSchedule`]).
 */
typedef struct FfiTransferProposal {
  /**
   * The transfer's id (the engine's decimal id), as an owned C string.
   */
  char *id;
  /**
   * The value (zatoshi) that crosses the turnstile.
   */
  int64_t amount;
  /**
   * The "now" reference height at encode time (the chain tip). With ZIP 374 the real anchor is
   * drawn per transfer and installed at proving time; this field is NOT a commitment-tree
   * anchor and callers must not treat it as one.
   */
  int64_t anchor_height;
  /**
   * The height after which the platform may broadcast this transfer.
   */
  int64_t next_executable_after_height;
  /**
   * The height after which this transfer is no longer valid.
   */
  int64_t expiry_height;
} FfiTransferProposal;

/**
 * A full migration schedule presented to the user for one-time confirmation, in chronological
 * broadcast order. An empty schedule means there is nothing to migrate.
 */
typedef struct FfiMigrationSchedule {
  /**
   * Heap array of `transfers_len` scheduled transfers, in execution order.
   */
  struct FfiTransferProposal *transfers;
  uintptr_t transfers_len;
  /**
   * A rough estimate of how long the schedule takes to fully execute, in hours — measured
   * from the encode-time chain tip to the last scheduled broadcast (#1806).
   */
  uint32_t estimated_duration_hours;
  /**
   * Opaque identifier of the cached plan this schedule was rendered from. Display fields are
   * never accepted back as commit authority. `0` means no live cached plan backs the schedule.
   */
  uint64_t proposal_handle;
} FfiMigrationSchedule;

/**
 * A single run's estimate (element of [`FfiMigrationRunEstimate`]): what one migration run
 * migrates (the note-split side) and what preparing it costs (the note-preparation side), so
 * the two can be compared.
 */
typedef struct FfiRunEstimate {
  /**
   * The total value (zatoshi) that crosses the turnstile in this run.
   */
  int64_t migratable;
  /**
   * The number of pool-crossing transfers this run makes: one per self-funding note.
   */
  uint32_t crossings;
  /**
   * The number of sequential note-preparation layers this run needs — its wall-clock depth,
   * since each layer waits for the previous one to mine before it can be broadcast.
   */
  uint32_t prep_layers;
  /**
   * The number of note-preparation transactions this run builds across all its layers.
   */
  uint32_t prep_transactions;
} FfiRunEstimate;

/**
 * An estimate of migrating the account's whole spendable balance across successive migration
 * RUNS ("rounds"): one [`FfiRunEstimate`] per run, plus the value left un-migrated at the end.
 * `runs_len == 0` means nothing migrates (a zero or fully sub-quantum balance) — a legitimate
 * estimate, not an error.
 */
typedef struct FfiMigrationRunEstimate {
  /**
   * Heap array of `runs_len` per-run estimates, in run order.
   */
  struct FfiRunEstimate *runs;
  uintptr_t runs_len;
  /**
   * The value (zatoshi) left in the source pool after the last run — below the smallest
   * self-funding note, so it never migrates. Zero when the balance divides exactly into
   * self-funding notes and fees.
   */
  int64_t final_residual;
} FfiMigrationRunEstimate;

/**
 * An unsigned PCZT awaiting an external signer (element of [`FfiUnsignedTransferPczts`]).
 */
typedef struct FfiUnsignedTransferPczt {
  /**
   * The transaction's id (the engine's decimal id), as an owned C string.
   */
  char *id;
  /**
   * Heap `pczt_len`-byte serialized unsigned PCZT.
   */
  uint8_t *pczt;
  uintptr_t pczt_len;
} FfiUnsignedTransferPczt;

/**
 * A set of unsigned PCZTs to route to an external signer. Despite the name, this is really a
 * generic `(id, PCZT bytes)` pair set: [`zcashlc_migration_keystone_apply_batch_signatures`]
 * also returns its batch-SIGNED PCZTs through this same type, positionally paired back up with
 * the ids the caller passed in.
 */
typedef struct FfiUnsignedTransferPczts {
  struct FfiUnsignedTransferPczt *ptr;
  uintptr_t len;
} FfiUnsignedTransferPczts;

/**
 * One migration transaction's LIVE status, as the engine computes it — an element of
 * [`FfiMigrationTransactionStatuses`]. Mirrors
 * [`zcash_pool_migration::state::TransactionStatus`] field-for-field — minus its
 * `depends_on` edge list, deliberately not marshaled so every row stays heap-pointer-free (a
 * `blocked_on = dependencies` row reports THAT it waits, not on which ids) — and nothing here
 * is derived independently of the engine's own view (see
 * [`zcashlc_migration_transaction_statuses`]).
 */
typedef struct FfiMigrationTransactionStatus {
  /**
   * This transaction's stable id (`MigrationTxId`'s raw ordinal). Stable across reads and
   * across a stale-transfer rebuild (a rebuilt transfer keeps its id; only its PCZT and
   * heights change), so a wallet may use it as a durable row key.
   */
  uint32_t id;
  /**
   * The transaction's kind: `true` for a phase-2 pool-crossing TRANSFER, `false` for a
   * note-PREPARATION. See `prep_layer`/`prep_index`/`crossing` for the per-kind payload
   * (`MigrationTxKind::Preparation { layer, index }` / `MigrationTxKind::Transfer { crossing }`).
   */
  bool is_transfer;
  /**
   * For a preparation: its dependency-layer index. `-1` when `is_transfer` is `true`.
   */
  int64_t prep_layer;
  /**
   * For a preparation: its index within `prep_layer`. `-1` when `is_transfer` is `true`.
   */
  int64_t prep_index;
  /**
   * For a transfer: the funding-note crossing index. `-1` when `is_transfer` is `false`.
   */
  int64_t crossing;
  /**
   * Lifecycle discriminant: `0` = AwaitingSignature, `1` = Signed, `2` = Proved,
   * `3` = Broadcast, `4` = Mined.
   */
  uint8_t state;
  /**
   * The height at or after which this transaction is due to broadcast.
   */
  int64_t scheduled_height;
  /**
   * The height after which this transaction can no longer be mined (ZIP 203); `0` means it
   * never expires (the engine's own sentinel, carried through unchanged).
   */
  int64_t expiry_height;
  /**
   * The height it was mined at, once `state == 4` (Mined). `-1` otherwise.
   */
  int64_t mined_height;
  /**
   * The transaction id (raw internal-order bytes), meaningful only when `has_txid` is `true`.
   */
  uint8_t txid[32];
  /**
   * Whether `txid` is populated. Set only while `state == 3` (Broadcast): the engine's own
   * [`MigrationTxState::Mined`] carries just the mined height, not a txid, so once mined this
   * goes back to `false` — a verbatim mirror of the engine's own view, not a gap in this
   * marshaling (see [`zcashlc_migration_transaction_statuses`]'s doc).
   */
  bool has_txid;
  /**
   * Whether the wallet can act on this transaction right now.
   */
  bool ready;
  /**
   * The action available now, when `ready` is `true`: `0` = none, `1` = prove, `2` = broadcast.
   */
  uint8_t action;
  /**
   * Why it is not yet actionable, when waiting (and not already broadcast or mined): `0` =
   * none, `1` = dependencies, `2` = schedule, `3` = anchor_boundary, `4` = signature,
   * `5` = expired.
   */
  uint8_t blocked_on;
} FfiMigrationTransactionStatus;

/**
 * A snapshot of every committed migration transaction's LIVE status (element type
 * [`FfiMigrationTransactionStatus`]), as returned by [`zcashlc_migration_transaction_statuses`].
 * `len == 0` means no stored run, or a stored run with no transactions — not an error.
 */
typedef struct FfiMigrationTransactionStatuses {
  /**
   * Heap array of `len` rows, in the engine's own `transaction_statuses` order (dependency
   * order: preparation layers first, then transfers).
   */
  struct FfiMigrationTransactionStatus *ptr;
  uintptr_t len;
} FfiMigrationTransactionStatuses;

/**
 * A set of animated multi-part QR frame strings for a Keystone batch-signing request. Element
 * order is the wire fragment order — display/scan them in that order.
 *
 * This crate's first string-array FFI output type: kept intentionally minimal (unlike
 * [`FfiUnsignedTransferPczts`], there is no paired per-element id or byte blob here, just
 * strings), rather than generalizing [`ffi::BoxedSlice`] (a single binary blob, not an array) or
 * inventing a shared generic array wrapper for a need that has arisen exactly once so far.
 */
typedef struct FfiKeystoneQrParts {
  /**
   * Heap array of `len` owned, NUL-terminated UTF-8 strings.
   */
  char **ptr;
  uintptr_t len;
} FfiKeystoneQrParts;

/**
 * The result of feeding one scanned QR frame to
 * `zcashlc_migration_keystone_decode_sign_batch_part`, mirroring
 * [`crate::migration_keystone::DecodePartResult`].
 *
 * `complete == false` means more frames are needed: `progress` is the 0-100 completion
 * percentage so far, and `data`/the firmware fields are unset (null / `false` / zeroed).
 * `complete == true` means `data` holds the serialized `BatchSignResponse` bytes to pass to
 * `zcashlc_migration_keystone_apply_batch_signatures`, and — when `has_firmware_version` — the
 * signing device's own reported firmware version is in `firmware_major`/`firmware_minor`/
 * `firmware_build`.
 */
typedef struct FfiKeystoneBatchDecodeResult {
  bool complete;
  uint32_t progress;
  /**
   * Heap `data_len`-byte serialized `BatchSignResponse` (null unless `complete`).
   */
  uint8_t *data;
  uintptr_t data_len;
  bool has_firmware_version;
  uint8_t firmware_major;
  uint8_t firmware_minor;
  uint8_t firmware_build;
} FfiKeystoneBatchDecodeResult;

/**
 * Voting hotkey returned by `zcashlc_voting_generate_hotkey`.
 */
typedef struct FfiVotingHotkey {
  uint8_t *secret_key;
  uintptr_t secret_key_len;
  uint8_t *public_key;
  uintptr_t public_key_len;
  char *address;
} FfiVotingHotkey;

/**
 * Bundle setup result returned by `zcashlc_voting_setup_bundles`.
 */
typedef struct FfiBundleSetupResult {
  uint32_t bundle_count;
  uint64_t eligible_weight;
} FfiBundleSetupResult;

/**
 * Round state returned by `zcashlc_voting_get_round_state`.
 */
typedef struct FfiRoundState {
  char *round_id;
  /**
   * 0=Initialized, 1=HotkeyGenerated, 2=DelegationConstructed,
   * 3=DelegationProved, 4=VoteReady
   */
  uint32_t phase;
  uint64_t snapshot_height;
  /**
   * Nullable: null if no hotkey has been generated yet.
   */
  char *hotkey_address;
  /**
   * -1 if None, otherwise the delegated weight value.
   */
  int64_t delegated_weight;
  bool proof_generated;
} FfiRoundState;

/**
 * Round summary for list display.
 */
typedef struct FfiRoundSummary {
  char *round_id;
  uint32_t phase;
  uint64_t snapshot_height;
  uint64_t created_at;
} FfiRoundSummary;

/**
 * Array of round summaries.
 */
typedef struct FfiRoundSummaries {
  struct FfiRoundSummary *ptr;
  uintptr_t len;
} FfiRoundSummaries;

/**
 * Vote record for a single proposal/bundle.
 */
typedef struct FfiVoteRecord {
  uint32_t proposal_id;
  uint32_t bundle_index;
  uint32_t choice;
  bool submitted;
} FfiVoteRecord;

/**
 * Array of vote records.
 */
typedef struct FfiVoteRecords {
  struct FfiVoteRecord *ptr;
  uintptr_t len;
} FfiVoteRecords;

/**
 * Initializes global Rust state, such as the logging infrastructure and threadpools.
 *
 * `log_level` defines how the Rust layer logs its events. These values are supported,
 * each level logging more information in addition to the earlier levels:
 * - `off`: The logs are completely disabled.
 * - `error`: Logs very serious errors.
 * - `warn`: Logs hazardous situations.
 * - `info`: Logs useful information.
 * - `debug`: Logs lower priority information.
 * - `trace`: Logs very low priority, often extremely verbose, information.
 *
 * # Safety
 *
 * - The memory pointed to by `log_level` must contain a valid nul terminator at the end
 *   of the string.
 * - `log_level` must be valid for reads of bytes up to and including the nul terminator.
 *   This means in particular:
 *   - The entire memory range of this `CStr` must be contained within a single allocated
 *     object!
 * - The memory referenced by the returned `CStr` must not be mutated for the duration of
 *   the function call.
 * - The nul terminator must be within `isize::MAX` from `log_level`.
 *
 * # Panics
 *
 * This method panics if called more than once.
 */
void zcashlc_init_on_load(const char *log_level);

/**
 * Returns the length of the last error message to be logged.
 */
int32_t zcashlc_last_error_length(void);

/**
 * Copies the last error message into the provided allocated buffer.
 *
 * # Safety
 *
 * - `buf` must be non-null and valid for reads for `length` bytes, and it must have an alignment
 *   of `1`.
 * - The memory referenced by `buf` must not be mutated for the duration of the function call.
 * - The total size `length` must be no larger than `isize::MAX`. See the safety documentation of
 *   pointer::offset.
 */
int32_t zcashlc_error_message_utf8(char *buf, int32_t length);

/**
 * Clears the record of the last error message.
 */
void zcashlc_clear_last_error(void);

/**
 * Sets up the internal structure of the data database.  The value for `seed` may be provided as a
 * null pointer if the caller wishes to attempt migrations without providing the wallet's seed
 * value.
 *
 * Returns:
 * - 0 if successful.
 * - 1 if the seed must be provided in order to execute the requested migrations
 * - 2 if the provided seed is not relevant to any of the derived accounts in the wallet.
 * - -1 on error.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `seed` must be non-null and valid for reads for `seed_len` bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `seed` must not be mutated for the duration of the function call.
 * - The total size `seed_len` must be no larger than `isize::MAX`. See the safety documentation
 *   of pointer::offset.
 */
int32_t zcashlc_init_data_database(const uint8_t *db_data,
                                   uintptr_t db_data_len,
                                   const uint8_t *seed,
                                   uintptr_t seed_len,
                                   uint32_t network_id);

/**
 * Returns a list of the accounts in the wallet.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - Call [`zcashlc_free_accounts`] to free the memory associated with the returned pointer
 *   when done using it.
 */
struct FfiAccounts *zcashlc_list_accounts(const uint8_t *db_data,
                                          uintptr_t db_data_len,
                                          uint32_t network_id);

/**
 * Returns the account data for the specified account identifier, or the [`ffi::Account::NOT_FOUND`]
 * sentinel value if the account id does not correspond to an account in the wallet.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `account_uuid_bytes` must be non-null and valid for reads for 16 bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `account_uuid_bytes` must not be mutated for the duration of the
 *   function call.
 * - Call [`zcashlc_free_account`] to free the memory associated with the returned pointer
 *   when done using it.
 */
struct FfiAccount *zcashlc_get_account(const uint8_t *db_data,
                                       uintptr_t db_data_len,
                                       uint32_t network_id,
                                       const uint8_t *account_uuid_bytes);

/**
 * Adds the next available account-level spend authority, given the current set of [ZIP 316]
 * account identifiers known, to the wallet database.
 *
 * Returns the newly created [ZIP 316] account identifier, along with the binary encoding of the
 * [`UnifiedSpendingKey`] for the newly created account.  The caller should manage the memory of
 * (and store) the returned spending keys in a secure fashion.
 *
 * If `seed` was imported from a backup and this method is being used to restore a
 * previous wallet state, you should use this method to add all of the desired
 * accounts before scanning the chain from the seed's birthday height.
 *
 * By convention, wallets should only allow a new account to be generated after funds
 * have been received by the currently available account (in order to enable
 * automated account recovery).
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `seed` must be non-null and valid for reads for `seed_len` bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `seed` must not be mutated for the duration of the function call.
 * - The total size `seed_len` must be no larger than `isize::MAX`. See the safety documentation
 *   of pointer::offset.
 * - `treestate` must be non-null and valid for reads for `treestate_len` bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `treestate` must not be mutated for the duration of the function call.
 * - The total size `treestate_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - Call [`zcashlc_free_binary_key`] to free the memory associated with the returned pointer when
 *   you are finished using it.
 *
 * [ZIP 316]: https://zips.z.cash/zip-0316
 */
struct FFIBinaryKey *zcashlc_create_account(const uint8_t *db_data,
                                            uintptr_t db_data_len,
                                            const uint8_t *seed,
                                            uintptr_t seed_len,
                                            const uint8_t *treestate,
                                            uintptr_t treestate_len,
                                            int64_t recover_until,
                                            uint32_t network_id,
                                            const char *account_name,
                                            const char *key_source);

/**
 * Adds a new account to the wallet by importing the UFVK that will be used to detect incoming
 * payments.
 *
 * Derivation metadata may optionally be included. To indicate that no derivation metadata is
 * available, the `seed_fingerprint` argument should be set to the null pointer and
 * `hd_account_index` should be set to the value `u32::MAX`. Derivation metadata will not be
 * stored unless both the seed fingerprint and the HD account index are provided.
 *
 * Returns the globally unique identifier for the account.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `ufvk` must be non-null and must point to a null-terminated UTF-8 string.
 * - `treestate` must be non-null and valid for reads for `treestate_len` bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `treestate` must not be mutated for the duration of the function call.
 * - The total size `treestate_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `seed_fingerprint` must either be either null or valid for reads for 32 bytes, and it must
 *   have an alignment of `1`.
 *
 * - Call [`zcashlc_free_ffi_uuid`] to free the memory associated with the returned pointer when
 *   you are finished using it.
 */
struct FfiUuid *zcashlc_import_account_ufvk(const uint8_t *db_data,
                                            uintptr_t db_data_len,
                                            const char *ufvk,
                                            const uint8_t *treestate,
                                            uintptr_t treestate_len,
                                            int64_t recover_until,
                                            uint32_t network_id,
                                            uint32_t purpose,
                                            const char *account_name,
                                            const char *key_source,
                                            const uint8_t *seed_fingerprint,
                                            uint32_t hd_account_index_raw);

/**
 * Checks whether the given seed is relevant to any of the accounts in the wallet.
 *
 * Returns:
 * - `1` for `Ok(true)`.
 * - `0` for `Ok(false)`.
 * - `-1` for `Err(_)`.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `seed` must be non-null and valid for reads for `seed_len` bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `seed` must not be mutated for the duration of the function call.
 * - The total size `seed_len` must be no larger than `isize::MAX`. See the safety documentation
 *   of pointer::offset.
 */
int8_t zcashlc_is_seed_relevant_to_any_derived_account(const uint8_t *db_data,
                                                       uintptr_t db_data_len,
                                                       const uint8_t *seed,
                                                       uintptr_t seed_len,
                                                       uint32_t network_id);

/**
 * Deletes the specified account, and all transactions that exclusively involve it, from the
 * wallet database.
 *
 * WARNING: This is a destructive operation and may result in the permanent loss of
 * potentially important information that is not recoverable from chain data, including:
 * * Data about transactions sent by the account for which [`OvkPolicy::Discard`] (or
 *   [`OvkPolicy::Custom`] with random OVKs) was used;
 * * Data related to transactions that the account attempted to send that expired or were
 *   otherwise invalidated without having been mined in the main chain;
 * * Data related to transactions that were observed in the mempool as having inputs or
 *   outputs that involved the account, but that were never mined in the main chain;
 * * Data related to transactions that were received by the wallet in a mined block, where
 *   that block was later un-mined in a chain reorg and the transaction was either invalidated
 *   or was never re-mined.
 *
 * Returns `true` on success, or `false` if an error is raised.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `seed` must be non-null and valid for reads for `seed_len` bytes, and it must have an
 *   alignment of `1`.
 *
 * [`OvkPolicy::Discard`]: zcash_client_backend::wallet::OvkPolicy::Discard
 * [`OvkPolicy::Custom`]: zcash_client_backend::wallet::OvkPolicy::Custom
 */
bool zcashlc_delete_account(const uint8_t *db_data,
                            uintptr_t db_data_len,
                            uint32_t network_id,
                            const uint8_t *account_uuid_bytes);

/**
 * Returns the most-recently-generated unified payment address for the specified account.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `account_uuid_bytes` must be non-null and valid for reads for 16 bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `account_uuid_bytes` must not be mutated for the duration of the
 *   function call.
 * - Call [`zcashlc_string_free`] to free the memory associated with the returned pointer
 *   when done using it.
 */
char *zcashlc_get_current_address(const uint8_t *db_data,
                                  uintptr_t db_data_len,
                                  const uint8_t *account_uuid_bytes,
                                  uint32_t network_id);

/**
 * Generates and returns an ephemeral address for one-time use, such as when receiving a swap from
 * a decentralized exchange.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `account_uuid_bytes` must be non-null and valid for reads for 16 bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `account_uuid_bytes` must not be mutated for the duration of the
 *   function call.
 * - Call [`zcashlc_free_single_use_address`] to free the memory associated with the returned pointer
 *   when done using it.
 */
struct FfiSingleUseTaddr *zcashlc_get_single_use_taddr(const uint8_t *db_data,
                                                       uintptr_t db_data_len,
                                                       uint32_t network_id,
                                                       const uint8_t *account_uuid_bytes);

/**
 * Returns a newly-generated unified payment address for the specified account, with the next
 * available diversifier and the specified set of receivers.
 *
 * The set of receivers to include in the generated address is specified by a byte which may have
 * any of the following bits set:
 * * P2PKH = 0b00000001
 * * SAPLING = 0b00000100
 * * ORCHARD = 0b00001000
 *
 * For each bit set, a corresponding receiver will be required to be generated. If no
 * corresponding viewing key exists in the wallet for a required receiver, this will return an
 * error. At present, p2pkh-only unified addresses are not supported.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `account_uuid_bytes` must be non-null and valid for reads for 16 bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `account_uuid_bytes` must not be mutated for the duration of the
 *   function call.
 * - Call [`zcashlc_string_free`] to free the memory associated with the returned pointer
 *   when done using it.
 */
char *zcashlc_get_next_available_address(const uint8_t *db_data,
                                         uintptr_t db_data_len,
                                         const uint8_t *account_uuid_bytes,
                                         uint32_t network_id,
                                         uint32_t receiver_flags);

/**
 * Returns a list of the transparent addresses that have been allocated for the provided account,
 * including potentially-unrevealed public-scope and private-scope (change) addresses within the
 * gap limit, which is currently set to 10 for public-scope addresses and 5 for change addresses.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `account_uuid_bytes` must be non-null and valid for reads for 16 bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `account_uuid_bytes` must not be mutated for the duration of the
 *   function call.
 * - Call [`zcashlc_free_keys`] to free the memory associated with the returned pointer
 *   when done using it.
 */
struct FFIEncodedKeys *zcashlc_list_transparent_receivers(const uint8_t *db_data,
                                                          uintptr_t db_data_len,
                                                          const uint8_t *account_uuid_bytes,
                                                          uint32_t network_id);

/**
 * Returns the verified transparent balance for `address`, which ignores utxos that have been
 * received too recently and are not yet deemed spendable according to `confirmations_policy`.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `address` must be non-null and must point to a null-terminated UTF-8 string.
 * - The memory referenced by `address` must not be mutated for the duration of the function call.
 */
int64_t zcashlc_get_verified_transparent_balance(const uint8_t *db_data,
                                                 uintptr_t db_data_len,
                                                 const char *address,
                                                 uint32_t network_id,
                                                 struct ConfirmationsPolicy confirmations_policy);

/**
 * Returns the verified transparent balance for `account`, which ignores utxos that have been
 * received too recently and are not yet deemed spendable according to `confirmations_policy`.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `account_uuid_bytes` must be non-null and valid for reads for 16 bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `account_uuid_bytes` must not be mutated for the duration of the
 *   function call.
 */
int64_t zcashlc_get_verified_transparent_balance_for_account(const uint8_t *db_data,
                                                             uintptr_t db_data_len,
                                                             uint32_t network_id,
                                                             const uint8_t *account_uuid_bytes,
                                                             struct ConfirmationsPolicy confirmations_policy);

/**
 * Returns the balance for `address`, including all UTXOs that we know about.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `address` must be non-null and must point to a null-terminated UTF-8 string.
 * - The memory referenced by `address` must not be mutated for the duration of the function call.
 */
int64_t zcashlc_get_total_transparent_balance(const uint8_t *db_data,
                                              uintptr_t db_data_len,
                                              const char *address,
                                              uint32_t network_id);

/**
 * Returns the balance for `account`, including all UTXOs that we know about.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `account_uuid_bytes` must be non-null and valid for reads for 16 bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `account_uuid_bytes` must not be mutated for the duration of the
 *   function call.
 */
int64_t zcashlc_get_total_transparent_balance_for_account(const uint8_t *db_data,
                                                          uintptr_t db_data_len,
                                                          uint32_t network_id,
                                                          const uint8_t *account_uuid_bytes);

/**
 * Returns the memo for a note by copying the corresponding bytes to the received
 * pointer in `memo_bytes_ret`.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `txid_bytes` must be non-null and valid for reads for 32 bytes, and it must have an alignment
 *   of `1`.
 * - `memo_bytes_ret` must be non-null and must point to an allocated 512-byte region of memory.
 */
bool zcashlc_get_memo(const uint8_t *db_data,
                      uintptr_t db_data_len,
                      const uint8_t *txid_bytes,
                      uint32_t output_pool,
                      uint16_t output_index,
                      uint8_t *memo_bytes_ret,
                      uint32_t network_id);

/**
 * Returns a ZIP-32 signature of the given seed bytes.
 *
 * # Safety
 * - `seed` must be non-null and valid for reads for `seed_len` bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `seed` must not be mutated for the duration of the function call.
 * - The total size `seed_len` must be at least 32 no larger than `252`. See the safety documentation
 *   of pointer::offset.
 */
bool zcashlc_seed_fingerprint(const uint8_t *seed,
                              uintptr_t seed_len,
                              uint8_t *signature_bytes_ret);

/**
 * Rewinds the data database to at most the given height.
 *
 * If the requested height is greater than or equal to the height of the last scanned block, this
 * function sets the `safe_rewind_ret` output parameter to `-1` and does nothing else.
 *
 * This procedure returns the height to which the database was actually rewound, or `-1` if no
 * rewind was performed.
 *
 * If the requested rewind could not be performed, but a rewind to a different (greater) height
 * would be valid, the `safe_rewind_ret` output parameter will be set to that value on completion;
 * otherwise, it will be set to `-1`.
 *
 * # Safety
 *
 * - `safe_rewind_ret` must be non-null, aligned, and valid for writing an `int64_t`.
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 */
int64_t zcashlc_rewind_to_height(const uint8_t *db_data,
                                 uintptr_t db_data_len,
                                 uint32_t height,
                                 uint32_t network_id,
                                 int64_t *safe_rewind_ret);

/**
 * Truncates the data database to the specified chain state.
 *
 * In contrast to [`zcashlc_rewind_to_height`], this function allows the caller to truncate the
 * wallet database to a precise height by providing additional chain state information needed for
 * note commitment tree maintenance after the truncation.
 *
 * The `chain_state` parameter is a protobuf-encoded `TreeState` value representing the chain
 * state at the height to which the database should be truncated.
 *
 * Returns `true` if the truncation succeeded, or `false` if an error occurred. When `false` is
 * returned, the caller should check for errors.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `chain_state` must be non-null and valid for reads for `chain_state_len` bytes, and it must
 *   have an alignment of `1`. Its contents must be a protobuf-encoded `TreeState` value.
 * - The memory referenced by `chain_state` must not be mutated for the duration of the function
 *   call.
 * - The total size `chain_state_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 */
bool zcashlc_truncate_to_chain_state(const uint8_t *db_data,
                                     uintptr_t db_data_len,
                                     const uint8_t *chain_state,
                                     uintptr_t chain_state_len,
                                     uint32_t network_id);

/**
 * Adds a sequence of Sapling subtree roots to the data store.
 *
 * Returns true if the subtrees could be stored, false otherwise. When false is returned,
 * caller should check for errors.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 * - `roots` must be non-null and initialized.
 * - The memory referenced by `roots` must not be mutated for the duration of the function call.
 */
bool zcashlc_put_sapling_subtree_roots(const uint8_t *db_data,
                                       uintptr_t db_data_len,
                                       uint64_t start_index,
                                       const struct FfiSubtreeRoots *roots,
                                       uint32_t network_id);

/**
 * Adds a sequence of Orchard subtree roots to the data store.
 *
 * Returns true if the subtrees could be stored, false otherwise. When false is returned,
 * caller should check for errors.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 * - `roots` must be non-null and initialized.
 * - The memory referenced by `roots` must not be mutated for the duration of the function call.
 */
bool zcashlc_put_orchard_subtree_roots(const uint8_t *db_data,
                                       uintptr_t db_data_len,
                                       uint64_t start_index,
                                       const struct FfiSubtreeRoots *roots,
                                       uint32_t network_id);

/**
 * Adds a sequence of Ironwood subtree roots to the data store.
 *
 * Ironwood is Orchard note-version V3 and shares Orchard's commitment-tree machinery, so the roots
 * are Orchard-shaped; they are tracked in a dedicated Ironwood commitment tree.
 *
 * Returns true if the subtrees could be stored, false otherwise. When false is returned,
 * caller should check for errors.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 * - `roots` must be non-null and initialized.
 * - The memory referenced by `roots` must not be mutated for the duration of the function call.
 */
bool zcashlc_put_ironwood_subtree_roots(const uint8_t *db_data,
                                        uintptr_t db_data_len,
                                        uint64_t start_index,
                                        const struct FfiSubtreeRoots *roots,
                                        uint32_t network_id);

/**
 * Updates the wallet's view of the blockchain.
 *
 * This method is used to provide the wallet with information about the state of the blockchain,
 * and detect any previously scanned data that needs to be re-validated before proceeding with
 * scanning. It should be called at wallet startup prior to calling `zcashlc_suggest_scan_ranges`
 * in order to provide the wallet with the information it needs to correctly prioritize scanning
 * operations.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 */
bool zcashlc_update_chain_tip(const uint8_t *db_data,
                              uintptr_t db_data_len,
                              int32_t height,
                              uint32_t network_id);

/**
 * Returns the height to which the wallet has been fully scanned.
 *
 * This is the height for which the wallet has fully trial-decrypted this and all
 * preceding blocks above the wallet's birthday height.
 *
 * Returns a non-negative block height, -1 if empty, or -2 if an error occurred.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 */
int64_t zcashlc_fully_scanned_height(const uint8_t *db_data,
                                     uintptr_t db_data_len,
                                     uint32_t network_id);

/**
 * Returns the maximum height that the wallet has scanned.
 *
 * If the wallet is fully synced, this will be equivalent to `zcashlc_block_fully_scanned`;
 * otherwise the maximal scanned height is likely to be greater than the fully scanned
 * height due to the fact that out-of-order scanning can leave gaps.
 *
 * Returns a non-negative block height, -1 if empty, or -2 if an error occurred.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 */
int64_t zcashlc_max_scanned_height(const uint8_t *db_data,
                                   uintptr_t db_data_len,
                                   uint32_t network_id);

/**
 * Returns the account balances and sync status given the specified minimum number of
 * confirmations.
 *
 * Returns `fully_scanned_height = -1` if the wallet has no balance data available.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must
 *   have an alignment of `1`. Its contents must be a string representing a valid system
 *   path in the operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the
 *   function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - Call [`zcashlc_free_wallet_summary`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiWalletSummary *zcashlc_get_wallet_summary(const uint8_t *db_data,
                                                    uintptr_t db_data_len,
                                                    uint32_t network_id,
                                                    struct ConfirmationsPolicy confirmations_policy);

/**
 * Returns a list of suggested scan ranges based upon the current wallet state.
 *
 * This method should only be used in cases where the `CompactBlock` data that will be
 * made available to `zcashlc_scan_blocks` for the requested block ranges includes note
 * commitment tree size information for each block; or else the scan is likely to fail if
 * notes belonging to the wallet are detected.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must
 *   have an alignment of `1`. Its contents must be a string representing a valid system
 *   path in the operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the
 *   function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - Call [`zcashlc_free_scan_ranges`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiScanRanges *zcashlc_suggest_scan_ranges(const uint8_t *db_data,
                                                  uintptr_t db_data_len,
                                                  uint32_t network_id);

/**
 * Scans new blocks added to the cache for any transactions received by the tracked
 * accounts, while checking that they form a valid chan.
 *
 * This function is built on the core assumption that the information provided in the
 * block cache is more likely to be accurate than the previously-scanned information.
 * This follows from the design (and trust) assumption that the `lightwalletd` server
 * provides accurate block information as of the time it was requested.
 *
 * This function **assumes** that the caller is handling rollbacks.
 *
 * For brand-new light client databases, this function starts scanning from the Sapling
 * activation height. This height can be fast-forwarded to a more recent block by calling
 * [`zcashlc_init_blocks_table`] before this function.
 *
 * Scanned blocks are required to be height-sequential. If a block is missing from the
 * cache, an error will be signalled.
 *
 * # Safety
 *
 * - `fs_block_db_root` must be non-null and valid for reads for `fs_block_db_root_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `fs_block_db_root` must not be mutated for the duration of the function call.
 * - The total size `fs_block_db_root_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 */
struct FfiScanSummary *zcashlc_scan_blocks(const uint8_t *fs_block_cache_root,
                                           uintptr_t fs_block_cache_root_len,
                                           const uint8_t *db_data,
                                           uintptr_t db_data_len,
                                           int32_t from_height,
                                           const uint8_t *from_state,
                                           uintptr_t from_state_len,
                                           uint32_t scan_limit,
                                           uint32_t network_id);

/**
 * Inserts a UTXO into the wallet database.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `txid_bytes` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `txid_bytes_len` must not be mutated for the duration of the function call.
 * - The total size `txid_bytes_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `script_bytes` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `script_bytes_len` must not be mutated for the duration of the function call.
 * - The total size `script_bytes_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 */
bool zcashlc_put_utxo(const uint8_t *db_data,
                      uintptr_t db_data_len,
                      const uint8_t *txid_bytes,
                      uintptr_t txid_bytes_len,
                      int32_t index,
                      const uint8_t *script_bytes,
                      uintptr_t script_bytes_len,
                      int64_t value,
                      int32_t height,
                      uint32_t network_id);

/**
 * # Safety
 * Initializes the `FsBlockDb` sqlite database. Does nothing if already created
 *
 * Returns true when successful, false otherwise. When false is returned caller
 * should check for errors.
 * - `fs_block_db_root` must be non-null and valid for reads for `fs_block_db_root_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `fs_block_db_root` must not be mutated for the duration of the function call.
 * - The total size `fs_block_db_root_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 */
bool zcashlc_init_block_metadata_db(const uint8_t *fs_block_db_root,
                                    uintptr_t fs_block_db_root_len);

/**
 * Writes the blocks provided in `blocks_meta` into the `BlockMeta` database
 *
 * Returns true if the `blocks_meta` could be stored into the `FsBlockDb`. False
 * otherwise.
 *
 * When false is returned caller should check for errors.
 *
 * # Safety
 *
 * - `fs_block_db_root` must be non-null and valid for reads for `fs_block_db_root_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `fs_block_db_root` must not be mutated for the duration of the function call.
 * - The total size `fs_block_db_root_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - Block metadata represented in `blocks_meta` must be non-null. Caller must guarantee that the
 *   memory reference by this pointer is not freed up, dereferenced or invalidated while this
 *   function is invoked.
 */
bool zcashlc_write_block_metadata(const uint8_t *fs_block_db_root,
                                  uintptr_t fs_block_db_root_len,
                                  struct FFIBlocksMeta *blocks_meta);

/**
 * Rewinds the data database to the given height.
 *
 * If the requested height is greater than or equal to the height of the last scanned
 * block, this function does nothing.
 *
 * # Safety
 *
 * - `fs_block_db_root` must be non-null and valid for reads for `fs_block_db_root_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `fs_block_db_root` must not be mutated for the duration of the function call.
 * - The total size `fs_block_db_root_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 */
bool zcashlc_rewind_fs_block_cache_to_height(const uint8_t *fs_block_db_root,
                                             uintptr_t fs_block_db_root_len,
                                             int32_t height);

/**
 * Get the latest cached block height in the filesystem block cache
 *
 * Returns a non-negative block height, -1 if empty, or -2 if an error occurred.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `tx` must be non-null and valid for reads for `tx_len` bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `tx` must not be mutated for the duration of the function call.
 * - The total size `tx_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 */
int32_t zcashlc_latest_cached_block_height(const uint8_t *fs_block_db_root,
                                           uintptr_t fs_block_db_root_len);

/**
 * Decrypts whatever parts of the specified transaction it can and stores them in db_data.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `tx` must be non-null and valid for reads for `tx_len` bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `tx` must not be mutated for the duration of the function call.
 * - The total size `tx_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `txid_ret` must be non-null and valid for writes of 32 bytes with an alignment of 1.
 *   On successful execution this will contain the txid of the decrypted transaction.
 */
int32_t zcashlc_decrypt_and_store_transaction(const uint8_t *db_data,
                                              uintptr_t db_data_len,
                                              const uint8_t *tx,
                                              uintptr_t tx_len,
                                              int64_t mined_height,
                                              uint32_t network_id,
                                              uint8_t *txid_ret);

/**
 * Select transaction inputs, compute fees, and construct a proposal for a transaction
 * that can then be authorized and made ready for submission to the network with
 * `zcashlc_create_proposed_transaction`.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `account_uuid_bytes` must be non-null and valid for reads for 16 bytes, and it must have an alignment
 *   of `1`.
 * - The memory referenced by `account_uuid_bytes` must not be mutated for the duration of the
 *   function call.
 * - `to` must be non-null and must point to a null-terminated UTF-8 string.
 * - `memo` must either be null (indicating an empty memo or a transparent recipient) or point to a
 *   512-byte array.
 * - Call [`zcashlc_free_boxed_slice`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiBoxedSlice *zcashlc_propose_transfer(const uint8_t *db_data,
                                               uintptr_t db_data_len,
                                               const uint8_t *account_uuid_bytes,
                                               const char *to,
                                               int64_t value,
                                               const uint8_t *memo,
                                               uint32_t network_id,
                                               struct ConfirmationsPolicy confirmations_policy);

/**
 * Selects all spendable transaction inputs, computes fees, and constructs a proposal for a transaction
 * that can then be authorized and made ready for submission to the network with
 * `zcashlc_create_proposed_transaction`.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `account_uuid_bytes` must be non-null and valid for reads for 16 bytes, and it must have an alignment
 *   of `1`.
 * - The memory referenced by `account_uuid_bytes` must not be mutated for the duration of the
 *   function call.
 * - `to` must be non-null and must point to a null-terminated UTF-8 string.
 * - `memo` must either be null (indicating an empty memo or a transparent recipient) or point to a
 *   512-byte array.
 * - `orchard_only`: when `true`, restricts the spendable pools to Orchard alone (the Orchard→
 *   Ironwood immediate migration lane's sweep, which must not draw on Sapling funds); when
 *   `false`, spends from both Sapling and Orchard (pre-existing behavior).
 * - Call [`zcashlc_free_boxed_slice`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiBoxedSlice *zcashlc_propose_send_max_transfer(const uint8_t *db_data,
                                                        uintptr_t db_data_len,
                                                        uint32_t network_id,
                                                        const uint8_t *account_uuid_bytes,
                                                        const char *to,
                                                        const uint8_t *memo,
                                                        enum FfiMaxSpendMode mode,
                                                        struct ConfirmationsPolicy confirmations_policy,
                                                        bool orchard_only);

/**
 * Select transaction inputs, compute fees, and construct a proposal for a transaction
 * from a ZIP-321 payment URI that can then be authorized and made ready for submission to the
 * network with `zcashlc_create_proposed_transaction`.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `account_uuid_bytes` must be non-null and valid for reads for 16 bytes, and it must have an alignment
 *   of `1`.
 * - The memory referenced by `account_uuid_bytes` must not be mutated for the duration of the
 *   function call.
 * - `payment_uri` must be non-null and must point to a null-terminated UTF-8 string.
 * - `network_id` a u32. 0 for Testnet and 1 for Mainnet
 * - `confirmations_policy` number of trusted/untrusted confirmations of the funds to spend
 * - `use_zip317_fees` `true` to use ZIP-317 fees.
 * - Call [`zcashlc_free_boxed_slice`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiBoxedSlice *zcashlc_propose_transfer_from_uri(const uint8_t *db_data,
                                                        uintptr_t db_data_len,
                                                        const uint8_t *account_uuid_bytes,
                                                        const char *payment_uri,
                                                        uint32_t network_id,
                                                        struct ConfirmationsPolicy confirmations_policy);

int32_t zcashlc_branch_id_for_height(int32_t height, uint32_t network_id);

/**
 * Frees strings returned by other zcashlc functions.
 *
 * # Safety
 *
 * - `s` should be a non-null pointer returned as a string by another zcashlc function.
 */
void zcashlc_string_free(char *s);

/**
 * Select transaction inputs, compute fees, and construct a proposal for a shielding
 * transaction that can then be authorized and made ready for submission to the network
 * with `zcashlc_create_proposed_transaction`. If there are no receivers (as selected
 * by `transparent_receiver`) for which at least `shielding_threshold` of value is
 * available to shield, fail with an error.
 *
 * # Parameters
 *
 * - db_data: A string represented as a sequence of UTF-8 bytes.
 * - db_data_len: The length of `db_data`, in bytes.
 * - account_uuid_bytes: a 16-byte array representing the UUID for an account
 * - memo: `null` to represent "no memo", or a pointer to an array containing exactly 512 bytes.
 * - shielding_threshold: the minimum value to be shielded for each receiver.
 * - transparent_receiver: `null` to represent "all receivers with shieldable funds", or a single
 *   transparent address for which to shield funds. WARNING: Note that calling this with `null`
 *   will leak the fact that all the addresses from which funds are drawn in the shielding
 *   transaction belong to the same wallet *ON CHAIN*. This immutably reveals the shared ownership
 *   of these addresses to all blockchain observers. If a caller wishes to avoid such linkability,
 *   they should not pass `null` for this parameter; however, note that temporal correlations can
 *   also heuristically be used to link addresses on-chain if funds from multiple addresses are
 *   individually shielded in transactions that may be temporally clustered. Keeping transparent
 *   activity private is very difficult; caveat emptor.
 * - network_id: The identifier for the network in use: 0 for testnet, 1 for mainnet.
 * - confirmations_policy: The minimum number of confirmations that are required for a UTXO to be considered
 *   for shielding.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `account_uuid_bytes` must be non-null and valid for reads for 16 bytes, and it must have an alignment
 *   of `1`.
 * - The memory referenced by `account_uuid_bytes` must not be mutated for the duration of the
 *   function call.
 * - `shielding_threshold` a non-negative shielding threshold amount in zatoshi
 * - Call [`zcashlc_free_boxed_slice`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiBoxedSlice *zcashlc_propose_shielding(const uint8_t *db_data,
                                                uintptr_t db_data_len,
                                                const uint8_t *account_uuid_bytes,
                                                const uint8_t *memo,
                                                uint64_t shielding_threshold,
                                                const char *transparent_receiver,
                                                uint32_t network_id,
                                                struct ConfirmationsPolicy confirmations_policy);

/**
 * Creates a transaction from the given proposal.
 *
 * Returns the row index of the newly-created transaction in the `transactions` table
 * within the data database. The caller can read the raw transaction bytes from the `raw`
 * column in order to broadcast the transaction to the network.
 *
 * Do not call this multiple times in parallel, or you will generate transactions that
 * double-spend the same notes.
 *
 * # Parameters
 * - `spend_params`: A pointer to a buffer containing the operating system path of the Sapling
 *   spend proving parameters, in the operating system's preferred path representation.
 * - `spend_params_len`: the length of the `spend_params` buffer.
 * - `output_params`: A pointer to a buffer containing the operating system path of the Sapling
 *   output proving parameters, in the operating system's preferred path representation.
 * - `output_params_len`: the length of the `output_params` buffer.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must
 *   have an alignment of `1`. Its contents must be a string representing a valid system
 *   path in the operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the
 *   function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 * - `proposal_ptr` must be non-null and valid for reads for `proposal_len` bytes, and it
 *   must have an alignment of `1`. Its contents must be an encoded Proposal protobuf.
 * - The memory referenced by `proposal_ptr` must not be mutated for the duration of the
 *   function call.
 * - The total size `proposal_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 * - `usk_ptr` must be non-null and must point to an array of `usk_len` bytes containing
 *   a unified spending key encoded as returned from the `zcashlc_create_account` or
 *   `zcashlc_derive_spending_key` functions.
 * - The memory referenced by `usk_ptr` must not be mutated for the duration of the
 *   function call.
 * - The total size `usk_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 * - `spend_params` must be non-null and valid for reads for `spend_params_len` bytes,
 *   and it must have an alignment of `1`.
 * - The memory referenced by `spend_params` must not be mutated for the duration of the
 *   function call.
 * - The total size `spend_params_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 * - `output_params` must be non-null and valid for reads for `output_params_len` bytes,
 *   and it must have an alignment of `1`.
 * - The memory referenced by `output_params` must not be mutated for the duration of the
 *   function call.
 * - The total size `output_params_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 */
FfiTxIds *zcashlc_create_proposed_transactions(const uint8_t *db_data,
                                               uintptr_t db_data_len,
                                               const uint8_t *proposal_ptr,
                                               uintptr_t proposal_len,
                                               const uint8_t *usk_ptr,
                                               uintptr_t usk_len,
                                               const uint8_t *spend_params,
                                               uintptr_t spend_params_len,
                                               const uint8_t *output_params,
                                               uintptr_t output_params_len,
                                               uint32_t network_id);

/**
 * Creates a partially-constructed (unsigned without proofs) transaction from the given proposal.
 *
 * Returns the partially constructed transaction in the `postcard` format generated by the `pczt`
 * crate.
 *
 * Do not call this multiple times in parallel, or you will generate pczt instances that, if
 * finalized, would double-spend the same notes.
 *
 * # Parameters
 * - `db_data`: A pointer to a buffer containing the operating system path of the wallet database,
 *   in the operating system's preferred path representation.
 * - `db_data_len`: The length of the `db_data` buffer.
 * - `proposal_ptr`: A pointer to a buffer containing an encoded `Proposal` protobuf.
 * - `proposal_len`: The length of the `proposal_ptr` buffer.
 * - `account_uuid_bytes`: A pointer to the 16-byte representaion of the account UUID.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 * - `proposal_ptr` must be non-null and valid for reads for `proposal_len` bytes, and it
 *   must have an alignment of `1`.
 * - The memory referenced by `proposal_ptr` must not be mutated for the duration of the
 *   function call.
 * - The total size `proposal_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 * - `account_uuid_bytes` must be non-null and valid for reads for 16 bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `account_uuid_bytes` must not be mutated for the duration of the
 *   function call.
 * - Call [`zcashlc_free_boxed_slice`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiBoxedSlice *zcashlc_create_pczt_from_proposal(const uint8_t *db_data,
                                                        uintptr_t db_data_len,
                                                        uint32_t network_id,
                                                        const uint8_t *proposal_ptr,
                                                        uintptr_t proposal_len,
                                                        const uint8_t *account_uuid_bytes);

/**
 * Redacts information from the given PCZT that is unnecessary for the Signer role.
 *
 * Applies the canonical Signer-role policy from
 * [`zcash_client_backend::data_api::wallet::redact_pczt_for_signer`], and additionally
 * omits Sapling spend witnesses. The caller must retain the unredacted PCZT and combine
 * the Signer output into it via [`zcashlc_extract_and_store_from_pczt`].
 *
 * Returns the updated PCZT in its serialized format.
 *
 * # Parameters
 * - `pczt_ptr`: A pointer to a byte array containing the encoded partially-constructed
 *   transaction to be redacted.
 * - `pczt_len`: The length of the `pczt_ptr` buffer.
 *
 * # Safety
 *
 * - `pczt_ptr` must be non-null and valid for reads for `pczt_len` bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `pczt_ptr` must not be mutated for the duration of the function
 *   call.
 * - The total size `pczt_len` must be no larger than `isize::MAX`. See the safety documentation
 *   of `pointer::offset`.
 * - Call [`zcashlc_free_boxed_slice`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiBoxedSlice *zcashlc_redact_pczt_for_signer(const uint8_t *pczt_ptr, uintptr_t pczt_len);

/**
 * Returns `true` if this PCZT requires Sapling proofs (and thus the caller needs to have
 * downloaded them). If the PCZT is invalid, `false` will be returned.
 *
 * # Parameters
 * - `pczt_ptr`: A pointer to a byte array containing the encoded partially-constructed
 *   transaction to be redacted.
 * - `pczt_len`: The length of the `pczt_ptr` buffer.
 *
 * # Safety
 *
 * - `pczt_ptr` must be non-null and valid for reads for `pczt_len` bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `pczt_ptr` must not be mutated for the duration of the function
 *   call.
 * - The total size `pczt_len` must be no larger than `isize::MAX`. See the safety documentation
 *   of `pointer::offset`.
 */
bool zcashlc_pczt_requires_sapling_proofs(const uint8_t *pczt_ptr, uintptr_t pczt_len);

/**
 * Adds proofs to the given PCZT.
 *
 * Returns the updated PCZT in its serialized format.
 *
 * # Parameters
 * - `pczt_ptr`: A pointer to a byte array containing the encoded partially-constructed
 *   transaction for which proofs will be computed.
 * - `pczt_len`: The length of the `pczt_ptr` buffer.
 * - `spend_params`: A pointer to a buffer containing the operating system path of the Sapling
 *   spend proving parameters, in the operating system's preferred path representation.
 * - `spend_params_len`: the length of the `spend_params` buffer.
 * - `output_params`: A pointer to a buffer containing the operating system path of the Sapling
 *   output proving parameters, in the operating system's preferred path representation.
 * - `output_params_len`: the length of the `output_params` buffer.
 *
 * # Safety
 *
 * - `pczt_ptr` must be non-null and valid for reads for `pczt_len` bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `pczt_ptr` must not be mutated for the duration of the function
 *   call.
 * - The total size `pczt_len` must be no larger than `isize::MAX`. See the safety documentation
 *   of `pointer::offset`.
 * - `spend_params` must be non-null and valid for reads for `spend_params_len` bytes, and it must
 *   have an alignment of `1`.
 * - The memory referenced by `spend_params` must not be mutated for the duration of the function
 *   call.
 * - The total size `spend_params_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 * - `output_params` must be non-null and valid for reads for `output_params_len` bytes, and it
 *   must have an alignment of `1`.
 * - The memory referenced by `output_params` must not be mutated for the duration of the function
 *   call.
 * - The total size `output_params_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - Call [`zcashlc_free_boxed_slice`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiBoxedSlice *zcashlc_add_proofs_to_pczt(const uint8_t *pczt_ptr,
                                                 uintptr_t pczt_len,
                                                 const uint8_t *spend_params,
                                                 uintptr_t spend_params_len,
                                                 const uint8_t *output_params,
                                                 uintptr_t output_params_len);

/**
 * Takes a PCZT that has been separately proven and signed, finalizes it, and stores it
 * in the wallet.
 *
 * Returns the txid of the completed transaction as a byte array.
 *
 * # Parameters
 * - `db_data`: A pointer to a buffer containing the operating system path of the wallet database,
 *   in the operating system's preferred path representation.
 * - `db_data_len`: The length of the `db_data` buffer.
 * - `pczt_with_proofs`: A pointer to a byte array containing the encoded partially-constructed
 *   transaction to which proofs have been added.
 * - `pczt_with_proofs_len`: The length of the `pczt_with_proofs` buffer.
 * - `pczt_with_sigs_ptr`: A pointer to a byte array containing the encoded partially-constructed
 *   transaction to which signatures have been added.
 * - `pczt_with_sigs_len`: The length of the `pczt_with_sigs` buffer.
 * - `spend_params`: A pointer to a buffer containing the operating system path of the Sapling
 *   spend proving parameters, in the operating system's preferred path representation.
 * - `spend_params_len`: the length of the `spend_params` buffer.
 * - `output_params`: A pointer to a buffer containing the operating system path of the Sapling
 *   output proving parameters, in the operating system's preferred path representation.
 * - `output_params_len`: the length of the `output_params` buffer.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 * - `pczt_with_proofs_ptr` must be non-null and valid for reads for `pczt_with_proofs_len` bytes,
 *   and it must have an alignment of `1`.
 * - The memory referenced by `pczt_with_proofs_ptr` must not be mutated for the duration of the
 *   function call.
 * - The total size `pczt_with_proofs_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 * - `pczt_with_sigs_ptr` must be non-null and valid for reads for `pczt_with_sigs_len` bytes, and
 *   it must have an alignment of `1`.
 * - The memory referenced by `pczt_with_sigs_ptr` must not be mutated for the duration of the
 *   function call.
 * - The total size `pczt_with_sigs_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 * - `spend_params` must either be null, or it must be valid for reads for `spend_params_len` bytes
 *   and have an alignment of `1`.
 * - The memory referenced by `spend_params` must not be mutated for the duration of the function
 *   call.
 * - The total size `spend_params_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 * - `output_params` must either be null, or it must be valid for reads for `output_params_len`
 *   bytes and have an alignment of `1`.
 * - The memory referenced by `output_params` must not be mutated for the duration of the function
 *   call.
 * - The total size `output_params_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - Call [`zcashlc_free_boxed_slice`] to free the memory associated with the returned pointer
 *   when done using it.
 */
struct FfiBoxedSlice *zcashlc_extract_and_store_from_pczt(const uint8_t *db_data,
                                                          uintptr_t db_data_len,
                                                          uint32_t network_id,
                                                          const uint8_t *pczt_with_proofs_ptr,
                                                          uintptr_t pczt_with_proofs_len,
                                                          const uint8_t *pczt_with_sigs_ptr,
                                                          uintptr_t pczt_with_sigs_len,
                                                          const uint8_t *spend_params,
                                                          uintptr_t spend_params_len,
                                                          const uint8_t *output_params,
                                                          uintptr_t output_params_len);

/**
 * Sets the transaction status to the provided value.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must
 *   have an alignment of `1`. Its contents must be a string representing a valid system
 *   path in the operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the
 *   function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - `txid_bytes` must be non-null and valid for reads for `db_data_len` bytes, and it must have
 *   an alignment of `1`.
 * - The memory referenced by `txid_bytes_len` must not be mutated for the duration of the
 *   function call.
 * - The total size `txid_bytes_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 */
void zcashlc_set_transaction_status(const uint8_t *db_data,
                                    uintptr_t db_data_len,
                                    uint32_t network_id,
                                    const uint8_t *txid_bytes,
                                    uintptr_t txid_bytes_len,
                                    struct FfiTransactionStatus status);

/**
 * Returns a list of transaction data requests that the network client should satisfy.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - Call [`zcashlc_free_transaction_data_requests`] to free the memory associated with the
 *   returned pointer when done using it.
 */
struct FfiTransactionDataRequests *zcashlc_transaction_data_requests(const uint8_t *db_data,
                                                                     uintptr_t db_data_len,
                                                                     uint32_t network_id);

/**
 * Detects notes with corrupt witnesses, and adds the block ranges corresponding to the corrupt
 * ranges to the scan queue so that the ordinary scanning process will re-scan these ranges to fix
 * the corruption in question.
 *
 * # Safety
 *
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 */
void zcashlc_fix_witnesses(const uint8_t *db_data, uintptr_t db_data_len, uint32_t network_id);

/**
 * Creates a Tor runtime.
 *
 * # Safety
 *
 * - `tor_dir` must be non-null and valid for reads for `tor_dir_len` bytes, and it must
 *   have an alignment of `1`. Its contents must be a string representing a valid system
 *   path in the operating system's preferred representation.
 * - The memory referenced by `tor_dir` must not be mutated for the duration of the
 *   function call.
 * - The total size `tor_dir_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - Call [`zcashlc_free_tor_runtime`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct TorRuntime *zcashlc_create_tor_runtime(const uint8_t *tor_dir, uintptr_t tor_dir_len);

/**
 * Frees a Tor runtime.
 *
 * # Safety
 *
 * - If `ptr` is non-null, it must be a pointer returned by a `zcashlc_*` method with
 *   return type `*mut TorRuntime` that has not previously been freed.
 */
void zcashlc_free_tor_runtime(struct TorRuntime *ptr);

/**
 * Returns a new isolated `TorRuntime` handle.
 *
 * The two `TorRuntime`s will share internal state and configuration, but their streams
 * will never share circuits with one another.
 *
 * Use this method when you want separate parts of your program to each have a
 * `TorRuntime` handle, but where you don't want their activities to be linkable to one
 * another over the Tor network.
 *
 * Calling this method is usually preferable to creating a completely separate
 * `TorRuntime` instance, since it can share its internals with the existing `TorRuntime`.
 *
 * # Safety
 *
 * - `tor_runtime` must be a non-null pointer returned by a `zcashlc_*` method with
 *   return type `*mut TorRuntime` that has not previously been freed.
 * - `tor_runtime` must not be passed to two FFI calls at the same time.
 * - Call [`zcashlc_free_tor_runtime`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct TorRuntime *zcashlc_tor_isolated_client(struct TorRuntime *tor_runtime);

/**
 * Changes the client's current dormant mode, putting background tasks to sleep or waking
 * them up as appropriate.
 *
 * This can be used to conserve CPU usage if you aren’t planning on using the client for
 * a while, especially on mobile platforms.
 *
 * See the [`ffi::TorDormantMode`] documentation for more details.
 *
 * # Safety
 *
 * - `tor_runtime` must be a non-null pointer returned by a `zcashlc_*` method with
 *   return type `*mut TorRuntime` that has not previously been freed.
 * - `tor_runtime` must not be passed to two FFI calls at the same time.
 */
bool zcashlc_tor_set_dormant(struct TorRuntime *tor_runtime, enum TorDormantMode mode);

/**
 * Makes an HTTP GET request over Tor.
 *
 * `retry_limit` is the maximum number of times that a failed request should be retried.
 * You can disable retries by setting this to 0.
 *
 * # Safety
 *
 * - `tor_runtime` must be a non-null pointer returned by a `zcashlc_*` method with
 *   return type `*mut TorRuntime` that has not previously been freed.
 * - `tor_runtime` must not be passed to two FFI calls at the same time.
 * - `url` must be non-null and must point to a null-terminated UTF-8 string.
 * - `headers` must be non-null and valid for reads for
 *   `headers_len * size_of::<ffi::HttpRequestHeader>()` bytes, and it must be properly
 *   aligned. This means in particular:
 *   - The entire memory range of this slice must be contained within a single allocated
 *     object! Slices can never span across multiple allocated objects.
 *   - `headers` must be non-null and aligned even for zero-length slices.
 * - `headers` must point to `headers_len` consecutive properly initialized values of
 *   type `ffi::HttpRequestHeader`.
 * - The memory referenced by `headers` must not be mutated for the duration of the function
 *   call.
 * - The total size `headers_len * size_of::<ffi::HttpRequestHeader>()` of the slice must
 *   be no larger than `isize::MAX`, and adding that size to `headers` must not "wrap
 *   around" the address space.  See the safety documentation of pointer::offset.
 * - Call [`zcashlc_free_http_response_bytes`] to free the memory associated with the
 *   returned pointer when done using it.
 */
struct FfiHttpResponseBytes *zcashlc_tor_http_get(struct TorRuntime *tor_runtime,
                                                  const char *url,
                                                  const struct FfiHttpRequestHeader *headers,
                                                  uintptr_t headers_len,
                                                  uint8_t retry_limit);

/**
 * Makes an HTTP POST request over Tor.
 *
 * `retry_limit` is the maximum number of times that a failed request should be retried.
 * You can disable retries by setting this to 0.
 *
 * # Safety
 *
 * - `tor_runtime` must be a non-null pointer returned by a `zcashlc_*` method with
 *   return type `*mut TorRuntime` that has not previously been freed.
 * - `tor_runtime` must not be passed to two FFI calls at the same time.
 * - `url` must be non-null and must point to a null-terminated UTF-8 string.
 * - `headers` must be non-null and valid for reads for
 *   `headers_len * size_of::<ffi::HttpRequestHeader>()` bytes, and it must be properly
 *   aligned. This means in particular:
 *   - The entire memory range of this slice must be contained within a single allocated
 *     object! Slices can never span across multiple allocated objects.
 *   - `headers` must be non-null and aligned even for zero-length slices.
 * - `headers` must point to `headers_len` consecutive properly initialized values of
 *   type `ffi::HttpRequestHeader`.
 * - The memory referenced by `headers` must not be mutated for the duration of the function
 *   call.
 * - The total size `headers_len * size_of::<ffi::HttpRequestHeader>()` of the slice must
 *   be no larger than `isize::MAX`, and adding that size to `headers` must not "wrap
 *   around" the address space.  See the safety documentation of pointer::offset.
 * - `body` must be non-null and valid for reads for `body_len` bytes, and it must have
 *   an alignment of `1`.
 * - The memory referenced by `body` must not be mutated for the duration of the function
 *   call.
 * - The total size `body_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - Call [`zcashlc_free_http_response_bytes`] to free the memory associated with the
 *   returned pointer when done using it.
 */
struct FfiHttpResponseBytes *zcashlc_tor_http_post(struct TorRuntime *tor_runtime,
                                                   const char *url,
                                                   const struct FfiHttpRequestHeader *headers,
                                                   uintptr_t headers_len,
                                                   const uint8_t *body,
                                                   uintptr_t body_len,
                                                   uint8_t retry_limit);

/**
 * Fetches the current ZEC-USD exchange rate over Tor.
 *
 * The result is a [`Decimal`] struct containing the fields necessary to construct an
 * [`NSDecimalNumber`](https://developer.apple.com/documentation/foundation/nsdecimalnumber/1416003-init).
 *
 * Returns a negative value on error.
 *
 * # Safety
 *
 * - `tor_runtime` must be a non-null pointer returned by a `zcashlc_*` method with
 *   return type `*mut TorRuntime` that has not previously been freed.
 * - `tor_runtime` must not be passed to two FFI calls at the same time.
 */
struct Decimal zcashlc_get_exchange_rate_usd(struct TorRuntime *tor_runtime);

/**
 * Fetches the current ZEC-USD exchange rate over Tor from the specified exchanges.
 *
 * The result is a [`Decimal`] struct containing the fields necessary to construct an
 * [`NSDecimalNumber`](https://developer.apple.com/documentation/foundation/nsdecimalnumber/1416003-init).
 *
 * Returns a negative value on error.
 *
 * # Safety
 *
 * - `tor_runtime` must be a non-null pointer returned by a `zcashlc_*` method with
 *   return type `*mut TorRuntime` that has not previously been freed.
 * - `tor_runtime` must not be passed to two FFI calls at the same time.
 * - `exchanges` must be non-null and valid for reads for
 *   `exchanges_len * size_of::<ffi::ZecUsdExchange>()` bytes, and it must be properly
 *   aligned. This means in particular:
 *   - The entire memory range of this slice must be contained within a single allocated
 *     object! Slices can never span across multiple allocated objects.
 *   - `exchanges` must be non-null and aligned even for zero-length slices.
 * - `exchanges` must point to `exchanges_len` consecutive properly initialized values of
 *   type `ffi::ZecUsdExchange`.
 * - The memory referenced by `exchanges` must not be mutated for the duration of the function
 *   call.
 * - The total size `exchanges_len * size_of::<ffi::ZecUsdExchange>()` of the slice must
 *   be no larger than `isize::MAX`, and adding that size to `exchanges` must not "wrap
 *   around" the address space.  See the safety documentation of `pointer::offset`.
 */
struct Decimal zcashlc_get_exchange_rate_usd_from(struct TorRuntime *tor_runtime,
                                                  enum FfiZecUsdExchange trusted_exchange,
                                                  const enum FfiZecUsdExchange *exchanges,
                                                  uintptr_t exchanges_len);

/**
 * Connects to the lightwalletd server at the given endpoint.
 *
 * Each connection returned by this method is isolated from any other Tor usage.
 *
 * # Safety
 *
 * - `tor_runtime` must be a non-null pointer returned by a `zcashlc_*` method with
 *   return type `*mut TorRuntime` that has not previously been freed.
 * - `tor_runtime` must not be passed to two FFI calls at the same time.
 * - `endpoint` must be non-null and must point to a null-terminated UTF-8 string.
 * - Call [`zcashlc_free_tor_lwd_conn`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct LwdConn *zcashlc_tor_connect_to_lightwalletd(struct TorRuntime *tor_runtime,
                                                    const char *endpoint);

/**
 * Frees a Tor lightwalletd connection.
 *
 * # Safety
 *
 * - If `ptr` is non-null, it must be a pointer returned by a `zcashlc_*` method with
 *   return type `*mut tor::LwdConn` that has not previously been freed.
 */
void zcashlc_free_tor_lwd_conn(struct LwdConn *ptr);

/**
 * Returns information about this lightwalletd instance and the blockchain.
 *
 * # Safety
 *
 * - `lwd_conn` must be a non-null pointer returned by a `zcashlc_*` method with
 *   return type `*mut tor::LwdConn` that has not previously been freed.
 * - `lwd_conn` must not be passed to two FFI calls at the same time.
 * - Call [`zcashlc_free_boxed_slice`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiBoxedSlice *zcashlc_tor_lwd_conn_get_info(struct LwdConn *lwd_conn);

/**
 * Fetches the height and hash of the block at the tip of the best chain.
 *
 * # Safety
 *
 * - `lwd_conn` must be a non-null pointer returned by a `zcashlc_*` method with
 *   return type `*mut tor::LwdConn` that has not previously been freed.
 * - `lwd_conn` must not be passed to two FFI calls at the same time.
 * - `height_ret` must be non-null and valid for writes for 4 bytes, and it must have an
 *   alignment of `1`.
 * - Call [`zcashlc_free_boxed_slice`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiBoxedSlice *zcashlc_tor_lwd_conn_latest_block(struct LwdConn *lwd_conn,
                                                        uint32_t *height_ret);

/**
 * Fetches the transaction with the given ID.
 *
 * # Safety
 *
 * - `lwd_conn` must be a non-null pointer returned by a `zcashlc_*` method with
 *   return type `*mut tor::LwdConn` that has not previously been freed.
 * - `lwd_conn` must not be passed to two FFI calls at the same time.
 * - `txid_bytes` must be non-null and valid for reads for 32 bytes, and it must have an
 *   alignment of `1`.
 * - `height_ret` must be non-null and valid for writes for 8 bytes, and it must have an
 *   alignment of `1`.
 * - Call [`zcashlc_free_boxed_slice`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiBoxedSlice *zcashlc_tor_lwd_conn_fetch_transaction(struct LwdConn *lwd_conn,
                                                             const uint8_t *txid_bytes,
                                                             uint64_t *height_ret);

/**
 * Submits a transaction to the Zcash network via the given lightwalletd connection.
 *
 * # Safety
 *
 * - `lwd_conn` must be a non-null pointer returned by a `zcashlc_*` method with
 *   return type `*mut tor::LwdConn` that has not previously been freed.
 * - `lwd_conn` must not be passed to two FFI calls at the same time.
 * - `tx` must be non-null and valid for reads for `tx_len` bytes, and it must have an
 *   alignment of `1`.
 * - The memory referenced by `tx` must not be mutated for the duration of the function call.
 * - The total size `tx_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 */
bool zcashlc_tor_lwd_conn_submit_transaction(struct LwdConn *lwd_conn,
                                             const uint8_t *tx,
                                             uintptr_t tx_len);

/**
 * Fetches the note commitment tree state corresponding to the given block height.
 *
 * # Safety
 *
 * - `lwd_conn` must be a non-null pointer returned by a `zcashlc_*` method with
 *   return type `*mut tor::LwdConn` that has not previously been freed.
 * - `lwd_conn` must not be passed to two FFI calls at the same time.
 * - Call [`zcashlc_free_boxed_slice`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiBoxedSlice *zcashlc_tor_lwd_conn_get_tree_state(struct LwdConn *lwd_conn,
                                                          uint32_t height);

/**
 * Finds all transactions associated with the given transparent address within the given block
 * range, and calls [`decrypt_and_store_transaction`] with each such transaction.
 *
 * The query to the light wallet server will cover the provided block range. The end height is
 * optional; to omit the end height for the query range use the sentinel value `-1`. If any other
 * value is specified, it must be in the range of a valid u32. Note that older versions of
 * `lightwalletd` will return an error if the end height is not specified.
 *
 * Returns an [`ffi::AddressCheckResult`] if successful, or a null pointer in the case of an
 * error.
 *
 * # Safety
 *
 * - `lwd_conn` must be a non-null pointer returned by a `zcashlc_*` method with
 *   return type `*mut tor::LwdConn` that has not previously been freed.
 * - `lwd_conn` must not be passed to two FFI calls at the same time.
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - Call [`zcashlc_free_address_check_result`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiAddressCheckResult *zcashlc_tor_lwd_conn_update_transparent_address_transactions(struct LwdConn *lwd_conn,
                                                                                           const uint8_t *db_data,
                                                                                           uintptr_t db_data_len,
                                                                                           uint32_t network_id,
                                                                                           const char *address,
                                                                                           uint32_t start,
                                                                                           int64_t end);

/**
 * Checks to find any UTXOs associated with the given transparent address.
 *
 * This check will cover the block range starting at the exposure height for that address, if
 * known, or otherwise at the birthday height of the specified account.
 *
 * Returns an [`ffi::AddressCheckResult`] if successful, or a null pointer in the case of an
 * error.
 *
 * # Safety
 *
 * - `lwd_conn` must be a non-null pointer returned by a `zcashlc_*` method with
 *   return type `*mut tor::LwdConn` that has not previously been freed.
 * - `lwd_conn` must not be passed to two FFI calls at the same time.
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - Call [`zcashlc_free_address_check_result`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiAddressCheckResult *zcashlc_tor_lwd_conn_fetch_utxos_by_address(struct LwdConn *lwd_conn,
                                                                          const uint8_t *db_data,
                                                                          uintptr_t db_data_len,
                                                                          uint32_t network_id,
                                                                          const uint8_t *account_uuid_bytes,
                                                                          const char *address);

/**
 * Checks to find any single-use ephemeral addresses exposed in the past day that have not yet
 * received funds, excluding any whose next check time is in the future. This will then choose the
 * address that is most overdue for checking, retrieve any UTXOs for that address over Tor, and
 * add them to the wallet database. If no such UTXOs are found, the check will be rescheduled
 * following an expoential-backoff-with-jitter algorithm.
 *
 * Returns an [`ffi::AddressCheckResult`] if successful, or a null pointer in the case of an
 * error.
 *
 * # Safety
 *
 * - `lwd_conn` must be a non-null pointer returned by a `zcashlc_*` method with
 *   return type `*mut tor::LwdConn` that has not previously been freed.
 * - `lwd_conn` must not be passed to two FFI calls at the same time.
 * - `db_data` must be non-null and valid for reads for `db_data_len` bytes, and it must have an
 *   alignment of `1`. Its contents must be a string representing a valid system path in the
 *   operating system's preferred representation.
 * - The memory referenced by `db_data` must not be mutated for the duration of the function call.
 * - The total size `db_data_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of pointer::offset.
 * - Call [`zcashlc_free_address_check_result`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiAddressCheckResult *zcashlc_tor_lwd_conn_check_single_use_taddr(struct LwdConn *lwd_conn,
                                                                          const uint8_t *db_data,
                                                                          uintptr_t db_data_len,
                                                                          uint32_t network_id,
                                                                          const uint8_t *account_uuid_bytes);

/**
 * Registers the **custom network** resolved for `network_id` [`NETWORK_ID_REGTEST`], which every
 * subsequent `zcashlc_*` call resolves through [`parse_network`]. `base_network_id` selects the base
 * identity — address encoding and `chainName` — as mainnet (1), testnet (0), or regtest (2); the
 * activation heights are custom regardless. Each height argument is a block height, or a negative value
 * meaning "not activated on this network"; set them to mirror the `nuparams` of the node /
 * `lightwalletd` being connected to. Idempotent; intended to be called once at init.
 *
 * Returns `true` on a fresh registration or an identical re-registration. Returns `false` on an
 * invalid `base_network_id`, a poisoned lock, or when a different configuration was already
 * registered. A conflicting registration does not replace the existing parameters: doing so would
 * silently change the consensus rules used by live wallets that share this process-global slot.
 */
bool zcashlc_set_custom_network(uint32_t base_network_id,
                                int64_t overwinter,
                                int64_t sapling,
                                int64_t blossom,
                                int64_t heartwood,
                                int64_t canopy,
                                int64_t nu5,
                                int64_t nu6,
                                int64_t nu6_1,
                                int64_t nu6_2,
                                int64_t nu6_3);

/**
 * Returns the network type and address kind for the given address string,
 * if the address is a valid Zcash address.
 *
 * Address kind codes are as follows:
 * * p2pkh: 0
 * * p2sh: 1
 * * sapling: 2
 * * unified: 3
 * * tex: 4
 *
 * # Safety
 *
 * - `address` must be non-null and must point to a null-terminated UTF-8 string.
 * - The memory referenced by `address` must not be mutated for the duration of the function call.
 */
bool zcashlc_get_address_metadata(const char *address,
                                  uint32_t *network_id_ret,
                                  uint32_t *addr_kind_ret);

/**
 * Extracts the typecodes of the receivers within the given Unified Address.
 *
 * Returns a pointer to a slice of typecodes. `len_ret` is set to the length of the
 * slice.
 *
 * See the following sections of ZIP 316 for details on how to interpret typecodes:
 * - [List of known typecodes](https://zips.z.cash/zip-0316#encoding-of-unified-addresses)
 * - [Adding new types](https://zips.z.cash/zip-0316#adding-new-types)
 * - [Metadata Items](https://zips.z.cash/zip-0316#metadata-items)
 *
 * # Safety
 *
 * - `ua` must be non-null and must point to a null-terminated UTF-8 string.
 * - The memory referenced by `ua` must not be mutated for the duration of the function call.
 * - Call [`zcashlc_free_typecodes`] to free the memory associated with the returned
 *   pointer when done using it.
 */
uint32_t *zcashlc_get_typecodes_for_unified_address_receivers(const char *ua, uintptr_t *len_ret);

/**
 * Frees a list of typecodes previously obtained from the FFI.
 *
 * # Safety
 *
 * - `data` and `len` must have been obtained from
 *   [`zcashlc_get_typecodes_for_unified_address_receivers`].
 */
void zcashlc_free_typecodes(uint32_t *data, uintptr_t len);

/**
 * Returns true when the provided key decodes to a valid Sapling extended spending key for the
 * specified network, false in any other case.
 *
 * # Safety
 *
 * - `extsk` must be non-null and must point to a null-terminated UTF-8 string.
 * - The memory referenced by `extsk` must not be mutated for the duration of the function call.
 */
bool zcashlc_is_valid_sapling_extended_spending_key(const char *extsk, uint32_t network_id);

/**
 * Returns true when the provided key decodes to a valid Sapling extended full viewing key for the
 * specified network, false in any other case.
 *
 * # Safety
 *
 * - `key` must be non-null and must point to a null-terminated UTF-8 string.
 * - The memory referenced by `key` must not be mutated for the duration of the function call.
 */
bool zcashlc_is_valid_viewing_key(const char *key, uint32_t network_id);

/**
 * Returns true when the provided key decodes to a valid unified full viewing key for the
 * specified network, false in any other case.
 *
 * # Safety
 *
 * - `ufvk` must be non-null and must point to a null-terminated UTF-8 string.
 * - The memory referenced by `ufvk` must not be mutated for the duration of the
 *   function call.
 */
bool zcashlc_is_valid_unified_full_viewing_key(const char *ufvk, uint32_t network_id);

/**
 * Returns true when the provided key encoding is a valid unified incoming viewing key for the
 * given network, false in any other case.
 *
 * # Safety
 *
 * - `uivk` must be non-null and must point to a null-terminated UTF-8 string.
 * - The memory referenced by `uivk` must not be mutated for the duration of the
 *   function call.
 */
bool zcashlc_is_valid_unified_incoming_viewing_key(const char *uivk, uint32_t network_id);

/**
 * Derives and returns a unified spending key from the given seed for the given account ID.
 *
 * Returns the binary encoding of the spending key. The caller should manage the memory of (and
 * store, if necessary) the returned spending key in a secure fashion.
 *
 * # Safety
 *
 * - `seed` must be non-null and valid for reads for `seed_len` bytes.
 * - The memory referenced by `seed` must not be mutated for the duration of the function call.
 * - The total size `seed_len` must be no larger than `isize::MAX`. See the safety documentation
 *   of `pointer::offset`.
 * - Call `zcashlc_free_binary_key` to free the memory associated with the returned pointer when
 *   you are finished using it.
 */
struct FfiBoxedSlice *zcashlc_derive_spending_key(const uint8_t *seed,
                                                  uintptr_t seed_len,
                                                  int32_t hd_account_index,
                                                  uint32_t network_id);

/**
 * Obtains the unified full viewing key for the given binary-encoded unified spending key
 * and returns the resulting encoded UFVK string. `usk_ptr` should point to an array of `usk_len`
 * bytes containing a unified spending key encoded as returned from the `zcashlc_create_account`
 * or `zcashlc_derive_spending_key` functions.
 *
 * # Safety
 *
 * - `usk_ptr` must be non-null and must point to an array of `usk_len` bytes.
 * - The memory referenced by `usk_ptr` must not be mutated for the duration of the function call.
 * - The total size `usk_len` must be no larger than `isize::MAX`. See the safety documentation
 *   of `pointer::offset`.
 * - Call [`zcashlc_string_free`] to free the memory associated with the returned pointer
 *   when you are done using it.
 */
char *zcashlc_spending_key_to_full_viewing_key(const uint8_t *usk_ptr,
                                               uintptr_t usk_len,
                                               uint32_t network_id);

/**
 * Derives a unified address address for the provided UFVK, along with the diversifier at which it
 * was derived; this may not be equal to the provided diversifier index if no valid Sapling
 * address could be derived at that index. If the `diversifier_index_bytes` parameter is null, the
 * default address for the UFVK is returned.
 *
 * # Safety
 *
 * - `ufvk` must be non-null and must point to a null-terminated UTF-8 string.
 * - `diversifier_index_bytes must either be null or be valid for reads for 11 bytes and have an
 *   alignment of `1`.
 * - Call [`zcashlc_free_ffi_address`] to free the memory associated with the returned pointer
 *   when done using it.
 */
struct FfiAddress *zcashlc_derive_address_from_ufvk(uint32_t network_id,
                                                    const char *ufvk,
                                                    const uint8_t *diversifier_index_bytes);

/**
 * Derives a unified address address for the provided UIVK, along with the diversifier at which it
 * was derived; this may not be equal to the provided diversifier index if no valid Sapling
 * address could be derived at that index. If the `diversifier_index_bytes` parameter is null, the
 * default address for the UIVK is returned.
 *
 * # Safety
 *
 * - `uivk` must be non-null and must point to a null-terminated UTF-8 string.
 * - `diversifier_index_bytes must either be null or be valid for reads for 11 bytes and have an
 *   alignment of `1`.
 * - Call [`zcashlc_string_free`] to free the memory associated with the returned pointer
 *   when done using it.
 */
struct FfiAddress *zcashlc_derive_address_from_uivk(uint32_t network_id,
                                                    const char *uivk,
                                                    const uint8_t *diversifier_index_bytes);

/**
 * Returns the transparent receiver within the given Unified Address, if any.
 *
 * # Safety
 *
 * - `ua` must be non-null and must point to a null-terminated UTF-8 string.
 * - The memory referenced by `ua` must not be mutated for the duration of the function call.
 * - Call [`zcashlc_string_free`] to free the memory associated with the returned pointer
 *   when done using it.
 */
char *zcashlc_get_transparent_receiver_for_unified_address(const char *ua);

/**
 * Returns the Sapling receiver within the given Unified Address, if any.
 *
 * # Safety
 *
 * - `ua` must be non-null and must point to a null-terminated UTF-8 string.
 * - The memory referenced by `ua` must not be mutated for the duration of the function call.
 * - Call [`zcashlc_string_free`] to free the memory associated with the returned pointer
 *   when done using it.
 */
char *zcashlc_get_sapling_receiver_for_unified_address(const char *ua);

/**
 * Constructs an ffi::AccountMetadataKey from its parts.
 *
 * # Safety
 *
 * - `sk` must be non-null and valid for reads for 32 bytes, and it must have an alignment of `1`.
 * - The memory referenced by `sk` must not be mutated for the duration of the function call.
 * - `chain_code` must be non-null and valid for reads for 32 bytes, and it must have an alignment
 *   of `1`.
 * - The memory referenced by `chain_code` must not be mutated for the duration of the function
 *   call.
 * - Call [`zcashlc_free_account_metadata_key`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiAccountMetadataKey *zcashlc_account_metadata_key_from_parts(const uint8_t *sk,
                                                                      const uint8_t *chain_code);

/**
 * Derives a ZIP 325 Account Metadata Key from the given seed.
 *
 * # Safety
 *
 * - `seed` must be non-null and valid for reads for `seed_len` bytes.
 * - The memory referenced by `seed` must not be mutated for the duration of the function call.
 * - The total size `seed_len` must be no larger than `isize::MAX`. See the safety documentation
 *   of `pointer::offset`.
 * - Call [`zcashlc_free_account_metadata_key`] to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiAccountMetadataKey *zcashlc_derive_account_metadata_key(const uint8_t *seed,
                                                                  uintptr_t seed_len,
                                                                  int32_t account,
                                                                  uint32_t network_id);

/**
 * Derives a metadata key for private use from a ZIP 325 Account Metadata Key.
 *
 * - `ufvk` is the external UFVK for which a metadata key is required, or `null` if the
 *   metadata key is "inherent" (for the same account as the Account Metadata Key).
 * - `private_use_subject` is a globally unique non-empty sequence of at most 252 bytes
 *   that identifies the desired private-use context.
 *
 * If `ufvk` is null, this function will return a single 32-byte metadata key.
 *
 * If `ufvk` is non-null, this function will return one metadata key for every FVK item
 * contained within the UFVK, in preference order. As UFVKs may in general change over
 * time (due to the inclusion of new higher-preference FVK items, or removal of older
 * deprecated FVK items), private usage of these keys should always follow preference
 * order:
 * - For encryption-like private usage, the first key in the array should always be
 *   used, and all other keys ignored.
 * - For decryption-like private usage, each key in the array should be tried in turn
 *   until metadata can be recovered, and then the metadata should be re-encrypted
 *   under the first key.
 *
 * # Safety
 *
 * - `account_metadata_key` must be non-null and must point to a struct having the layout
 *   of [`ffi::AccountMetadataKey`].
 * - The memory referenced by `account_metadata_key` must not be mutated for the duration
 *   of the function call.
 * - If `ufvk` is non-null, it must point to a null-terminated UTF-8 string.
 * - `private_use_subject` must be non-null and valid for reads for `private_use_subject_len`
 *   bytes.
 * - The memory referenced by `private_use_subject` must not be mutated for the duration
 *   of the function call.
 * - The total size `private_use_subject_len` must be no larger than `isize::MAX`. See
 *   the safety documentation of `pointer::offset`.
 * - Call `zcashlc_free_symmetric_keys` to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiSymmetricKeys *zcashlc_derive_private_use_metadata_key(const struct FfiAccountMetadataKey *account_metadata_key,
                                                                 const char *ufvk,
                                                                 const uint8_t *private_use_subject,
                                                                 uintptr_t private_use_subject_len,
                                                                 uint32_t network_id);

/**
 * Derives and returns a ZIP 32 Arbitrary Key from the given seed at the "wallet level", i.e.
 * directly from the seed with no ZIP 32 path applied.
 *
 * The resulting key will be the same across all networks (Zcash mainnet, Zcash testnet, OtherCoin
 * mainnet, and so on). You can think of it as a context-specific seed fingerprint that can be used
 * as (static) key material.
 *
 * `context_string` is a globally-unique non-empty sequence of at most 252 bytes that identifies
 * the desired context.
 *
 * # Safety
 *
 * - `context_string` must be non-null and valid for reads for `context_string_len` bytes.
 * - The memory referenced by `context_string` must not be mutated for the duration of the function
 *   call.
 * - The total size `context_string_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 * - `seed` must be non-null and valid for reads for `seed_len` bytes.
 * - The memory referenced by `seed` must not be mutated for the duration of the function call.
 * - The total size `seed_len` must be no larger than `isize::MAX`. See the safety documentation
 *   of `pointer::offset`.
 * - Call `zcashlc_free_boxed_slice` to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiBoxedSlice *zcashlc_derive_arbitrary_wallet_key(const uint8_t *context_string,
                                                          uintptr_t context_string_len,
                                                          const uint8_t *seed,
                                                          uintptr_t seed_len);

/**
 * Derives and returns a ZIP 32 Arbitrary Key from the given seed at the account level.
 *
 * `context_string` is a globally-unique non-empty sequence of at most 252 bytes that identifies
 * the desired context.
 *
 * # Safety
 *
 * - `context_string` must be non-null and valid for reads for `context_string_len` bytes.
 * - The memory referenced by `context_string` must not be mutated for the duration of the function
 *   call.
 * - The total size `context_string_len` must be no larger than `isize::MAX`. See the safety
 *   documentation of `pointer::offset`.
 * - `seed` must be non-null and valid for reads for `seed_len` bytes`.
 * - The memory referenced by `seed` must not be mutated for the duration of the function call.
 * - The total size `seed_len` must be no larger than `isize::MAX`. See the safety documentation
 *   of `pointer::offset`.
 * - Call `zcashlc_free_boxed_slice` to free the memory associated with the returned
 *   pointer when done using it.
 */
struct FfiBoxedSlice *zcashlc_derive_arbitrary_account_key(const uint8_t *context_string,
                                                           uintptr_t context_string_len,
                                                           const uint8_t *seed,
                                                           uintptr_t seed_len,
                                                           int32_t account,
                                                           uint32_t network_id);

/**
 * Parse an EIP-681 URI string into a [`Eip681TransactionRequest`].
 *
 * Returns a pointer to the parsed request on success, or null on failure.
 * On failure the error can be retrieved via `zcashlc_last_error_message`.
 *
 * The returned pointer must be freed with [`zcashlc_free_eip681_transaction_request`].
 *
 * # Safety
 *
 * - `input` must be a non-null pointer to a null-terminated UTF-8 string.
 */
struct FfiEip681TransactionRequest *zcashlc_eip681_parse_transaction_request(const char *input);

/**
 * Returns the type of the parsed EIP-681 transaction request.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a valid [`Eip681TransactionRequest`] as
 *   returned by [`zcashlc_eip681_parse_transaction_request`].
 */
enum FfiEip681TransactionRequestType zcashlc_eip681_transaction_request_type(const struct FfiEip681TransactionRequest *ptr);

/**
 * Extract the native transfer data from a parsed EIP-681 transaction request.
 *
 * Returns a pointer to an [`Eip681NativeRequest`] on success, or null if the parsed
 * request is not a native transfer.
 *
 * The returned pointer must be freed with [`zcashlc_free_eip681_native_request`].
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a valid [`Eip681TransactionRequest`] as
 *   returned by [`zcashlc_eip681_parse_transaction_request`].
 */
struct FfiEip681NativeRequest *zcashlc_eip681_transaction_request_as_native(const struct FfiEip681TransactionRequest *ptr);

/**
 * Extract the ERC-20 transfer data from a parsed EIP-681 transaction request.
 *
 * Returns a pointer to an [`Eip681Erc20Request`] on success, or null if the parsed
 * request is not an ERC-20 transfer.
 *
 * The returned pointer must be freed with [`zcashlc_free_eip681_erc20_request`].
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a valid [`Eip681TransactionRequest`] as
 *   returned by [`zcashlc_eip681_parse_transaction_request`].
 */
struct FfiEip681Erc20Request *zcashlc_eip681_transaction_request_as_erc20(const struct FfiEip681TransactionRequest *ptr);

/**
 * Serialize a parsed EIP-681 transaction request back to a URI string.
 *
 * Returns a heap-allocated null-terminated UTF-8 string, or null on failure.
 * The returned string must be freed with [`zcashlc_string_free`](crate::zcashlc_string_free).
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a valid [`Eip681TransactionRequest`] as
 *   returned by [`zcashlc_eip681_parse_transaction_request`].
 */
char *zcashlc_eip681_transaction_request_to_uri(const struct FfiEip681TransactionRequest *ptr);

/**
 * Construct an [`Eip681TransactionRequest`] for a native ETH/chain token transfer
 * from individual parts.
 *
 * Returns a pointer to the constructed request on success, or null on failure.
 * On failure the error can be retrieved via `zcashlc_last_error_message`.
 *
 * The returned pointer must be freed with [`zcashlc_free_eip681_transaction_request`].
 *
 * # Safety
 *
 * - `schema_prefix` must be a non-null pointer to a null-terminated UTF-8 string.
 * - `recipient` must be a non-null pointer to a null-terminated UTF-8 string.
 * - `value_hex`, `gas_limit_hex`, and `gas_price_hex` are either null (indicating the
 *   parameter should be omitted) or non-null pointers to null-terminated UTF-8 strings
 *   containing `0x`-prefixed hex-encoded `U256` values.
 * - If `has_chain_id` is false, `chain_id` is ignored.
 */
struct FfiEip681TransactionRequest *zcashlc_eip681_native_request_from_parts(const char *schema_prefix,
                                                                             bool has_pay,
                                                                             bool has_chain_id,
                                                                             uint64_t chain_id,
                                                                             const char *recipient,
                                                                             const char *value_hex,
                                                                             const char *gas_limit_hex,
                                                                             const char *gas_price_hex);

/**
 * Construct an [`Eip681TransactionRequest`] for an ERC-20 token transfer
 * from individual parts.
 *
 * Returns a pointer to the constructed request on success, or null on failure.
 * On failure the error can be retrieved via `zcashlc_last_error_message`.
 *
 * The returned pointer must be freed with [`zcashlc_free_eip681_transaction_request`].
 *
 * # Safety
 *
 * - `schema_prefix`, `token_contract_address`, `recipient_address`, and `value_hex` must
 *   be non-null pointers to null-terminated UTF-8 strings.
 * - `value_hex` must contain a `0x`-prefixed hex-encoded `U256` value.
 * - If `has_chain_id` is false, `chain_id` is ignored.
 */
struct FfiEip681TransactionRequest *zcashlc_eip681_erc20_request_from_parts(const char *schema_prefix,
                                                                            bool has_pay,
                                                                            bool has_chain_id,
                                                                            uint64_t chain_id,
                                                                            const char *token_contract_address,
                                                                            const char *recipient_address,
                                                                            const char *value_hex);

/**
 * Frees an [`Eip681TransactionRequest`] value.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct having the layout of
 *   [`Eip681TransactionRequest`] as returned by
 *   [`zcashlc_eip681_parse_transaction_request`].
 */
void zcashlc_free_eip681_transaction_request(struct FfiEip681TransactionRequest *ptr);

/**
 * Frees an [`Eip681NativeRequest`] value.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct having the layout of
 *   [`Eip681NativeRequest`] as returned by
 *   [`zcashlc_eip681_transaction_request_as_native`].
 */
void zcashlc_free_eip681_native_request(struct FfiEip681NativeRequest *ptr);

/**
 * Frees an [`Eip681Erc20Request`] value.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct having the layout of
 *   [`Eip681Erc20Request`] as returned by
 *   [`zcashlc_eip681_transaction_request_as_erc20`].
 */
void zcashlc_free_eip681_erc20_request(struct FfiEip681Erc20Request *ptr);

/**
 * Frees an [`Account`] value
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct having the layout of [`Account`].
 */
void zcashlc_free_account(struct FfiAccount *ptr);

/**
 * Frees a [`Uuid`] value
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct having the layout of [`Uuid`].
 */
void zcashlc_free_ffi_uuid(struct FfiUuid *ptr);

/**
 * Frees an array of [`Uuid`] values as allocated by `zcashlc_list_accounts`.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct having the layout of [`Accounts`].
 *   See the safety documentation of [`Accounts`].
 */
void zcashlc_free_accounts(struct FfiAccounts *ptr);

/**
 * Frees a [`BinaryKey`] value
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct having the layout of [`BinaryKey`].
 *   See the safety documentation of [`BinaryKey`].
 */
void zcashlc_free_binary_key(struct FFIBinaryKey *ptr);

/**
 * Frees an array of [`EncodedKey`] values as allocated by `zcashlc_list_transparent_receivers`.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct having the layout of [`EncodedKeys`].
 *   See the safety documentation of [`EncodedKeys`].
 */
void zcashlc_free_keys(struct FFIEncodedKeys *ptr);

/**
 * Frees an [`WalletSummary`] value.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct having the layout of [`WalletSummary`].
 *   See the safety documentation of [`WalletSummary`].
 */
void zcashlc_free_wallet_summary(struct FfiWalletSummary *ptr);

/**
 * Frees an array of [`ScanRange`] values as allocated by `zcashlc_suggest_scan_ranges`.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct having the layout of [`ScanRanges`].
 *   See the safety documentation of [`ScanRanges`].
 */
void zcashlc_free_scan_ranges(struct FfiScanRanges *ptr);

/**
 * Frees a [`ScanSummary`] value.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct having the layout of [`ScanSummary`].
 */
void zcashlc_free_scan_summary(struct FfiScanSummary *ptr);

/**
 * Frees a [`BoxedSlice`].
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct having the layout of
 *   [`BoxedSlice`]. See the safety documentation of [`BoxedSlice`].
 */
void zcashlc_free_boxed_slice(struct FfiBoxedSlice *ptr);

/**
 * Frees an array of `[u8; 32]` values.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct having the layout of
 *   [`SymmetricKeys`]. See the safety documentation of [`SymmetricKeys`].
 */
void zcashlc_free_symmetric_keys(struct FfiSymmetricKeys *ptr);

/**
 * Frees an array of `[u8; 32]` values as allocated by `zcashlc_create_proposed_transactions`.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct having the layout of [`TxIds`].
 *   See the safety documentation of [`TxIds`].
 */
void zcashlc_free_txids(FfiTxIds *ptr);

/**
 * Frees an array of [`TransactionDataRequest`] values as allocated by `zcashlc_transaction_data_requests`.
 *
 * # Safety
 *
 * - `ptr` if `ptr` is non-null it must point to a struct having the layout of [`TransactionDataRequests`].
 *   See the safety documentation of [`TransactionDataRequests`].
 */
void zcashlc_free_transaction_data_requests(struct FfiTransactionDataRequests *ptr);

/**
 * Frees an [`Address`] value
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct having the layout of [`Address`].
 */
void zcashlc_free_ffi_address(struct FfiAddress *ptr);

/**
 * Frees an AccountMetadataKey value
 *
 * # Safety
 *
 * - `ptr` must either be null or point to a struct having the layout of [`AccountMetadataKey`].
 */
void zcashlc_free_account_metadata_key(struct FfiAccountMetadataKey *ptr);

/**
 * Frees an HttpResponseBytes value
 *
 * # Safety
 *
 * - `ptr` must either be null or point to a struct having the layout of [`HttpResponseBytes`].
 */
void zcashlc_free_http_response_bytes(struct FfiHttpResponseBytes *ptr);

/**
 * Frees an [`SingleUseTaddr`] value.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct having the layout of [`SingleUseTaddr`].
 */
void zcashlc_free_single_use_taddr(struct FfiSingleUseTaddr *ptr);

/**
 * Frees an [`AddressCheckResult`] value.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct having the layout of [`AddressCheckResult`].
 */
void zcashlc_free_address_check_result(struct FfiAddressCheckResult *ptr);

/**
 * Returns one account's canonical-plus-delivery runtime from a single atomic wallet-store read.
 *
 * # Safety
 * Common database/account pointer rules apply. Free the returned DTO with
 * [`zcashlc_free_migration_runtime_snapshot_v1`].
 */
struct FfiMigrationRuntimeSnapshotV1 *zcashlc_migration_runtime_snapshot_v1(const uint8_t *db_data,
                                                                            uintptr_t db_data_len,
                                                                            const uint8_t *account_uuid_bytes,
                                                                            uint32_t network_id);

/**
 * Returns exactly one owning runtime per wallet account from one SQLite read transaction.
 *
 * # Safety
 * Common database-path pointer rules apply. Free the result with
 * [`zcashlc_free_migration_runtime_batch_v1`].
 */
struct FfiMigrationRuntimeBatchV1 *zcashlc_migration_runtime_batch_v1(const uint8_t *db_data,
                                                                      uintptr_t db_data_len,
                                                                      uint32_t network_id);

/**
 * Frees one owning runtime DTO and its sanitized claims/run handle.
 *
 * # Safety
 * `snapshot` must be null or one pointer returned by `zcashlc_migration_runtime_snapshot_v1`.
 */
void zcashlc_free_migration_runtime_snapshot_v1(struct FfiMigrationRuntimeSnapshotV1 *snapshot);

/**
 * Frees one atomic batch and every nested runtime allocation.
 *
 * # Safety
 * `batch` must be null or one pointer returned by `zcashlc_migration_runtime_batch_v1`.
 */
void zcashlc_free_migration_runtime_batch_v1(struct FfiMigrationRuntimeBatchV1 *batch);

/**
 * Returns a fresh owned clone of an immutable run capability.
 *
 * # Safety
 * `handle` must be null or a live pointer returned by this module.
 */
struct FfiMigrationRunHandle *zcashlc_migration_clone_run_handle_v1(const struct FfiMigrationRunHandle *handle);

/**
 * Frees one opaque run capability. Null is a no-op.
 *
 * # Safety
 * A non-null pointer must have been returned by this module and not already freed.
 */
void zcashlc_migration_free_run_handle_v1(struct FfiMigrationRunHandle *handle);

/**
 * Returns `-1` when the run has a validated bound policy; otherwise returns the stable typed
 * policy-validation-failure tag. Returns `-2` for an invalid handle.
 */
int32_t zcashlc_migration_run_policy_validation_failure_v1(const struct FfiMigrationRunHandle *handle);

/**
 * Returns the validated transport tag (`0` direct TLS, `1` Tor onion, `2` loopback development,
 * `3` public TLS over Tor), or `-1` when no policy is bound / the handle is invalid.
 */
int32_t zcashlc_migration_run_submission_transport_v1(const struct FfiMigrationRunHandle *handle);

/**
 * Copies the exact Rust-normalized submission endpoint, or returns an empty optional slice when
 * no validated policy is bound.
 */
struct FfiBoxedSlice *zcashlc_migration_run_submission_endpoint_v1(const struct FfiMigrationRunHandle *handle);

/**
 * Returns a fresh owned clone of an exact immutable claim capability.
 *
 * # Safety
 * `handle` must be null or a live pointer returned by this module.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_clone_claim_handle_v1(const struct FfiMigrationClaimHandle *handle);

/**
 * Frees one opaque claim capability. Null is a no-op.
 *
 * # Safety
 * A non-null pointer must have been returned by this module and not already freed.
 */
void zcashlc_migration_free_claim_handle_v1(struct FfiMigrationClaimHandle *handle);

/**
 * Returns a fresh owned run capability carrying the claim's latest revision.
 */
struct FfiMigrationRunHandle *zcashlc_migration_claim_run_handle_v1(const struct FfiMigrationClaimHandle *handle);

/**
 * Copies the post-commit canonical immediate wallet proposal, if this handle owns one.
 */
struct FfiBoxedSlice *zcashlc_migration_claim_proposal_v1(const struct FfiMigrationClaimHandle *handle);

/**
 * Copies exact PCZT bytes already staged before external exposure, if present.
 */
struct FfiBoxedSlice *zcashlc_migration_claim_external_signing_pczt_v1(const struct FfiMigrationClaimHandle *handle);

/**
 * Copies exact canonical merged signed-PCZT bytes, if present.
 */
struct FfiBoxedSlice *zcashlc_migration_claim_signed_pczt_v1(const struct FfiMigrationClaimHandle *handle);

/**
 * Copies exact network transaction bytes, if materialization is complete.
 */
struct FfiBoxedSlice *zcashlc_migration_claim_exact_transaction_v1(const struct FfiMigrationClaimHandle *handle);

/**
 * Copies the exact transaction id, if materialization is complete.
 */
struct FfiBoxedSlice *zcashlc_migration_claim_txid_v1(const struct FfiMigrationClaimHandle *handle);

/**
 * Returns the stable claim-status tag, or `-1` on error.
 */
int32_t zcashlc_migration_claim_status_v1(const struct FfiMigrationClaimHandle *handle);

/**
 * Returns the consensus expiry height, or `-1` on error.
 */
int64_t zcashlc_migration_claim_expiry_height_v1(const struct FfiMigrationClaimHandle *handle);

/**
 * Returns the consensus branch id sealed into the claim's canonical Rust evidence, or `-1` when
 * the handle or its evidence is invalid.
 *
 * Swift uses this typed projection only for selected-endpoint preflight. It never infers the
 * transaction branch from the expiry height (an upgrade can activate inside the expiry window),
 * and it never parses or accepts caller-authored proposal or transaction bytes. Scheduled claims
 * read the branch from their canonical PCZT; immediate claims read it from their sealed proposal.
 */
int64_t zcashlc_migration_claim_consensus_branch_id_v1(const struct FfiMigrationClaimHandle *handle);

/**
 * Validates and binds raw transport intent entirely in Rust. A typed validation failure is
 * persisted and returned as a fresh run handle with no bound policy; only storage/ABI errors
 * return null. The input capability is borrowed and remains caller-owned.
 *
 * # Safety
 * Common database/account pointer rules apply; `run_handle` must be a live borrowed handle and
 * `endpoint` must be a non-null UTF-8 C string.
 */
struct FfiMigrationRunHandle *zcashlc_migration_bind_submission_policy_v1(const uint8_t *db_data,
                                                                          uintptr_t db_data_len,
                                                                          const uint8_t *account_uuid_bytes,
                                                                          uint32_t network_id,
                                                                          const struct FfiMigrationRunHandle *run_handle_ptr,
                                                                          uint8_t transport_tag,
                                                                          const char *endpoint);

/**
 * Retained only as a disabled C ABI compatibility symbol.
 *
 * The original, unreleased-WIP v1 ABI did not accept a gross-amount authorization. It therefore
 * cannot safely reserve spend authority under the current migration contract. The signature must
 * remain stable for already-generated headers and binaries, but every invocation fails closed
 * before reading caller data or opening wallet state. New callers must use v2.
 *
 * # Safety
 * All arguments are ignored and no caller pointers are dereferenced. The function always returns
 * NULL and sets the last-error channel.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_reserve_immediate_v1(const uint8_t *db_data,
                                                                       uintptr_t db_data_len,
                                                                       const uint8_t *account_uuid_bytes,
                                                                       uint32_t network_id,
                                                                       uint8_t signer_tag,
                                                                       uint8_t transport_tag,
                                                                       const char *endpoint);

/**
 * Atomically derives and reserves an immediate Orchard-to-Ironwood proposal, binds its validated
 * submission policy, enforces the user-confirmed maximum gross amount against the exact selected
 * Orchard inputs, and acquires the initial bounded materialization claim. Proposal bytes are
 * unavailable to the host until this call commits successfully.
 *
 * # Safety
 * Common database/account pointer rules apply; `endpoint` must be a non-null UTF-8 C string.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_reserve_immediate_v2(const uint8_t *db_data,
                                                                       uintptr_t db_data_len,
                                                                       const uint8_t *account_uuid_bytes,
                                                                       uint32_t network_id,
                                                                       uint8_t signer_tag,
                                                                       int64_t maximum_gross_amount,
                                                                       uint8_t transport_tag,
                                                                       const char *endpoint);

/**
 * Acquires bounded materialization authority for one canonical scheduled transaction.
 *
 * A null return with no last error means no claim was eligible. Lease duration is selected by
 * Rust and never crosses the ABI.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_claim_materialization_v1(const uint8_t *db_data,
                                                                           uintptr_t db_data_len,
                                                                           const uint8_t *account_uuid_bytes,
                                                                           uint32_t network_id,
                                                                           const struct FfiMigrationRunHandle *run_handle_ptr,
                                                                           uint32_t transaction_id,
                                                                           uint8_t signer_tag);

/**
 * Builds and proves the exact PCZT sealed by an immediate external-signer claim, then stages it
 * durably before returning a handle that can expose those bytes to the signer.
 *
 * Swift supplies no proposal or PCZT. The proposal target, consensus branch, expiry, sources,
 * destination, amount, and fee all come from the post-reservation Rust evidence. The returned
 * handle is the first point at which external-signing bytes are accessible.
 *
 * # Safety
 * Common database/account pointer rules apply. `claim_handle_ptr` must be a live borrowed claim
 * handle.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_prepare_immediate_external_signing_v1(const uint8_t *db_data,
                                                                                        uintptr_t db_data_len,
                                                                                        const uint8_t *account_uuid_bytes,
                                                                                        uint32_t network_id,
                                                                                        const struct FfiMigrationClaimHandle *claim_handle_ptr);

/**
 * Stages exact PCZT bytes durably before an external signer can observe them.
 *
 * For scheduled migration artifacts, `pczt_ptr` must be null and `pczt_len` zero: Rust derives
 * the exact canonical unsigned PCZT from the claimed generation and persists it under the live
 * token before the returned handle can expose bytes. Immediate claims are rejected before the
 * pointer is read; they use [`zcashlc_migration_prepare_immediate_external_signing_v1`] so no
 * host-authored PCZT can cross the reservation boundary.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_stage_external_signing_pczt_v1(const uint8_t *db_data,
                                                                                 uintptr_t db_data_len,
                                                                                 const uint8_t *account_uuid_bytes,
                                                                                 uint32_t network_id,
                                                                                 const struct FfiMigrationClaimHandle *claim_handle_ptr,
                                                                                 const uint8_t *pczt_ptr,
                                                                                 uintptr_t pczt_len);

/**
 * Validates a signer response as the canonical merge of the exact staged PCZT, then stages that
 * merge durably. A late response never creates a replacement artifact.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_stage_signed_pczt_v1(const uint8_t *db_data,
                                                                       uintptr_t db_data_len,
                                                                       const uint8_t *account_uuid_bytes,
                                                                       uint32_t network_id,
                                                                       const struct FfiMigrationClaimHandle *claim_handle_ptr,
                                                                       const uint8_t *signer_pczt_ptr,
                                                                       uintptr_t signer_pczt_len);

/**
 * Finalizes the exact signed PCZT bound to an immediate external-signer claim, stores the
 * resulting wallet transaction, and stages exact delivery evidence in one SQLite transaction.
 *
 * The signer response must first pass [`zcashlc_migration_stage_signed_pczt_v1`], which persists
 * the canonical merge against the Rust-built PCZT. This call accepts no PCZT or transaction bytes
 * from Swift; it consumes only that opaque claim and exposes exact network bytes only through the
 * fresh post-commit handle.
 *
 * # Safety
 * Common database/account pointer rules apply. `claim_handle_ptr` must be a live borrowed claim
 * handle returned after staging a signer response.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_finalize_immediate_external_signing_v1(const uint8_t *db_data,
                                                                                         uintptr_t db_data_len,
                                                                                         const uint8_t *account_uuid_bytes,
                                                                                         uint32_t network_id,
                                                                                         const struct FfiMigrationClaimHandle *claim_handle_ptr);

/**
 * Applies the exact already-staged external signer merge to scheduled canonical state under the
 * same live materialization token. Swift supplies no successor state, revision, row identity, or
 * PCZT bytes; Rust derives the sole AwaitingSignature -> Signed successor from the opaque claim.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_advance_external_signature_v1(const uint8_t *db_data,
                                                                                uintptr_t db_data_len,
                                                                                const uint8_t *account_uuid_bytes,
                                                                                uint32_t network_id,
                                                                                const struct FfiMigrationClaimHandle *claim_handle_ptr);

/**
 * Proves one exact scheduled materialization claim with the wallet-owned prover, advances the
 * sole Signed -> Proved canonical successor under CAS, derives the exact network transaction, and
 * stages those bytes before returning them through the fresh claim handle. A restored Proved
 * claim resumes at exact-byte staging without reproving or replanning.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_prove_claim_v1(const uint8_t *db_data,
                                                                 uintptr_t db_data_len,
                                                                 const uint8_t *account_uuid_bytes,
                                                                 uint32_t network_id,
                                                                 const struct FfiMigrationClaimHandle *claim_handle_ptr);

/**
 * Materializes the exact proposal already sealed by an immediate SDK-signer claim, stores the
 * resulting wallet transaction, and stages its exact delivery evidence in one SQLite transaction.
 *
 * The host supplies no proposal, sources, destination, amount, expiry, transaction bytes, or
 * delivery identity. Rust reconstructs the post-reservation proposal from the opaque claim,
 * applies the claim's immutable expiry, builds exactly one transaction with the wallet key, and
 * asks the wallet store to validate the complete proposal/transaction binding before either the
 * wallet transaction or delivery state can commit. Exact bytes become visible only through the
 * fresh returned claim handle after that commit.
 *
 * # Safety
 * Common database/account pointer rules apply. `claim_handle_ptr` must be a live borrowed claim
 * handle. `usk_ptr`, `spend_params`, and `output_params` must be non-null and valid for reads of
 * their respective lengths for the duration of this call.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_materialize_immediate_sdk_v1(const uint8_t *db_data,
                                                                               uintptr_t db_data_len,
                                                                               const uint8_t *account_uuid_bytes,
                                                                               uint32_t network_id,
                                                                               const struct FfiMigrationClaimHandle *claim_handle_ptr,
                                                                               const uint8_t *usk_ptr,
                                                                               uintptr_t usk_len,
                                                                               const uint8_t *spend_params,
                                                                               uintptr_t spend_params_len,
                                                                               const uint8_t *output_params,
                                                                               uintptr_t output_params_len);

/**
 * Retired raw-byte staging ABI retained only for binary compatibility.
 *
 * Exact scheduled bytes are staged by [`zcashlc_migration_prove_claim_v1`], while exact immediate
 * bytes are built, stored, and staged atomically by
 * [`zcashlc_migration_materialize_immediate_sdk_v1`]. Accepting host-authored transaction bytes
 * here would reopen a post-reservation mutation seam, so every call fails before reading caller
 * memory or opening storage.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_stage_materialized_transaction_v1(const uint8_t *db_data,
                                                                                    uintptr_t db_data_len,
                                                                                    const uint8_t *account_uuid_bytes,
                                                                                    uint32_t network_id,
                                                                                    const struct FfiMigrationClaimHandle *claim_handle_ptr,
                                                                                    const uint8_t *transaction_ptr,
                                                                                    uintptr_t transaction_len);

/**
 * Acquires the one-shot bounded submission capability for exact staged bytes.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_claim_submission_v1(const uint8_t *db_data,
                                                                      uintptr_t db_data_len,
                                                                      const uint8_t *account_uuid_bytes,
                                                                      uint32_t network_id,
                                                                      const struct FfiMigrationClaimHandle *claim_handle_ptr);

/**
 * Acquires bounded resolution-only authority for an outcome-unknown artifact. The returned handle
 * cannot authorize resubmission.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_claim_outcome_resolution_v1(const uint8_t *db_data,
                                                                              uintptr_t db_data_len,
                                                                              const uint8_t *account_uuid_bytes,
                                                                              uint32_t network_id,
                                                                              const struct FfiMigrationClaimHandle *claim_handle_ptr);

/**
 * Resumes the same still-live Rust-generated claim. It never mints a replacement token.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_resume_claim_v1(const uint8_t *db_data,
                                                                  uintptr_t db_data_len,
                                                                  const uint8_t *account_uuid_bytes,
                                                                  uint32_t network_id,
                                                                  const struct FfiMigrationClaimHandle *claim_handle_ptr);

/**
 * Reacquires a fresh bounded materialization token for the same unexposed immediate artifact
 * after a known-unsent materialization failure. The persisted proposal must remain within the
 * caller's current explicit gross-amount authorization; this operation never replans.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_reacquire_failed_immediate_materialization_v1(const uint8_t *db_data,
                                                                                                uintptr_t db_data_len,
                                                                                                const uint8_t *account_uuid_bytes,
                                                                                                uint32_t network_id,
                                                                                                const struct FfiMigrationClaimHandle *claim_handle_ptr,
                                                                                                uint8_t signer_tag,
                                                                                                int64_t maximum_gross_amount);

/**
 * Reacquires a fresh bounded materialization token for the same externally staged artifact after
 * expiry/relaunch. Exact staged PCZT bytes, source reservations, and artifact identity are
 * retained; this operation never replans.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_reacquire_external_signing_v1(const uint8_t *db_data,
                                                                                uintptr_t db_data_len,
                                                                                const uint8_t *account_uuid_bytes,
                                                                                uint32_t network_id,
                                                                                const struct FfiMigrationClaimHandle *claim_handle_ptr);

/**
 * Renews a live claim using the bounded Rust-owned duration selected by its exact claim kind.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_renew_claim_v1(const uint8_t *db_data,
                                                                 uintptr_t db_data_len,
                                                                 const uint8_t *account_uuid_bytes,
                                                                 uint32_t network_id,
                                                                 const struct FfiMigrationClaimHandle *claim_handle_ptr);

/**
 * Records exactly one typed transport outcome under a live submission capability.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_record_submission_outcome_v1(const uint8_t *db_data,
                                                                               uintptr_t db_data_len,
                                                                               const uint8_t *account_uuid_bytes,
                                                                               uint32_t network_id,
                                                                               const struct FfiMigrationClaimHandle *claim_handle_ptr,
                                                                               uint8_t outcome_tag);

/**
 * Resolves chain evidence under an outcome-resolution claim without granting resubmission.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_reconcile_submission_v1(const uint8_t *db_data,
                                                                          uintptr_t db_data_len,
                                                                          const uint8_t *account_uuid_bytes,
                                                                          uint32_t network_id,
                                                                          const struct FfiMigrationClaimHandle *claim_handle_ptr);

/**
 * Atomically reconciles every scheduled canonical artifact against the store-owned fully scanned
 * active-chain view. No lifecycle, height, txid, or clock input crosses the ABI. A no-op still
 * returns a fresh equivalent owned handle; a committed reconciliation returns the next-revision
 * handle from the canonical-plus-delivery receipt.
 */
struct FfiMigrationRunHandle *zcashlc_migration_reconcile_canonical_chain_v1(const uint8_t *db_data,
                                                                             uintptr_t db_data_len,
                                                                             const uint8_t *account_uuid_bytes,
                                                                             uint32_t network_id,
                                                                             const struct FfiMigrationRunHandle *run_handle_ptr);

/**
 * Atomically replaces one positively expired scheduled transfer attempt inside its existing run.
 *
 * Rust derives the complete successor from the exact generation-safe claim, current canonical
 * state, wallet chain view, and a CSPRNG. The host chooses only the signer lane and, for the SDK
 * lane, supplies the account spending key. No schedule, height, revision, fingerprint, owner, or
 * token is accepted from the host. The store CAS archives the old attempt's durable fingerprint
 * and revision; its expired lease token is intentionally absent and is never reconstructed or
 * treated as generation authority. The returned handle owns the fresh replacement identity and
 * materialization token.
 *
 * # Safety
 * See [`open`]. `claim_handle_ptr` must be a live handle returned by this module. For signer tag
 * `0` (SDK), `usk_ptr` must be valid for `usk_len` bytes. For tag `1` (external), `usk_ptr` must be
 * null and `usk_len` zero. Free the returned handle with
 * [`zcashlc_migration_free_claim_handle_v1`].
 */
struct FfiMigrationClaimHandle *zcashlc_migration_rebuild_expired_transfer_v1(const uint8_t *db_data,
                                                                              uintptr_t db_data_len,
                                                                              const uint8_t *account_uuid_bytes,
                                                                              uint32_t network_id,
                                                                              const struct FfiMigrationClaimHandle *claim_handle_ptr,
                                                                              uint8_t signer_ownership_tag,
                                                                              const uint8_t *usk_ptr,
                                                                              uintptr_t usk_len);

/**
 * Releases a claim only for a Rust-validated known-unsent failure. Once exact external-signing
 * bytes have been staged, the artifact is cancellation-unsafe and this wrapper rejects release
 * before consulting storage; the same artifact must be resumed through its terminal resolution.
 */
struct FfiMigrationClaimHandle *zcashlc_migration_release_claim_known_unsent_v1(const uint8_t *db_data,
                                                                                uintptr_t db_data_len,
                                                                                const uint8_t *account_uuid_bytes,
                                                                                uint32_t network_id,
                                                                                const struct FfiMigrationClaimHandle *claim_handle_ptr,
                                                                                uint8_t failure_tag);

/**
 * Pauses delivery without releasing source reservations or exposed evidence.
 */
struct FfiMigrationRunHandle *zcashlc_migration_pause_delivery_v1(const uint8_t *db_data,
                                                                  uintptr_t db_data_len,
                                                                  const uint8_t *account_uuid_bytes,
                                                                  uint32_t network_id,
                                                                  const struct FfiMigrationRunHandle *run_handle_ptr);

/**
 * Resumes a paused delivery run.
 */
struct FfiMigrationRunHandle *zcashlc_migration_resume_delivery_v1(const uint8_t *db_data,
                                                                   uintptr_t db_data_len,
                                                                   const uint8_t *account_uuid_bytes,
                                                                   uint32_t network_id,
                                                                   const struct FfiMigrationRunHandle *run_handle_ptr);

/**
 * Begins abandonment while retaining every possibly exposed artifact and source reservation.
 */
struct FfiMigrationRunHandle *zcashlc_migration_begin_abandonment_v1(const uint8_t *db_data,
                                                                     uintptr_t db_data_len,
                                                                     const uint8_t *account_uuid_bytes,
                                                                     uint32_t network_id,
                                                                     const struct FfiMigrationRunHandle *run_handle_ptr);

/**
 * Finishes abandonment only after Rust proves every exposed artifact terminally safe.
 */
struct FfiMigrationRunHandle *zcashlc_migration_finish_abandonment_v1(const uint8_t *db_data,
                                                                      uintptr_t db_data_len,
                                                                      const uint8_t *account_uuid_bytes,
                                                                      uint32_t network_id,
                                                                      const struct FfiMigrationRunHandle *run_handle_ptr);

/**
 * Frees a [`FfiMigrationState`], including the attention transfer id if present.
 *
 * # Safety
 * `ptr` must be null or point to a [`FfiMigrationState`] handed out by this module.
 */
void zcashlc_free_migration_state(struct FfiMigrationState *ptr);

/**
 * Frees a [`FfiMigrationProgress`].
 *
 * # Safety
 * `ptr` must be null or point to a [`FfiMigrationProgress`] handed out by this module.
 */
void zcashlc_free_migration_progress(struct FfiMigrationProgress *ptr);

/**
 * Frees a [`FfiNoteSplitProposal`], including its output-values array.
 *
 * # Safety
 * `ptr` must be null or point to a [`FfiNoteSplitProposal`] handed out by this module.
 */
void zcashlc_free_migration_note_split_proposal(struct FfiNoteSplitProposal *ptr);

/**
 * Frees a [`FfiPreparedTransfer`], including its id string and PCZT bytes.
 *
 * # Safety
 * `ptr` must be null or point to a [`FfiPreparedTransfer`] handed out by this module.
 */
void zcashlc_free_migration_prepared_transfer(struct FfiPreparedTransfer *ptr);

/**
 * Frees a [`FfiMigrationSchedule`], including every transfer's id string.
 *
 * # Safety
 * `ptr` must be null or point to a [`FfiMigrationSchedule`] handed out by this module.
 */
void zcashlc_free_migration_schedule(struct FfiMigrationSchedule *ptr);

/**
 * Frees a standalone [`FfiTransferProposal`] (as returned by
 * `zcashlc_migration_pending_transfer_proposal`), including its id string.
 *
 * # Safety
 * `ptr` must be null or point to a [`FfiTransferProposal`] handed out by this module.
 */
void zcashlc_free_migration_transfer_proposal(struct FfiTransferProposal *ptr);

/**
 * Frees a [`FfiMigrationRunEstimate`], including its runs array.
 *
 * # Safety
 * `ptr` must be null or point to a [`FfiMigrationRunEstimate`] handed out by this module.
 */
void zcashlc_free_migration_run_estimate(struct FfiMigrationRunEstimate *ptr);

/**
 * Frees a [`FfiUnsignedTransferPczts`], including every element's id string and PCZT bytes.
 *
 * # Safety
 * `ptr` must be null or point to a [`FfiUnsignedTransferPczts`] handed out by this module.
 */
void zcashlc_free_migration_unsigned_transfer_pczts(struct FfiUnsignedTransferPczts *ptr);

/**
 * Frees a [`FfiMigrationTransactionStatuses`] container. Every row is a fixed-size value (the
 * `txid` is an inline `[u8; 32]`, not a heap pointer), so freeing the array itself is enough —
 * no per-row free callback, unlike [`zcashlc_free_migration_unsigned_transfer_pczts`].
 *
 * # Safety
 * `ptr` must be null or point to a [`FfiMigrationTransactionStatuses`] handed out by this
 * module.
 */
void zcashlc_free_migration_transaction_statuses(struct FfiMigrationTransactionStatuses *ptr);

/**
 * Frees a [`FfiKeystoneQrParts`], including every element string.
 *
 * # Safety
 * `ptr` must be null or point to a [`FfiKeystoneQrParts`] handed out by this module.
 */
void zcashlc_free_migration_keystone_qr_parts(struct FfiKeystoneQrParts *ptr);

/**
 * Frees a [`FfiKeystoneBatchDecodeResult`], including its data bytes.
 *
 * # Safety
 * `ptr` must be null or point to a [`FfiKeystoneBatchDecodeResult`] handed out by this module.
 */
void zcashlc_free_migration_keystone_batch_decode_result(struct FfiKeystoneBatchDecodeResult *ptr);

/**
 * The current migration-state projection. Canonical chain reconciliation is a separate typed CAS
 * requiring an opaque scheduled-run capability. `Complete` is PER-RUN (see the module doc).
 *
 * # Safety
 * See [`open`]. Free the returned pointer with [`zcashlc_free_migration_state`].
 */
struct FfiMigrationState *zcashlc_migration_state(const uint8_t *db_data,
                                                  uintptr_t db_data_len,
                                                  const uint8_t *account_uuid_bytes,
                                                  uint32_t network_id);

/**
 * Migration progress, present only while a migration run is in progress. On success the returned
 * pointer is non-null; its `is_present` flag is `false` when there is no progress to report. A
 * NULL return signals an error.
 *
 * # Safety
 * See [`open`]. Free the returned pointer with [`zcashlc_free_migration_progress`].
 */
struct FfiMigrationProgress *zcashlc_migration_progress(const uint8_t *db_data,
                                                        uintptr_t db_data_len,
                                                        const uint8_t *account_uuid_bytes,
                                                        uint32_t network_id);

/**
 * The LIVE status of every committed migration transaction, keyed by its stable id — a verbatim
 * marshal of `MigrationState::transaction_statuses(target)` at `target = tip + 1` (see
 * [`CallCtx::target`]), the engine's own per-transaction view a wallet renders progress from and
 * decides what to sign/prove/broadcast next. The read is side-effect free: callers must reconcile
 * canonical chain evidence first through the opaque-run delivery CAS. No stored run, or a stored
 * run with no transactions, returns an EMPTY container (`len == 0`) — not an error, the same
 * convention as [`encode_empty_schedule`].
 *
 * This is a pure read: it never claims an artifact or drives a prove-ready `Signed` row through
 * proving — a `Signed` row ready to prove is reported via `ready`/`action` (`action == 1`), not
 * silently advanced to `Proved`.
 *
 * # Safety
 * See [`open`]. Free the returned pointer with [`zcashlc_free_migration_transaction_statuses`].
 */
struct FfiMigrationTransactionStatuses *zcashlc_migration_transaction_statuses(const uint8_t *db_data,
                                                                               uintptr_t db_data_len,
                                                                               const uint8_t *account_uuid_bytes,
                                                                               uint32_t network_id);

/**
 * Whether the account's balance needs preparation (note-split) transactions before it can
 * migrate. Plans fresh against the live balance without changing any reviewed proposal's cache
 * handle. Returns `false` both
 * when no split is needed and when there is nothing to migrate at all; returns `false` on error
 * too (see `zcashlc_last_error_message` — the Swift layer disambiguates).
 *
 * # Safety
 * See [`open`].
 */
bool zcashlc_migration_is_note_split_needed(const uint8_t *db_data,
                                            uintptr_t db_data_len,
                                            const uint8_t *account_uuid_bytes,
                                            uint32_t network_id);

/**
 * Whether any transaction of the stored run is due-and-unbroadcast at the current tip — that
 * is, whether the delivery lane has actionable work: an already-`Proved` transaction due for
 * broadcast, or a due, dependency-satisfied, prove-ready `Signed` one the opaque claim lane can
 * drive through proving (proofs are assumed to succeed — a transiently unwitnessable anchor
 * defers the delivery, not this report; see [`due_assuming_proving`]). A row awaiting an EXTERNAL
 * signature is not delivery work (the signing ceremony advances it). Returns `false` on error
 * (see `zcashlc_last_error_message`).
 *
 * # Safety
 * See [`open`].
 */
bool zcashlc_migration_has_overdue_transfers(const uint8_t *db_data,
                                             uintptr_t db_data_len,
                                             const uint8_t *account_uuid_bytes,
                                             uint32_t network_id);

/**
 * Whether the stored canonical run has an expired, unmined transaction. Durable local and
 * transport failure classification belongs to the delivery-control runtime and is intentionally
 * not reconstructed by this compatibility query.
 *
 * # Safety
 * See [`open`].
 */
bool zcashlc_migration_has_invalid_transfers(const uint8_t *db_data,
                                             uintptr_t db_data_len,
                                             const uint8_t *account_uuid_bytes,
                                             uint32_t network_id);

/**
 * The note-split preview for the account's live balance: the preparation output values and the
 * preparation fees. Plans fresh (and caches the preview for the later commit). An empty proposal
 * (zero outputs) means there is nothing to migrate.
 *
 * # Safety
 * See [`open`]. Free the returned pointer with [`zcashlc_free_migration_note_split_proposal`].
 */
struct FfiNoteSplitProposal *zcashlc_migration_prepare_note_split(const uint8_t *db_data,
                                                                  uintptr_t db_data_len,
                                                                  const uint8_t *account_uuid_bytes,
                                                                  uint32_t network_id);

/**
 * Retained only as a disabled C ABI compatibility symbol. This entry point always fails closed
 * before reading caller data or opening wallet state because it cannot bind the returned
 * transaction to a Rust-owned delivery capability. Callers must use the current typed migration
 * scheduling and opaque delivery-v1 handle APIs.
 *
 * # Safety
 * All arguments are ignored and no caller pointers are dereferenced. The function always returns
 * NULL and sets the last-error channel.
 */
struct FfiPreparedTransfer *zcashlc_migration_sign_note_split(const uint8_t *db_data,
                                                              uintptr_t db_data_len,
                                                              const uint8_t *account_uuid_bytes,
                                                              uint32_t network_id,
                                                              const int64_t *output_values,
                                                              uintptr_t output_values_len,
                                                              int64_t fee,
                                                              const uint8_t *usk_ptr,
                                                              uintptr_t usk_len);

/**
 * The residual (zatoshi) that stays in Orchard after the migration: the note split's change,
 * below the migratable dust floor. Pre-commit this is read from a fresh preview; post-commit
 * from the stored run. Returns `-1` for "none" (and on error — see `zcashlc_last_error_message`;
 * the Swift layer disambiguates).
 *
 * # Safety
 * See [`open`].
 */
int64_t zcashlc_migration_residual_after_migration(const uint8_t *db_data,
                                                   uintptr_t db_data_len,
                                                   const uint8_t *account_uuid_bytes,
                                                   uint32_t network_id);

/**
 * After strict public migration `Complete`, locks EVERY currently-spendable,
 * not-already-locked legacy-Orchard note of the account until explicit unlock, and returns the
 * TOTAL LOCKED VALUE in zatoshi. `0` is a legitimate result (nothing was spendable, or everything
 * spendable is already locked); `-1` signals an error (see `zcashlc_last_error_message`).
 *
 * The strict-completion gate first reconciles reorgs and invokes the centralized exact-output
 * finalizer. This ensures the provisional migration owner is gone before the distinct residual
 * owner is acquired; an engine-only/provisional `Complete` is rejected. The lock expiry is
 * permanent (`u32::MAX`), so no chain height ever releases it — only an explicit
 * `zcashlc_migration_unlock_residual` does. Note selection excludes already-locked notes, so
 * repeating the call is idempotent-additive: it locks only notes that became spendable since
 * (and returns only their value). Locks are keyed to the deterministic per-account
 * [`residual_lock_owner`], so a retry re-locks under the same owner instead of conflicting with
 * itself. Selection and locking share one wallet transaction, so another database writer cannot
 * interleave between them; an already-conflicting foreign lock fails the whole transaction.
 *
 * # Safety
 * See [`open`].
 */
int64_t zcashlc_migration_lock_residual(const uint8_t *db_data,
                                        uintptr_t db_data_len,
                                        const uint8_t *account_uuid_bytes,
                                        uint32_t network_id);

/**
 * Unlocks only the exact active Orchard outputs held by this account's deterministic
 * [`residual_lock_owner`] — the release half of `zcashlc_migration_lock_residual` — and returns
 * the number of outputs unlocked (`0` when nothing was locked; `-1` signals an error, see
 * `zcashlc_last_error_message`). Migration locks, ordinary-PCZT locks, and every foreign owner
 * are deliberately preserved. The active-lock query and every exact owner-checked unlock share
 * one wallet transaction.
 *
 * # Safety
 * See [`open`].
 */
int64_t zcashlc_migration_unlock_residual(const uint8_t *db_data,
                                          uintptr_t db_data_len,
                                          const uint8_t *account_uuid_bytes,
                                          uint32_t network_id);

/**
 * Estimates how the account migrates its whole spendable balance: the number of migration RUNS
 * ("rounds") it takes, and for each run BOTH what it migrates (the note-split crossings) and
 * what preparing it costs (the note-preparation layers and transactions), so the platform can
 * preview and compare the two before anything is planned or committed. A balance beyond one
 * run's capacity migrates over several runs; the estimate depends on the wallet's NOTE
 * STRUCTURE, not just its total value (each run is decomposed with the real planners, and the
 * notes a run spends plus the residuals it leaves form the next run's structure).
 *
 * An external signer's per-session capacity is NOT part of the estimate: the SDK evaluates
 * signing sessions from the returned per-run transaction counts for any signer capacity,
 * without re-running the planners. A zero (or fully sub-quantum) balance yields the ZERO-RUN
 * estimate (`runs_len == 0`) — a legitimate result, not an error. NULL signals an error (see
 * `zcashlc_last_error_message`).
 *
 * # Safety
 * See [`open`]. Free the returned pointer with [`zcashlc_free_migration_run_estimate`].
 */
struct FfiMigrationRunEstimate *zcashlc_migration_estimate_runs(const uint8_t *db_data,
                                                                uintptr_t db_data_len,
                                                                const uint8_t *account_uuid_bytes,
                                                                uint32_t network_id);

/**
 * The migration schedule preview for the account's live balance, in chronological broadcast
 * order. Plans fresh (drawing new ZIP 318 randomness) and caches the preview — a later commit
 * signs exactly this plan. An EMPTY schedule means there is nothing to migrate: after a
 * completed run this is the "does anything remain" answer.
 *
 * # Safety
 * See [`open`]. Free the returned pointer with [`zcashlc_free_migration_schedule`].
 */
struct FfiMigrationSchedule *zcashlc_migration_propose_transfers(const uint8_t *db_data,
                                                                 uintptr_t db_data_len,
                                                                 const uint8_t *account_uuid_bytes,
                                                                 uint32_t network_id);

/**
 * Commits the previewed migration with the spending key if nothing is committed yet. A matching
 * non-terminal run resumes as a no-op; a terminal run must use the typed successor-rollover API.
 *
 * `proposal_handle` is the only proposal authority accepted from the caller. It identifies the
 * exact Rust-cached plan the user reviewed. A fresh commit fails with `MIGRATION_PLAN_STALE` when
 * the plan is missing or superseded; a durable resume does not consult the handle.
 *
 * # Safety
 * See [`open`]; `usk_ptr` must be valid for reads of `usk_len` bytes.
 */
bool zcashlc_migration_sign_and_store_schedule(const uint8_t *db_data,
                                               uintptr_t db_data_len,
                                               const uint8_t *account_uuid_bytes,
                                               uint32_t network_id,
                                               uint64_t proposal_handle,
                                               const uint8_t *usk_ptr,
                                               uintptr_t usk_len);

/**
 * Commits the reviewed schedule for external signing without exposing unsigned PCZT bytes.
 * `proposal_handle` is the only proposal authority accepted from the caller; Rust builds and
 * atomically locks the exact cached plan it identifies, initializes delivery, and returns only
 * an opaque run handle. A non-terminal durable run resumes without consulting the handle.
 *
 * # Safety
 * See [`open`].
 */
struct FfiMigrationRunHandle *zcashlc_migration_commit_external_schedule_v1(const uint8_t *db_data,
                                                                            uintptr_t db_data_len,
                                                                            const uint8_t *account_uuid_bytes,
                                                                            uint32_t network_id,
                                                                            uint64_t proposal_handle);

/**
 * Atomically replaces a terminal scheduled predecessor with a fresh SDK-signed successor.
 *
 * The host supplies only an opaque current predecessor capability, the opaque handle from the
 * most recent Rust preview, and the account spending key. Rust rebuilds the successor with
 * the unchanged upstream engine and generates every successor identity in the wallet-store CAS;
 * the predecessor archive and its source reservations remain retained.
 *
 * # Safety
 * See [`open`]. `predecessor_run_handle` must be a live borrowed handle, and `usk_ptr` must be
 * valid for `usk_len` bytes.
 * Free the returned handle with [`zcashlc_migration_free_run_handle_v1`].
 */
struct FfiMigrationRunHandle *zcashlc_migration_rollover_internal_schedule_v1(const uint8_t *db_data,
                                                                              uintptr_t db_data_len,
                                                                              const uint8_t *account_uuid_bytes,
                                                                              uint32_t network_id,
                                                                              const struct FfiMigrationRunHandle *predecessor_run_handle,
                                                                              uint64_t proposal_handle,
                                                                              const uint8_t *usk_ptr,
                                                                              uintptr_t usk_len);

/**
 * Atomically replaces a terminal scheduled predecessor with a fresh externally-signed successor.
 *
 * No spending key or caller-built successor crosses this ABI. Rust uses the account's stored
 * UFVK and the unchanged upstream unsigned builder, discards the unsigned output before return,
 * and exposes canonical PCZT bytes only after a later delivery claim atomically stages them.
 *
 * # Safety
 * See [`open`]. `predecessor_run_handle` must be a live borrowed handle. Free the returned handle
 * with [`zcashlc_migration_free_run_handle_v1`].
 */
struct FfiMigrationRunHandle *zcashlc_migration_rollover_external_schedule_v1(const uint8_t *db_data,
                                                                              uintptr_t db_data_len,
                                                                              const uint8_t *account_uuid_bytes,
                                                                              uint32_t network_id,
                                                                              const struct FfiMigrationRunHandle *predecessor_run_handle,
                                                                              uint64_t proposal_handle);

/**
 * Retained only as a disabled C ABI compatibility symbol. Standalone delivery cannot prove that
 * the caller owns the exact artifact, so this entry point always fails closed before reading
 * caller data or opening wallet state. Callers must use the opaque delivery-v1 claim APIs.
 *
 * # Safety
 * All arguments are ignored and no caller pointers are dereferenced. The function always returns
 * NULL and sets the last-error channel.
 */
struct FfiPreparedTransfer *zcashlc_migration_next_due_transfer(const uint8_t *db_data,
                                                                uintptr_t db_data_len,
                                                                const uint8_t *account_uuid_bytes,
                                                                uint32_t network_id);

/**
 * The next due-and-unbroadcast TRANSFER of the stored run as a proposal row (id, amount, its
 * scheduled and expiry heights), or NULL with no error when there is none. Distinguish the two
 * NULL meanings via `zcashlc_last_error_length`.
 *
 * "Due-and-unbroadcast" matches what the opaque delivery claim lane is being driven toward: an
 * already-`Proved` due transfer, or a due, prove-ready `Signed` one the delivery flow first proves
 * (see [`due_assuming_proving`] — this query itself never proves and assumes the later proof
 * succeeds). NULL when the next claimable transaction is a preparation, when due rows still
 * await an external signature, or when nothing is due.
 *
 * # Safety
 * See [`open`]. Free the returned pointer with [`zcashlc_free_migration_transfer_proposal`].
 */
struct FfiTransferProposal *zcashlc_migration_pending_transfer_proposal(const uint8_t *db_data,
                                                                        uintptr_t db_data_len,
                                                                        const uint8_t *account_uuid_bytes,
                                                                        uint32_t network_id);

/**
 * Retained only as a disabled C ABI compatibility symbol. This unscoped extraction entry point
 * predates delivery ownership and carries neither the exact source-reservation owner nor the
 * canonical wallet-lock owner required to authorize migration inputs, so it always fails closed.
 * Callers must use the token-bound materialization flow under the owning run and claim.
 *
 * # Safety
 * All arguments are ignored and no caller pointers are dereferenced. The function always returns
 * NULL and sets the last-error channel.
 */
struct FfiBoxedSlice *zcashlc_migration_extract_broadcast_tx(const uint8_t *_db_data,
                                                             uintptr_t _db_data_len,
                                                             const uint8_t *_account_uuid_bytes,
                                                             uint32_t _network_id,
                                                             const uint8_t *_pczt_ptr,
                                                             uintptr_t _pczt_len);

/**
 * Retained only as a disabled C ABI compatibility symbol. This unscoped callback cannot prove
 * ownership of the canonical artifact or delivery claim, so it always fails closed before
 * reading caller data or opening wallet state. Callers must record exact transport outcomes and
 * failures through the token-bound delivery-v1 API.
 *
 * # Safety
 * All arguments are ignored and no caller pointers are dereferenced. The function always returns
 * `false` and sets the last-error channel.
 */
bool zcashlc_migration_record_transfer_result(const uint8_t *db_data,
                                              uintptr_t db_data_len,
                                              const uint8_t *account_uuid_bytes,
                                              uint32_t network_id,
                                              const char *transfer_id,
                                              int32_t result_tag,
                                              const uint8_t *txid_bytes);

/**
 * Retained only as a disabled C ABI compatibility symbol. This entry point cannot safely release
 * delivery-owned source reservations, so it always fails closed before opening wallet state.
 * Callers must use [`zcashlc_migration_begin_abandonment_v1`] followed by
 * [`zcashlc_migration_finish_abandonment_v1`], re-propose, and commit through the appropriate
 * typed successor-rollover API.
 *
 * # Safety
 * All arguments are ignored and no caller pointers are dereferenced. The function always returns
 * NULL and sets the last-error channel.
 */
struct FfiMigrationSchedule *zcashlc_migration_restart_step(const uint8_t *db_data,
                                                            uintptr_t db_data_len,
                                                            const uint8_t *account_uuid_bytes,
                                                            uint32_t network_id);

/**
 * Retained only as a disabled C ABI compatibility symbol. This bulk, unscoped refresh entry point
 * cannot bind a rebuild to the exact current artifact and claim, so it always fails closed before
 * reading caller data or opening wallet state. Callers must use
 * [`zcashlc_migration_rebuild_expired_transfer_v1`] with the current opaque claim handle.
 *
 * # Safety
 * All arguments are ignored and no caller pointers are dereferenced. The function always returns
 * NULL and sets the last-error channel.
 */
struct FfiMigrationSchedule *zcashlc_migration_refresh_stale_transfers(const uint8_t *db_data,
                                                                       uintptr_t db_data_len,
                                                                       const uint8_t *account_uuid_bytes,
                                                                       uint32_t network_id,
                                                                       const uint8_t *usk_ptr,
                                                                       uintptr_t usk_len);

/**
 * Retained only as a disabled C ABI compatibility symbol. This entry point would expose unsigned
 * transactions without a Rust-owned delivery claim, so it always fails closed before opening
 * wallet state. Callers must commit an external schedule with
 * [`zcashlc_migration_commit_external_schedule_v1`] and expose canonical bytes only through the
 * typed external-signing claim flow.
 *
 * # Safety
 * All arguments are ignored and no caller pointers are dereferenced. The function always returns
 * NULL and sets the last-error channel.
 */
struct FfiUnsignedTransferPczts *zcashlc_migration_create_unsigned_note_split_pczts(const uint8_t *db_data,
                                                                                    uintptr_t db_data_len,
                                                                                    const uint8_t *account_uuid_bytes,
                                                                                    uint32_t network_id);

/**
 * Retained only as a disabled C ABI compatibility symbol. This entry point accepts signed bytes
 * without an owning Rust delivery claim, so it always fails closed before reading caller data or
 * opening wallet state. Callers must advance the exact staged external-signing claim with
 * [`zcashlc_migration_advance_external_signature_v1`].
 *
 * # Safety
 * All arguments are ignored and no caller pointers are dereferenced. The function always returns
 * NULL and sets the last-error channel.
 */
struct FfiPreparedTransfer *zcashlc_migration_store_signed_note_split_pczts(const uint8_t *db_data,
                                                                            uintptr_t db_data_len,
                                                                            const uint8_t *account_uuid_bytes,
                                                                            uint32_t network_id,
                                                                            const char *const *ids,
                                                                            uintptr_t ids_len,
                                                                            const uint8_t *const *pczts,
                                                                            const uintptr_t *pczt_lens);

/**
 * Retained only as a disabled C ABI compatibility symbol. This entry point would expose unsigned
 * transfer PCZTs without an owning Rust delivery claim, so it always fails closed before reading
 * caller data or opening wallet state. Callers must use the typed external-signing claim flow.
 * # Safety
 * All arguments are ignored and no caller pointers are dereferenced. The function always returns
 * NULL and sets the last-error channel.
 */
struct FfiUnsignedTransferPczts *zcashlc_migration_create_unsigned_transfer_pczts(const uint8_t *db_data,
                                                                                  uintptr_t db_data_len,
                                                                                  const uint8_t *account_uuid_bytes,
                                                                                  uint32_t network_id,
                                                                                  const char *const *ids,
                                                                                  uintptr_t ids_len,
                                                                                  const int64_t *amounts,
                                                                                  const int64_t *anchor_heights,
                                                                                  const int64_t *next_executable_after_heights,
                                                                                  const int64_t *expiry_heights,
                                                                                  uint32_t estimated_duration_hours);

/**
 * Retained only as a disabled C ABI compatibility symbol. This entry point accepts signed bytes
 * without an owning Rust delivery claim, so it always fails closed before reading caller data or
 * opening wallet state. Callers must advance the exact staged external-signing claim with
 * [`zcashlc_migration_advance_external_signature_v1`].
 *
 * # Safety
 * All arguments are ignored and no caller pointers are dereferenced. The function always returns
 * `false` and sets the last-error channel.
 */
bool zcashlc_migration_store_signed_schedule_pczts(const uint8_t *db_data,
                                                   uintptr_t db_data_len,
                                                   const uint8_t *account_uuid_bytes,
                                                   uint32_t network_id,
                                                   const char *const *ids,
                                                   uintptr_t ids_len,
                                                   const uint8_t *const *pczts,
                                                   const uintptr_t *pczt_lens);

/**
 * Builds the animated multi-part QR frames for a Keystone batch-signing request covering every
 * PCZT in `pczts`, in the given order (preparation PCZTs first, then transfer PCZTs — see
 * [`crate::migration_keystone`]'s module doc). `ids` is deliberately NOT a parameter: the build
 * step has no use for them — only [`zcashlc_migration_keystone_apply_batch_signatures`] echoes
 * ids back out, since that is what the caller matches signed PCZTs to stored transactions by.
 *
 * # Safety
 * `request_id` must be valid for reads of `request_id_len` bytes. `pczts`/`pczt_lens` must be
 * valid for reads of `pczts_len` elements, and each `pczts[i]` valid for `pczt_lens[i]` bytes.
 * Free the returned pointer with [`zcashlc_free_migration_keystone_qr_parts`].
 */
struct FfiKeystoneQrParts *zcashlc_migration_keystone_build_sign_batch_qr_parts(const uint8_t *request_id,
                                                                                uintptr_t request_id_len,
                                                                                const uint8_t *const *pczts,
                                                                                const uintptr_t *pczt_lens,
                                                                                uintptr_t pczts_len,
                                                                                uintptr_t max_fragment_len);

/**
 * Builds Keystone batch-signing QR frames for exact PCZTs owned by Zend's opaque delivery lane.
 *
 * This versioned wrapper preserves the upstream pure codec above, but accepts only current
 * scheduled external-signing claim capabilities — never caller-supplied PCZT bytes. It reloads
 * and validates each claim against the same live delivery snapshot and canonical migration state,
 * derives the account's ZIP 32 metadata inside Rust, and annotates only transient QR-input copies.
 * The durable staged PCZTs remain byte-for-byte canonical, and
 * [`zcashlc_migration_keystone_apply_batch_signatures`] applies the returned signatures to those
 * original bytes in the same order.
 *
 * # Safety
 * The database and account pointers follow [`open`]. `request_id` must be valid for reads of
 * `request_id_len` bytes. `claim_handles` must be valid for reads of `claim_handles_len` elements,
 * and each element must be a live borrowed handle returned by this module. Free the returned
 * pointer with [`zcashlc_free_migration_keystone_qr_parts`].
 */
struct FfiKeystoneQrParts *zcashlc_migration_keystone_build_sign_batch_qr_parts_v2(const uint8_t *db_data,
                                                                                   uintptr_t db_data_len,
                                                                                   const uint8_t *account_uuid_bytes,
                                                                                   uint32_t network_id,
                                                                                   const uint8_t *request_id,
                                                                                   uintptr_t request_id_len,
                                                                                   const struct FfiMigrationClaimHandle *const *claim_handles,
                                                                                   uintptr_t claim_handles_len,
                                                                                   uintptr_t max_fragment_len);

/**
 * Discards any in-flight multi-part Keystone sign-batch-response scan session. Callers should
 * invoke this on scan-screen entry so a new attempt always starts from a clean slate regardless
 * of how a previous attempt ended (cancel, back button, mid-stream error). Void and infallible.
 */
void zcashlc_migration_keystone_reset_sign_batch_decoder(void);

/**
 * Feeds one scanned QR frame into the active (or a freshly started) Keystone sign-batch-response
 * decode session, pinned to the `"zcash-batch-sig-result"` UR type. `expected_request_id` must
 * match the decoded response's own request id once complete, or this errors (a scan of an
 * unrelated/stale response) instead of silently accepting it. See
 * [`crate::migration_keystone::decode_sign_batch_part`].
 *
 * # Safety
 * `part` must be a valid, NUL-terminated C string. `expected_request_id` must be valid for reads
 * of `expected_request_id_len` bytes. Free the returned pointer with
 * [`zcashlc_free_migration_keystone_batch_decode_result`].
 */
struct FfiKeystoneBatchDecodeResult *zcashlc_migration_keystone_decode_sign_batch_part(const char *part,
                                                                                       const uint8_t *expected_request_id,
                                                                                       uintptr_t expected_request_id_len);

/**
 * Applies the ceremony's Keystone batch signatures to the caller-held unsigned PCZTs,
 * positionally (see [`crate::migration_keystone::apply_batch_signatures`]) — `ids`/`pczts` must
 * be the SAME PCZTs, in the SAME order, passed to
 * [`zcashlc_migration_keystone_build_sign_batch_qr_parts`]. `ids` pass through positionally onto
 * the returned signed PCZTs, reusing [`FfiUnsignedTransferPczts`] as a generic `(id, PCZT
 * bytes)` pair set (see its doc) and [`decode_signed_pairs`] to decode the parallel input
 * arrays.
 *
 * # Safety
 * See [`decode_signed_pairs`]. `response` must be valid for reads of `response_len` bytes. Free
 * the returned pointer with [`zcashlc_free_migration_unsigned_transfer_pczts`].
 */
struct FfiUnsignedTransferPczts *zcashlc_migration_keystone_apply_batch_signatures(const char *const *ids,
                                                                                   uintptr_t ids_len,
                                                                                   const uint8_t *const *pczts,
                                                                                   const uintptr_t *pczt_lens,
                                                                                   const uint8_t *response,
                                                                                   uintptr_t response_len);

/**
 * The Ironwood (NU6.3) activation height for a standard network, or `-1` when unset/unknown (and
 * on error — see `zcashlc_last_error_message`).
 */
int64_t zcashlc_ironwood_activation_height(uint32_t network_id);

/**
 * Open a voting database at the given path.
 *
 * Returns an opaque `*mut VotingDatabaseHandle` on success, or null on error.
 *
 * # Safety
 *
 * - For the `(path, path_len)` byte argument: if `path_len > 0` then `path` must be
 *   non-null and valid for reads for `path_len` bytes; if `path_len == 0`, `path` is
 *   ignored.
 * - Call `zcashlc_voting_db_free` to free the returned handle.
 */
struct VotingDatabaseHandle *zcashlc_voting_db_open(const uint8_t *path,
                                                    uintptr_t path_len,
                                                    uint32_t network_id);

/**
 * Free a `VotingDatabaseHandle`.
 *
 * # Safety
 *
 * - If `ptr` is non-null, it must be a pointer previously returned by
 *   `zcashlc_voting_db_open` that has not already been freed.
 * - Calling this twice on the same non-null pointer, or on any pointer not obtained
 *   from `zcashlc_voting_db_open`, is undefined behavior.
 */
void zcashlc_voting_db_free(struct VotingDatabaseHandle *ptr);

/**
 * Set the wallet identifier for all subsequent voting operations.
 * Must be called after `zcashlc_voting_db_open` and before any round operations.
 *
 * Returns 0 on success, -1 on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - For the `(wallet_id, wallet_id_len)` byte argument: if `wallet_id_len > 0` then
 *   `wallet_id` must be non-null and valid for reads for `wallet_id_len` bytes; if
 *   `wallet_id_len == 0`, `wallet_id` is ignored.
 */
int32_t zcashlc_voting_set_wallet_id(struct VotingDatabaseHandle *db,
                                     const uint8_t *wallet_id,
                                     uintptr_t wallet_id_len);

/**
 * Generate or reconstruct an app-owned voting hotkey.
 *
 * zcash_voting 1.0 uses app-owned hotkeys. Pass an empty `stored_secret` to
 * generate a fresh random hotkey, or a previously stored 64-byte secret to
 * deterministically reconstruct the same hotkey; any other length is an
 * error. The caller must persist `secret_key` (the stored secret) — it is
 * the only way to reconstruct the hotkey.
 *
 * Returns a pointer to `FfiVotingHotkey` on success, or null on error.
 * Call `zcashlc_voting_free_hotkey` to free the returned pointer.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 */
struct FfiVotingHotkey *zcashlc_voting_generate_hotkey(struct VotingDatabaseHandle *db,
                                                       const uint8_t *stored_secret,
                                                       uintptr_t stored_secret_len);

/**
 * Set up note bundles for a voting round.
 *
 * `notes_json` is a JSON-encoded `Vec<NoteInfo>`. Bundle packing follows the
 * crate-owned policy (denomination-aware thresholds), and re-running with the
 * same notes is idempotent.
 *
 * Returns a pointer to `FfiBundleSetupResult` on success, or null on error.
 * Call `zcashlc_voting_free_bundle_setup_result` to free the returned pointer.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 */
struct FfiBundleSetupResult *zcashlc_voting_setup_bundles(struct VotingDatabaseHandle *db,
                                                          const uint8_t *round_id,
                                                          uintptr_t round_id_len,
                                                          const uint8_t *notes_json,
                                                          uintptr_t notes_json_len);

/**
 * Get the number of bundles for a round.
 *
 * Returns the bundle count on success, or -1 on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 */
int64_t zcashlc_voting_get_bundle_count(struct VotingDatabaseHandle *db,
                                        const uint8_t *round_id,
                                        uintptr_t round_id_len);

/**
 * Build the governance PCZT for one delegation bundle.
 *
 * zcash_voting 1.0 selects snapshot-eligible notes and shapes key material
 * from the wallet database itself, so this takes the wallet DB path and
 * account UUID plus the app-owned hotkey stored secret.
 *
 * Returns JSON-encoded `JsonDelegationSetup` as `*mut FfiBoxedSlice`, or null on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - For every `(ptr, len)` byte argument, if `len > 0` then `ptr` must be
 *   non-null and valid for reads for `len` bytes; if `len == 0`, `ptr` is ignored.
 */
struct FfiBoxedSlice *zcashlc_voting_build_pczt(struct VotingDatabaseHandle *db,
                                                const uint8_t *round_id,
                                                uintptr_t round_id_len,
                                                uint32_t bundle_index,
                                                const uint8_t *wallet_db_data,
                                                uintptr_t wallet_db_data_len,
                                                const uint8_t *account_uuid,
                                                uintptr_t account_uuid_len,
                                                const uint8_t *hotkey_secret,
                                                uintptr_t hotkey_secret_len,
                                                const uint8_t *round_name,
                                                uintptr_t round_name_len);

/**
 * Store a tree state for witness generation.
 *
 * Returns 0 on success, -1 on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 */
int32_t zcashlc_voting_store_tree_state(struct VotingDatabaseHandle *db,
                                        const uint8_t *round_id,
                                        uintptr_t round_id_len,
                                        const uint8_t *tree_state_bytes,
                                        uintptr_t tree_state_bytes_len);

/**
 * Generate Merkle inclusion witnesses for the notes in a bundle and cache
 * them in the voting DB.
 *
 * `notes_json` is a JSON-encoded `Vec<NoteInfo>`.
 *
 * Returns JSON-encoded `Vec<WitnessData>` as `*mut FfiBoxedSlice`, or null on
 * error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - For every `(ptr, len)` byte argument (`round_id`, `wallet_db_path`,
 *   `notes_json`): if `len > 0` then `ptr` must be non-null and valid for
 *   reads for `len` bytes; if `len == 0`, `ptr` is ignored. An empty
 *   `notes_json` is treated as the empty notes list (JSON is not parsed),
 *   and produces an empty witness list.
 * - `network_id` must be `0` (testnet) or `1` (mainnet), matching other
 *   `zcashlc_*` FFI.
 */
struct FfiBoxedSlice *zcashlc_voting_generate_note_witnesses(struct VotingDatabaseHandle *db,
                                                             const uint8_t *round_id,
                                                             uintptr_t round_id_len,
                                                             uint32_t bundle_index,
                                                             const uint8_t *wallet_db_path,
                                                             uintptr_t wallet_db_path_len,
                                                             const uint8_t *notes_json,
                                                             uintptr_t notes_json_len,
                                                             uint32_t network_id);

/**
 * Precompute PIR-backed nullifier data for one delegation bundle.
 *
 * Witnesses must already be stored (generate_note_witnesses). Returns
 * JSON-encoded `JsonDelegationPirPrecomputeResult`, or null on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - For every `(ptr, len)` byte argument, if `len > 0` then `ptr` must be
 *   non-null and valid for reads for `len` bytes; if `len == 0`, `ptr` is ignored.
 */
struct FfiBoxedSlice *zcashlc_voting_precompute_delegation_pir(struct VotingDatabaseHandle *db,
                                                               const uint8_t *round_id,
                                                               uintptr_t round_id_len,
                                                               uint32_t bundle_index,
                                                               const uint8_t *notes_json,
                                                               uintptr_t notes_json_len,
                                                               const uint8_t *pir_server_url,
                                                               uintptr_t pir_server_url_len,
                                                               uint32_t network_id);

/**
 * Generate and persist the delegation proof for one bundle.
 *
 * Witnesses and PIR precompute data must already be present. zcash_voting
 * 1.0 shapes key material from the wallet database, so this takes the wallet
 * DB path, account UUID, and app-owned hotkey stored secret.
 *
 * Returns JSON-encoded `JsonDelegationProofResult`, or null on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - For every `(ptr, len)` byte argument, if `len > 0` then `ptr` must be
 *   non-null and valid for reads for `len` bytes; if `len == 0`, `ptr` is ignored.
 * - `progress_callback`/`progress_context` follow the same contract as
 *   `zcashlc_voting_build_vote_commitment`.
 */
struct FfiBoxedSlice *zcashlc_voting_build_and_prove_delegation(struct VotingDatabaseHandle *db,
                                                                const uint8_t *round_id,
                                                                uintptr_t round_id_len,
                                                                uint32_t bundle_index,
                                                                const uint8_t *wallet_db_data,
                                                                uintptr_t wallet_db_data_len,
                                                                const uint8_t *account_uuid,
                                                                uintptr_t account_uuid_len,
                                                                const uint8_t *hotkey_secret,
                                                                uintptr_t hotkey_secret_len,
                                                                const uint8_t *round_name,
                                                                uintptr_t round_name_len,
                                                                const uint8_t *pir_server_url,
                                                                uintptr_t pir_server_url_len,
                                                                void (*progress_callback)(double,
                                                                                          void*),
                                                                void *progress_context);

/**
 * Assemble chain-ready delegation submission fields, signing locally.
 *
 * The wallet seed never enters zcash_voting: the crate returns a signing
 * request (sighash + alpha + routing fingerprint), the SpendAuth signature is
 * produced here from the seed, and the signed submission is assembled from
 * stored proof state.
 *
 * Returns JSON-encoded `JsonDelegationSubmission`, or null on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - For every `(ptr, len)` byte argument, if `len > 0` then `ptr` must be
 *   non-null and valid for reads for `len` bytes; if `len == 0`, `ptr` is ignored.
 */
struct FfiBoxedSlice *zcashlc_voting_get_delegation_submission(struct VotingDatabaseHandle *db,
                                                               const uint8_t *round_id,
                                                               uintptr_t round_id_len,
                                                               uint32_t bundle_index,
                                                               const uint8_t *wallet_db_data,
                                                               uintptr_t wallet_db_data_len,
                                                               const uint8_t *account_uuid,
                                                               uintptr_t account_uuid_len,
                                                               const uint8_t *hotkey_secret,
                                                               uintptr_t hotkey_secret_len,
                                                               const uint8_t *round_name,
                                                               uintptr_t round_name_len,
                                                               const uint8_t *sender_seed,
                                                               uintptr_t sender_seed_len);

/**
 * Get the delegation submission payload using a Keystone-provided signature.
 *
 * Returns JSON-encoded `DelegationSubmission` as `*mut FfiBoxedSlice`, or null on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 */
struct FfiBoxedSlice *zcashlc_voting_get_delegation_submission_with_keystone_sig(struct VotingDatabaseHandle *db,
                                                                                 const uint8_t *round_id,
                                                                                 uintptr_t round_id_len,
                                                                                 uint32_t bundle_index,
                                                                                 const uint8_t *sig,
                                                                                 uintptr_t sig_len,
                                                                                 const uint8_t *sighash,
                                                                                 uintptr_t sighash_len);

/**
 * Store the VAN leaf position after delegation transaction confirmation.
 *
 * Returns 0 on success, -1 on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 */
int32_t zcashlc_voting_store_van_position(struct VotingDatabaseHandle *db,
                                          const uint8_t *round_id,
                                          uintptr_t round_id_len,
                                          uint32_t bundle_index,
                                          uint32_t position);

/**
 * Validate a PIR-fetched IMT non-membership proof bytewise.
 *
 * Inputs are the wire format of `zcash_voting::ImtProofData`: 32-byte LE
 * pallas::Base values for the root and the three nf_bounds, a u32 leaf
 * position, and 29 32-byte path siblings.
 *
 * Returns 1 if the proof is valid, 0 if it is well-formed but invalid, and -1
 * if inputs are malformed or a panic occurs.
 *
 * # Safety
 *
 * - `root`, `nullifier`, and `expected_root` must each point to exactly 32 bytes.
 * - `nf_bounds` must point to exactly 96 bytes (3 * 32).
 * - `path` must point to exactly 928 bytes (29 * 32).
 */
int32_t zcashlc_voting_validate_pir_proof(const uint8_t *root,
                                          const uint8_t *nf_bounds,
                                          uint32_t leaf_pos,
                                          const uint8_t *path,
                                          const uint8_t *nullifier,
                                          const uint8_t *expected_root);

/**
 * Free an `FfiRoundState` value.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct returned by
 *   `zcashlc_voting_get_round_state`.
 */
void zcashlc_voting_free_round_state(struct FfiRoundState *ptr);

/**
 * Free an `FfiVotingHotkey` value.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct returned by the voting FFI.
 */
void zcashlc_voting_free_hotkey(struct FfiVotingHotkey *ptr);

/**
 * Free an `FfiBundleSetupResult` value.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct returned by
 *   `zcashlc_voting_setup_bundles`.
 */
void zcashlc_voting_free_bundle_setup_result(struct FfiBundleSetupResult *ptr);

/**
 * Free an `FfiRoundSummaries` value.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct returned by
 *   `zcashlc_voting_list_rounds`.
 */
void zcashlc_voting_free_round_summaries(struct FfiRoundSummaries *ptr);

/**
 * Free an `FfiVoteRecords` value.
 *
 * # Safety
 *
 * - `ptr` must be non-null and must point to a struct returned by
 *   `zcashlc_voting_get_votes`.
 */
void zcashlc_voting_free_vote_records(struct FfiVoteRecords *ptr);

/**
 * Get wallet notes eligible for voting at the given snapshot height.
 *
 * Returns JSON-encoded `Vec<NoteInfo>` as `*mut FfiBoxedSlice`, or null on error.
 *
 * `account_uuid` must be a non-null pointer to exactly `ACCOUNT_UUID_BYTE_LEN` bytes
 * (binary account UUID).
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - `wallet_db_path` must be a valid path for reads of `wallet_db_path_len` bytes.
 * - When `account_uuid_len == ACCOUNT_UUID_BYTE_LEN`, `account_uuid` must be valid for
 *   reads of `ACCOUNT_UUID_BYTE_LEN` bytes.
 */
struct FfiBoxedSlice *zcashlc_voting_get_wallet_notes(struct VotingDatabaseHandle *db,
                                                      const uint8_t *wallet_db_path,
                                                      uintptr_t wallet_db_path_len,
                                                      uint64_t snapshot_height,
                                                      uint32_t network_id,
                                                      const uint8_t *account_uuid,
                                                      uintptr_t account_uuid_len);

/**
 * Persist the on-chain transaction hash of a submitted delegation bundle.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - `round_id` and `tx_hash` must be valid UTF-8 pointers with their stated lengths.
 */
int32_t zcashlc_voting_store_delegation_tx_hash(struct VotingDatabaseHandle *db,
                                                const uint8_t *round_id,
                                                uintptr_t round_id_len,
                                                uint32_t bundle_index,
                                                const uint8_t *tx_hash,
                                                uintptr_t tx_hash_len);

/**
 * Load a previously stored delegation transaction hash.
 *
 * Returns a JSON-encoded `Option<String>`.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - `round_id` must be a valid UTF-8 pointer with its stated length.
 */
struct FfiBoxedSlice *zcashlc_voting_get_delegation_tx_hash(struct VotingDatabaseHandle *db,
                                                            const uint8_t *round_id,
                                                            uintptr_t round_id_len,
                                                            uint32_t bundle_index);

/**
 * Persist the on-chain transaction hash of a submitted vote.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - `round_id` and `tx_hash` must be valid UTF-8 pointers with their stated lengths.
 */
int32_t zcashlc_voting_store_vote_tx_hash(struct VotingDatabaseHandle *db,
                                          const uint8_t *round_id,
                                          uintptr_t round_id_len,
                                          uint32_t bundle_index,
                                          uint32_t proposal_id,
                                          const uint8_t *tx_hash,
                                          uintptr_t tx_hash_len);

/**
 * Load a previously stored vote transaction hash.
 *
 * Returns a JSON-encoded `Option<String>`.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - `round_id` must be a valid UTF-8 pointer with its stated length.
 */
struct FfiBoxedSlice *zcashlc_voting_get_vote_tx_hash(struct VotingDatabaseHandle *db,
                                                      const uint8_t *round_id,
                                                      uintptr_t round_id_len,
                                                      uint32_t bundle_index,
                                                      uint32_t proposal_id);

/**
 * Persist a vote commitment bundle and vote-commitment-tree position.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - `round_id` and `bundle_json` must be valid UTF-8 pointers with their stated lengths.
 */
int32_t zcashlc_voting_store_commitment_bundle(struct VotingDatabaseHandle *db,
                                               const uint8_t *round_id,
                                               uintptr_t round_id_len,
                                               uint32_t bundle_index,
                                               uint32_t proposal_id,
                                               const uint8_t *bundle_json,
                                               uintptr_t bundle_json_len,
                                               uint64_t vc_tree_position);

/**
 * Load a stored commitment bundle and vote-commitment-tree position.
 *
 * Returns a JSON-encoded `Option<(String, u64)>`.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - `round_id` must be a valid UTF-8 pointer with its stated length.
 */
struct FfiBoxedSlice *zcashlc_voting_get_commitment_bundle(struct VotingDatabaseHandle *db,
                                                           const uint8_t *round_id,
                                                           uintptr_t round_id_len,
                                                           uint32_t bundle_index,
                                                           uint32_t proposal_id);

/**
 * Record the confirmed vote-commitment tree position for a committed vote.
 *
 * Wraps `CommittedVote::recover` + `record_vc_position`: after the cast-vote
 * transaction confirms with a `leaf_index`, record the VC position so
 * recovered helper-share payloads carry it. Returns 0 on success, -1 on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - `round_id` must be a valid UTF-8 pointer with its stated length.
 */
int32_t zcashlc_voting_record_vc_position(struct VotingDatabaseHandle *db,
                                          const uint8_t *round_id,
                                          uintptr_t round_id_len,
                                          uint32_t bundle_index,
                                          uint32_t proposal_id,
                                          uint64_t vc_tree_position);

/**
 * Reconstruct a committed vote from crate recovery state.
 *
 * Returns the same enriched JSON as `zcashlc_voting_build_vote_commitment`
 * (bundle fields + `vote_auth_sig` + `share_payloads`, with payloads carrying
 * the currently stored VC tree position) plus `vc_tree_position`. Call after
 * `zcashlc_voting_record_vc_position` to obtain payloads at the confirmed
 * position. Returns null (with the error retrievable) when no committed vote
 * exists for the key.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - `round_id` must be a valid UTF-8 pointer with its stated length.
 */
struct FfiBoxedSlice *zcashlc_voting_recover_committed_vote(struct VotingDatabaseHandle *db,
                                                            const uint8_t *round_id,
                                                            uintptr_t round_id_len,
                                                            uint32_t bundle_index,
                                                            uint32_t proposal_id);

/**
 * Persist a Keystone-produced PCZT signature.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - `round_id` must be a valid UTF-8 pointer with its stated length.
 * - `sig` must point to exactly 64 bytes.
 * - `sighash` and `rk` must each point to exactly 32 bytes.
 */
int32_t zcashlc_voting_store_keystone_signature(struct VotingDatabaseHandle *db,
                                                const uint8_t *round_id,
                                                uintptr_t round_id_len,
                                                uint32_t bundle_index,
                                                const uint8_t *sig,
                                                uintptr_t sig_len,
                                                const uint8_t *sighash,
                                                uintptr_t sighash_len,
                                                const uint8_t *rk,
                                                uintptr_t rk_len);

/**
 * Load all Keystone signatures stored for a round.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - `round_id` must be a valid UTF-8 pointer with its stated length.
 */
struct FfiBoxedSlice *zcashlc_voting_get_keystone_signatures(struct VotingDatabaseHandle *db,
                                                             const uint8_t *round_id,
                                                             uintptr_t round_id_len);

/**
 * Remove all recovery-state rows for a round.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - `round_id` must be a valid UTF-8 pointer with its stated length.
 */
int32_t zcashlc_voting_clear_recovery_state(struct VotingDatabaseHandle *db,
                                            const uint8_t *round_id,
                                            uintptr_t round_id_len);

/**
 * Initialize a voting round.
 *
 * Returns 0 on success, -1 on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - String/byte parameters must be valid for their stated lengths.
 */
int32_t zcashlc_voting_init_round(struct VotingDatabaseHandle *db,
                                  const uint8_t *round_id,
                                  uintptr_t round_id_len,
                                  uint64_t snapshot_height,
                                  const uint8_t *ea_pk,
                                  uintptr_t ea_pk_len,
                                  const uint8_t *nc_root,
                                  uintptr_t nc_root_len,
                                  const uint8_t *nullifier_imt_root,
                                  uintptr_t nullifier_imt_root_len,
                                  const uint8_t *session_json,
                                  uintptr_t session_json_len);

/**
 * Get the state of a voting round.
 *
 * Returns a pointer to `FfiRoundState` on success, or null on error.
 * Call `zcashlc_voting_free_round_state` to free the returned pointer.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 */
struct FfiRoundState *zcashlc_voting_get_round_state(struct VotingDatabaseHandle *db,
                                                     const uint8_t *round_id,
                                                     uintptr_t round_id_len);

/**
 * List all voting rounds.
 *
 * Returns a pointer to `FfiRoundSummaries` on success, or null on error.
 * Call `zcashlc_voting_free_round_summaries` to free the returned pointer.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 */
struct FfiRoundSummaries *zcashlc_voting_list_rounds(struct VotingDatabaseHandle *db);

/**
 * Get vote records for a round.
 *
 * Returns a pointer to `FfiVoteRecords` on success, or null on error.
 * Call `zcashlc_voting_free_vote_records` to free the returned pointer.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 */
struct FfiVoteRecords *zcashlc_voting_get_votes(struct VotingDatabaseHandle *db,
                                                const uint8_t *round_id,
                                                uintptr_t round_id_len);

/**
 * Clear all data for a voting round.
 *
 * Returns 0 on success, -1 on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 */
int32_t zcashlc_voting_clear_round(struct VotingDatabaseHandle *db,
                                   const uint8_t *round_id,
                                   uintptr_t round_id_len);

/**
 * Delete bundle rows with index >= `keep_count`, removing skipped bundles.
 *
 * Returns the number of deleted rows on success, or -1 on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 */
int64_t zcashlc_voting_delete_skipped_bundles(struct VotingDatabaseHandle *db,
                                              const uint8_t *round_id,
                                              uintptr_t round_id_len,
                                              uint32_t keep_count);

/**
 * Compute the share reveal nullifier from client-known inputs.
 *
 * Returns the 32-byte nullifier as a hex string (64 chars), or null on error.
 *
 * # Safety
 *
 * - `vote_commitment` must point to exactly 32 bytes.
 * - `primary_blind` must point to exactly 32 bytes.
 */
char *zcashlc_voting_compute_share_nullifier(const uint8_t *vote_commitment,
                                             const uint8_t *primary_blind,
                                             uint32_t share_index);

/**
 * Compute the crate-scheduled helper-share submit time.
 *
 * Pure policy over `zcash_voting`'s `share_policy`: derives the last-moment
 * buffer from the ceremony timing and samples uniformly inside the
 * pre-last-moment window from the supplied entropy (callers must pass at
 * least 8 fresh CSPRNG bytes when a delay window exists; the crate owns the
 * sampling). Returns the Unix seconds to submit at (0 = immediately), or -1
 * on error.
 *
 * # Safety
 *
 * - If `entropy_len > 0` then `entropy` must be non-null and valid for reads
 *   for `entropy_len` bytes; if `entropy_len == 0`, `entropy` is ignored.
 */
int64_t zcashlc_voting_scheduled_share_submit_at(uint64_t now_seconds,
                                                 uint64_t ceremony_start_seconds,
                                                 uint64_t vote_end_seconds,
                                                 uint8_t single_share,
                                                 const uint8_t *entropy,
                                                 uintptr_t entropy_len);

/**
 * Record a share delegation after sending to helper servers.
 *
 * Returns 0 on success, -1 on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - String params must be valid UTF-8 pointers with correct lengths.
 * - `nullifier_hex` must point to exactly 64 hex chars.
 * - `sent_to_urls_json` must be a JSON array of strings.
 */
int32_t zcashlc_voting_record_share_delegation(struct VotingDatabaseHandle *db,
                                               const uint8_t *round_id,
                                               uintptr_t round_id_len,
                                               uint32_t bundle_index,
                                               uint32_t proposal_id,
                                               uint32_t share_index,
                                               const uint8_t *sent_to_urls_json,
                                               uintptr_t sent_to_urls_json_len,
                                               const uint8_t *nullifier_hex,
                                               uintptr_t nullifier_hex_len,
                                               uint64_t submit_at);

/**
 * Get all share delegations for a round.
 *
 * Returns a JSON array of `JsonShareDelegationRecord`, or null on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 */
struct FfiBoxedSlice *zcashlc_voting_get_share_delegations(struct VotingDatabaseHandle *db,
                                                           const uint8_t *round_id,
                                                           uintptr_t round_id_len);

/**
 * Get unconfirmed share delegations for a round.
 *
 * Returns a JSON array of `JsonShareDelegationRecord`, or null on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 */
struct FfiBoxedSlice *zcashlc_voting_get_unconfirmed_delegations(struct VotingDatabaseHandle *db,
                                                                 const uint8_t *round_id,
                                                                 uintptr_t round_id_len);

/**
 * Mark a share delegation as confirmed on-chain.
 *
 * Returns 0 on success, -1 on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 */
int32_t zcashlc_voting_mark_share_confirmed(struct VotingDatabaseHandle *db,
                                            const uint8_t *round_id,
                                            uintptr_t round_id_len,
                                            uint32_t bundle_index,
                                            uint32_t proposal_id,
                                            uint32_t share_index);

/**
 * Append new server URLs to a share delegation's `sent_to_urls`.
 *
 * Returns 0 on success, -1 on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - `new_urls_json` must be a JSON array of strings.
 */
int32_t zcashlc_voting_add_sent_servers(struct VotingDatabaseHandle *db,
                                        const uint8_t *round_id,
                                        uintptr_t round_id_len,
                                        uint32_t bundle_index,
                                        uint32_t proposal_id,
                                        uint32_t share_index,
                                        const uint8_t *new_urls_json,
                                        uintptr_t new_urls_json_len);

/**
 * Sync the vote commitment tree from a chain node.
 *
 * Returns the latest synced block height on success (>= 0), or -1 on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 */
int64_t zcashlc_voting_sync_vote_tree(struct VotingDatabaseHandle *db,
                                      const uint8_t *round_id,
                                      uintptr_t round_id_len,
                                      const uint8_t *node_url,
                                      uintptr_t node_url_len);

/**
 * Generate a Vote Authority Note (VAN) Merkle witness.
 *
 * Returns JSON-encoded `VanWitness` as `*mut FfiBoxedSlice`, or null on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 */
struct FfiBoxedSlice *zcashlc_voting_generate_van_witness(struct VotingDatabaseHandle *db,
                                                          const uint8_t *round_id,
                                                          uintptr_t round_id_len,
                                                          uint32_t bundle_index,
                                                          uint32_t anchor_height);

/**
 * Drop the in-memory TreeClient so the next `sync_vote_tree()` call
 * creates a fresh one.
 *
 * Returns 0 on success, -1 on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 */
int32_t zcashlc_voting_reset_tree_client(struct VotingDatabaseHandle *db,
                                         const uint8_t *round_id,
                                         uintptr_t round_id_len);

/**
 * Warm process-lifetime proving-key caches used by voting proofs.
 *
 * Returns 0 on success, -1 on error.
 */
int32_t zcashlc_voting_warm_proving_caches(void);

/**
 * Decompose a weight into power-of-two components.
 *
 * Returns JSON-encoded `Vec<u64>` as `*mut FfiBoxedSlice`, or null on error.
 *
 * # Safety
 *
 * No pointer parameters.
 */
struct FfiBoxedSlice *zcashlc_voting_decompose_weight(uint64_t weight);

/**
 * Superseded: zcash_voting 1.0 derives delegation inputs from the wallet database
 * inside the delegation lanes (`build_pczt` / `build_and_prove_delegation` /
 * `get_delegation_submission`); seed-derived side inputs no longer exist.
 * Always returns null with a "superseded" error (C symbol preserved).
 *
 * # Safety
 *
 * - The pointer arguments are not read.
 */
struct FfiBoxedSlice *zcashlc_voting_generate_delegation_inputs(const uint8_t *_sender_seed,
                                                                uintptr_t _sender_seed_len,
                                                                const uint8_t *_hotkey_seed,
                                                                uintptr_t _hotkey_seed_len,
                                                                uint32_t _network_id,
                                                                uint32_t _account_index);

/**
 * Superseded: zcash_voting 1.0 derives delegation inputs from the wallet database
 * inside the delegation lanes; see `zcashlc_voting_generate_delegation_inputs`.
 * Always returns null with a "superseded" error (C symbol preserved).
 *
 * # Safety
 *
 * - The pointer arguments are not read.
 */
struct FfiBoxedSlice *zcashlc_voting_generate_delegation_inputs_with_fvk(const uint8_t *_fvk_bytes,
                                                                         uintptr_t _fvk_bytes_len,
                                                                         const uint8_t *_hotkey_seed,
                                                                         uintptr_t _hotkey_seed_len,
                                                                         uint32_t _network_id,
                                                                         const uint8_t *_seed_fingerprint,
                                                                         uintptr_t _seed_fingerprint_len);

/**
 * Extract the ZIP-244 shielded sighash from finalized PCZT bytes.
 *
 * Returns the 32-byte sighash as `*mut FfiBoxedSlice`, or null on error.
 *
 * # Safety
 *
 * - `pczt_bytes` must be valid for reads of `pczt_bytes_len` bytes.
 */
struct FfiBoxedSlice *zcashlc_voting_extract_pczt_sighash(const uint8_t *pczt_bytes,
                                                          uintptr_t pczt_bytes_len);

/**
 * Extract a spend auth signature from a signed PCZT.
 *
 * Returns the signature bytes as `*mut FfiBoxedSlice`, or null on error.
 *
 * # Safety
 *
 * - `signed_pczt_bytes` must be valid for reads of `signed_pczt_bytes_len` bytes.
 */
struct FfiBoxedSlice *zcashlc_voting_extract_spend_auth_sig(const uint8_t *signed_pczt_bytes,
                                                            uintptr_t signed_pczt_bytes_len,
                                                            uint32_t action_index);

/**
 * Extract the 96-byte Orchard FVK from a UFVK string.
 *
 * Returns the raw 96-byte Orchard FVK as `*mut FfiBoxedSlice`, or null on error.
 *
 * # Safety
 *
 * - `ufvk_str` must be valid for reads of `ufvk_str_len` bytes (UTF-8 encoded).
 */
struct FfiBoxedSlice *zcashlc_voting_extract_orchard_fvk_from_ufvk(const uint8_t *ufvk_str,
                                                                   uintptr_t ufvk_str_len,
                                                                   uint32_t network_id);

/**
 * Extract the Ironwood note commitment tree root from a protobuf-encoded TreeState.
 *
 * Voting rounds anchor to the Ironwood pool (zcash_voting 1.0), so the `nc_root`
 * comes from the Ironwood tree, not Orchard. Returns the 32-byte nc_root as
 * `*mut FfiBoxedSlice`, or null on error.
 *
 * # Safety
 *
 * - `tree_state_bytes` must be valid for reads of `tree_state_bytes_len` bytes.
 */
struct FfiBoxedSlice *zcashlc_voting_extract_nc_root(const uint8_t *tree_state_bytes,
                                                     uintptr_t tree_state_bytes_len);

/**
 * Verify a Merkle witness.
 *
 * `witness_json` is a JSON-encoded `WitnessData`.
 *
 * Returns 1 if valid, 0 if invalid, -1 on error.
 *
 * # Safety
 *
 * - `witness_json` must be valid for reads of `witness_json_len` bytes.
 */
int32_t zcashlc_voting_verify_witness(const uint8_t *witness_json, uintptr_t witness_json_len);

/**
 * Encrypt voting shares for a round.
 *
 * `shares_json` is a JSON-encoded `Vec<u64>`.
 *
 * Returns JSON-encoded `Vec<WireEncryptedShare>` as `*mut FfiBoxedSlice`, or null on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - For every `(ptr, len)` byte argument, if `len > 0` then `ptr` must be
 *   non-null and valid for reads for `len` bytes; if `len == 0`, `ptr` is ignored.
 */
struct FfiBoxedSlice *zcashlc_voting_encrypt_shares(struct VotingDatabaseHandle *db,
                                                    const uint8_t *round_id,
                                                    uintptr_t round_id_len,
                                                    const uint8_t *shares_json,
                                                    uintptr_t shares_json_len);

/**
 * Build a vote commitment proof for a proposal.
 *
 * `van_auth_path_json` is a JSON-encoded `Vec<Vec<u8>>`, where each element is 32 bytes.
 *
 * Returns JSON-encoded `VoteCommitmentBundle` as `*mut FfiBoxedSlice`, or null on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - For every `(ptr, len)` byte argument, if `len > 0` then `ptr` must be
 *   non-null and valid for reads for `len` bytes; if `len == 0`, `ptr` is ignored.
 * - `progress_callback` must be a valid function pointer, or null to skip
 *   progress. If provided, it must remain callable until this function returns.
 *   It must be thread-safe and reentrant; callers must not assume it runs on
 *   the main thread, because progress may be reported from proving worker threads.
 * - `progress_context` is passed to `progress_callback` unchanged. If non-null,
 *   it must point to state that remains valid until this function returns. The
 *   callback must not store `progress_context` or use it after this function returns.
 * - The callback must not call back into this voting database handle or perform
 *   work that can deadlock or reenter the active proof operation.
 */
struct FfiBoxedSlice *zcashlc_voting_build_vote_commitment(struct VotingDatabaseHandle *db,
                                                           const uint8_t *round_id,
                                                           uintptr_t round_id_len,
                                                           uint32_t bundle_index,
                                                           const uint8_t *hotkey_seed,
                                                           uintptr_t hotkey_seed_len,
                                                           uint32_t network_id,
                                                           uint32_t proposal_id,
                                                           uint32_t choice,
                                                           uint32_t num_options,
                                                           const uint8_t *van_auth_path_json,
                                                           uintptr_t van_auth_path_json_len,
                                                           uint32_t van_position,
                                                           uint32_t anchor_height,
                                                           void (*progress_callback)(double, void*),
                                                           void *progress_context,
                                                           uint8_t single_share);

/**
 * Build share payloads for delegated share submission.
 *
 * `commitment_json` is the JSON-encoded `VoteCommitmentBundle` returned by
 * `zcashlc_voting_build_vote_commitment`. Its `enc_shares` field is extracted
 * to wire-share form before reconstructing the core commitment, ensuring
 * helper payloads are built from the ciphertexts committed by the vote proof.
 *
 * Returns JSON-encoded `Vec<SharePayload>` as `*mut FfiBoxedSlice`, or null on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - For every `(ptr, len)` byte argument, if `len > 0` then `ptr` must be
 *   non-null and valid for reads for `len` bytes; if `len == 0`, `ptr` is ignored.
 */
struct FfiBoxedSlice *zcashlc_voting_build_share_payloads(struct VotingDatabaseHandle *db,
                                                          const uint8_t *commitment_json,
                                                          uintptr_t commitment_json_len,
                                                          uint32_t vote_decision,
                                                          uint32_t num_options,
                                                          uint64_t vc_tree_position,
                                                          uint8_t single_share);

/**
 * Mark a vote as submitted for a specific proposal and bundle.
 *
 * Returns 0 on success, or -1 on error.
 *
 * # Safety
 *
 * - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
 * - For the `(round_id, round_id_len)` byte argument, if `round_id_len > 0`
 *   then `round_id` must be non-null and valid for reads for `round_id_len`
 *   bytes; if `round_id_len == 0`, `round_id` is ignored.
 */
int32_t zcashlc_voting_mark_vote_submitted(struct VotingDatabaseHandle *db,
                                           const uint8_t *round_id,
                                           uintptr_t round_id_len,
                                           uint32_t bundle_index,
                                           uint32_t proposal_id);

/**
 * Sign a cast-vote transaction.
 *
 * Takes fields from `VoteCommitmentBundle` plus the hotkey seed and computes
 * the spend authorization signature.
 * `vote_round_id_hex` must encode exactly 32 bytes as ASCII hex. `r_vpk_bytes`,
 * `van_nullifier`, `vote_authority_note_new`, `vote_commitment`, and
 * `alpha_v` must each be exactly 32 bytes.
 *
 * Returns JSON-encoded `CastVoteSignature` as `*mut FfiBoxedSlice`, or null on error.
 *
 * # Safety
 *
 * - For every `(ptr, len)` byte argument, if `len > 0` then `ptr` must be
 *   non-null and valid for reads for `len` bytes; if `len == 0`, `ptr` is ignored.
 */
struct FfiBoxedSlice *zcashlc_voting_sign_cast_vote(const uint8_t *hotkey_seed,
                                                    uintptr_t hotkey_seed_len,
                                                    uint32_t network_id,
                                                    const uint8_t *vote_round_id_hex,
                                                    uintptr_t vote_round_id_hex_len,
                                                    const uint8_t *r_vpk_bytes,
                                                    uintptr_t r_vpk_bytes_len,
                                                    const uint8_t *van_nullifier,
                                                    uintptr_t van_nullifier_len,
                                                    const uint8_t *vote_authority_note_new,
                                                    uintptr_t vote_authority_note_new_len,
                                                    const uint8_t *vote_commitment,
                                                    uintptr_t vote_commitment_len,
                                                    uint32_t proposal_id,
                                                    uint32_t anchor_height,
                                                    const uint8_t *alpha_v,
                                                    uintptr_t alpha_v_len);
