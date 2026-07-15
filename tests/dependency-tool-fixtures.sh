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

assert_equal() {
    local expected="$1" actual="$2" message="$3"
    [[ "$actual" == "$expected" ]] || fail "$message (expected $expected, found $actual)"
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
FIXTURE_MODEL_URL='https://huggingface.co/fixtures/model/resolve/0000000000000000000000000000000000000000/fixture-model.bin'
FIXTURE_BACKEND='fixture-whisper-cli'

cat > "$FIXTURE_MANIFEST" <<EOF
TALKTEXT_DEPENDENCY_MANIFEST_VERSION='1'
MODEL_REPOSITORY='fixtures/model'
MODEL_REVISION='0000000000000000000000000000000000000000'
MODEL_FILE_NAME='fixture-model.bin'
MODEL_URL='$FIXTURE_MODEL_URL'
MODEL_SIZE_BYTES='$FIXTURE_SIZE'
MODEL_SHA256='$FIXTURE_SHA'
MODEL_MAGIC_HEX='6c6d6767'
BACKEND_FORMULA='whisper-cpp'
BACKEND_EXECUTABLE='$FIXTURE_BACKEND'
BACKEND_REPOSITORY_URL='https://github.com/ggml-org/whisper.cpp.git'
BACKEND_SUPPORTED_VERSIONS='1.8.4 1.9.1'
BACKEND_UPSTREAM_REVISIONS='1.8.4=9386f239401074690479731c1e41683fbbeac557 1.9.1=f049fff95a089aa9969deb009cdd4892b3e74916'
BACKEND_REQUIRED_FLAGS='--model --file --no-timestamps --threads'
EOF

run_install() {
    local mode="$1" destination="$2" marker="${3:-}"
    TALKTEXT_DEPENDENCY_MANIFEST="$FIXTURE_MANIFEST" \
    TALKTEXT_CONNECT_TIMEOUT_SECONDS='' \
    TALKTEXT_DOWNLOAD_RETRIES='' \
    CURL_BIN="$FAKE_CURL" \
    MOCK_CURL_MODE="$mode" \
    MOCK_CURL_MARKER="$marker" \
    MOCK_DOWNLOAD_SOURCE="$VALID_FIXTURE" \
    MOCK_EXPECTED_CONNECT_TIMEOUT=15 \
    MOCK_EXPECTED_RETRIES=3 \
    MOCK_EXPECTED_URL="$FIXTURE_MODEL_URL" \
        "$TOOL" install-model "$destination"
}

make_backend() {
    local path="$1"
    mkdir -p "$(dirname -- "$path")"
    cat > "$path" <<'EOF'
#!/bin/bash
set -euo pipefail

case "${1:-}" in
    --help)
        printf '%s\n' '--model --file --no-timestamps --threads'
        ;;
    --version)
        printf '%s\n' "${MOCK_BACKEND_VERSION_OUTPUT:-fixture version 1.9.1}"
        ;;
    *)
        exit 64
        ;;
esac
EOF
    chmod 755 "$path"
}

canonical_fixture_path() {
    local path="$1"
    printf '%s/%s\n' \
        "$(CDPATH= cd -- "$(dirname -- "$path")" && pwd -P)" \
        "$(basename -- "$path")"
}

RESOLVER_REPOSITORY="$TEMP_ROOT/resolver-checkout"
RESOLVER_TOOL="$RESOLVER_REPOSITORY/scripts/dependency-tool.sh"
RESOLVER_HOME="$TEMP_ROOT/resolver-home"
EMPTY_HOMEBREW="$TEMP_ROOT/empty-homebrew"
mkdir -p "$(dirname -- "$RESOLVER_TOOL")" "$RESOLVER_HOME" "$EMPTY_HOMEBREW"
cp "$TOOL" "$RESOLVER_TOOL"

run_resolver() {
    local working_directory="$1"
    shift
    (
        CDPATH= cd -- "$working_directory"
        TALKTEXT_BUNDLE_RESOURCES='' \
        TALKTEXT_DEPENDENCY_MANIFEST="$FIXTURE_MANIFEST" \
        TALKTEXT_DEVELOPMENT_ROOT="${RESOLVER_DEVELOPMENT_ROOT:-}" \
        TALKTEXT_WHISPER_CLI="${RESOLVER_BACKEND_OVERRIDE:-}" \
        TALKTEXT_WHISPER_CLI_VERSION="${RESOLVER_VERSION_OVERRIDE:-}" \
        HOME="$RESOLVER_HOME" \
        HOMEBREW_PREFIX="$EMPTY_HOMEBREW" \
        MOCK_BACKEND_VERSION_OUTPUT="${MOCK_BACKEND_VERSION_OUTPUT:-fixture version 1.9.1}" \
        PATH='/usr/bin:/bin' \
            "$RESOLVER_TOOL" "$@"
    )
}

expect_failure 'setup manifest override' \
    env TALKTEXT_DEPENDENCY_MANIFEST="$FIXTURE_MANIFEST" "$REPOSITORY_ROOT/setup.sh"
grep -q 'does not accept a dependency manifest override' "$TEMP_ROOT/last.stderr" || \
    fail 'setup did not reject the test dependency manifest explicitly'
pass 'production setup rejects a test dependency manifest override'

expect_failure 'release manifest override' \
    env TALKTEXT_DEPENDENCY_MANIFEST="$FIXTURE_MANIFEST" "$REPOSITORY_ROOT/release.sh"
grep -q 'does not accept a dependency manifest override' "$TEMP_ROOT/last.stderr" || \
    fail 'release did not reject the test dependency manifest explicitly'
pass 'production release rejects a test dependency manifest override'

DEVELOPMENT_ROOT="$RESOLVER_HOME/configured"
INFERRED_BACKEND="$RESOLVER_REPOSITORY/.dependencies/bin/$FIXTURE_BACKEND"
WORKING_PARENT="$TEMP_ROOT/working-parent"
WORKING_DIRECTORY="$WORKING_PARENT/project"
CURRENT_BACKEND="$WORKING_DIRECTORY/.dependencies/bin/$FIXTURE_BACKEND"
PARENT_BACKEND="$WORKING_PARENT/bin/$FIXTURE_BACKEND"
USER_BACKEND="$RESOLVER_HOME/.local/bin/$FIXTURE_BACKEND"
CONFIGURED_BACKEND="$DEVELOPMENT_ROOT/.dependencies/bin/$FIXTURE_BACKEND"
mkdir -p "$WORKING_DIRECTORY"
make_backend "$CONFIGURED_BACKEND"
make_backend "$INFERRED_BACKEND"
make_backend "$CURRENT_BACKEND"
make_backend "$PARENT_BACKEND"
make_backend "$USER_BACKEND"

RESOLVED_BACKEND="$(
    RESOLVER_DEVELOPMENT_ROOT='~/configured' \
        run_resolver "$WORKING_DIRECTORY" resolve-backend
)"
assert_equal "$(canonical_fixture_path "$CONFIGURED_BACKEND")" "$RESOLVED_BACKEND" \
    'configured development root did not take precedence'
pass 'development lookup expands and prioritizes the configured root'

rm -f "$CONFIGURED_BACKEND"
RESOLVED_BACKEND="$(
    RESOLVER_DEVELOPMENT_ROOT='~/configured' \
        run_resolver "$WORKING_DIRECTORY" resolve-backend
)"
assert_equal "$(canonical_fixture_path "$INFERRED_BACKEND")" "$RESOLVED_BACKEND" \
    'inferred checkout was discarded when a development root was configured'
pass 'configured development root falls through to the inferred checkout'

rm -f "$INFERRED_BACKEND"
RESOLVED_BACKEND="$(run_resolver "$WORKING_DIRECTORY" resolve-backend)"
assert_equal "$(canonical_fixture_path "$CURRENT_BACKEND")" "$RESOLVED_BACKEND" \
    'current-directory development backend was not discovered'
pass 'development lookup searches the current directory after the checkout'

rm -f "$CURRENT_BACKEND"
RESOLVED_BACKEND="$(run_resolver "$WORKING_DIRECTORY" resolve-backend)"
assert_equal "$(canonical_fixture_path "$PARENT_BACKEND")" "$RESOLVED_BACKEND" \
    'parent development backend did not precede the user-local backend'
pass 'development lookup searches the parent before user-local storage'

rm -f "$PARENT_BACKEND"
RESOLVED_BACKEND="$(run_resolver "$WORKING_DIRECTORY" resolve-backend)"
assert_equal "$(canonical_fixture_path "$USER_BACKEND")" "$RESOLVED_BACKEND" \
    'user-local backend was not used after development candidates'
pass 'user-local lookup remains the final backend fallback'

PROBE_BACKEND="$TEMP_ROOT/probe/$FIXTURE_BACKEND"
make_backend "$PROBE_BACKEND"

PROBE_OUTPUT="$(
    RESOLVER_VERSION_OVERRIDE=$' \t\nv1.8.4 \r\n' \
        run_resolver "$WORKING_DIRECTORY" probe-backend "$PROBE_BACKEND"
)"
grep -q '^version=1\.8\.4$' <<< "$PROBE_OUTPUT" || \
    fail 'version override was not trimmed and normalized'
pass 'version override trims its edges and normalizes a leading v'

RESOLVER_VERSION_OVERRIDE='V1.8.4' \
    expect_failure 'uppercase version override' \
    run_resolver "$WORKING_DIRECTORY" probe-backend "$PROBE_BACKEND"
grep -q 'did not report a version' "$TEMP_ROOT/last.stderr" || \
    fail 'invalid nonempty version override did not fail closed'
pass 'invalid nonempty version override does not fall through'

PROBE_OUTPUT="$(
    RESOLVER_VERSION_OVERRIDE=$' \t\n ' \
    MOCK_BACKEND_VERSION_OUTPUT='fixture vErSiOn: 1.9.1' \
        run_resolver "$WORKING_DIRECTORY" probe-backend "$PROBE_BACKEND"
)"
grep -q '^version=1\.9\.1$' <<< "$PROBE_OUTPUT" || \
    fail 'whitespace-only override did not fall through to mixed-case version output'
pass 'whitespace-only override falls through to case-insensitive probe output'

printf ' \n v1.8.4 \t\n' > "${PROBE_BACKEND}.version"
PROBE_OUTPUT="$(run_resolver "$WORKING_DIRECTORY" probe-backend "$PROBE_BACKEND")"
grep -q '^version=1\.8\.4$' <<< "$PROBE_OUTPUT" || \
    fail 'version sidecar was not edge-trimmed and normalized'
pass 'version sidecar trims only surrounding whitespace and normalizes v'

printf '1.8. 4\n' > "${PROBE_BACKEND}.version"
PROBE_OUTPUT="$(
    MOCK_BACKEND_VERSION_OUTPUT='fixture version 1.9.1' \
        run_resolver "$WORKING_DIRECTORY" probe-backend "$PROBE_BACKEND"
)"
grep -q '^version=1\.9\.1$' <<< "$PROBE_OUTPUT" || \
    fail 'invalid sidecar did not fall through to executable version output'
pass 'internal sidecar whitespace is rejected instead of removed'

CELLAR_BACKEND="$TEMP_ROOT/Cellar/whisper-cpp/v1.8.4/bin/$FIXTURE_BACKEND"
make_backend "$CELLAR_BACKEND"
PROBE_OUTPUT="$(
    MOCK_BACKEND_VERSION_OUTPUT='usage only' \
        run_resolver "$WORKING_DIRECTORY" probe-backend "$CELLAR_BACKEND"
)"
grep -q '^version=1\.8\.4$' <<< "$PROBE_OUTPUT" || \
    fail 'Cellar version component did not normalize a leading v'
pass 'Cellar-derived versions use the same normalization policy'

mkdir -p "$TEMP_ROOT/http"
expect_failure 'HTTP failure' run_install http-failure "$TEMP_ROOT/http/model.bin"
assert_absent "$TEMP_ROOT/http/model.bin"
assert_no_download_temps "$TEMP_ROOT/http"
grep -q 'HTTP 503' "$TEMP_ROOT/last.stderr" || fail 'HTTP failure was not reported clearly'
pass 'HTTP failure handling retains the required fail and retry policy'

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

mkdir -p "$TEMP_ROOT/preservation"
printf 'previous verified release model\n' > "$TEMP_ROOT/preservation/model.bin"
cp "$TEMP_ROOT/preservation/model.bin" "$TEMP_ROOT/preservation/original.bin"
expect_failure 'failed replacement preservation' \
    run_install digest-mismatch "$TEMP_ROOT/preservation/model.bin"
cmp "$TEMP_ROOT/preservation/original.bin" "$TEMP_ROOT/preservation/model.bin" >/dev/null || \
    fail 'failed replacement destroyed or changed the existing destination'
assert_no_download_temps "$TEMP_ROOT/preservation"
QUARANTINE_COUNT="$(find "$TEMP_ROOT/preservation" -name 'model.bin.invalid.*' | wc -l | tr -d '[:space:]')"
[[ "$QUARANTINE_COUNT" == 0 ]] || fail 'failed replacement quarantined the live destination prematurely'
pass 'failed download verification preserves the existing destination unchanged'

MV_WRAPPER_DIRECTORY="$TEMP_ROOT/mv-wrapper"
REAL_MV="$(command -v mv)"
mkdir -p "$MV_WRAPPER_DIRECTORY"
cat > "$MV_WRAPPER_DIRECTORY/mv" <<'EOF'
#!/bin/bash
set -euo pipefail

target="${!#}"
printf '%s\n' "$*" >> "$ATOMIC_MV_LOG"
if [[ "$target" == "$ATOMIC_DESTINATION" && ! -e "$target" ]]; then
    : > "$ATOMIC_MISSING_MARKER"
fi
if [[ "$target" == "$ATOMIC_DESTINATION" && "${ATOMIC_MV_FAIL_REPLACEMENT:-0}" == 1 ]]; then
    exit 75
fi
exec "$REAL_MV" "$@"
EOF
chmod 755 "$MV_WRAPPER_DIRECTORY/mv"

mkdir -p "$TEMP_ROOT/rename-failure"
printf 'previous verified release model\n' > "$TEMP_ROOT/rename-failure/model.bin"
cp "$TEMP_ROOT/rename-failure/model.bin" "$TEMP_ROOT/rename-failure/original.bin"
RENAME_FAILURE_LOG="$TEMP_ROOT/rename-failure/mv.log"
RENAME_FAILURE_MISSING="$TEMP_ROOT/rename-failure/destination-was-missing"
ATOMIC_DESTINATION="$TEMP_ROOT/rename-failure/model.bin" \
ATOMIC_MISSING_MARKER="$RENAME_FAILURE_MISSING" \
ATOMIC_MV_FAIL_REPLACEMENT=1 \
ATOMIC_MV_LOG="$RENAME_FAILURE_LOG" \
PATH="$MV_WRAPPER_DIRECTORY:$PATH" \
REAL_MV="$REAL_MV" \
    expect_failure 'atomic rename failure' \
    run_install valid "$TEMP_ROOT/rename-failure/model.bin"
cmp "$TEMP_ROOT/rename-failure/original.bin" "$TEMP_ROOT/rename-failure/model.bin" >/dev/null || \
    fail 'failed rename destroyed or moved the existing destination'
assert_absent "$RENAME_FAILURE_MISSING"
assert_no_download_temps "$TEMP_ROOT/rename-failure"
QUARANTINE_COUNT="$(find "$TEMP_ROOT/rename-failure" -name 'model.bin.invalid.*' | wc -l | tr -d '[:space:]')"
[[ "$QUARANTINE_COUNT" == 1 ]] || fail 'failed rename did not preserve exactly one quarantine'
QUARANTINE_PATH="$(find "$TEMP_ROOT/rename-failure" -name 'model.bin.invalid.*' -print -quit)"
cmp "$TEMP_ROOT/rename-failure/original.bin" "$QUARANTINE_PATH" >/dev/null || \
    fail 'failed rename quarantine did not preserve the previous destination'
pass 'failed atomic rename leaves the existing destination live and unchanged'

mkdir -p "$TEMP_ROOT/atomic"
printf 'not-a-model\n' > "$TEMP_ROOT/atomic/model.bin"
cp "$TEMP_ROOT/atomic/model.bin" "$TEMP_ROOT/atomic/original.bin"
MV_LOG="$TEMP_ROOT/atomic/mv.log"
MISSING_MARKER="$TEMP_ROOT/atomic/destination-was-missing"
ATOMIC_DESTINATION="$TEMP_ROOT/atomic/model.bin" \
ATOMIC_MISSING_MARKER="$MISSING_MARKER" \
ATOMIC_MV_FAIL_REPLACEMENT=0 \
ATOMIC_MV_LOG="$MV_LOG" \
PATH="$MV_WRAPPER_DIRECTORY:$PATH" \
REAL_MV="$REAL_MV" \
    run_install valid "$TEMP_ROOT/atomic/model.bin"
cmp "$VALID_FIXTURE" "$TEMP_ROOT/atomic/model.bin" >/dev/null || fail 'verified replacement was not installed'
QUARANTINE_COUNT="$(find "$TEMP_ROOT/atomic" -name 'model.bin.invalid.*' | wc -l | tr -d '[:space:]')"
[[ "$QUARANTINE_COUNT" == 1 ]] || fail 'invalid cache was not quarantined exactly once'
QUARANTINE_PATH="$(find "$TEMP_ROOT/atomic" -name 'model.bin.invalid.*' -print -quit)"
cmp "$TEMP_ROOT/atomic/original.bin" "$QUARANTINE_PATH" >/dev/null || \
    fail 'quarantine did not preserve the previous destination'
MV_COUNT="$(wc -l < "$MV_LOG" | tr -d '[:space:]')"
[[ "$MV_COUNT" == 1 ]] || fail 'replacement used more than one rename operation'
assert_absent "$MISSING_MARKER"
assert_no_download_temps "$TEMP_ROOT/atomic"
pass 'verified temporary atomically renames over the live path while preserving quarantine'

printf '1..%d\n' "$pass_count"
