//
//  ZcashRustBackend.swift
//  ZcashLightClientKit
//
//  Created by Jack Grigg on 5/8/19.
//  Copyright © 2019 Electric Coin Company. All rights reserved.
//
// swiftlint:disable type_body_length
import Foundation
import libzcashlc

enum RustLogging: String {
    /// The logs are completely disabled.
    case off
    /// Logs very serious errors.
    case error
    /// Logs hazardous situations.
    case warn
    /// Logs useful information.
    case info
    /// Logs lower priority information.
    case debug
    /// Logs very low priority, often extremely verbose, information.
    case trace
}

/// A description of the policy that is used to determine what notes are available for spending,
/// based upon the number of confirmations (the number of blocks in the chain since and including
/// the block in which a note was produced.)
///
/// See [`ZIP 315`] for details including the definitions of "trusted" and "untrusted" notes.
///
/// # Note
///
/// `trusted` and `untrusted` are both meant to be non-zero values.
/// `0` will be treated as a request for a default value.
///
/// [`ZIP 315`]: https://zips.z.cash/zip-0315
public struct ConfirmationsPolicy {
    /// NonZero, zero for default
    let trusted: UInt32
    /// NonZero, zero for default; if this is set to zero, `trusted` must also be set to zero
    let untrusted: UInt32
    let allowZeroConfShielding: Bool

    init(trusted: UInt32 = 3, untrusted: UInt32 = 10, allowZeroConfShielding: Bool = true) {
        self.trusted = trusted
        self.untrusted = untrusted
        self.allowZeroConfShielding = allowZeroConfShielding
    }

    public static func defaultTransferPolicy() -> Self {
        ConfirmationsPolicy.init()
    }

    public static func defaultShieldingPolicy() -> Self {
        ConfirmationsPolicy.init(trusted: 1, untrusted: 1, allowZeroConfShielding: true)
    }

    public func toBackend() -> libzcashlc.ConfirmationsPolicy {
        var libzcashlcConfirmationsPolicy = libzcashlc.ConfirmationsPolicy()
        libzcashlcConfirmationsPolicy.trusted = self.trusted
        libzcashlcConfirmationsPolicy.untrusted = self.untrusted
        libzcashlcConfirmationsPolicy.allow_zero_conf_shielding = self.allowZeroConfShielding
        return libzcashlcConfirmationsPolicy
    }
}

struct ZcashRustBackend: ZcashRustBackendWelding {
    let confirmationsPolicy: ConfirmationsPolicy = ConfirmationsPolicy.defaultTransferPolicy()
    let shieldingConfirmationsPolicy: ConfirmationsPolicy = ConfirmationsPolicy.defaultShieldingPolicy()

    let dbData: (String, UInt)
    let fsBlockDbRoot: (String, UInt)
    let spendParamsPath: (String, UInt)
    let outputParamsPath: (String, UInt)
    let keyDeriving: ZcashKeyDerivationBackendWelding

    let networkType: NetworkType
    let sdkFlags: SDKFlags

    /// Guards the one-time Rust initialization (`initializeRust(logLevel:)` / `zcashlc_init_on_load`)
    /// against concurrent first construction. The underlying FFI call panics if invoked more than
    /// once (tracing's `.init()` plus rayon's `build_global().expect`), and an unwind across the FFI
    /// boundary aborts the process; a plain check-then-act on `rustInitialized` let two instances
    /// racing to be first (e.g. `OrchardMigration`'s own backend and the synchronizer's, constructed
    /// concurrently at launch -- see `Synchronizer/Dependencies.swift` and
    /// `Migration/OrchardMigration.swift`'s `init(config:)`, both of which construct a
    /// `ZcashRustBackend`) both observe "not yet initialized" and both call in.
    ///
    /// `OSAllocatedUnfairLock` (the user's stated global preference for new locking code) requires
    /// iOS 16 / macOS 13; this package's `Package.swift` declares `.iOS(.v13)` / `.macOS(.v12)`, and
    /// `OSAllocatedUnfairLock` does not typecheck against that deployment target (verified directly:
    /// `swiftc -target arm64-apple-macos12.0 -typecheck` on a minimal use fails with "'OSAllocatedUnfairLock'
    /// is only available in macOS 13.0 or newer"). Per that same preference's own stated fallback --
    /// "below iOS 16, use NSLock" -- this uses `NSLock`, matching the plain-`NSLock` convention already
    /// used elsewhere in this codebase (`Utils/DIContainer.swift`, `Utils/UsedAliasesChecker.swift`).
    private static let rustInitLock = NSLock()
    private static var rustInitialized = false

    /// Creates instance of `ZcashRustBackend`.
    /// - Parameters:
    ///   - dbData: `URL` pointing to file where data database will be.
    ///   - fsBlockDbRoot: `URL` pointing to the filesystem root directory where the fsBlock cache is.
    ///                    this directory  is expected to contain a `/blocks` sub-directory with the blocks stored in the convened filename
    ///                    format `{height}-{hash}-block`. This directory has must be granted both write and read permissions.
    ///   - spendParamsPath: `URL` pointing to spend parameters file.
    ///   - outputParamsPath: `URL` pointing to output parameters file.
    ///   - networkType: Network type to use.
    ///   - logLevel: this sets up whether the tracing system will dump logs onto the OSLogger system or not.
    ///     **Important note:** this will enable the tracing **for all instances** of ZcashRustBackend, not only for this one.
    ///     This is ignored after the first ZcashRustBackend instance is created -- first caller wins the log
    ///     level, even when two instances are constructed concurrently from different call sites.
    init(
        dbData: URL,
        fsBlockDbRoot: URL,
        spendParamsPath: URL,
        outputParamsPath: URL,
        networkType: NetworkType,
        logLevel: RustLogging = RustLogging.off,
        sdkFlags: SDKFlags
    ) {
        self.dbData = dbData.osStr()
        self.fsBlockDbRoot = fsBlockDbRoot.osPathStr()
        self.spendParamsPath = spendParamsPath.osPathStr()
        self.outputParamsPath = outputParamsPath.osPathStr()
        self.networkType = networkType
        self.keyDeriving = ZcashKeyDerivationBackend(networkType: networkType)
        self.sdkFlags = sdkFlags

        Self.rustInitLock.lock()
        defer { Self.rustInitLock.unlock() }
        if !Self.rustInitialized {
            Self.rustInitialized = true
            Self.initializeRust(logLevel: logLevel)
        }
    }

    /// Registers the custom network used for the regtest network id (`NetworkType.regtest`) with the
    /// Rust core: its `base` identity (address encoding / `chainName`) plus its per-NU activation
    /// heights, so subsequent FFI calls made with that network id resolve to it instead of failing.
    /// Process-global and idempotent; call once before using a custom network (see `MIGRATING.md`).
    /// A `nil` height means "not activated on this network".
    ///
    /// Returns `true` on a fresh registration or an identical re-registration. Returns `false` when
    /// the call replaced a **different** existing configuration (the replacement is still applied,
    /// last writer wins) — a host configuration bug, since the parameters are process-global and two
    /// live instances with different custom networks cannot both be honored.
    @discardableResult
    static func setCustomNetwork(base: NetworkType, _ heights: NetworkActivationHeights) -> Bool {
        func height(_ value: BlockHeight?) -> Int64 {
            guard let value else { return -1 }
            return Int64(value)
        }

        return zcashlc_set_custom_network(
            base.networkId,
            height(heights.overwinter),
            height(heights.sapling),
            height(heights.blossom),
            height(heights.heartwood),
            height(heights.canopy),
            height(heights.nu5),
            height(heights.nu6),
            height(heights.nu6_1),
            height(heights.nu6_2),
            height(heights.nu6_3)
        )
    }

    @DBActor
    func listAccounts() async throws -> [Account] {
        let accountsPtr = zcashlc_list_accounts(
            dbData.0,
            dbData.1,
            networkType.networkId
        )

        guard let accountsPtr else {
            throw ZcashError.rustListAccounts(lastErrorMessage(fallback: "`listAccounts` failed with unknown error"))
        }

        defer { zcashlc_free_accounts(accountsPtr) }

        var accounts: [Account] = []

        for i in (0 ..< Int(accountsPtr.pointee.len)) {
            let accountUUIDPtr = accountsPtr.pointee.ptr.advanced(by: i).pointee
            let accountUUID = AccountUUID(id: accountUUIDPtr.uuidArray)

            let account = try await getAccount(for: accountUUID)

            accounts.append(account)
        }

        return accounts
    }

    @DBActor
    func getAccount(
        for accountUUID: AccountUUID
    ) async throws -> Account {
        let accountPtr: UnsafeMutablePointer<FfiAccount>? = zcashlc_get_account(
            dbData.0,
            dbData.1,
            networkType.networkId,
            accountUUID.id
        )

        guard let accountPtr else {
            throw ZcashError.rustImportAccountUfvk(lastErrorMessage(fallback: "`getAccount` failed with unknown error"))
        }

        defer { zcashlc_free_account(accountPtr) }

        guard let validAccount = accountPtr.pointee.unsafeToAccount() else {
            throw ZcashError.rustUUIDAccountNotFound(lastErrorMessage(fallback: "`getAccount` failed with unknown error"))
        }

        return validAccount
    }

    // swiftlint:disable:next function_parameter_count
    @DBActor func importAccount(
        ufvk: String,
        seedFingerprint: [UInt8]?,
        zip32AccountIndex: Zip32AccountIndex?,
        treeState: TreeState,
        recoverUntil: UInt32?,
        purpose: AccountPurpose,
        name: String,
        keySource: String?
    ) async throws -> AccountUUID {
        var rUntil: Int64 = -1

        if let recoverUntil {
            rUntil = Int64(recoverUntil)
        }

        let treeStateBytes = try treeState.serializedData(partial: false).bytes

        var kSource: [CChar]?

        if let keySource {
            kSource = [CChar](keySource.utf8CString)
        }

        let index: UInt32 = zip32AccountIndex?.index ?? UINT32_MAX

        let uuidPtr = zcashlc_import_account_ufvk(
            dbData.0,
            dbData.1,
            [CChar](ufvk.utf8CString),
            treeStateBytes,
            UInt(treeStateBytes.count),
            rUntil,
            networkType.networkId,
            purpose.rawValue,
            [CChar](name.utf8CString),
            kSource,
            seedFingerprint,
            index
        )

        guard let uuidPtr else {
            throw ZcashError.rustImportAccountUfvk(lastErrorMessage(fallback: "`importAccount` failed with unknown error"))
        }

        defer { zcashlc_free_ffi_uuid(uuidPtr) }

        return uuidPtr.pointee.unsafeToAccountUUID()
    }

    @DBActor
    func createAccount(
        seed: [UInt8],
        treeState: TreeState,
        recoverUntil: UInt32?,
        name: String,
        keySource: String?
    ) async throws -> UnifiedSpendingKey {
        var rUntil: Int64 = -1

        if let recoverUntil {
            rUntil = Int64(recoverUntil)
        }

        let treeStateBytes = try treeState.serializedData(partial: false).bytes

        var kSource: [CChar]?

        if let keySource {
            kSource = [CChar](keySource.utf8CString)
        }

        let ffiBinaryKeyPtr = zcashlc_create_account(
            dbData.0,
            dbData.1,
            seed,
            UInt(seed.count),
            treeStateBytes,
            UInt(treeStateBytes.count),
            rUntil,
            networkType.networkId,
            [CChar](name.utf8CString),
            kSource
        )

        guard let ffiBinaryKeyPtr else {
            throw ZcashError.rustCreateAccount(lastErrorMessage(fallback: "`createAccount` failed with unknown error"))
        }

        defer { zcashlc_free_binary_key(ffiBinaryKeyPtr) }

        return ffiBinaryKeyPtr.pointee.unsafeToUnifiedSpendingKey(network: networkType)
    }

    @DBActor
    func isSeedRelevantToAnyDerivedAccount(seed: [UInt8]) async throws -> Bool {
        let result = zcashlc_is_seed_relevant_to_any_derived_account(
            dbData.0,
            dbData.1,
            seed,
            UInt(seed.count),
            networkType.networkId
        )

        // -1 is the error sentinel.
        guard result >= 0 else {
            throw ZcashError.rustIsSeedRelevantToAnyDerivedAccount(
                lastErrorMessage(fallback: "`isSeedRelevantToAnyDerivedAccount` failed with unknown error")
            )
        }

        // 0 is false, 1 is true.
        return result != 0
    }

    @DBActor
    func proposeTransfer(
        accountUUID: AccountUUID,
        to address: String,
        value: Int64,
        memo: MemoBytes?
    ) async throws -> FfiProposal {
        let proposal = zcashlc_propose_transfer(
            dbData.0,
            dbData.1,
            accountUUID.id,
            [CChar](address.utf8CString),
            value,
            memo?.bytes,
            networkType.networkId,
            confirmationsPolicy.toBackend()
        )

        guard let proposal else {
            throw ZcashError.rustCreateToAddress(lastErrorMessage(fallback: "`proposeTransfer` failed with unknown error"))
        }

        defer { zcashlc_free_boxed_slice(proposal) }

        return try FfiProposal(serializedBytes: Data(
            bytes: proposal.pointee.ptr,
            count: Int(proposal.pointee.len)
        ))
    }

    @DBActor
    func proposeTransferFromURI(
        _ uri: String,
        accountUUID: AccountUUID
    ) async throws -> FfiProposal {
        let proposal = zcashlc_propose_transfer_from_uri(
            dbData.0,
            dbData.1,
            accountUUID.id,
            [CChar](uri.utf8CString),
            networkType.networkId,
            confirmationsPolicy.toBackend()
        )

        guard let proposal else {
            throw ZcashError.rustCreateToAddress(lastErrorMessage(fallback: "`proposeTransfer` failed with unknown error"))
        }

        defer { zcashlc_free_boxed_slice(proposal) }

        return try FfiProposal(serializedBytes: Data(
            bytes: proposal.pointee.ptr,
            count: Int(proposal.pointee.len)
        ))
    }

    @DBActor
    func createPCZTFromProposal(
        accountUUID: AccountUUID,
        proposal: FfiProposal
    ) async throws -> Pczt {
        let proposalBytes = try proposal.serializedData(partial: false).bytes

        let pcztPtr = proposalBytes.withUnsafeBufferPointer { proposalPtr in
            zcashlc_create_pczt_from_proposal(
                dbData.0,
                dbData.1,
                networkType.networkId,
                proposalPtr.baseAddress,
                UInt(proposalBytes.count),
                accountUUID.id
            )
        }

        guard let pcztPtr else {
            throw ZcashError.rustCreatePCZTFromProposal(lastErrorMessage(fallback: "`createPCZTFromProposal` failed with unknown error"))
        }

        defer { zcashlc_free_boxed_slice(pcztPtr) }

        return Pczt(
            bytes: pcztPtr.pointee.ptr,
            count: Int(pcztPtr.pointee.len)
        )
    }

    func redactPCZTForSigner(pczt: Pczt) async throws -> Pczt {
        let pcztPtr: UnsafeMutablePointer<FfiBoxedSlice>? = pczt.withUnsafeBytes { buffer in
            guard let bufferPtr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }

            return zcashlc_redact_pczt_for_signer(
                bufferPtr,
                UInt(pczt.count)
            )
        }

        guard let pcztPtr else {
            throw ZcashError.rustRedactPCZTForSigner(lastErrorMessage(fallback: "`redactPCZTForSigner` failed with unknown error"))
        }

        defer { zcashlc_free_boxed_slice(pcztPtr) }

        return Pczt(
            bytes: pcztPtr.pointee.ptr,
            count: Int(pcztPtr.pointee.len)
        )
    }

    func PCZTRequiresSaplingProofs(pczt: Pczt) async -> Bool {
        return pczt.withUnsafeBytes { buffer in
            guard let bufferPtr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                // Return `false` here so the caller proceeds to `addProofsToPCZT` and
                // gets the same error.
                return false
            }

            return zcashlc_pczt_requires_sapling_proofs(
                bufferPtr,
                UInt(pczt.count)
            )
        }
    }

    func addProofsToPCZT(
        pczt: Pczt
    ) async throws -> Pczt {
        let pcztPtr: UnsafeMutablePointer<FfiBoxedSlice>? = pczt.withUnsafeBytes { buffer in
            guard let bufferPtr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }

            return zcashlc_add_proofs_to_pczt(
                bufferPtr,
                UInt(pczt.count),
                spendParamsPath.0,
                spendParamsPath.1,
                outputParamsPath.0,
                outputParamsPath.1
            )
        }

        guard let pcztPtr else {
            throw ZcashError.rustAddProofsToPCZT(lastErrorMessage(fallback: "`addProofsToPCZT` failed with unknown error"))
        }

        defer { zcashlc_free_boxed_slice(pcztPtr) }

        return Pczt(
            bytes: pcztPtr.pointee.ptr,
            count: Int(pcztPtr.pointee.len)
        )
    }

    @DBActor
    func extractAndStoreTxFromPCZT(
        pcztWithProofs: Pczt,
        pcztWithSigs: Pczt
    ) async throws -> Data {
        let txidPtr: UnsafeMutablePointer<FfiBoxedSlice>? = pcztWithProofs.withUnsafeBytes { pcztWithProofsBuffer in
            guard let pcztWithProofsBufferPtr = pcztWithProofsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }

            return pcztWithSigs.withUnsafeBytes { pcztWithSigsBuffer in
                guard let pcztWithSigsBufferPtr = pcztWithSigsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return nil
                }

                return zcashlc_extract_and_store_from_pczt(
                    dbData.0,
                    dbData.1,
                    networkType.networkId,
                    pcztWithProofsBufferPtr,
                    UInt(pcztWithProofs.count),
                    pcztWithSigsBufferPtr,
                    UInt(pcztWithSigs.count),
                    spendParamsPath.0,
                    spendParamsPath.1,
                    outputParamsPath.0,
                    outputParamsPath.1
                )
            }
        }

        guard let txidPtr else {
            throw ZcashError.rustExtractAndStoreTxFromPCZT(lastErrorMessage(fallback: "`extractAndStoreTxFromPCZT` failed with unknown error"))
        }

        guard txidPtr.pointee.len == 32 else {
            throw ZcashError.rustTxidPtrIncorrectLength(lastErrorMessage(fallback: "`extractAndStoreTxFromPCZT` failed with unknown error"))
        }

        defer { zcashlc_free_boxed_slice(txidPtr) }

        return Data(
            bytes: txidPtr.pointee.ptr,
            count: Int(txidPtr.pointee.len)
        )
    }

    @DBActor
    func decryptAndStoreTransaction(txBytes: [UInt8], minedHeight: UInt32?) async throws -> Data {
        var contiguousTxidBytes = ContiguousArray<UInt8>(Data(count: 32))

        let result = contiguousTxidBytes.withUnsafeMutableBufferPointer { txidBytePtr in
            zcashlc_decrypt_and_store_transaction(
                dbData.0,
                dbData.1,
                txBytes,
                UInt(txBytes.count),
                Int64(minedHeight ?? 0),
                networkType.networkId,
                txidBytePtr.baseAddress
            )
        }

        guard result != 0 else {
            throw ZcashError.rustDecryptAndStoreTransaction(lastErrorMessage(fallback: "`decryptAndStoreTransaction` failed with unknown error"))
        }

        return Data(contiguousTxidBytes)
    }

    @DBActor
    func getCurrentAddress(accountUUID: AccountUUID) async throws -> UnifiedAddress {
        let addressCStr = zcashlc_get_current_address(
            dbData.0,
            dbData.1,
            accountUUID.id,
            networkType.networkId
        )

        guard let addressCStr else {
            throw ZcashError.rustGetCurrentAddress(lastErrorMessage(fallback: "`getCurrentAddress` failed with unknown error"))
        }

        defer { zcashlc_string_free(addressCStr) }

        guard let address = String(validatingUTF8: addressCStr) else {
            throw ZcashError.rustGetCurrentAddressInvalidAddress
        }

        return UnifiedAddress(validatedEncoding: address, networkType: networkType)
    }

    @DBActor
    func getNextAvailableAddress(accountUUID: AccountUUID, receiverFlags: UInt32) async throws -> UnifiedAddress {
        let addressCStr = zcashlc_get_next_available_address(
            dbData.0,
            dbData.1,
            accountUUID.id,
            networkType.networkId,
            receiverFlags
        )

        guard let addressCStr else {
            throw ZcashError.rustGetNextAvailableAddress(lastErrorMessage(fallback: "`getNextAvailableAddress` failed with unknown error"))
        }

        defer { zcashlc_string_free(addressCStr) }

        guard let address = String(validatingUTF8: addressCStr) else {
            throw ZcashError.rustGetNextAvailableAddressInvalidAddress
        }

        return UnifiedAddress(validatedEncoding: address, networkType: networkType)
    }

    @DBActor
    func getMemo(txId: Data, outputPool: UInt32, outputIndex: UInt16) async throws -> Memo? {
        guard txId.count == 32 else {
            throw ZcashError.rustGetMemoInvalidTxIdLength
        }

        var contiguousMemoBytes = ContiguousArray<UInt8>(MemoBytes.empty().bytes)
        var success = false

        contiguousMemoBytes.withUnsafeMutableBufferPointer { memoBytePtr in
            success = zcashlc_get_memo(dbData.0, dbData.1, txId.bytes, outputPool, outputIndex, memoBytePtr.baseAddress, networkType.networkId)
        }

        guard success else { return nil }

        return (try? MemoBytes(contiguousBytes: contiguousMemoBytes)).flatMap { try? $0.intoMemo() }
    }

    @DBActor
    func getTransparentBalance(accountUUID: AccountUUID) async throws -> Int64 {
        let balance = zcashlc_get_total_transparent_balance_for_account(
            dbData.0,
            dbData.1,
            networkType.networkId,
            accountUUID.id
        )

        guard balance >= 0 else {
            throw ZcashError.rustGetTransparentBalance(
                accountUUID,
                lastErrorMessage(fallback: "Error getting Total Transparent balance from accountUUID \(accountUUID.id)")
            )
        }

        return balance
    }

    @DBActor
    func getVerifiedTransparentBalance(accountUUID: AccountUUID) async throws -> Int64 {
        let balance = zcashlc_get_verified_transparent_balance_for_account(
            dbData.0,
            dbData.1,
            networkType.networkId,
            accountUUID.id,
            shieldingConfirmationsPolicy.toBackend()
        )

        guard balance >= 0 else {
            throw ZcashError.rustGetVerifiedTransparentBalance(
                accountUUID,
                lastErrorMessage(fallback: "Error getting verified transparent balance from accountUUID \(accountUUID.id)")
            )
        }

        return balance
    }

    @DBActor
    func initDataDb(seed: [UInt8]?) async throws -> DbInitResult {
        let initResult = zcashlc_init_data_database(dbData.0, dbData.1, seed, UInt(seed?.count ?? 0), networkType.networkId)

        switch initResult {
        case 0: // ok
            return DbInitResult.success
        case 1:
            return DbInitResult.seedRequired
        case 2:
            return DbInitResult.seedNotRelevant
        default:
            throw ZcashError.rustInitDataDb(lastErrorMessage(fallback: "`initDataDb` failed with unknown error"))
        }
    }

    @DBActor
    func initBlockMetadataDb() async throws {
        let result = zcashlc_init_block_metadata_db(fsBlockDbRoot.0, fsBlockDbRoot.1)

        guard result else {
            throw ZcashError.rustInitBlockMetadataDb(lastErrorMessage(fallback: "`initBlockMetadataDb` failed with unknown error"))
        }
    }

    @DBActor
    func writeBlocksMetadata(blocks: [ZcashCompactBlock]) async throws {
        var ffiBlockMetaVec: [FFIBlockMeta] = []

        for block in blocks {
            let meta = block.meta
            let hashPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: meta.hash.count)

            let contiguousHashBytes = ContiguousArray(meta.hash.bytes)

            let result: Void? = contiguousHashBytes.withContiguousStorageIfAvailable { hashBytesPtr in
                // swiftlint:disable:next force_unwrapping
                hashPtr.initialize(from: hashBytesPtr.baseAddress!, count: hashBytesPtr.count)
            }

            guard result != nil else {
                defer {
                    hashPtr.deallocate()
                    ffiBlockMetaVec.deallocateElements()
                }
                throw ZcashError.rustWriteBlocksMetadataAllocationProblem
            }

            ffiBlockMetaVec.append(
                FFIBlockMeta(
                    height: UInt32(block.height),
                    block_hash_ptr: hashPtr,
                    block_hash_ptr_len: UInt(contiguousHashBytes.count),
                    block_time: meta.time,
                    sapling_outputs_count: meta.saplingOutputs,
                    orchard_actions_count: meta.orchardOutputs
                )
            )
        }

        var contiguousFFIBlocks = ContiguousArray(ffiBlockMetaVec)

        let len = UInt(contiguousFFIBlocks.count)

        let fsBlocks = UnsafeMutablePointer<FFIBlocksMeta>.allocate(capacity: 1)

        defer { ffiBlockMetaVec.deallocateElements() }

        try contiguousFFIBlocks.withContiguousMutableStorageIfAvailable { ptr in
            var meta = FFIBlocksMeta()
            meta.ptr = ptr.baseAddress
            meta.len = len

            fsBlocks.initialize(to: meta)

            let res = zcashlc_write_block_metadata(fsBlockDbRoot.0, fsBlockDbRoot.1, fsBlocks)

            guard res else {
                throw ZcashError.rustWriteBlocksMetadata(lastErrorMessage(fallback: "`writeBlocksMetadata` failed with unknown error"))
            }
        }
    }

    @DBActor
    func latestCachedBlockHeight() async throws -> BlockHeight {
        let height = zcashlc_latest_cached_block_height(fsBlockDbRoot.0, fsBlockDbRoot.1)

        if height >= 0 {
            return BlockHeight(height)
        } else if height == -1 {
            return BlockHeight.empty()
        } else {
            throw ZcashError.rustLatestCachedBlockHeight(lastErrorMessage(fallback: "`latestCachedBlockHeight` failed with unknown error"))
        }
    }

    @DBActor
    func listTransparentReceivers(accountUUID: AccountUUID) async throws -> [TransparentAddress] {
        let encodedKeysPtr = zcashlc_list_transparent_receivers(
            dbData.0,
            dbData.1,
            accountUUID.id,
            networkType.networkId
        )

        guard let encodedKeysPtr else {
            throw ZcashError.rustListTransparentReceivers(lastErrorMessage(fallback: "`listTransparentReceivers` failed with unknown error"))
        }

        defer { zcashlc_free_keys(encodedKeysPtr) }

        var addresses: [TransparentAddress] = []

        for i in (0 ..< Int(encodedKeysPtr.pointee.len)) {
            let key = encodedKeysPtr.pointee.ptr.advanced(by: i).pointee

            guard let taddrStr = String(validatingUTF8: key.encoding) else {
                throw ZcashError.rustListTransparentReceiversInvalidAddress
            }

            addresses.append(
                TransparentAddress(validatedEncoding: taddrStr)
            )
        }

        return addresses
    }

    @DBActor
    func putUnspentTransparentOutput(
        txid: [UInt8],
        index: Int,
        script: [UInt8],
        value: Int64,
        height: BlockHeight
    ) async throws {
        let result = zcashlc_put_utxo(
            dbData.0,
            dbData.1,
            txid,
            UInt(txid.count),
            Int32(index),
            script,
            UInt(script.count),
            value,
            Int32(height),
            networkType.networkId
        )

        guard result else {
            throw ZcashError.rustPutUnspentTransparentOutput(lastErrorMessage(fallback: "`putUnspentTransparentOutput` failed with unknown error"))
        }
    }

    @DBActor
    func rewindToHeight(height: BlockHeight) async throws -> RewindResult {
        var safeRewindHeight: Int64 = -1
        let result = zcashlc_rewind_to_height(dbData.0, dbData.1, UInt32(height), networkType.networkId, &safeRewindHeight)

        if result >= 0 {
            return .success(BlockHeight(result))
        } else if result == -1 && safeRewindHeight > 0 {
            return .requestedHeightTooLow(BlockHeight(safeRewindHeight))
        } else {
            throw ZcashError.rustRewindToHeight(Int32(height), lastErrorMessage(fallback: "`rewindToHeight` failed with unknown error"))
        }
    }

    @DBActor
    func truncateToChainState(chainState: TreeState) async throws {
        let chainStateBytes = try chainState.serializedData(partial: false).bytes

        let result = zcashlc_truncate_to_chain_state(
            dbData.0,
            dbData.1,
            chainStateBytes,
            UInt(chainStateBytes.count),
            networkType.networkId
        )

        guard result else {
            throw ZcashError.rustTruncateToChainState(lastErrorMessage(fallback: "`truncateToChainState` failed with unknown error"))
        }
    }

    @DBActor
    func rewindCacheToHeight(height: Int32) async throws {
        let result = zcashlc_rewind_fs_block_cache_to_height(fsBlockDbRoot.0, fsBlockDbRoot.1, height)

        guard result else {
            throw ZcashError.rustRewindCacheToHeight(lastErrorMessage(fallback: "`rewindCacheToHeight` failed with unknown error"))
        }
    }

    @DBActor
    func putSaplingSubtreeRoots(startIndex: UInt64, roots: [SubtreeRoot]) async throws {
        var ffiSubtreeRootsVec: [FfiSubtreeRoot] = []

        for root in roots {
            let hashPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: root.rootHash.count)

            let contiguousHashBytes = ContiguousArray(root.rootHash.bytes)

            let result: Void? = contiguousHashBytes.withContiguousStorageIfAvailable { hashBytesPtr in
                // swiftlint:disable:next force_unwrapping
                hashPtr.initialize(from: hashBytesPtr.baseAddress!, count: hashBytesPtr.count)
            }

            guard result != nil else {
                defer {
                    hashPtr.deallocate()
                    ffiSubtreeRootsVec.deallocateElements()
                }
                throw ZcashError.rustPutSaplingSubtreeRootsAllocationProblem
            }

            guard let completingBlockHeight = UInt32(exactly: root.completingBlockHeight) else {
                defer {
                    hashPtr.deallocate()
                    ffiSubtreeRootsVec.deallocateElements()
                }
                throw ZcashError.rustPutSaplingSubtreeRoots(
                    "server-supplied completing block height \(root.completingBlockHeight) does not fit in UInt32"
                )
            }

            ffiSubtreeRootsVec.append(
                FfiSubtreeRoot(
                    root_hash_ptr: hashPtr,
                    root_hash_ptr_len: UInt(contiguousHashBytes.count),
                    completing_block_height: completingBlockHeight
                )
            )
        }

        var contiguousFfiRoots = ContiguousArray(ffiSubtreeRootsVec)

        let len = UInt(contiguousFfiRoots.count)

        let rootsPtr = UnsafeMutablePointer<FfiSubtreeRoots>.allocate(capacity: 1)

        defer {
            ffiSubtreeRootsVec.deallocateElements()
            rootsPtr.deallocate()
        }

        try contiguousFfiRoots.withContiguousMutableStorageIfAvailable { ptr in
            var roots = FfiSubtreeRoots()
            roots.ptr = ptr.baseAddress
            roots.len = len

            rootsPtr.initialize(to: roots)

            let res = zcashlc_put_sapling_subtree_roots(dbData.0, dbData.1, startIndex, rootsPtr, networkType.networkId)

            guard res else {
                throw ZcashError.rustPutSaplingSubtreeRoots(lastErrorMessage(fallback: "`putSaplingSubtreeRoots` failed with unknown error"))
            }
        }
    }

    @DBActor
    func putOrchardSubtreeRoots(startIndex: UInt64, roots: [SubtreeRoot]) async throws {
        var ffiSubtreeRootsVec: [FfiSubtreeRoot] = []

        for root in roots {
            let hashPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: root.rootHash.count)

            let contiguousHashBytes = ContiguousArray(root.rootHash.bytes)

            let result: Void? = contiguousHashBytes.withContiguousStorageIfAvailable { hashBytesPtr in
                // swiftlint:disable:next force_unwrapping
                hashPtr.initialize(from: hashBytesPtr.baseAddress!, count: hashBytesPtr.count)
            }

            guard result != nil else {
                defer {
                    hashPtr.deallocate()
                    ffiSubtreeRootsVec.deallocateElements()
                }
                throw ZcashError.rustPutOrchardSubtreeRootsAllocationProblem
            }

            guard let completingBlockHeight = UInt32(exactly: root.completingBlockHeight) else {
                defer {
                    hashPtr.deallocate()
                    ffiSubtreeRootsVec.deallocateElements()
                }
                throw ZcashError.rustPutOrchardSubtreeRoots(
                    "server-supplied completing block height \(root.completingBlockHeight) does not fit in UInt32"
                )
            }

            ffiSubtreeRootsVec.append(
                FfiSubtreeRoot(
                    root_hash_ptr: hashPtr,
                    root_hash_ptr_len: UInt(contiguousHashBytes.count),
                    completing_block_height: completingBlockHeight
                )
            )
        }

        var contiguousFfiRoots = ContiguousArray(ffiSubtreeRootsVec)

        let len = UInt(contiguousFfiRoots.count)

        let rootsPtr = UnsafeMutablePointer<FfiSubtreeRoots>.allocate(capacity: 1)

        defer {
            ffiSubtreeRootsVec.deallocateElements()
            rootsPtr.deallocate()
        }

        try contiguousFfiRoots.withContiguousMutableStorageIfAvailable { ptr in
            var roots = FfiSubtreeRoots()
            roots.ptr = ptr.baseAddress
            roots.len = len

            rootsPtr.initialize(to: roots)

            let res = zcashlc_put_orchard_subtree_roots(dbData.0, dbData.1, startIndex, rootsPtr, networkType.networkId)

            guard res else {
                throw ZcashError.rustPutOrchardSubtreeRoots(lastErrorMessage(fallback: "`putOrchardSubtreeRoots` failed with unknown error"))
            }
        }
    }

    @DBActor
    func putIronwoodSubtreeRoots(startIndex: UInt64, roots: [SubtreeRoot]) async throws {
        var ffiSubtreeRootsVec: [FfiSubtreeRoot] = []

        for root in roots {
            let hashPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: root.rootHash.count)

            let contiguousHashBytes = ContiguousArray(root.rootHash.bytes)

            let result: Void? = contiguousHashBytes.withContiguousStorageIfAvailable { hashBytesPtr in
                // swiftlint:disable:next force_unwrapping
                hashPtr.initialize(from: hashBytesPtr.baseAddress!, count: hashBytesPtr.count)
            }

            guard result != nil else {
                defer {
                    hashPtr.deallocate()
                    ffiSubtreeRootsVec.deallocateElements()
                }
                throw ZcashError.rustPutIronwoodSubtreeRootsAllocationProblem
            }

            guard let completingBlockHeight = UInt32(exactly: root.completingBlockHeight) else {
                defer {
                    hashPtr.deallocate()
                    ffiSubtreeRootsVec.deallocateElements()
                }
                throw ZcashError.rustPutIronwoodSubtreeRoots(
                    "server-supplied completing block height \(root.completingBlockHeight) does not fit in UInt32"
                )
            }

            ffiSubtreeRootsVec.append(
                FfiSubtreeRoot(
                    root_hash_ptr: hashPtr,
                    root_hash_ptr_len: UInt(contiguousHashBytes.count),
                    completing_block_height: completingBlockHeight
                )
            )
        }

        var contiguousFfiRoots = ContiguousArray(ffiSubtreeRootsVec)

        let len = UInt(contiguousFfiRoots.count)

        let rootsPtr = UnsafeMutablePointer<FfiSubtreeRoots>.allocate(capacity: 1)

        defer {
            ffiSubtreeRootsVec.deallocateElements()
            rootsPtr.deallocate()
        }

        try contiguousFfiRoots.withContiguousMutableStorageIfAvailable { ptr in
            var roots = FfiSubtreeRoots()
            roots.ptr = ptr.baseAddress
            roots.len = len

            rootsPtr.initialize(to: roots)

            let res = zcashlc_put_ironwood_subtree_roots(dbData.0, dbData.1, startIndex, rootsPtr, networkType.networkId)

            guard res else {
                throw ZcashError.rustPutIronwoodSubtreeRoots(lastErrorMessage(fallback: "`putIronwoodSubtreeRoots` failed with unknown error"))
            }
        }
    }

    @DBActor
    func updateChainTip(height: Int32) async throws {
        let result = zcashlc_update_chain_tip(dbData.0, dbData.1, height, networkType.networkId)

        guard result else {
            throw ZcashError.rustUpdateChainTip(lastErrorMessage(fallback: "`updateChainTip` failed with unknown error"))
        }
    }

    @DBActor
    func fullyScannedHeight() async throws -> BlockHeight? {
        let height = zcashlc_fully_scanned_height(dbData.0, dbData.1, networkType.networkId)

        if height >= 0 {
            return BlockHeight(height)
        } else if height == -1 {
            return nil
        } else {
            throw ZcashError.rustFullyScannedHeight(lastErrorMessage(fallback: "`fullyScannedHeight` failed with unknown error"))
        }
    }

    @DBActor
    func maxScannedHeight() async throws -> BlockHeight? {
        let height = zcashlc_max_scanned_height(dbData.0, dbData.1, networkType.networkId)

        if height >= 0 {
            return BlockHeight(height)
        } else if height == -1 {
            return nil
        } else {
            throw ZcashError.rustMaxScannedHeight(lastErrorMessage(fallback: "`maxScannedHeight` failed with unknown error"))
        }
    }

    @DBActor
    func getWalletSummary() async throws -> WalletSummary? {
        let summaryPtr = zcashlc_get_wallet_summary(dbData.0, dbData.1, networkType.networkId, confirmationsPolicy.toBackend())

        guard let summaryPtr else {
            throw ZcashError.rustGetWalletSummary(lastErrorMessage(fallback: "`getWalletSummary` failed with unknown error"))
        }

        defer { zcashlc_free_wallet_summary(summaryPtr) }

        // C → Swift mapping shared with the unified wallet-summary path (WalletSummary+FFI.swift).
        guard let summary = WalletSummary.fromFFI(summaryPtr) else { return nil }

        // Mask spendable `accountBalances` while chainTip hasn't been updated yet ([#1591]).
        if await !sdkFlags.chainTipUpdated {
            return summary.withSpendableMasked()
        }

        return summary
    }

    @DBActor
    func suggestScanRanges() async throws -> [ScanRange] {
        let scanRangesPtr = zcashlc_suggest_scan_ranges(dbData.0, dbData.1, networkType.networkId)

        guard let scanRangesPtr else {
            throw ZcashError.rustSuggestScanRanges(lastErrorMessage(fallback: "`suggestScanRanges` failed with unknown error"))
        }

        defer { zcashlc_free_scan_ranges(scanRangesPtr) }

        var scanRanges: [ScanRange] = []

        for i in (0 ..< Int(scanRangesPtr.pointee.len)) {
            let scanRange = scanRangesPtr.pointee.ptr.advanced(by: i).pointee

            scanRanges.append(
                ScanRange(
                    range: Range(uncheckedBounds: (
                        BlockHeight(scanRange.start),
                        BlockHeight(scanRange.end)
                    )),
                    priority: ScanRange.Priority(scanRange.priority)
                )
            )
        }

        return scanRanges
    }

    @DBActor
    func scanBlocks(fromHeight: Int32, fromState: TreeState, limit: UInt32 = 0) async throws -> ScanSummary {
        let fromStateBytes = try fromState.serializedData(partial: false).bytes

        let summaryPtr = zcashlc_scan_blocks(
            fsBlockDbRoot.0,
            fsBlockDbRoot.1,
            dbData.0,
            dbData.1,
            fromHeight,
            fromStateBytes,
            UInt(fromStateBytes.count),
            limit,
            networkType.networkId
        )

        guard let summaryPtr else {
            throw ZcashError.rustScanBlocks(lastErrorMessage(fallback: "`scanBlocks` failed with unknown error"))
        }

        defer { zcashlc_free_scan_summary(summaryPtr) }

        return ScanSummary(
            scannedRange: Range(uncheckedBounds: (
                BlockHeight(summaryPtr.pointee.scanned_start),
                BlockHeight(summaryPtr.pointee.scanned_end)
            )),
            spentSaplingNoteCount: summaryPtr.pointee.spent_sapling_note_count,
            receivedSaplingNoteCount: summaryPtr.pointee.received_sapling_note_count
        )
    }

    @DBActor
    func proposeShielding(
        accountUUID: AccountUUID,
        memo: MemoBytes?,
        shieldingThreshold: Zatoshi,
        transparentReceiver: String?
    ) async throws -> FfiProposal? {
        let proposal = zcashlc_propose_shielding(
            dbData.0,
            dbData.1,
            accountUUID.id,
            memo?.bytes,
            UInt64(shieldingThreshold.amount),
            transparentReceiver.map { [CChar]($0.utf8CString) },
            networkType.networkId,
            shieldingConfirmationsPolicy.toBackend()
        )

        guard let proposal else {
            throw ZcashError.rustShieldFunds(lastErrorMessage(fallback: "Failed with nil proposal."))
        }

        defer { zcashlc_free_boxed_slice(proposal) }

        guard proposal.pointee.ptr != nil else {
            return nil
        }

        return try FfiProposal(serializedBytes: Data(
            bytes: proposal.pointee.ptr,
            count: Int(proposal.pointee.len)
        ))
    }

    @DBActor
    func createProposedTransactions(
        proposal: FfiProposal,
        usk: UnifiedSpendingKey
    ) async throws -> [Data] {
        let proposalBytes = try proposal.serializedData(partial: false).bytes

        let txIdsPtr = proposalBytes.withUnsafeBufferPointer { proposalPtr in
            usk.bytes.withUnsafeBufferPointer { uskPtr in
                zcashlc_create_proposed_transactions(
                    dbData.0,
                    dbData.1,
                    proposalPtr.baseAddress,
                    UInt(proposalBytes.count),
                    uskPtr.baseAddress,
                    UInt(usk.bytes.count),
                    spendParamsPath.0,
                    spendParamsPath.1,
                    outputParamsPath.0,
                    outputParamsPath.1,
                    networkType.networkId
                )
            }
        }

        guard let txIdsPtr else {
            throw ZcashError.rustCreateToAddress(lastErrorMessage(fallback: "`createToAddress` failed with unknown error"))
        }

        defer { zcashlc_free_txids(txIdsPtr) }

        var txIds: [Data] = []

        for i in (0 ..< Int(txIdsPtr.pointee.len)) {
            let txId = FfiTxId(tuple: txIdsPtr.pointee.ptr.advanced(by: i).pointee)
            txIds.append(Data(txId.array))
        }

        return txIds
    }

    nonisolated func consensusBranchIdFor(height: Int32) throws -> Int32 {
        let branchId = zcashlc_branch_id_for_height(height, networkType.networkId)

        guard branchId != -1 else {
            throw ZcashError.rustNoConsensusBranchId(height)
        }

        return branchId
    }

    // swiftlint:disable:next cyclomatic_complexity
    @DBActor func transactionDataRequests() async throws -> [TransactionDataRequest] {
        let tDataRequestsPtr = zcashlc_transaction_data_requests(
            dbData.0,
            dbData.1,
            networkType.networkId
        )

        guard let tDataRequestsPtr else {
            throw ZcashError.rustTransactionDataRequests(lastErrorMessage(fallback: "`transactionDataRequests` failed with unknown error"))
        }

        defer { zcashlc_free_transaction_data_requests(tDataRequestsPtr) }

        var transactionDataRequests: [TransactionDataRequest] = []

        for i in (0 ..< Int(tDataRequestsPtr.pointee.len)) {
            let tDataRequestPtr = tDataRequestsPtr.pointee.ptr.advanced(by: i).pointee

            var tDataRequest: TransactionDataRequest?

            if tDataRequestPtr.tag == 0 {
                tDataRequest = TransactionDataRequest.getStatus(FfiTxId(tuple: tDataRequestPtr.get_status).array)
            } else if tDataRequestPtr.tag == 1 {
                tDataRequest = TransactionDataRequest.enhancement(FfiTxId(tuple: tDataRequestPtr.enhancement).array)
            } else if tDataRequestPtr.tag == 2, let address = String(validatingUTF8: tDataRequestPtr.transactions_involving_address.address) {
                let end = tDataRequestPtr.transactions_involving_address.block_range_end
                let blockRangeEnd: UInt32? = end > UInt32.max || end == -1 ? nil : UInt32(end)

                let ffiRequestAt = tDataRequestPtr.transactions_involving_address.request_at
                let requestAt: Date? = if ffiRequestAt == -1 {
                    nil
                } else if ffiRequestAt >= 0 {
                    Date(timeIntervalSince1970: TimeInterval(ffiRequestAt))
                } else {
                    throw ZcashError.rustTransactionDataRequests("Invalid request_at")
                }

                let ffiTxStatusFilter = tDataRequestPtr.transactions_involving_address.tx_status_filter
                let txStatusFilter = if ffiTxStatusFilter == TransactionStatusFilter_Mined {
                    TransactionStatusFilter.mined
                } else if ffiTxStatusFilter == TransactionStatusFilter_Mempool {
                    TransactionStatusFilter.mempool
                } else if ffiTxStatusFilter == TransactionStatusFilter_All {
                    TransactionStatusFilter.all
                } else {
                    throw ZcashError.rustTransactionDataRequests("Invalid tx_status_filter")
                }

                let ffiOutputStatusFilter = tDataRequestPtr.transactions_involving_address.output_status_filter
                let outputStatusFilter = if ffiOutputStatusFilter == OutputStatusFilter_Unspent {
                    OutputStatusFilter.unspent
                } else if ffiOutputStatusFilter == OutputStatusFilter_All {
                    OutputStatusFilter.all
                } else {
                    throw ZcashError.rustTransactionDataRequests("Invalid output_status_filter")
                }

                tDataRequest = TransactionDataRequest.transactionsInvolvingAddress(
                    TransactionsInvolvingAddress(
                        address: address,
                        blockRangeStart: tDataRequestPtr.transactions_involving_address.block_range_start,
                        blockRangeEnd: blockRangeEnd,
                        requestAt: requestAt,
                        txStatusFilter: txStatusFilter,
                        outputStatusFilter: outputStatusFilter
                    )
                )
            }

            if let tDataRequest {
                transactionDataRequests.append(tDataRequest)
            }
        }

        return transactionDataRequests
    }

    @DBActor
    func setTransactionStatus(txId: Data, status: TransactionStatus) async throws {
        var transactionStatus = FfiTransactionStatus()

        switch status {
        case .txidNotRecognized:
            transactionStatus.tag = 0
        case .notInMainChain:
            transactionStatus.tag = 1
        case .mined(let height):
            transactionStatus.tag = 2
            transactionStatus.mined = UInt32(height)
        }

        zcashlc_set_transaction_status(
            dbData.0,
            dbData.1,
            networkType.networkId,
            txId.bytes,
            UInt(txId.bytes.count),
            transactionStatus
        )
    }

    @DBActor
    func fixWitnesses() async {
        zcashlc_fix_witnesses(dbData.0, dbData.1, networkType.networkId)
    }

    @DBActor
    func getSingleUseTransparentAddress(accountUUID: AccountUUID) async throws -> SingleUseTransparentAddress {
        let singleUseTaddrPtr = zcashlc_get_single_use_taddr(
            dbData.0,
            dbData.1,
            networkType.networkId,
            accountUUID.id
        )

        guard let singleUseTaddrPtr else {
            throw ZcashError.rustGetSingleUseTransparentAddress(
                lastErrorMessage(fallback: "`getSingleUseTransparentAddress` failed with unknown error")
            )
        }

        defer { zcashlc_free_single_use_taddr(singleUseTaddrPtr) }

        return SingleUseTransparentAddress(
            address: String(cString: singleUseTaddrPtr.pointee.address),
            gapPosition: singleUseTaddrPtr.pointee.gap_position,
            gapLimit: singleUseTaddrPtr.pointee.gap_limit
        )
    }

    @DBActor
    func deleteAccount(_ accountUUID: AccountUUID) async throws {
        let success = zcashlc_delete_account(
            dbData.0,
            dbData.1,
            networkType.networkId,
            accountUUID.id
        )

        guard success else {
            throw ZcashError.rustDeleteAccount(
                lastErrorMessage(fallback: "`deleteAccount` failed with unknown error")
            )
        }
    }

    // MARK: - Ironwood migration

    @DBActor
    func migrationState(for account: AccountUUID) async throws -> MigrationState {
        let statePtr = zcashlc_migration_state(
            dbData.0,
            dbData.1,
            account.id,
            networkType.networkId
        )

        guard let statePtr else {
            throw ZcashError.rustMigrationState(lastErrorMessage(fallback: "`migrationState` failed with unknown error"))
        }

        defer { zcashlc_free_migration_state(statePtr) }

        guard let state = statePtr.pointee.unsafeToMigrationState() else {
            throw ZcashError.rustMigrationState(lastErrorMessage(fallback: "`migrationState` returned a malformed state"))
        }

        return state
    }

    @DBActor
    func migrationProgress(for account: AccountUUID) async throws -> MigrationProgress? {
        let progressPtr = zcashlc_migration_progress(
            dbData.0,
            dbData.1,
            account.id,
            networkType.networkId
        )

        guard let progressPtr else {
            throw ZcashError.rustMigrationProgress(lastErrorMessage(fallback: "`migrationProgress` failed with unknown error"))
        }

        defer { zcashlc_free_migration_progress(progressPtr) }

        return progressPtr.pointee.unsafeToMigrationProgress()
    }

    @DBActor
    func migrationTransactionStatuses(for account: AccountUUID) async throws -> [MigrationTransactionStatus] {
        let statusesPtr = zcashlc_migration_transaction_statuses(
            dbData.0,
            dbData.1,
            account.id,
            networkType.networkId
        )

        guard let statusesPtr else {
            throw ZcashError.rustMigrationTransactionStatuses(
                lastErrorMessage(fallback: "`migrationTransactionStatuses` failed with unknown error")
            )
        }

        defer { zcashlc_free_migration_transaction_statuses(statusesPtr) }

        guard let statuses = statusesPtr.pointee.unsafeToMigrationTransactionStatuses() else {
            throw ZcashError.rustMigrationTransactionStatuses(
                lastErrorMessage(fallback: "`migrationTransactionStatuses` returned malformed data")
            )
        }

        return statuses
    }

    @DBActor
    func migrationIsNoteSplitNeeded(for account: AccountUUID) async throws -> Bool {
        // Clear any stale, unconsumed last-error left by an earlier producer before reading this
        // ambiguous-bool sentinel: thread-local `LAST_ERROR` is never cleared on success, only when
        // read via `lastErrorMessage`, so a leftover error here would misfire the check below on
        // this call's own legitimate `false`.
        zcashlc_clear_last_error()

        let needed = zcashlc_migration_is_note_split_needed(
            dbData.0,
            dbData.1,
            account.id,
            networkType.networkId
        )

        // `false` overloads "legitimately not needed" and "error" (see `zcashlc_last_error_message`);
        // only a recorded last-error distinguishes the two.
        if !needed, zcashlc_last_error_length() > 0 {
            throw ZcashError.rustMigrationIsNoteSplitNeeded(
                lastErrorMessage(fallback: "`migrationIsNoteSplitNeeded` failed with unknown error")
            )
        }

        return needed
    }

    @DBActor
    func migrationHasOverdueTransfers(for account: AccountUUID) async throws -> Bool {
        // Clear any stale, unconsumed last-error before this sentinel read (see
        // `migrationIsNoteSplitNeeded` above).
        zcashlc_clear_last_error()

        let hasOverdue = zcashlc_migration_has_overdue_transfers(
            dbData.0,
            dbData.1,
            account.id,
            networkType.networkId
        )

        // `false` overloads "legitimately none overdue" and "error"; check last-error to disambiguate.
        if !hasOverdue, zcashlc_last_error_length() > 0 {
            throw ZcashError.rustMigrationHasOverdueTransfers(
                lastErrorMessage(fallback: "`migrationHasOverdueTransfers` failed with unknown error")
            )
        }

        return hasOverdue
    }

    @DBActor
    func migrationHasInvalidTransfers(for account: AccountUUID) async throws -> Bool {
        // Clear any stale, unconsumed last-error before this sentinel read (see
        // `migrationIsNoteSplitNeeded` above).
        zcashlc_clear_last_error()

        let hasInvalid = zcashlc_migration_has_invalid_transfers(
            dbData.0,
            dbData.1,
            account.id,
            networkType.networkId
        )

        // `false` overloads "legitimately none invalid" and "error"; check last-error to disambiguate.
        if !hasInvalid, zcashlc_last_error_length() > 0 {
            throw ZcashError.rustMigrationHasInvalidTransfers(
                lastErrorMessage(fallback: "`migrationHasInvalidTransfers` failed with unknown error")
            )
        }

        return hasInvalid
    }

    @DBActor
    func migrationPrepareNoteSplit(for account: AccountUUID) async throws -> NoteSplitProposal {
        let proposalPtr = zcashlc_migration_prepare_note_split(
            dbData.0,
            dbData.1,
            account.id,
            networkType.networkId
        )

        guard let proposalPtr else {
            throw ZcashError.rustMigrationPrepareNoteSplit(
                lastErrorMessage(fallback: "`migrationPrepareNoteSplit` failed with unknown error")
            )
        }

        defer { zcashlc_free_migration_note_split_proposal(proposalPtr) }

        return proposalPtr.pointee.toNoteSplitProposal()
    }

    /// Routes the rust layer's stable error prefixes to their dedicated `ZcashError` cases:
    /// `MIGRATION_PLAN_STALE` -> `.migrationPlanStale` (re-propose) and
    /// `MIGRATION_PROVING_UNAVAILABLE` -> `.migrationProvingUnavailable` (proving failed hard).
    /// Anything else falls back to the member's own case.
    nonisolated private func migrationRoutedError(_ message: String, fallback: (String) -> ZcashError) -> ZcashError {
        if message.hasPrefix("MIGRATION_PLAN_STALE") {
            return .migrationPlanStale
        }
        if message.hasPrefix("MIGRATION_PROVING_UNAVAILABLE") {
            return .migrationProvingUnavailable(message)
        }
        return fallback(message)
    }

    @DBActor
    func migrationResidualAfterMigration(for account: AccountUUID) async throws -> Zatoshi? {
        // Clear any stale, unconsumed last-error before this sentinel read (see
        // `migrationIsNoteSplitNeeded` above).
        zcashlc_clear_last_error()

        let residual = zcashlc_migration_residual_after_migration(
            dbData.0,
            dbData.1,
            account.id,
            networkType.networkId
        )

        // `-1` overloads "legitimately no residual" and "error"; check last-error to disambiguate.
        if residual < 0 {
            if zcashlc_last_error_length() > 0 {
                throw ZcashError.rustMigrationResidualAfterMigration(
                    lastErrorMessage(fallback: "`migrationResidualAfterMigration` failed with unknown error")
                )
            }

            return nil
        }

        return Zatoshi(residual)
    }

    @DBActor
    func lockMigrationResidual(accountUUID: AccountUUID) async throws -> Zatoshi {
        let locked = zcashlc_migration_lock_residual(
            dbData.0,
            dbData.1,
            accountUUID.id,
            networkType.networkId
        )

        // Unlike the ambiguous sentinels above, `-1` here means only "error": `0` is the
        // legitimate "nothing was spendable" answer, so no last-error disambiguation is needed.
        guard locked >= 0 else {
            throw ZcashError.rustMigrationLockResidual(
                lastErrorMessage(fallback: "`lockMigrationResidual` failed with unknown error")
            )
        }

        return Zatoshi(locked)
    }

    @DBActor
    func unlockMigrationResidual(accountUUID: AccountUUID) async throws -> Int {
        let unlocked = zcashlc_migration_unlock_residual(
            dbData.0,
            dbData.1,
            accountUUID.id,
            networkType.networkId
        )

        // `-1` means only "error" (`0` is the legitimate "nothing was locked" answer).
        guard unlocked >= 0 else {
            throw ZcashError.rustMigrationUnlockResidual(
                lastErrorMessage(fallback: "`unlockMigrationResidual` failed with unknown error")
            )
        }

        return Int(unlocked)
    }

    @DBActor
    func estimateMigrationRuns(accountUUID: AccountUUID) async throws -> MigrationRunEstimate {
        let estimatePtr = zcashlc_migration_estimate_runs(
            dbData.0,
            dbData.1,
            accountUUID.id,
            networkType.networkId
        )

        guard let estimatePtr else {
            throw ZcashError.rustMigrationEstimateRuns(
                lastErrorMessage(fallback: "`estimateMigrationRuns` failed with unknown error")
            )
        }

        defer { zcashlc_free_migration_run_estimate(estimatePtr) }

        return estimatePtr.pointee.toMigrationRunEstimate()
    }

    @DBActor
    func migrationProposeTransfers(for account: AccountUUID) async throws -> MigrationSchedule {
        let schedulePtr = zcashlc_migration_propose_transfers(
            dbData.0,
            dbData.1,
            account.id,
            networkType.networkId
        )

        guard let schedulePtr else {
            throw ZcashError.rustMigrationProposeTransfers(
                lastErrorMessage(fallback: "`migrationProposeTransfers` failed with unknown error")
            )
        }

        defer { zcashlc_free_migration_schedule(schedulePtr) }

        guard let schedule = schedulePtr.pointee.unsafeToMigrationSchedule() else {
            throw ZcashError.rustMigrationProposeTransfers(
                lastErrorMessage(fallback: "`migrationProposeTransfers` returned a malformed schedule")
            )
        }

        return schedule
    }

    // MARK: - Rust-owned migration delivery runtime

    @DBActor
    func migrationRuntimeSnapshot(for account: AccountUUID) async throws -> MigrationRuntimeSnapshot {
        let snapshotPtr = zcashlc_migration_runtime_snapshot_v1(
            dbData.0,
            dbData.1,
            account.id,
            networkType.networkId
        )
        guard let snapshotPtr else {
            throw migrationDeliveryError("migrationRuntimeSnapshot")
        }
        defer { zcashlc_free_migration_runtime_snapshot_v1(snapshotPtr) }
        return try decodeMigrationRuntimeSnapshot(snapshotPtr.pointee)
    }

    @DBActor
    func migrationRuntimeSnapshots() async throws -> [MigrationRuntimeSnapshot] {
        let batchPtr = zcashlc_migration_runtime_batch_v1(dbData.0, dbData.1, networkType.networkId)
        guard let batchPtr else {
            throw migrationDeliveryError("migrationRuntimeSnapshots")
        }
        defer { zcashlc_free_migration_runtime_batch_v1(batchPtr) }

        let batch = batchPtr.pointee
        guard batch.abi_version == 1 else {
            throw malformedMigrationDelivery("unsupported runtime ABI version \(batch.abi_version)")
        }
        if batch.accounts_len == 0 {
            return []
        }
        guard let accounts = batch.accounts else {
            throw malformedMigrationDelivery("runtime batch omitted its account array")
        }
        return try (0 ..< Int(batch.accounts_len)).map {
            try decodeMigrationRuntimeSnapshot(accounts.advanced(by: $0).pointee)
        }
    }

    @DBActor
    func migrationBindSubmissionPolicy(
        _ intent: MigrationSubmissionIntent,
        run: MigrationRunHandle,
        for account: AccountUUID
    ) async throws -> MigrationRunHandle {
        let endpoint = intent.endpoint.utf8CString
        let pointer = endpoint.withUnsafeBufferPointer { endpoint in
            zcashlc_migration_bind_submission_policy_v1(
                dbData.0,
                dbData.1,
                account.id,
                networkType.networkId,
                run.pointer,
                migrationTransportTag(intent.transport),
                endpoint.baseAddress
            )
        }
        return try ownedMigrationRun(pointer, operation: "migrationBindSubmissionPolicy")
    }

    func migrationBoundSubmissionTarget(for run: MigrationRunHandle) async throws -> MigrationBoundSubmissionTarget? {
        zcashlc_clear_last_error()
        let transportTag = zcashlc_migration_run_submission_transport_v1(run.pointer)
        guard transportTag >= 0 else {
            if zcashlc_last_error_length() > 0 {
                throw migrationDeliveryError("migrationBoundSubmissionTarget")
            }
            return nil
        }
        guard let transport = migrationTransport(tag: transportTag) else {
            throw malformedMigrationDelivery("unknown bound submission transport tag \(transportTag)")
        }

        let endpointPtr = zcashlc_migration_run_submission_endpoint_v1(run.pointer)
        guard let endpointPtr else {
            throw migrationDeliveryError("migrationBoundSubmissionTarget")
        }
        defer { zcashlc_free_boxed_slice(endpointPtr) }
        guard let bytes = endpointPtr.pointee.ptr, endpointPtr.pointee.len > 0 else {
            throw malformedMigrationDelivery("bound submission policy omitted its endpoint")
        }
        let endpointData = Data(bytes: bytes, count: Int(endpointPtr.pointee.len))
        guard let endpoint = String(data: endpointData, encoding: .utf8) else {
            throw malformedMigrationDelivery("bound submission endpoint was not UTF-8")
        }
        return MigrationBoundSubmissionTarget(transport: transport, endpoint: endpoint)
    }

    @DBActor
    func migrationReserveImmediate(
        signer: MigrationSignerOwnership,
        submission: MigrationSubmissionIntent,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle {
        let endpoint = submission.endpoint.utf8CString
        let pointer = endpoint.withUnsafeBufferPointer { endpoint in
            zcashlc_migration_reserve_immediate_v1(
                dbData.0,
                dbData.1,
                account.id,
                networkType.networkId,
                migrationSignerTag(signer),
                migrationTransportTag(submission.transport),
                endpoint.baseAddress
            )
        }
        return try ownedMigrationClaim(pointer, operation: "migrationReserveImmediate")
    }

    @DBActor
    func migrationMaterializeImmediateSDK(
        claim: MigrationClaimHandle,
        usk: UnifiedSpendingKey,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle {
        let pointer = usk.bytes.withUnsafeBufferPointer { uskBytes in
            zcashlc_migration_materialize_immediate_sdk_v1(
                dbData.0,
                dbData.1,
                account.id,
                networkType.networkId,
                claim.pointer,
                uskBytes.baseAddress,
                UInt(uskBytes.count),
                spendParamsPath.0,
                spendParamsPath.1,
                outputParamsPath.0,
                outputParamsPath.1
            )
        }
        return try ownedMigrationClaim(pointer, operation: "migrationMaterializeImmediateSDK")
    }

    @DBActor
    func migrationPrepareImmediateExternalSigning(
        claim: MigrationClaimHandle,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle {
        try ownedMigrationClaim(
            zcashlc_migration_prepare_immediate_external_signing_v1(
                dbData.0,
                dbData.1,
                account.id,
                networkType.networkId,
                claim.pointer
            ),
            operation: "migrationPrepareImmediateExternalSigning"
        )
    }

    @DBActor
    func migrationFinalizeImmediateExternalSigning(
        claim: MigrationClaimHandle,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle {
        try ownedMigrationClaim(
            zcashlc_migration_finalize_immediate_external_signing_v1(
                dbData.0,
                dbData.1,
                account.id,
                networkType.networkId,
                claim.pointer
            ),
            operation: "migrationFinalizeImmediateExternalSigning"
        )
    }

    @DBActor
    func migrationCommitExternalSchedule(
        _ schedule: MigrationSchedule,
        for account: AccountUUID
    ) async throws -> MigrationRunHandle {
        let pointer = zcashlc_migration_commit_external_schedule_v1(
            dbData.0,
            dbData.1,
            account.id,
            networkType.networkId,
            schedule.proposalHandle
        )
        return try ownedMigrationRun(pointer, operation: "migrationCommitExternalSchedule")
    }

    @DBActor
    func migrationRolloverInternalSchedule(
        _ schedule: MigrationSchedule,
        predecessor: MigrationRunHandle,
        usk: UnifiedSpendingKey,
        for account: AccountUUID
    ) async throws -> MigrationRunHandle {
        let pointer = zcashlc_migration_rollover_internal_schedule_v1(
            dbData.0,
            dbData.1,
            account.id,
            networkType.networkId,
            predecessor.pointer,
            schedule.proposalHandle,
            usk.bytes,
            UInt(usk.bytes.count)
        )
        return try ownedMigrationRun(pointer, operation: "migrationRolloverInternalSchedule")
    }

    @DBActor
    func migrationRolloverExternalSchedule(
        _ schedule: MigrationSchedule,
        predecessor: MigrationRunHandle,
        for account: AccountUUID
    ) async throws -> MigrationRunHandle {
        let pointer = zcashlc_migration_rollover_external_schedule_v1(
            dbData.0,
            dbData.1,
            account.id,
            networkType.networkId,
            predecessor.pointer,
            schedule.proposalHandle
        )
        return try ownedMigrationRun(pointer, operation: "migrationRolloverExternalSchedule")
    }

    @DBActor
    func migrationClaimMaterialization(
        transactionID: UInt32,
        signer: MigrationSignerOwnership,
        run: MigrationRunHandle,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle? {
        zcashlc_clear_last_error()
        let pointer = zcashlc_migration_claim_materialization_v1(
            dbData.0,
            dbData.1,
            account.id,
            networkType.networkId,
            run.pointer,
            transactionID,
            migrationSignerTag(signer)
        )
        return try optionalOwnedMigrationClaim(pointer, operation: "migrationClaimMaterialization")
    }

    @DBActor
    func migrationStageExternalSigningPCZT(
        claim: MigrationClaimHandle,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle {
        let pointer = zcashlc_migration_stage_external_signing_pczt_v1(
            dbData.0,
            dbData.1,
            account.id,
            networkType.networkId,
            claim.pointer,
            nil,
            0
        )
        return try ownedMigrationClaim(pointer, operation: "migrationStageExternalSigningPCZT")
    }

    @DBActor
    func migrationStageSignedPCZT(
        _ signedPCZT: Data,
        claim: MigrationClaimHandle,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle {
        let pointer = signedPCZT.withUnsafeBytes { bytes in
            zcashlc_migration_stage_signed_pczt_v1(
                dbData.0,
                dbData.1,
                account.id,
                networkType.networkId,
                claim.pointer,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                UInt(bytes.count)
            )
        }
        return try ownedMigrationClaim(pointer, operation: "migrationStageSignedPCZT")
    }

    @DBActor
    func migrationAdvanceExternalSignature(
        claim: MigrationClaimHandle,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle {
        try ownedMigrationClaim(
            zcashlc_migration_advance_external_signature_v1(
                dbData.0, dbData.1, account.id, networkType.networkId, claim.pointer
            ),
            operation: "migrationAdvanceExternalSignature"
        )
    }

    @DBActor
    func migrationProveClaim(
        claim: MigrationClaimHandle,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle {
        try ownedMigrationClaim(
            zcashlc_migration_prove_claim_v1(
                dbData.0, dbData.1, account.id, networkType.networkId, claim.pointer
            ),
            operation: "migrationProveClaim"
        )
    }

    @DBActor
    func migrationClaimSubmission(
        claim: MigrationClaimHandle,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle? {
        zcashlc_clear_last_error()
        return try optionalOwnedMigrationClaim(
            zcashlc_migration_claim_submission_v1(
                dbData.0, dbData.1, account.id, networkType.networkId, claim.pointer
            ),
            operation: "migrationClaimSubmission"
        )
    }

    @DBActor
    func migrationClaimOutcomeResolution(
        claim: MigrationClaimHandle,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle? {
        zcashlc_clear_last_error()
        return try optionalOwnedMigrationClaim(
            zcashlc_migration_claim_outcome_resolution_v1(
                dbData.0, dbData.1, account.id, networkType.networkId, claim.pointer
            ),
            operation: "migrationClaimOutcomeResolution"
        )
    }

    @DBActor
    func migrationResumeClaim(
        claim: MigrationClaimHandle,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle? {
        zcashlc_clear_last_error()
        return try optionalOwnedMigrationClaim(
            zcashlc_migration_resume_claim_v1(
                dbData.0, dbData.1, account.id, networkType.networkId, claim.pointer
            ),
            operation: "migrationResumeClaim"
        )
    }

    @DBActor
    func migrationReacquireExternalSigning(
        claim: MigrationClaimHandle,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle? {
        zcashlc_clear_last_error()
        return try optionalOwnedMigrationClaim(
            zcashlc_migration_reacquire_external_signing_v1(
                dbData.0, dbData.1, account.id, networkType.networkId, claim.pointer
            ),
            operation: "migrationReacquireExternalSigning"
        )
    }

    @DBActor
    func migrationRenewClaim(
        claim: MigrationClaimHandle,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle? {
        zcashlc_clear_last_error()
        return try optionalOwnedMigrationClaim(
            zcashlc_migration_renew_claim_v1(
                dbData.0, dbData.1, account.id, networkType.networkId, claim.pointer
            ),
            operation: "migrationRenewClaim"
        )
    }

    @DBActor
    func migrationRecordSubmissionOutcome(
        _ outcome: MigrationSubmissionOutcome,
        claim: MigrationClaimHandle,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle {
        try ownedMigrationClaim(
            zcashlc_migration_record_submission_outcome_v1(
                dbData.0,
                dbData.1,
                account.id,
                networkType.networkId,
                claim.pointer,
                migrationSubmissionOutcomeTag(outcome)
            ),
            operation: "migrationRecordSubmissionOutcome"
        )
    }

    @DBActor
    func migrationReconcileSubmission(
        claim: MigrationClaimHandle,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle {
        try ownedMigrationClaim(
            zcashlc_migration_reconcile_submission_v1(
                dbData.0, dbData.1, account.id, networkType.networkId, claim.pointer
            ),
            operation: "migrationReconcileSubmission"
        )
    }

    @DBActor
    func migrationReconcileCanonicalChain(
        run: MigrationRunHandle,
        for account: AccountUUID
    ) async throws -> MigrationRunHandle {
        try ownedMigrationRun(
            zcashlc_migration_reconcile_canonical_chain_v1(
                dbData.0, dbData.1, account.id, networkType.networkId, run.pointer
            ),
            operation: "migrationReconcileCanonicalChain"
        )
    }

    @DBActor
    func migrationReleaseKnownUnsentClaim(
        claim: MigrationClaimHandle,
        failure: MigrationDeliveryFailureReason,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle {
        try ownedMigrationClaim(
            zcashlc_migration_release_claim_known_unsent_v1(
                dbData.0,
                dbData.1,
                account.id,
                networkType.networkId,
                claim.pointer,
                migrationDeliveryFailureTag(failure)
            ),
            operation: "migrationReleaseKnownUnsentClaim"
        )
    }

    @DBActor
    func migrationRebuildExpiredTransfer(
        claim: MigrationClaimHandle,
        signer: MigrationSignerOwnership,
        usk: UnifiedSpendingKey?,
        for account: AccountUUID
    ) async throws -> MigrationClaimHandle {
        let pointer: OpaquePointer?
        switch signer {
        case .sdk:
            guard let usk else {
                throw malformedMigrationDelivery("SDK expired-transfer rebuild requires a spending key")
            }
            pointer = zcashlc_migration_rebuild_expired_transfer_v1(
                dbData.0,
                dbData.1,
                account.id,
                networkType.networkId,
                claim.pointer,
                migrationSignerTag(signer),
                usk.bytes,
                UInt(usk.bytes.count)
            )
        case .external:
            guard usk == nil else {
                throw malformedMigrationDelivery("external expired-transfer rebuild rejects a spending key")
            }
            pointer = zcashlc_migration_rebuild_expired_transfer_v1(
                dbData.0,
                dbData.1,
                account.id,
                networkType.networkId,
                claim.pointer,
                migrationSignerTag(signer),
                nil,
                0
            )
        }
        return try ownedMigrationClaim(pointer, operation: "migrationRebuildExpiredTransfer")
    }

    @DBActor
    func migrationPauseDelivery(
        run: MigrationRunHandle,
        for account: AccountUUID
    ) async throws -> MigrationRunHandle {
        try migrationRunTransition(run, account: account, operation: "migrationPauseDelivery") {
            zcashlc_migration_pause_delivery_v1(dbData.0, dbData.1, account.id, networkType.networkId, $0)
        }
    }

    @DBActor
    func migrationResumeDelivery(
        run: MigrationRunHandle,
        for account: AccountUUID
    ) async throws -> MigrationRunHandle {
        try migrationRunTransition(run, account: account, operation: "migrationResumeDelivery") {
            zcashlc_migration_resume_delivery_v1(dbData.0, dbData.1, account.id, networkType.networkId, $0)
        }
    }

    @DBActor
    func migrationBeginAbandonment(
        run: MigrationRunHandle,
        for account: AccountUUID
    ) async throws -> MigrationRunHandle {
        try migrationRunTransition(run, account: account, operation: "migrationBeginAbandonment") {
            zcashlc_migration_begin_abandonment_v1(dbData.0, dbData.1, account.id, networkType.networkId, $0)
        }
    }

    @DBActor
    func migrationFinishAbandonment(
        run: MigrationRunHandle,
        for account: AccountUUID
    ) async throws -> MigrationRunHandle {
        try migrationRunTransition(run, account: account, operation: "migrationFinishAbandonment") {
            zcashlc_migration_finish_abandonment_v1(dbData.0, dbData.1, account.id, networkType.networkId, $0)
        }
    }

    func migrationClaimRun(_ claim: MigrationClaimHandle) async throws -> MigrationRunHandle {
        try ownedMigrationRun(
            zcashlc_migration_claim_run_handle_v1(claim.pointer),
            operation: "migrationClaimRun"
        )
    }

    func migrationClaimProposal(_ claim: MigrationClaimHandle) async throws -> Data? {
        try migrationClaimBytes(claim, operation: "migrationClaimProposal", zcashlc_migration_claim_proposal_v1)
    }

    func migrationClaimExternalSigningPCZT(_ claim: MigrationClaimHandle) async throws -> Data? {
        try migrationClaimBytes(
            claim,
            operation: "migrationClaimExternalSigningPCZT",
            zcashlc_migration_claim_external_signing_pczt_v1
        )
    }

    func migrationClaimSignedPCZT(_ claim: MigrationClaimHandle) async throws -> Data? {
        try migrationClaimBytes(claim, operation: "migrationClaimSignedPCZT", zcashlc_migration_claim_signed_pczt_v1)
    }

    func migrationClaimExactTransaction(_ claim: MigrationClaimHandle) async throws -> Data? {
        try migrationClaimBytes(
            claim,
            operation: "migrationClaimExactTransaction",
            zcashlc_migration_claim_exact_transaction_v1
        )
    }

    func migrationClaimTransactionID(_ claim: MigrationClaimHandle) async throws -> Data? {
        let txid = try migrationClaimBytes(claim, operation: "migrationClaimTransactionID", zcashlc_migration_claim_txid_v1)
        guard txid == nil || txid?.count == 32 else {
            throw malformedMigrationDelivery("migration transaction id was not 32 bytes")
        }
        return txid
    }

    func migrationClaimStatus(_ claim: MigrationClaimHandle) async throws -> MigrationDeliveryClaimStatus {
        zcashlc_clear_last_error()
        let tag = zcashlc_migration_claim_status_v1(claim.pointer)
        guard tag >= 0, let status = decodeMigrationClaimStatus(tag: UInt8(tag)) else {
            if zcashlc_last_error_length() > 0 {
                throw migrationDeliveryError("migrationClaimStatus")
            }
            throw malformedMigrationDelivery("unknown claim status tag \(tag)")
        }
        return status
    }

    func migrationClaimExpiryHeight(_ claim: MigrationClaimHandle) async throws -> BlockHeight {
        zcashlc_clear_last_error()
        let height = zcashlc_migration_claim_expiry_height_v1(claim.pointer)
        guard height >= 0, let decoded = BlockHeight(exactly: height) else {
            if zcashlc_last_error_length() > 0 {
                throw migrationDeliveryError("migrationClaimExpiryHeight")
            }
            throw malformedMigrationDelivery("invalid migration expiry height \(height)")
        }
        return decoded
    }

    func migrationClaimConsensusBranchID(_ claim: MigrationClaimHandle) async throws -> UInt32 {
        zcashlc_clear_last_error()
        let branchID = zcashlc_migration_claim_consensus_branch_id_v1(claim.pointer)
        guard branchID >= 0, let decoded = UInt32(exactly: branchID) else {
            if zcashlc_last_error_length() > 0 {
                throw migrationDeliveryError("migrationClaimConsensusBranchID")
            }
            throw malformedMigrationDelivery("invalid migration consensus branch id \(branchID)")
        }
        return decoded
    }

    private func migrationRunTransition(
        _ run: MigrationRunHandle,
        account: AccountUUID,
        operation: String,
        _ transition: (OpaquePointer) -> OpaquePointer?
    ) throws -> MigrationRunHandle {
        try ownedMigrationRun(transition(run.pointer), operation: operation)
    }

    private func migrationClaimBytes(
        _ claim: MigrationClaimHandle,
        operation: String,
        _ accessor: (OpaquePointer) -> UnsafeMutablePointer<FfiBoxedSlice>?
    ) throws -> Data? {
        zcashlc_clear_last_error()
        guard let pointer = accessor(claim.pointer) else {
            throw migrationDeliveryError(operation)
        }
        defer { zcashlc_free_boxed_slice(pointer) }
        let slice = pointer.pointee
        guard let bytes = slice.ptr else {
            guard slice.len == 0 else {
                throw malformedMigrationDelivery("\(operation) returned a null non-empty slice")
            }
            return nil
        }
        return Data(bytes: bytes, count: Int(slice.len))
    }

    private func optionalOwnedMigrationClaim(
        _ pointer: OpaquePointer?,
        operation: String
    ) throws -> MigrationClaimHandle? {
        guard let pointer else {
            if zcashlc_last_error_length() > 0 {
                throw migrationDeliveryError(operation)
            }
            return nil
        }
        return try ownedMigrationClaim(pointer, operation: operation)
    }

    private func ownedMigrationRun(_ pointer: OpaquePointer?, operation: String) throws -> MigrationRunHandle {
        guard let pointer else {
            throw migrationDeliveryError(operation)
        }
        return MigrationRunHandle(
            storage: MigrationOpaqueHandleStorage(pointer: pointer) {
                zcashlc_migration_free_run_handle_v1($0)
            }
        )
    }

    private func ownedMigrationClaim(_ pointer: OpaquePointer?, operation: String) throws -> MigrationClaimHandle {
        guard let pointer else {
            throw migrationDeliveryError(operation)
        }
        return MigrationClaimHandle(
            storage: MigrationOpaqueHandleStorage(pointer: pointer) {
                zcashlc_migration_free_claim_handle_v1($0)
            }
        )
    }

    private func migrationDeliveryError(_ operation: String) -> ZcashError {
        .rustMigrationDelivery(lastErrorMessage(fallback: "`\(operation)` failed with unknown error"))
    }

    private func malformedMigrationDelivery(_ message: String) -> ZcashError {
        .rustMigrationDelivery("Malformed Rust migration delivery value: \(message)")
    }

    @DBActor
    func proposeSendMaxTransfer(
        accountUUID: AccountUUID,
        recipient: String,
        memo: MemoBytes?,
        orchardOnly: Bool
    ) async throws -> FfiProposal {
        let proposal = zcashlc_propose_send_max_transfer(
            dbData.0,
            dbData.1,
            networkType.networkId,
            accountUUID.id,
            [CChar](recipient.utf8CString),
            memo?.bytes,
            MaxSpendable,
            confirmationsPolicy.toBackend(),
            orchardOnly
        )

        guard let proposal else {
            throw ZcashError.rustProposeSendMaxTransfer(lastErrorMessage(fallback: "`proposeSendMaxTransfer` failed with unknown error"))
        }

        defer { zcashlc_free_boxed_slice(proposal) }

        return try FfiProposal(serializedBytes: Data(
            bytes: proposal.pointee.ptr,
            count: Int(proposal.pointee.len)
        ))
    }

    @DBActor
    func migrationSignAndStoreSchedule(
        _ schedule: MigrationSchedule,
        usk: UnifiedSpendingKey,
        for account: AccountUUID
    ) async throws {
        let success = zcashlc_migration_sign_and_store_schedule(
            dbData.0,
            dbData.1,
            account.id,
            networkType.networkId,
            schedule.proposalHandle,
            usk.bytes,
            UInt(usk.bytes.count)
        )

        guard success else {
            throw migrationRoutedError(
                lastErrorMessage(fallback: "`migrationSignAndStoreSchedule` failed with unknown error"),
                fallback: ZcashError.rustMigrationSignAndStoreSchedule
            )
        }
    }

    @DBActor
    func migrationPendingTransferProposal(for account: AccountUUID) async throws -> MigrationTransferProposal? {
        // Clear any stale, unconsumed last-error before this sentinel read (see
        // `migrationIsNoteSplitNeeded` above). Added alongside the pointer-sentinel accessor itself,
        // which follows the same ambiguous-sentinel pattern as the five bool/`-1` wrappers.
        zcashlc_clear_last_error()

        let proposalPtr = zcashlc_migration_pending_transfer_proposal(
            dbData.0,
            dbData.1,
            account.id,
            networkType.networkId
        )

        // A NULL pointer overloads "legitimately nothing pending" and "error"; check last-error to
        // disambiguate (the pointer analog of `migrationResidualAfterMigration`'s `-1` sentinel).
        guard let proposalPtr else {
            if zcashlc_last_error_length() > 0 {
                throw ZcashError.rustMigrationPendingTransferProposal(
                    lastErrorMessage(fallback: "`migrationPendingTransferProposal` failed with unknown error")
                )
            }

            return nil
        }

        defer { zcashlc_free_migration_transfer_proposal(proposalPtr) }

        return proposalPtr.pointee.unsafeToMigrationTransferProposal()
    }

    /// The NU6.3 (Ironwood) activation height for `networkType`, or `nil` when NU6.3 is unset for
    /// that network. Stateless (no db access).
    ///
    /// - Note: The underlying FFI also returns `-1` (indistinguishable from "unset") for a network
    ///   id outside `{testnet, mainnet}` (e.g. `.regtest`), and sets `zcashlc_last_error_message`
    ///   in that case. Unlike the instance methods above, this wrapper does not disambiguate the
    ///   two and always maps `-1` to `nil` — callers are expected to pass `.testnet`/`.mainnet`. It
    ///   does, however, consume/clear that last-error before returning: thread-local `LAST_ERROR` is
    ///   never cleared on its own, so leaving it set here would let it misfire an unrelated,
    ///   legitimately-`false`/`-1` sentinel read made later on the same thread.
    static func ironwoodActivationHeight(networkType: NetworkType) -> BlockHeight? {
        let height = zcashlc_ironwood_activation_height(networkType.networkId)

        guard height >= 0 else {
            // Consume/clear whatever last-error this call may have set (e.g. an unsupported network
            // id) so it cannot leak into a later, unrelated sentinel read on this thread.
            zcashlc_clear_last_error()
            return nil
        }

        return BlockHeight(height)
    }
}

private extension ZcashRustBackend {
    func decodeMigrationRuntimeSnapshot(
        _ ffi: FfiMigrationRuntimeSnapshotV1
    ) throws -> MigrationRuntimeSnapshot {
        guard ffi.abi_version == 1 else {
            throw malformedMigrationDelivery("unsupported runtime ABI version \(ffi.abi_version)")
        }

        let aggregateFinality = try migrationStorageFinality(
            tag: ffi.aggregate_storage_finality,
            recoveryTag: ffi.aggregate_storage_recovery_reason,
            releaseHeight: ffi.aggregate_delivery_release_height
        )
        let availability = try migrationAvailability(
            tag: ffi.availability,
            reasonTag: ffi.unavailable_reason,
            detail: ffi.unavailable_detail
        )
        let delivery = try ffi.has_delivery ? decodeMigrationDelivery(
            laneTag: ffi.delivery_lane,
            phaseTag: ffi.delivery_phase,
            finalityTag: ffi.storage_finality,
            recoveryTag: ffi.storage_recovery_reason,
            releaseHeight: ffi.delivery_release_height,
            activeSourceReservationCount: ffi.active_source_reservation_count,
            hasSubmissionPolicy: ffi.has_submission_policy,
            policyFailureTag: ffi.policy_validation_failure,
            safeToCancel: ffi.safe_to_cancel,
            claims: ffi.claims,
            claimsCount: ffi.claims_len,
            run: ffi.run_handle
        ) : nil

        if !ffi.has_delivery, ffi.run_handle != nil || ffi.claims_len != 0 {
            throw malformedMigrationDelivery("runtime without delivery carried current-run capabilities")
        }

        var retained: [MigrationRetainedRun] = []
        retained.reserveCapacity(Int(ffi.retained_runs_len))
        if ffi.retained_runs_len > 0 {
            guard let retainedRuns = ffi.retained_runs else {
                throw malformedMigrationDelivery("runtime omitted retained-run storage")
            }
            for index in 0 ..< Int(ffi.retained_runs_len) {
                retained.append(try decodeRetainedMigrationRun(retainedRuns.advanced(by: index).pointee))
            }
        }

        return MigrationRuntimeSnapshot(
            account: AccountUUID(id: ffiInlineBytes(ffi.account_uuid)),
            canonical: try migrationCanonicalSummary(
                hasState: ffi.canonical_status >= 0,
                statusTag: ffi.canonical_status,
                transactionCount: ffi.canonical_transaction_count
            ),
            schemaProvenance: try migrationSchemaProvenance(
                tag: ffi.schema_provenance,
                version: ffi.schema_version
            ),
            legacyCutover: try migrationLegacyCutover(
                tag: ffi.legacy_cutover,
                objects: ffi.legacy_object_count
            ),
            destinationSpendability: try migrationDestinationSpendability(tag: ffi.destination_spendability),
            availability: availability,
            ordinarySpendAuthorization: try migrationOrdinarySpendAuthorization(
                tag: ffi.ordinary_spend_authorization,
                reasonTag: ffi.ordinary_spend_block_reason,
                releaseHeight: ffi.ordinary_spend_release_height,
                availability: availability,
                aggregateFinality: aggregateFinality
            ),
            accountDeletionAuthorization: try migrationAccountDeletionAuthorization(
                tag: ffi.account_deletion_authorization,
                reasonTag: ffi.account_deletion_block_reason
            ),
            canonicalMutationAuthorization: try migrationCanonicalMutationAuthorization(
                tag: ffi.canonical_mutation_authorization,
                reasonTag: ffi.canonical_mutation_block_reason
            ),
            aggregateStorageFinality: aggregateFinality,
            delivery: delivery,
            retainedRuns: retained
        )
    }

    func decodeRetainedMigrationRun(_ ffi: FfiRetainedMigrationRunV1) throws -> MigrationRetainedRun {
        MigrationRetainedRun(
            canonical: try migrationCanonicalSummary(
                hasState: ffi.has_canonical_state,
                statusTag: ffi.canonical_status,
                transactionCount: ffi.canonical_transaction_count
            ),
            destinationSpendability: try migrationDestinationSpendability(tag: ffi.destination_spendability),
            delivery: try decodeMigrationDelivery(
                laneTag: Int8(ffi.delivery_lane),
                phaseTag: Int8(ffi.delivery_phase),
                finalityTag: Int8(ffi.storage_finality),
                recoveryTag: ffi.storage_recovery_reason,
                releaseHeight: ffi.delivery_release_height,
                activeSourceReservationCount: ffi.active_source_reservation_count,
                hasSubmissionPolicy: ffi.has_submission_policy,
                policyFailureTag: ffi.policy_validation_failure,
                safeToCancel: ffi.safe_to_cancel,
                claims: ffi.claims,
                claimsCount: ffi.claims_len,
                run: ffi.run_handle
            )
        )
    }

    // swiftlint:disable:next function_parameter_count
    func decodeMigrationDelivery(
        laneTag: Int8,
        phaseTag: Int8,
        finalityTag: Int8,
        recoveryTag: Int8,
        releaseHeight: Int64,
        activeSourceReservationCount: UInt64,
        hasSubmissionPolicy: Bool,
        policyFailureTag: Int8,
        safeToCancel: Bool,
        claims: UnsafeMutablePointer<FfiMigrationClaimSummaryV1>?,
        claimsCount: UInt,
        run: OpaquePointer?
    ) throws -> MigrationDeliverySnapshot {
        guard let lane = migrationDeliveryLane(tag: laneTag),
              let phase = migrationDeliveryPhase(tag: phaseTag) else {
            throw malformedMigrationDelivery("unknown delivery lane/phase tags \(laneTag)/\(phaseTag)")
        }
        let runHandle = try cloneMigrationRun(run)
        var decodedClaims: [MigrationDeliveryClaimSummary] = []
        decodedClaims.reserveCapacity(Int(claimsCount))
        if claimsCount > 0 {
            guard let claims else {
                throw malformedMigrationDelivery("delivery omitted its claim array")
            }
            for index in 0 ..< Int(claimsCount) {
                decodedClaims.append(try decodeMigrationClaim(claims.advanced(by: index).pointee))
            }
        }
        return MigrationDeliverySnapshot(
            lane: lane,
            phase: phase,
            storageFinality: try migrationStorageFinality(
                tag: finalityTag,
                recoveryTag: recoveryTag,
                releaseHeight: releaseHeight
            ),
            activeSourceReservationCount: activeSourceReservationCount,
            hasSubmissionPolicy: hasSubmissionPolicy,
            policyValidationFailure: try migrationPolicyFailure(tag: policyFailureTag),
            safeToCancel: safeToCancel,
            claims: decodedClaims,
            runHandle: runHandle
        )
    }

    func decodeMigrationClaim(_ ffi: FfiMigrationClaimSummaryV1) throws -> MigrationDeliveryClaimSummary {
        let artifact: MigrationArtifactIdentitySummary
        switch ffi.artifact_lane {
        case 0:
            guard let transactionID = UInt32(exactly: ffi.scheduled_transaction_id) else {
                throw malformedMigrationDelivery("scheduled artifact carried an invalid transaction id")
            }
            artifact = .scheduled(transactionID: transactionID)
        case 1:
            artifact = .immediate(identity: Data(ffiInlineBytes(ffi.immediate_artifact_identity)))
        default:
            throw malformedMigrationDelivery("unknown claim artifact lane \(ffi.artifact_lane)")
        }
        guard let signer = migrationSigner(tag: ffi.signer_ownership),
              let status = decodeMigrationClaimStatus(tag: ffi.status) else {
            throw malformedMigrationDelivery("unknown claim signer/status tags")
        }
        let txid = ffi.has_txid ? Data(ffiInlineBytes(ffi.txid)) : nil
        guard txid == nil || txid?.count == 32 else {
            throw malformedMigrationDelivery("claim transaction id was not 32 bytes")
        }
        return MigrationDeliveryClaimSummary(
            artifact: artifact,
            signerOwnership: signer,
            status: status,
            activeClaimKind: try migrationClaimKind(tag: ffi.claim_kind),
            externallyExposed: ffi.externally_exposed,
            hasSignedPCZT: ffi.has_signed_pczt,
            hasExactTransaction: ffi.has_exact_transaction,
            expiryHeight: BlockHeight(ffi.expiry_height),
            txid: txid,
            lastError: try migrationDeliveryFailure(tag: ffi.last_error),
            claimHandle: try cloneMigrationClaim(ffi.claim_handle)
        )
    }

    func cloneMigrationRun(_ pointer: OpaquePointer?) throws -> MigrationRunHandle {
        guard let pointer else {
            throw malformedMigrationDelivery("delivery omitted its run capability")
        }
        return try ownedMigrationRun(
            zcashlc_migration_clone_run_handle_v1(pointer),
            operation: "migrationCloneRunHandle"
        )
    }

    func cloneMigrationClaim(_ pointer: OpaquePointer?) throws -> MigrationClaimHandle {
        guard let pointer else {
            throw malformedMigrationDelivery("claim summary omitted its capability")
        }
        return try ownedMigrationClaim(
            zcashlc_migration_clone_claim_handle_v1(pointer),
            operation: "migrationCloneClaimHandle"
        )
    }

    func migrationCanonicalSummary(
        hasState: Bool,
        statusTag: Int8,
        transactionCount: UInt32
    ) throws -> MigrationCanonicalSummary {
        guard hasState else {
            guard statusTag == -1, transactionCount == 0 else {
                throw malformedMigrationDelivery("absent canonical state carried canonical fields")
            }
            return MigrationCanonicalSummary(status: nil, transactionCount: 0)
        }
        let status: MigrationCanonicalStatus
        switch statusTag {
        case 0: status = .planning
        case 1: status = .committed
        case 2: status = .inProgress
        case 3: status = .complete
        case 4: status = .failed
        default: throw malformedMigrationDelivery("unknown canonical status tag \(statusTag)")
        }
        return MigrationCanonicalSummary(status: status, transactionCount: transactionCount)
    }

    func migrationSchemaProvenance(tag: UInt8, version: UInt32) throws -> MigrationSchemaProvenance {
        switch tag {
        case 0: return .compatible(version: version)
        case 1: return .unavailable
        case 2: return .future(version: version)
        case 3: return .corrupt
        default: throw malformedMigrationDelivery("unknown schema provenance tag \(tag)")
        }
    }

    func migrationLegacyCutover(tag: UInt8, objects: UInt32) throws -> MigrationLegacyCutoverStatus {
        switch tag {
        case 0: return .fresh
        case 1: return .recoveryRequired(objects: objects)
        default: throw malformedMigrationDelivery("unknown legacy cutover tag \(tag)")
        }
    }

    func migrationDestinationSpendability(tag: UInt8) throws -> MigrationDestinationSpendability {
        switch tag {
        case 0: return .notSpendable
        case 1: return .spendable
        case 2: return .alreadySpent
        case 3: return .notApplicable
        default: throw malformedMigrationDelivery("unknown destination spendability tag \(tag)")
        }
    }

    func migrationAvailability(
        tag: UInt8,
        reasonTag: Int8,
        detail: UInt32
    ) throws -> MigrationRuntimeAvailability {
        switch tag {
        case 0:
            guard reasonTag == -1 else {
                throw malformedMigrationDelivery("available runtime carried an unavailable reason")
            }
            return .available
        case 1:
            let reason: MigrationRuntimeUnavailableReason
            switch reasonTag {
            case 0: reason = .schemaUnavailable
            case 1: reason = .futureSchema(version: detail)
            case 2: reason = .corruptDeliveryState
            case 3: reason = .legacyCutoverRecovery(objects: detail)
            case 4: reason = .submissionPolicyMissing
            case 5: reason = .submissionPolicyMismatch
            case 6: reason = .deliveryInconsistent
            case 7:
                guard let recoveryTag = Int8(exactly: detail) else {
                    throw malformedMigrationDelivery("finality recovery detail did not fit in Int8")
                }
                reason = .finalityRecovery(try migrationStorageRecoveryReason(tag: recoveryTag))
            default: throw malformedMigrationDelivery("unknown unavailable reason tag \(reasonTag)")
            }
            return .unavailable(reason)
        default: throw malformedMigrationDelivery("unknown runtime availability tag \(tag)")
        }
    }

    func migrationOrdinarySpendAuthorization(
        tag: UInt8,
        reasonTag: Int8,
        releaseHeight: Int64,
        availability: MigrationRuntimeAvailability,
        aggregateFinality: MigrationStorageFinality
    ) throws -> MigrationOrdinarySpendAuthorization {
        switch tag {
        case 0:
            return .unrestricted
        case 1:
            return .excludingMigrationSources(
                releaseAtHeight: try migrationReleaseHeight(releaseHeight)
            )
        case 2:
            switch reasonTag {
            case 0: return .blocked(.migrationActive)
            case 1: return .blocked(.destinationNotSpendable)
            case 2: return .blocked(.runtimeUnavailable)
            case 3:
                if case .recoveryRequired(let reason) = aggregateFinality {
                    return .blocked(.finalityRecovery(reason))
                }
                if case .unavailable(.finalityRecovery(let reason)) = availability {
                    return .blocked(.finalityRecovery(reason))
                }
                throw malformedMigrationDelivery("finality-spend block omitted its recovery reason")
            default: throw malformedMigrationDelivery("unknown ordinary-spend block tag \(reasonTag)")
            }
        default: throw malformedMigrationDelivery("unknown ordinary-spend authorization tag \(tag)")
        }
    }

    func migrationAccountDeletionAuthorization(
        tag: UInt8,
        reasonTag: Int8
    ) throws -> MigrationAccountDeletionAuthorization {
        switch tag {
        case 0: return .allowed
        case 1:
            switch reasonTag {
            case 0: return .blocked(.runtimeUnavailable)
            case 1: return .blocked(.unresolvedDelivery)
            default: throw malformedMigrationDelivery("unknown account-deletion block tag \(reasonTag)")
            }
        default: throw malformedMigrationDelivery("unknown account-deletion authorization tag \(tag)")
        }
    }

    func migrationCanonicalMutationAuthorization(
        tag: UInt8,
        reasonTag: Int8
    ) throws -> MigrationCanonicalMutationAuthorization {
        switch tag {
        case 0: return .allowed
        case 1:
            switch reasonTag {
            case 0: return .blocked(.runtimeUnavailable)
            case 1: return .blocked(.deliveryOwned)
            default: throw malformedMigrationDelivery("unknown canonical-mutation block tag \(reasonTag)")
            }
        default: throw malformedMigrationDelivery("unknown canonical-mutation authorization tag \(tag)")
        }
    }

    func migrationStorageFinality(
        tag: Int8,
        recoveryTag: Int8,
        releaseHeight: Int64
    ) throws -> MigrationStorageFinality {
        switch tag {
        case 0: return .noRun
        case 1: return .active
        case 2: return .completePendingFinality(releaseAtHeight: try migrationReleaseHeight(releaseHeight))
        case 3: return .finalized(releaseAtHeight: try migrationReleaseHeight(releaseHeight))
        case 4: return .recoveryRequired(try migrationStorageRecoveryReason(tag: recoveryTag))
        default: throw malformedMigrationDelivery("unknown storage finality tag \(tag)")
        }
    }

    func migrationReleaseHeight(_ height: Int64) throws -> BlockHeight {
        guard height >= 0, let height = BlockHeight(exactly: height) else {
            throw malformedMigrationDelivery("invalid reservation release height \(height)")
        }
        return height
    }

    func migrationStorageRecoveryReason(tag: Int8) throws -> MigrationStorageRecoveryReason {
        switch tag {
        case 0: return .transferEvidenceLost
        case 1: return .rewoundBeyondFinalityHorizon
        case 2: return .corruptFinalityEvidence
        case 3: return .externalSigningExposureUnresolved
        default: throw malformedMigrationDelivery("unknown storage recovery tag \(tag)")
        }
    }

    func migrationPolicyFailure(tag: Int8) throws -> MigrationPolicyValidationFailure? {
        switch tag {
        case -1: return nil
        case 0: return .invalidEncoding
        case 1: return .policyTooLarge
        case 2: return .networkMismatch
        case 3: return .consensusMismatch
        case 4: return .unsupported
        default: throw malformedMigrationDelivery("unknown policy validation tag \(tag)")
        }
    }

    func migrationClaimKind(tag: Int8) throws -> MigrationDeliveryClaimKind? {
        switch tag {
        case -1: return nil
        case 0: return .materialization
        case 1: return .submission
        case 2: return .outcomeResolution
        default: throw malformedMigrationDelivery("unknown claim-kind tag \(tag)")
        }
    }

    func migrationDeliveryFailure(tag: Int8) throws -> MigrationDeliveryFailureReason? {
        switch tag {
        case -1: return nil
        case 0: return .materializationFailed
        case 1: return .materializationLeaseExpired
        case 2: return .signingCancelled
        case 3: return .transportSetupFailed
        case 4: return .transportDidNotBegin
        case 5: return .submissionLeaseExpired
        case 6: return .transportOutcomeUnknown
        default: throw malformedMigrationDelivery("unknown delivery-failure tag \(tag)")
        }
    }

    static func initializeRust(logLevel: RustLogging) {
        logLevel.rawValue.utf8CString.withUnsafeBufferPointer { levelPtr in
            zcashlc_init_on_load(levelPtr.baseAddress)
        }
    }
}

nonisolated func lastErrorMessage(fallback: String) -> String {
    let errorLen = zcashlc_last_error_length()
    defer { zcashlc_clear_last_error() }

    if errorLen > 0 {
        let error = UnsafeMutablePointer<Int8>.allocate(capacity: Int(errorLen))
        defer { error.deallocate() }

        zcashlc_error_message_utf8(error, errorLen)
        if let errorMessage = String(validatingUTF8: error) {
            return errorMessage
        } else {
            return fallback
        }
    } else {
        return fallback
    }
}

private func migrationTransportTag(_ transport: MigrationSubmissionTransport) -> UInt8 {
    switch transport {
    case .directTLS: return 0
    case .torOnion: return 1
    case .loopbackDevelopment: return 2
    }
}

private func migrationTransport(tag: Int32) -> MigrationSubmissionTransport? {
    switch tag {
    case 0: return .directTLS
    case 1: return .torOnion
    case 2: return .loopbackDevelopment
    default: return nil
    }
}

private func migrationSignerTag(_ signer: MigrationSignerOwnership) -> UInt8 {
    switch signer {
    case .sdk: return 0
    case .external: return 1
    }
}

private func migrationSigner(tag: UInt8) -> MigrationSignerOwnership? {
    switch tag {
    case 0: return .sdk
    case 1: return .external
    default: return nil
    }
}

private func migrationDeliveryLane(tag: Int8) -> MigrationDeliveryLane? {
    switch tag {
    case 0: return .scheduled
    case 1: return .immediate
    default: return nil
    }
}

private func migrationDeliveryPhase(tag: Int8) -> MigrationDeliveryPhase? {
    switch tag {
    case 0: return .active
    case 1: return .paused
    case 2: return .abandoning
    case 3: return .abandoned
    default: return nil
    }
}

private func decodeMigrationClaimStatus(tag: UInt8) -> MigrationDeliveryClaimStatus? {
    switch tag {
    case 0: return .materializing
    case 1: return .materializationFailed
    case 2: return .awaitingExternalSignature
    case 3: return .staged
    case 4: return .submitting
    case 5: return .outcomeUnknown
    case 6: return .broadcasted
    case 7: return .confirmed
    case 8: return .expiredUnmined
    case 9: return .externalSigningExpiredUnmined
    default: return nil
    }
}

private func migrationSubmissionOutcomeTag(_ outcome: MigrationSubmissionOutcome) -> UInt8 {
    switch outcome {
    case .accepted: return 0
    case .knownUnsent: return 1
    case .unknown: return 2
    }
}

private func migrationDeliveryFailureTag(_ failure: MigrationDeliveryFailureReason) -> UInt8 {
    switch failure {
    case .materializationFailed: return 0
    case .materializationLeaseExpired: return 1
    case .signingCancelled: return 2
    case .transportSetupFailed: return 3
    case .transportDidNotBegin: return 4
    case .submissionLeaseExpired: return 5
    case .transportOutcomeUnknown: return 6
    }
}

private func ffiInlineBytes<T>(_ value: T) -> [UInt8] {
    var value = value
    return withUnsafeBytes(of: &value) { [UInt8]($0) }
}

extension URL {
    func osStr() -> (String, UInt) {
        let path = self.absoluteString
        return (path, UInt(path.lengthOfBytes(using: .utf8)))
    }

    /// use when the rust ffi needs to make filesystem operations
    func osPathStr() -> (String, UInt) {
        let path = self.path
        return (path, UInt(path.lengthOfBytes(using: .utf8)))
    }
}

extension String {
    /**
    Checks whether this string contains null bytes before it's real ending
    */
    func containsCStringNullBytesBeforeStringEnding() -> Bool {
        self.utf8CString.firstIndex(of: 0) != (self.utf8CString.count - 1)
    }

    func isDbNotEmptyErrorMessage() -> Bool {
        return contains("is not empty")
    }
}

extension FfiAddress {
    /// converts an [`FfiAddress`] into a [`UnifiedAddress`]
    /// - Note: This does not check that the converted value actually holds a valid UnifiedAddress
    func unsafeToUnifiedAddress(_ networkType: NetworkType) -> UnifiedAddress {
        .init(validatedEncoding: String(cString: address), networkType: networkType)
    }
}

extension FfiAccount {
    var uuidArray: [UInt8] {
        withUnsafeBytes(of: uuid_bytes) { buf in
            [UInt8](buf)
        }
    }

    var seedFingerprintArray: [UInt8] {
        withUnsafeBytes(of: seed_fingerprint) { buf in
            [UInt8](buf)
        }
    }

    /// converts an [`FfiAccount`] into a [`Account`]
    /// - Note: This does not check that the converted value actually holds a valid Account
    func unsafeToAccount() -> Account? {
        // Invalid UUID check
        guard uuidArray != [UInt8](repeating: 0, count: 16) else {
            return nil
        }

        // Invalid ZIP 32 account index
        if hd_account_index == UInt32.max {
            return .init(
                id: AccountUUID(id: uuidArray),
                name: account_name != nil ? String(cString: account_name) : nil,
                keySource: key_source != nil ? String(cString: key_source) : nil,
                seedFingerprint: nil,
                hdAccountIndex: nil,
                ufvk: nil,
                uivk: nil
            )
        }

        let ufvkTyped = ufvk.map { UnifiedFullViewingKey(validatedEncoding: String(cString: $0)) }
        let uivkTyped = uivk.map { UnifiedIncomingViewingKey(validatedEncoding: String(cString: $0)) }

        // Valid ZIP32 account index
        return .init(
            id: AccountUUID(id: uuidArray),
            name: account_name != nil ? String(cString: account_name) : nil,
            keySource: key_source != nil ? String(cString: key_source) : nil,
            seedFingerprint: seedFingerprintArray,
            hdAccountIndex: Zip32AccountIndex(hd_account_index),
            ufvk: ufvkTyped,
            uivk: uivkTyped
        )
    }
}

extension FfiBoxedSlice {
    /// converts an [`FfiBoxedSlice`] into a [`UnifiedSpendingKey`]
    /// - Note: This does not check that the converted value actually holds a valid USK
    func unsafeToUnifiedSpendingKey(network: NetworkType) -> UnifiedSpendingKey {
        .init(
            network: network,
            bytes: self.ptr.toByteArray(length: Int(self.len))
        )
    }
}

extension FfiUuid {
    var uuidArray: [UInt8] {
        withUnsafeBytes(of: self.uuid_bytes) { buf in
            [UInt8](buf)
        }
    }

    /// converts an [`FfiUuid`] into a [`AccountUUID`]
    func unsafeToAccountUUID() -> AccountUUID {
        .init(
            id: self.uuidArray
        )
    }
}

extension FFIBinaryKey {
    var uuidArray: [UInt8] {
        withUnsafeBytes(of: self.account_uuid) { buf in
            [UInt8](buf)
        }
    }

    /// converts an [`FFIBinaryKey`] into a [`UnifiedSpendingKey`]
    /// - Note: This does not check that the converted value actually holds a valid USK
    func unsafeToUnifiedSpendingKey(network: NetworkType) -> UnifiedSpendingKey {
        .init(
            network: network,
            bytes: self.encoding.toByteArray(
                length: Int(self.encoding_len)
            )
        )
    }
}

extension UnsafeMutablePointer where Pointee == UInt8 {
    /// copies the bytes pointed on
    func toByteArray(length: Int) -> [UInt8] {
        var bytes: [UInt8] = []

        for index in 0 ..< length {
            bytes.append(self.advanced(by: index).pointee)
        }

        return bytes
    }
}

extension Array where Element == FFIBlockMeta {
    func deallocateElements() {
        self.forEach { element in
            element.block_hash_ptr.deallocate()
        }
    }
}

extension Array where Element == FfiSubtreeRoot {
    func deallocateElements() {
        self.forEach { element in
            element.root_hash_ptr.deallocate()
        }
    }
}

extension FfiBalance {
    /// Converts an [`FfiBalance`] into a [`PoolBalance`].
    func toPoolBalance() -> PoolBalance {
        PoolBalance(
            spendableValue: Zatoshi(self.spendable_value),
            changePendingConfirmation: Zatoshi(self.change_pending_confirmation),
            valuePendingSpendability: Zatoshi(self.value_pending_spendability),
            lockedValue: Zatoshi(self.locked_value)
        )
    }
}

extension FfiAccountBalance {
    var uuidArray: [UInt8] {
        withUnsafeBytes(of: self.account_uuid) { buf in
            [UInt8](buf)
        }
    }

    /// Converts an [`FfiAccountBalance`] into a [`AccountBalance`].
    func toAccountBalance() -> AccountBalance {
        .init(
            saplingBalance: self.sapling_balance.toPoolBalance(),
            orchardBalance: self.orchard_balance.toPoolBalance(),
            ironwoodBalance: self.ironwood_balance.toPoolBalance(),
            unshielded: Zatoshi(self.unshielded)
        )
    }
}

extension FfiScanProgress {
    /// Converts an [`FfiScanProgress`] into a [`ScanProgress`].
    func toScanProgress() -> ScanProgress {
        .init(
            numerator: min(self.numerator, self.denominator),
            denominator: self.denominator
        )
    }
}

extension FfiMigrationProgress {
    /// Converts an [`FfiMigrationProgress`] into a [`MigrationProgress`], or `nil` when
    /// `is_present` is `false` (no migration currently in progress).
    func unsafeToMigrationProgress() -> MigrationProgress? {
        guard is_present else { return nil }

        return MigrationProgress(
            completedTransfers: Int(completed_transfers),
            totalTransfers: Int(total_transfers),
            remainingOrchard: Zatoshi(remaining_orchard_value),
            nextTransferReadyAtHeight: next_transfer_ready_at_height >= 0 ? BlockHeight(next_transfer_ready_at_height) : nil,
            isImmediate: is_immediate
        )
    }
}

private enum DecodedMigrationField<Value> {
    case valid(Value)
    case invalid
}

extension FfiMigrationTransactionStatus {
    /// Converts an [`FfiMigrationTransactionStatus`] into a [`MigrationTransactionStatus`], or
    /// `nil` for an out-of-range discriminant or an invariant the engine's own contract rules out
    /// (should not happen; defensive only) -- see `zcashlc_migration_transaction_statuses`'s doc
    /// for the field-by-field contract this mirrors.
    func unsafeToMigrationTransactionStatus() -> MigrationTransactionStatus? {
        guard let kind = decodedKind, let state = decodedState else { return nil }
        guard case .valid(let nextAction) = decodedNextAction else { return nil }
        guard case .valid(let blockedOn) = decodedBlocker else { return nil }

        return MigrationTransactionStatus(
            id: id,
            kind: kind,
            state: state,
            scheduledHeight: BlockHeight(scheduled_height),
            expiryHeight: expiry_height == 0 ? nil : BlockHeight(expiry_height),
            isReady: ready,
            nextAction: nextAction,
            blockedOn: blockedOn
        )
    }

    private var decodedKind: MigrationTransactionStatus.Kind? {
        if is_transfer {
            crossing >= 0 ? .transfer(crossing: Int(crossing)) : nil
        } else if prep_layer >= 0, prep_index >= 0 {
            .preparation(layer: Int(prep_layer), index: Int(prep_index))
        } else {
            nil
        }
    }

    private var decodedState: MigrationTransactionStatus.State? {
        switch state {
        case 0: .awaitingSignature
        case 1: .signed
        case 2: .proved
        case 3 where has_txid: .broadcast(txid: Data(FfiTxId(tuple: txid).array))
        case 4 where mined_height >= 0: .mined(height: BlockHeight(mined_height))
        default: nil
        }
    }

    private var decodedNextAction: DecodedMigrationField<MigrationTransactionStatus.NextAction?> {
        switch action {
        case 0: .valid(nil)
        case 1: .valid(.prove)
        case 2: .valid(.broadcast)
        default: .invalid
        }
    }

    private var decodedBlocker: DecodedMigrationField<MigrationTransactionStatus.Blocker?> {
        switch blocked_on {
        case 0: .valid(nil)
        case 1: .valid(.dependencies)
        case 2: .valid(.schedule)
        case 3: .valid(.anchorBoundary)
        case 4: .valid(.signature)
        case 5: .valid(.expired)
        default: .invalid
        }
    }
}

extension FfiMigrationTransactionStatuses {
    /// Converts an [`FfiMigrationTransactionStatuses`] container into
    /// `[MigrationTransactionStatus]`, or `nil` if any row fails to decode (should not happen;
    /// defensive only). An empty container (`len == 0`) decodes to an empty array -- the
    /// legitimate "no stored run" / "stored run with no transactions" answer.
    func unsafeToMigrationTransactionStatuses() -> [MigrationTransactionStatus]? {
        var decoded: [MigrationTransactionStatus] = []
        decoded.reserveCapacity(Int(len))

        for index in 0 ..< Int(len) {
            guard let status = ptr.advanced(by: index).pointee.unsafeToMigrationTransactionStatus() else {
                return nil
            }

            decoded.append(status)
        }

        return decoded
    }
}

extension FfiAttentionReason {
    /// Converts an [`FfiAttentionReason`] into a [`MigrationAttentionReason`], or `nil` for an
    /// unrecognized tag or a missing `transfer_id` (should not happen; defensive only).
    func unsafeToMigrationAttentionReason() -> MigrationAttentionReason? {
        switch tag {
        case 0:
            guard
                let transferIdPtr = invalid_transfer.transfer_id,
                let transferId = String(validatingUTF8: transferIdPtr)
            else {
                return nil
            }

            return .invalidTransfer(transferId: transferId)
        case 1:
            return .transferExpired
        default:
            return nil
        }
    }
}

extension FfiMigrationState {
    /// Converts an [`FfiMigrationState`] into a [`MigrationState`], or `nil` for an unrecognized
    /// tag or malformed payload (should not happen; defensive only).
    func unsafeToMigrationState() -> MigrationState? {
        switch tag {
        case 0:
            return .notStarted
        case 1:
            return .splitPendingConfirmation
        case 2:
            guard let progress = in_progress.unsafeToMigrationProgress() else { return nil }
            return .inProgress(progress)
        case 3:
            guard let reason = requires_attention.unsafeToMigrationAttentionReason() else { return nil }
            return .requiresAttention(reason)
        case 4:
            return .complete
        default:
            return nil
        }
    }
}

extension FfiNoteSplitProposal {
    /// Converts an [`FfiNoteSplitProposal`] into a [`NoteSplitProposal`].
    func toNoteSplitProposal() -> NoteSplitProposal {
        var outputNotes: [Zatoshi] = []
        outputNotes.reserveCapacity(Int(output_values_len))

        for index in 0 ..< Int(output_values_len) {
            outputNotes.append(Zatoshi(output_values.advanced(by: index).pointee))
        }

        return NoteSplitProposal(
            outputNotes: outputNotes,
            fee: Zatoshi(fee),
            proposalHandle: proposal_handle
        )
    }
}

extension FfiTransferProposal {
    /// Converts an [`FfiTransferProposal`] into a [`MigrationTransferProposal`], or `nil` for a
    /// missing `id` (should not happen; defensive only).
    func unsafeToMigrationTransferProposal() -> MigrationTransferProposal? {
        guard let idPtr = id, let transferId = String(validatingUTF8: idPtr) else { return nil }

        return MigrationTransferProposal(
            id: transferId,
            amount: Zatoshi(amount),
            anchorHeight: BlockHeight(anchor_height),
            nextExecutableAfterHeight: BlockHeight(next_executable_after_height),
            expiryHeight: BlockHeight(expiry_height)
        )
    }
}

extension FfiMigrationSchedule {
    /// Converts an [`FfiMigrationSchedule`] into a [`MigrationSchedule`], or `nil` if any transfer
    /// in the array fails to decode (should not happen; defensive only).
    func unsafeToMigrationSchedule() -> MigrationSchedule? {
        var proposals: [MigrationTransferProposal] = []
        proposals.reserveCapacity(Int(transfers_len))

        for index in 0 ..< Int(transfers_len) {
            guard let proposal = transfers.advanced(by: index).pointee.unsafeToMigrationTransferProposal() else {
                return nil
            }

            proposals.append(proposal)
        }

        return MigrationSchedule(
            transfers: proposals,
            estimatedDurationHours: Int(estimated_duration_hours),
            proposalHandle: proposal_handle
        )
    }
}

extension FfiMigrationRunEstimate {
    /// Converts an [`FfiMigrationRunEstimate`] into a [`MigrationRunEstimate`]. Total, not
    /// failable: every field is a plain value, and an empty runs array (`runs_len == 0`) is the
    /// legitimate zero-run estimate.
    func toMigrationRunEstimate() -> MigrationRunEstimate {
        var decodedRuns: [MigrationRunEstimate.Run] = []
        decodedRuns.reserveCapacity(Int(runs_len))

        for index in 0 ..< Int(runs_len) {
            let run = runs.advanced(by: index).pointee
            decodedRuns.append(
                MigrationRunEstimate.Run(
                    migratable: Zatoshi(run.migratable),
                    crossings: Int(run.crossings),
                    preparationLayers: Int(run.prep_layers),
                    preparationTransactions: Int(run.prep_transactions)
                )
            )
        }

        return MigrationRunEstimate(runs: decodedRuns, finalResidual: Zatoshi(final_residual))
    }
}

// swiftlint:disable large_tuple line_length file_length
struct FfiTxId {
    var tuple: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    var array: [UInt8] {
        withUnsafeBytes(of: self.tuple) { buf in
            [UInt8](buf)
        }
    }
}
