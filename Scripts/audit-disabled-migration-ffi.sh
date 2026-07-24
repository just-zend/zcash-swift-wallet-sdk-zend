#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [production-swift-source-root]" >&2
    exit 1
fi
swift_source_root="${1:-$repo_root/Sources}"
if [[ ! -d "$swift_source_root" ]]; then
    echo "Production Swift source root is missing: $swift_source_root" >&2
    exit 1
fi

disabled_symbols=(
    zcashlc_migration_sign_note_split
    zcashlc_migration_next_due_transfer
    zcashlc_migration_extract_broadcast_tx
    zcashlc_migration_record_transfer_result
    zcashlc_migration_restart_step
    zcashlc_migration_refresh_stale_transfers
    zcashlc_migration_create_unsigned_note_split_pczts
    zcashlc_migration_store_signed_note_split_pczts
    zcashlc_migration_create_unsigned_transfer_pczts
    zcashlc_migration_store_signed_schedule_pczts
    zcashlc_migration_stage_materialized_transaction_v1
)

found=0
for symbol in "${disabled_symbols[@]}"; do
    if matches="$(rg --follow -n --glob '*.swift' --fixed-strings "$symbol" "$swift_source_root")"; then
        printf 'disabled migration FFI symbol is reachable from production Swift: %s\n%s\n' "$symbol" "$matches" >&2
        found=1
    else
        status=$?
        if [[ "$status" -ne 1 ]]; then
            echo "Failed to audit production Swift for disabled migration FFI symbol: $symbol" >&2
            exit "$status"
        fi
    fi
done

if [[ "$found" -ne 0 ]]; then
    exit 1
fi

printf 'Production Swift contains no calls to the %s fail-closed migration FFI symbols.\n' \
    "${#disabled_symbols[@]}"
