#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
DEPENDENCY_TOOL="$REPOSITORY_ROOT/scripts/dependency-tool.sh"
# shellcheck source=dependencies.env
source "$REPOSITORY_ROOT/dependencies.env"

BACKEND_PATH="${TALKTEXT_WHISPER_CLI:-}"
BACKEND_VERSION="${TALKTEXT_WHISPER_CLI_VERSION:-}"
MODEL_PATH="${TALKTEXT_MODEL_PATH:-$REPOSITORY_ROOT/models/$MODEL_FILE_NAME}"

[[ -n "$BACKEND_PATH" ]] || {
    echo 'error: TALKTEXT_WHISPER_CLI must select the pinned backend build under test' >&2
    exit 1
}
[[ -n "$BACKEND_VERSION" ]] || {
    echo 'error: TALKTEXT_WHISPER_CLI_VERSION must identify the pinned backend build under test' >&2
    exit 1
}

is_supported=0
for supported_version in $BACKEND_SUPPORTED_VERSIONS; do
    if [[ "$BACKEND_VERSION" == "$supported_version" ]]; then
        is_supported=1
        break
    fi
done
(( is_supported )) || {
    echo "error: backend fixture version $BACKEND_VERSION is not in: $BACKEND_SUPPORTED_VERSIONS" >&2
    exit 1
}

"$DEPENDENCY_TOOL" probe-backend "$BACKEND_PATH"
"$DEPENDENCY_TOOL" verify-model "$MODEL_PATH"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/talktext-backend-contract.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM
AUDIO_PATH="$TEMP_ROOT/controlled-silence.wav"

# Canonical 44-byte WAV header: PCM, mono, 16 kHz, signed 16-bit, followed by
# exactly one second (32,000 bytes) of silence. Keeping the header literal and
# generating zero samples makes the fixture byte-for-byte deterministic.
WAV_HEADER_BASE64='UklGRiR9AABXQVZFZm10IBAAAAABAAEAgD4AAAB9AAACABAAZGF0YQB9AAA='
if printf '%s' "$WAV_HEADER_BASE64" | base64 -D > "$AUDIO_PATH" 2>/dev/null; then
    :
else
    printf '%s' "$WAV_HEADER_BASE64" | base64 --decode > "$AUDIO_PATH"
fi
dd if=/dev/zero bs=32000 count=1 >> "$AUDIO_PATH" 2>/dev/null

# Keep these arguments byte-for-byte aligned with
# WhisperBackendContract.productionArguments. The Swift contract unit test and
# this real-process fixture jointly prevent invocation drift.
if ! "$BACKEND_PATH" \
    --model "$MODEL_PATH" \
    --file "$AUDIO_PATH" \
    --no-timestamps \
    --threads 4 \
    > "$TEMP_ROOT/stdout" \
    2> "$TEMP_ROOT/stderr"; then
    echo "error: whisper-cli $BACKEND_VERSION rejected the production invocation" >&2
    sed -n '1,120p' "$TEMP_ROOT/stderr" >&2
    exit 1
fi

echo "backend contract passed: version=$BACKEND_VERSION architecture=$(uname -m)"
