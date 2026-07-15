#!/bin/bash
set -euo pipefail

output=''
while (( $# )); do
    case "$1" in
        --output)
            output="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

[[ -n "$output" ]] || { echo 'fake-curl: missing --output' >&2; exit 64; }
[[ -n "${MOCK_DOWNLOAD_SOURCE:-}" ]] || { echo 'fake-curl: missing MOCK_DOWNLOAD_SOURCE' >&2; exit 64; }

if [[ -n "${MOCK_CURL_MARKER:-}" ]]; then
    printf 'called\n' >> "$MOCK_CURL_MARKER"
fi

case "${MOCK_CURL_MODE:-valid}" in
    valid)
        cp "$MOCK_DOWNLOAD_SOURCE" "$output"
        ;;
    http-failure)
        printf 'upstream returned HTTP 503\n' >&2
        exit 22
        ;;
    truncated)
        size="$(wc -c < "$MOCK_DOWNLOAD_SOURCE" | tr -d '[:space:]')"
        dd if="$MOCK_DOWNLOAD_SOURCE" of="$output" bs=1 count="$((size - 1))" 2>/dev/null
        ;;
    digest-mismatch)
        cp "$MOCK_DOWNLOAD_SOURCE" "$output"
        size="$(wc -c < "$output" | tr -d '[:space:]')"
        printf '\001' | dd of="$output" bs=1 seek="$((size - 1))" conv=notrunc 2>/dev/null
        ;;
    *)
        printf 'fake-curl: unknown mode %s\n' "$MOCK_CURL_MODE" >&2
        exit 64
        ;;
esac
