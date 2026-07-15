#!/bin/bash
set -euo pipefail

connect_timeout=''
fail_enabled=0
location_enabled=0
output=''
retry_all_errors=0
retry_count=''
url=''
while (( $# )); do
    case "$1" in
        --fail)
            fail_enabled=1
            shift
            ;;
        --location)
            location_enabled=1
            shift
            ;;
        --retry)
            retry_count="${2:-}"
            shift 2
            ;;
        --retry-all-errors)
            retry_all_errors=1
            shift
            ;;
        --connect-timeout)
            connect_timeout="${2:-}"
            shift 2
            ;;
        --output)
            output="${2:-}"
            shift 2
            ;;
        --*)
            printf 'fake-curl: unexpected option %s\n' "$1" >&2
            exit 64
            ;;
        *)
            [[ -z "$url" ]] || { echo 'fake-curl: multiple URLs' >&2; exit 64; }
            url="$1"
            shift
            ;;
    esac
done

[[ "$fail_enabled" == 1 ]] || { echo 'fake-curl: missing --fail' >&2; exit 64; }
[[ "$location_enabled" == 1 ]] || { echo 'fake-curl: missing --location' >&2; exit 64; }
[[ "$retry_count" == "${MOCK_EXPECTED_RETRIES:-3}" ]] || { echo 'fake-curl: incorrect --retry policy' >&2; exit 64; }
[[ "$retry_all_errors" == 1 ]] || { echo 'fake-curl: missing --retry-all-errors' >&2; exit 64; }
[[ "$connect_timeout" == "${MOCK_EXPECTED_CONNECT_TIMEOUT:-15}" ]] || { echo 'fake-curl: incorrect --connect-timeout' >&2; exit 64; }
[[ -n "$output" ]] || { echo 'fake-curl: missing --output' >&2; exit 64; }
[[ -n "$url" ]] || { echo 'fake-curl: missing URL' >&2; exit 64; }
if [[ -n "${MOCK_EXPECTED_URL:-}" && "$url" != "$MOCK_EXPECTED_URL" ]]; then
    echo 'fake-curl: unexpected URL' >&2
    exit 64
fi
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
