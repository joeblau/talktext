#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TOOL="$REPOSITORY_ROOT/scripts/dependency-tool.sh"
FAKE_CURL="$REPOSITORY_ROOT/tests/fixtures/fake-curl.sh"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/talktext-dependency-tests.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

pass_count=0

pass() {
    pass_count=$((pass_count + 1))
    printf 'ok %d - %s\n' "$pass_count" "$1"
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

expect_failure() {
    local label="$1"
    shift
    if "$@" >"$TEMP_ROOT/last.stdout" 2>"$TEMP_ROOT/last.stderr"; then
        fail "$label unexpectedly succeeded"
    fi
}

assert_absent() {
    [[ ! -e "$1" ]] || fail "expected path to be absent: $1"
}

assert_no_download_temps() {
    local directory="$1"
    if find "$directory" -name '.*.download.*' -print -quit | grep -q .; then
        fail "temporary download file was not cleaned up"
    fi
}

VALID_FIXTURE="$TEMP_ROOT/fixture-model.bin"
printf 'lmggTalkText deterministic model fixture\n' > "$VALID_FIXTURE"
FIXTURE_SIZE="$(wc -c < "$VALID_FIXTURE" | tr -d '[:space:]')"
FIXTURE_SHA="$(shasum -a 256 "$VALID_FIXTURE" | awk '{print $1}')"
FIXTURE_MANIFEST="$TEMP_ROOT/dependencies.env"

cat > "$FIXTURE_MANIFEST" <<EOF
TALKTEXT_DEPENDENCY_MANIFEST_VERSION='1'
MODEL_REPOSITORY='fixtures/model'
MODEL_REVISION='0000000000000000000000000000000000000000'
MODEL_FILE_NAME='fixture-model.bin'
MODEL_URL='https://huggingface.co/fixtures/model/resolve/0000000000000000000000000000000000000000/fixture-model.bin'
MODEL_SIZE_BYTES='$FIXTURE_SIZE'
MODEL_SHA256='$FIXTURE_SHA'
MODEL_MAGIC_HEX='6c6d6767'
BACKEND_FORMULA='whisper-cpp'
BACKEND_EXECUTABLE='whisper-cli'
BACKEND_REPOSITORY_URL='https://github.com/ggml-org/whisper.cpp.git'
BACKEND_SUPPORTED_VERSIONS='1.8.4 1.9.1'
BACKEND_UPSTREAM_REVISIONS='1.8.4=9386f239401074690479731c1e41683fbbeac557 1.9.1=f049fff95a089aa9969deb009cdd4892b3e74916'
BACKEND_REQUIRED_FLAGS='--model --file --no-timestamps --threads'
EOF

run_install() {
    local mode="$1" destination="$2" marker="${3:-}"
    TALKTEXT_DEPENDENCY_MANIFEST="$FIXTURE_MANIFEST" \
    CURL_BIN="$FAKE_CURL" \
    MOCK_CURL_MODE="$mode" \
    MOCK_CURL_MARKER="$marker" \
    MOCK_DOWNLOAD_SOURCE="$VALID_FIXTURE" \
        "$TOOL" install-model "$destination"
}

mkdir -p "$TEMP_ROOT/http"
expect_failure 'HTTP failure' run_install http-failure "$TEMP_ROOT/http/model.bin"
assert_absent "$TEMP_ROOT/http/model.bin"
assert_no_download_temps "$TEMP_ROOT/http"
grep -q 'HTTP 503' "$TEMP_ROOT/last.stderr" || fail 'HTTP failure was not reported clearly'
pass 'HTTP failure cannot create a model or leave a partial download'

mkdir -p "$TEMP_ROOT/truncated"
expect_failure 'truncated download' run_install truncated "$TEMP_ROOT/truncated/model.bin"
assert_absent "$TEMP_ROOT/truncated/model.bin"
assert_no_download_temps "$TEMP_ROOT/truncated"
grep -q 'size mismatch' "$TEMP_ROOT/last.stderr" || fail 'truncation did not report a size mismatch'
pass 'truncated download is rejected before replacement'

mkdir -p "$TEMP_ROOT/digest"
expect_failure 'digest mismatch' run_install digest-mismatch "$TEMP_ROOT/digest/model.bin"
assert_absent "$TEMP_ROOT/digest/model.bin"
assert_no_download_temps "$TEMP_ROOT/digest"
grep -q 'digest mismatch' "$TEMP_ROOT/last.stderr" || fail 'digest mismatch was not reported'
pass 'same-size digest mismatch is rejected'

mkdir -p "$TEMP_ROOT/cache"
cp "$VALID_FIXTURE" "$TEMP_ROOT/cache/model.bin"
MARKER="$TEMP_ROOT/cache/curl-called"
run_install http-failure "$TEMP_ROOT/cache/model.bin" "$MARKER"
assert_absent "$MARKER"
cmp "$VALID_FIXTURE" "$TEMP_ROOT/cache/model.bin" >/dev/null || fail 'valid cache was modified'
pass 'valid cache is verified without a network request'

mkdir -p "$TEMP_ROOT/atomic"
printf 'not-a-model\n' > "$TEMP_ROOT/atomic/model.bin"
run_install valid "$TEMP_ROOT/atomic/model.bin"
cmp "$VALID_FIXTURE" "$TEMP_ROOT/atomic/model.bin" >/dev/null || fail 'verified replacement was not installed'
QUARANTINE_COUNT="$(find "$TEMP_ROOT/atomic" -name 'model.bin.invalid.*' | wc -l | tr -d '[:space:]')"
[[ "$QUARANTINE_COUNT" == 1 ]] || fail 'invalid cache was not quarantined exactly once'
assert_no_download_temps "$TEMP_ROOT/atomic"
pass 'verified download atomically replaces and quarantines an invalid cache'

printf '1..%d\n' "$pass_count"
