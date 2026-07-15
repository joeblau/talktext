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
    LN_BIN="${INSTALL_LN_BIN:-}" \
    CP_BIN="${INSTALL_CP_BIN:-}" \
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

BUNDLE_MANIFEST_SOURCE_MARKER="$TEMP_ROOT/bundle-manifest-was-sourced"
BUNDLE_POISON_MANIFEST="$TEMP_ROOT/bundle-poison-dependencies.env"
cp "$FIXTURE_MANIFEST" "$BUNDLE_POISON_MANIFEST"
cat >> "$BUNDLE_POISON_MANIFEST" <<'EOF'
: > "${BUNDLE_MANIFEST_SOURCE_MARKER:?}"
EOF
expect_failure 'Developer ID bundle manifest override' \
    env \
        BUNDLE_MANIFEST_SOURCE_MARKER="$BUNDLE_MANIFEST_SOURCE_MARKER" \
        TALKTEXT_DEPENDENCY_MANIFEST="$BUNDLE_POISON_MANIFEST" \
        TALKTEXT_SIGNING_MODE=developer-id \
        "$REPOSITORY_ROOT/bundle.sh"
grep -q 'Developer ID bundling does not accept a dependency manifest override' "$TEMP_ROOT/last.stderr" || \
    fail 'Developer ID bundling did not reject the test dependency manifest explicitly'
assert_absent "$BUNDLE_MANIFEST_SOURCE_MARKER"
pass 'Developer ID bundling rejects a noncanonical manifest before sourcing it'

EXTERNAL_VERSION="$TEMP_ROOT/external-VERSION"
printf '9.9.9\n' > "$EXTERNAL_VERSION"

expect_failure 'release version override' \
    env TALKTEXT_VERSION_FILE="$EXTERNAL_VERSION" "$REPOSITORY_ROOT/release.sh"
grep -q 'release does not accept a VERSION file override' "$TEMP_ROOT/last.stderr" || \
    fail 'release did not reject the external VERSION explicitly'
pass 'production release rejects an external VERSION file'

expect_failure 'bundle version override' \
    env \
        TALKTEXT_SIGNING_MODE=developer-id \
        TALKTEXT_VERSION_FILE="$EXTERNAL_VERSION" \
        "$REPOSITORY_ROOT/bundle.sh"
grep -q 'bundle does not accept a VERSION file override' "$TEMP_ROOT/last.stderr" || \
    fail 'bundle did not reject the external VERSION explicitly'
pass 'bundle assembly rejects an external VERSION file'

expect_failure 'bundle verification version override' \
    env TALKTEXT_VERSION_FILE="$EXTERNAL_VERSION" "$REPOSITORY_ROOT/scripts/verify-bundle.sh"
grep -q 'bundle verification does not accept a VERSION file override' "$TEMP_ROOT/last.stderr" || \
    fail 'bundle verification did not reject the external VERSION explicitly'
pass 'bundle verification rejects an external VERSION file'

METADATA_EXPORT_REPOSITORY="$TEMP_ROOT/metadata-export-repository"
METADATA_EXPORT_ENV="$TEMP_ROOT/metadata-export.env"
mkdir -p "$METADATA_EXPORT_REPOSITORY/scripts" "$METADATA_EXPORT_REPOSITORY/TalkText"
cp "$REPOSITORY_ROOT/scripts/export-canonical-metadata.sh" "$METADATA_EXPORT_REPOSITORY/scripts/"
cp "$REPOSITORY_ROOT/TalkText/Info.plist" "$METADATA_EXPORT_REPOSITORY/TalkText/"
plutil -replace CFBundleName -string EchoFixture "$METADATA_EXPORT_REPOSITORY/TalkText/Info.plist"
plutil -replace CFBundleExecutable -string EchoFixtureExecutable "$METADATA_EXPORT_REPOSITORY/TalkText/Info.plist"
plutil -replace LSMinimumSystemVersion -string 13.3 "$METADATA_EXPORT_REPOSITORY/TalkText/Info.plist"
GITHUB_ENV="$METADATA_EXPORT_ENV" "$METADATA_EXPORT_REPOSITORY/scripts/export-canonical-metadata.sh"
grep -Fxq 'TALKTEXT_BUNDLE_NAME=EchoFixture' "$METADATA_EXPORT_ENV" || \
    fail 'metadata exporter retained the production bundle-name literal'
grep -Fxq 'TALKTEXT_EXECUTABLE_NAME=EchoFixtureExecutable' "$METADATA_EXPORT_ENV" || \
    fail 'metadata exporter retained the production executable-name literal'
grep -Fxq 'TALKTEXT_MINIMUM_SYSTEM_VERSION=13.3' "$METADATA_EXPORT_ENV" || \
    fail 'metadata exporter retained the production deployment-target literal'
pass 'workflow metadata export follows differential canonical plist values'

for workflow in "$REPOSITORY_ROOT/.github/workflows/ci.yml" "$REPOSITORY_ROOT/.github/workflows/release.yml"; do
    grep -Fq 'run: ./scripts/export-canonical-metadata.sh' "$workflow" || \
        fail "workflow does not export canonical metadata: $workflow"
done
if grep -Eq 'apple-macosx14\.0|CMAKE_OSX_DEPLOYMENT_TARGET=14\.0|TalkText-ci\.zip|zip_name="TalkText-|/TalkText\.app' \
    "$REPOSITORY_ROOT/.github/workflows/ci.yml" "$REPOSITORY_ROOT/.github/workflows/release.yml"; then
    fail 'workflow retains a hard-coded app artifact or deployment target'
fi
grep -Fq 'apple-macosx$TALKTEXT_MINIMUM_SYSTEM_VERSION' "$REPOSITORY_ROOT/.github/workflows/ci.yml" || \
    fail 'CI Swift triples do not use canonical minimum-system metadata'
grep -Fq 'CMAKE_OSX_DEPLOYMENT_TARGET="$TALKTEXT_MINIMUM_SYSTEM_VERSION"' \
    "$REPOSITORY_ROOT/.github/workflows/ci.yml" || \
    fail 'CI backend builds do not use canonical minimum-system metadata'
grep -Fq 'zip_name="$TALKTEXT_BUNDLE_NAME-$version.zip"' "$REPOSITORY_ROOT/.github/workflows/release.yml" || \
    fail 'release assets do not use canonical bundle-name metadata'
[[ "$(grep -Fc './release.sh verify-source' "$REPOSITORY_ROOT/.github/workflows/release.yml")" == 2 ]] || \
    fail 'release workflow does not recheck immutable source immediately before both publication transitions'
grep -Fq 'TALKTEXT_RELEASE_COMMIT: ${{ github.sha }}' "$REPOSITORY_ROOT/.github/workflows/release.yml" || \
    fail 'release workflow does not bind source checks to the immutable event commit'
pass 'CI and release workflows consume canonical artifact and deployment metadata'

METADATA_BUNDLE_REPOSITORY="$TEMP_ROOT/metadata-bundle-repository"
METADATA_FAKE_BIN="$TEMP_ROOT/metadata-fake-bin"
METADATA_PRODUCT_BIN="$TEMP_ROOT/metadata-products"
METADATA_SWIFT_LOG="$TEMP_ROOT/metadata-swift.log"
METADATA_PACKAGE_DUMP="$TEMP_ROOT/metadata-package.json"
METADATA_SPCTL_COUNT="$TEMP_ROOT/metadata-spctl-count"
mkdir -p \
    "$METADATA_BUNDLE_REPOSITORY/TalkText" \
    "$METADATA_BUNDLE_REPOSITORY/TalkText/Sources/TalkText" \
    "$METADATA_BUNDLE_REPOSITORY/TalkText/Tests/TalkTextTests" \
    "$METADATA_BUNDLE_REPOSITORY/scripts" \
    "$METADATA_FAKE_BIN" \
    "$METADATA_PRODUCT_BIN"
cp "$REPOSITORY_ROOT/bundle.sh" "$METADATA_BUNDLE_REPOSITORY/"
cp "$REPOSITORY_ROOT/release.sh" "$METADATA_BUNDLE_REPOSITORY/"
cp "$REPOSITORY_ROOT/.gitignore" "$METADATA_BUNDLE_REPOSITORY/"
cp "$REPOSITORY_ROOT/VERSION" "$METADATA_BUNDLE_REPOSITORY/"
cp "$REPOSITORY_ROOT/TalkText/Package.swift" "$METADATA_BUNDLE_REPOSITORY/TalkText/"
cp "$REPOSITORY_ROOT/TalkText/Info.plist" "$METADATA_BUNDLE_REPOSITORY/TalkText/"
cp "$REPOSITORY_ROOT/TalkText/TalkText.entitlements" "$METADATA_BUNDLE_REPOSITORY/TalkText/"
cp "$REPOSITORY_ROOT/scripts/dependency-tool.sh" "$METADATA_BUNDLE_REPOSITORY/scripts/"
cp "$REPOSITORY_ROOT/scripts/read-version.sh" "$METADATA_BUNDLE_REPOSITORY/scripts/"
cp "$REPOSITORY_ROOT/scripts/verify-bundle.sh" "$METADATA_BUNDLE_REPOSITORY/scripts/"
cp "$FIXTURE_MANIFEST" "$METADATA_BUNDLE_REPOSITORY/dependencies.env"
plutil -replace CFBundleName -string EchoFixture "$METADATA_BUNDLE_REPOSITORY/TalkText/Info.plist"
plutil -replace CFBundleExecutable -string EchoFixtureExecutable "$METADATA_BUNDLE_REPOSITORY/TalkText/Info.plist"
plutil -replace CFBundleIdentifier -string com.example.echo-fixture "$METADATA_BUNDLE_REPOSITORY/TalkText/Info.plist"
plutil -replace LSMinimumSystemVersion -string 13.3 "$METADATA_BUNDLE_REPOSITORY/TalkText/Info.plist"

if ! CLANG_MODULE_CACHE_PATH="$TEMP_ROOT/swift-module-cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$TEMP_ROOT/swift-module-cache" \
    swift package --disable-sandbox dump-package \
        --package-path "$METADATA_BUNDLE_REPOSITORY/TalkText" \
        > "$METADATA_PACKAGE_DUMP"; then
    fail 'real Package.swift did not evaluate with differential canonical metadata'
fi
PACKAGE_PRODUCT_NAME="$(plutil -extract products.0.name raw -o - "$METADATA_PACKAGE_DUMP")"
PACKAGE_TARGET_NAME="$(plutil -extract targets.0.name raw -o - "$METADATA_PACKAGE_DUMP")"
PACKAGE_NAME="$(plutil -extract name raw -o - "$METADATA_PACKAGE_DUMP")"
PACKAGE_MINIMUM_SYSTEM_VERSION="$(plutil -extract platforms.0.version raw -o - "$METADATA_PACKAGE_DUMP")"
assert_equal EchoFixture "$PACKAGE_NAME" \
    'SwiftPM package name did not follow differential CFBundleName'
assert_equal EchoFixtureExecutable "$PACKAGE_PRODUCT_NAME" \
    'SwiftPM product name did not follow differential CFBundleExecutable'
assert_equal EchoFixtureExecutable "$PACKAGE_TARGET_NAME" \
    'SwiftPM executable target did not follow differential CFBundleExecutable'
assert_equal 13.3 "$PACKAGE_MINIMUM_SYSTEM_VERSION" \
    'SwiftPM platform did not follow differential LSMinimumSystemVersion'

cat > "$METADATA_FAKE_BIN/swift" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "${METADATA_SWIFT_LOG:?}"
if [[ " $* " == *' --show-bin-path '* ]]; then
    printf '%s\n' "${METADATA_PRODUCT_BIN:?}"
fi
EOF
cat > "$METADATA_FAKE_BIN/lipo" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == '-archs' ]]; then
    printf '%s\n' 'arm64 x86_64'
    exit 0
fi
output=''
while (( $# )); do
    if [[ "$1" == '-output' ]]; then
        output="$2"
        shift 2
    else
        shift
    fi
done
[[ -n "$output" ]]
: > "$output"
EOF
cat > "$METADATA_FAKE_BIN/codesign" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ " $* " == *' --entitlements '* ]]; then
    cat "${METADATA_SOURCE_ENTITLEMENTS:?}"
    exit 0
fi
if [[ " $* " == *' --display '* ]]; then
    app_path="${!#}"
    identifier="$(plutil -extract CFBundleIdentifier raw -expect string -o - "$app_path/Contents/Info.plist")"
    printf '%s\n' \
        "Identifier=$identifier" \
        'flags=0x10000(runtime)' \
        'Info.plist entries=18' \
        'Sealed Resources version=2 rules=13 files=3'
    if [[ "${TALKTEXT_EXPECTED_SIGNATURE:-adhoc}" == 'developer-id' ]]; then
        printf '%s\n' \
            'Authority=Developer ID Application: Fixture' \
            'Timestamp=Jul 15, 2026 at 10:00:00' \
            "TeamIdentifier=${TALKTEXT_EXPECTED_TEAM_ID:?}"
    else
        printf '%s\n' 'Signature=adhoc' 'TeamIdentifier=not set'
    fi
fi
EOF
cat > "$METADATA_FAKE_BIN/xattr" <<'EOF'
#!/bin/bash
set -euo pipefail
exit 0
EOF
cat > "$METADATA_FAKE_BIN/file" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s: Mach-O universal binary with 2 architectures\n' "${1:-fixture}"
EOF
cat > "$METADATA_FAKE_BIN/vtool" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' '      platform MACOS' '         minos 13.3'
EOF
cat > "$METADATA_FAKE_BIN/ditto" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == '-c' ]]; then
    source_path="${@: -2:1}"
    destination="${!#}"
    rm -rf -- "${destination}.contents"
    mkdir -p "${destination}.contents"
    cp -R -- "$source_path" "${destination}.contents/"
    : > "$destination"
elif [[ "${1:-}" == '-x' ]]; then
    source_path="${@: -2:1}"
    destination="${!#}"
    mkdir -p "$destination"
    cp -R -- "${source_path}.contents/." "$destination/"
else
    exit 64
fi
EOF
cat > "$METADATA_FAKE_BIN/xcrun" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == 'notarytool' && "${2:-}" == 'submit' ]]; then
    printf '%s\n' '{"status":"Accepted","id":"fixture-notary-id"}'
fi
EOF
cat > "$METADATA_FAKE_BIN/spctl" <<'EOF'
#!/bin/bash
set -euo pipefail

count=0
if [[ -r "${METADATA_SPCTL_COUNT:?}" ]]; then
    count="$(<"$METADATA_SPCTL_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$METADATA_SPCTL_COUNT"
if [[ "${METADATA_MUTATE_ON_SPCTL:-0}" == 1 && "$count" == 2 ]]; then
    printf '\n' >> "${METADATA_CANONICAL_INFO:?}"
fi
EOF
printf '#!/bin/bash\nexit 0\n' > "$METADATA_PRODUCT_BIN/EchoFixtureExecutable"
chmod 755 \
    "$METADATA_BUNDLE_REPOSITORY/bundle.sh" \
    "$METADATA_BUNDLE_REPOSITORY/release.sh" \
    "$METADATA_BUNDLE_REPOSITORY/scripts/dependency-tool.sh" \
    "$METADATA_BUNDLE_REPOSITORY/scripts/read-version.sh" \
    "$METADATA_BUNDLE_REPOSITORY/scripts/verify-bundle.sh" \
    "$METADATA_FAKE_BIN/swift" \
    "$METADATA_FAKE_BIN/lipo" \
    "$METADATA_FAKE_BIN/codesign" \
    "$METADATA_FAKE_BIN/xattr" \
    "$METADATA_FAKE_BIN/file" \
    "$METADATA_FAKE_BIN/vtool" \
    "$METADATA_FAKE_BIN/ditto" \
    "$METADATA_FAKE_BIN/xcrun" \
    "$METADATA_FAKE_BIN/spctl" \
    "$METADATA_PRODUCT_BIN/EchoFixtureExecutable"

if ! PATH="$METADATA_FAKE_BIN:$PATH" \
    METADATA_SOURCE_ENTITLEMENTS="$METADATA_BUNDLE_REPOSITORY/TalkText/TalkText.entitlements" \
    METADATA_PRODUCT_BIN="$METADATA_PRODUCT_BIN" \
    METADATA_SWIFT_LOG="$METADATA_SWIFT_LOG" \
    TALKTEXT_MODEL_PATH="$VALID_FIXTURE" \
    TALKTEXT_SIGNING_MODE=adhoc \
        "$METADATA_BUNDLE_REPOSITORY/bundle.sh" \
        > "$TEMP_ROOT/metadata-bundle.stdout" \
        2> "$TEMP_ROOT/metadata-bundle.stderr"; then
    sed -n '1,120p' "$TEMP_ROOT/metadata-bundle.stderr" >&2
    fail 'differential canonical-metadata bundle failed'
fi

METADATA_APP="$METADATA_BUNDLE_REPOSITORY/EchoFixture.app"
[[ -d "$METADATA_APP" ]] || fail 'bundle did not use the differential CFBundleName'
assert_absent "$METADATA_BUNDLE_REPOSITORY/TalkText.app"
[[ -x "$METADATA_APP/Contents/MacOS/EchoFixtureExecutable" ]] || \
    fail 'bundle did not use the differential CFBundleExecutable'
grep -Fq -- '--triple arm64-apple-macosx13.3' "$METADATA_SWIFT_LOG" || \
    fail 'arm64 bundle build did not use the differential deployment target'
grep -Fq -- '--triple x86_64-apple-macosx13.3' "$METADATA_SWIFT_LOG" || \
    fail 'x86_64 bundle build did not use the differential deployment target'
if grep -Fq 'apple-macosx14.0' "$METADATA_SWIFT_LOG"; then
    fail 'bundle retained the production deployment-target literal'
fi
grep -Eq '^Verified .*/EchoFixture\.app$' "$TEMP_ROOT/metadata-bundle.stdout" || \
    fail 'real bundle verifier did not verify the differential app path'

cp "$METADATA_APP/Contents/Info.plist" "$TEMP_ROOT/metadata-final-info.plist"
plutil -replace CFBundleIdentifier -string com.joeblau.talktext "$METADATA_APP/Contents/Info.plist"
PATH="$METADATA_FAKE_BIN:$PATH" \
METADATA_SOURCE_ENTITLEMENTS="$METADATA_BUNDLE_REPOSITORY/TalkText/TalkText.entitlements" \
    expect_failure 'real verifier canonical identifier mismatch' \
    "$METADATA_BUNDLE_REPOSITORY/scripts/verify-bundle.sh" "$METADATA_APP"
grep -q 'final CFBundleIdentifier differs from canonical Info.plist' "$TEMP_ROOT/last.stderr" || \
    fail 'real verifier did not reject metadata differing from the altered canonical plist'
cp "$TEMP_ROOT/metadata-final-info.plist" "$METADATA_APP/Contents/Info.plist"
pass 'Package.swift, bundle assembly, and real verification follow differential canonical metadata'

git -C "$METADATA_BUNDLE_REPOSITORY" init -q
git -C "$METADATA_BUNDLE_REPOSITORY" config user.email fixture@example.com
git -C "$METADATA_BUNDLE_REPOSITORY" config user.name 'Fixture Release'
git -C "$METADATA_BUNDLE_REPOSITORY" add .
git -C "$METADATA_BUNDLE_REPOSITORY" commit -qm 'Differential metadata fixture'
METADATA_RELEASE_VERSION="$("$METADATA_BUNDLE_REPOSITORY/scripts/read-version.sh")"
METADATA_RELEASE_TAG="v$METADATA_RELEASE_VERSION"
git -C "$METADATA_BUNDLE_REPOSITORY" tag "$METADATA_RELEASE_TAG"
METADATA_RELEASE_COMMIT="$(git -C "$METADATA_BUNDLE_REPOSITORY" rev-parse HEAD)"

run_metadata_release() {
    PATH="$METADATA_FAKE_BIN:$PATH" \
    METADATA_CANONICAL_INFO="$METADATA_BUNDLE_REPOSITORY/TalkText/Info.plist" \
    METADATA_MUTATE_ON_SPCTL="${METADATA_MUTATE_ON_SPCTL:-0}" \
    METADATA_PRODUCT_BIN="$METADATA_PRODUCT_BIN" \
    METADATA_SOURCE_ENTITLEMENTS="$METADATA_BUNDLE_REPOSITORY/TalkText/TalkText.entitlements" \
    METADATA_SPCTL_COUNT="$METADATA_SPCTL_COUNT" \
    METADATA_SWIFT_LOG="$METADATA_SWIFT_LOG" \
    APPLE_TEAM_ID=FIXTURETEAM \
    NOTARYTOOL_PROFILE=fixture-profile \
    TALKTEXT_MODEL_PATH="$VALID_FIXTURE" \
    TALKTEXT_RELEASE_COMMIT="$METADATA_RELEASE_COMMIT" \
    TALKTEXT_RELEASE_TAG="$METADATA_RELEASE_TAG" \
    TALKTEXT_SIGNING_IDENTITY='Developer ID Application: Fixture' \
        "$METADATA_BUNDLE_REPOSITORY/release.sh"
}

if ! run_metadata_release \
    > "$TEMP_ROOT/metadata-release.stdout" \
    2> "$TEMP_ROOT/metadata-release.stderr"; then
    sed -n '1,160p' "$TEMP_ROOT/metadata-release.stderr" >&2
    fail 'real release.sh failed with differential canonical metadata'
fi
METADATA_RELEASE_ZIP="$METADATA_BUNDLE_REPOSITORY/dist/EchoFixture-$METADATA_RELEASE_VERSION.zip"
[[ -f "$METADATA_RELEASE_ZIP" ]] || fail 'release archive did not use differential CFBundleName'
[[ -f "$METADATA_RELEASE_ZIP.sha256" ]] || fail 'release checksum did not follow differential archive path'
assert_absent "$METADATA_BUNDLE_REPOSITORY/dist/TalkText-$METADATA_RELEASE_VERSION.zip"
grep -Eq "Artifact: .*/EchoFixture-$METADATA_RELEASE_VERSION\\.zip$" "$TEMP_ROOT/metadata-release.stdout" || \
    fail 'release output retained the production archive path'

PATH="$METADATA_FAKE_BIN:$PATH" \
TALKTEXT_RELEASE_COMMIT="$METADATA_RELEASE_COMMIT" \
TALKTEXT_RELEASE_TAG="$METADATA_RELEASE_TAG" \
    "$METADATA_BUNDLE_REPOSITORY/release.sh" verify-source \
    > "$TEMP_ROOT/metadata-source-verify.stdout"
grep -Fq "Verified immutable release source $METADATA_RELEASE_TAG at $METADATA_RELEASE_COMMIT" \
    "$TEMP_ROOT/metadata-source-verify.stdout" || \
    fail 'standalone pre-publication source verification did not bind the tag and commit'

run_metadata_source_verify() {
    PATH="$METADATA_FAKE_BIN:$PATH" \
    TALKTEXT_RELEASE_COMMIT="$METADATA_RELEASE_COMMIT" \
    TALKTEXT_RELEASE_TAG="$METADATA_RELEASE_TAG" \
        "$METADATA_BUNDLE_REPOSITORY/release.sh" verify-source
}

METADATA_OTHER_COMMIT="$(
    printf 'fixture release drift\n' | \
        git -C "$METADATA_BUNDLE_REPOSITORY" commit-tree \
            "$METADATA_RELEASE_COMMIT^{tree}" \
            -p "$METADATA_RELEASE_COMMIT"
)"
git -C "$METADATA_BUNDLE_REPOSITORY" tag -f "$METADATA_RELEASE_TAG" "$METADATA_OTHER_COMMIT" >/dev/null
expect_failure 'immutable release tag drift' run_metadata_source_verify
grep -q "$METADATA_RELEASE_TAG no longer points at the immutable release commit" "$TEMP_ROOT/last.stderr" || \
    fail 'standalone source verification did not reject tag drift'
git -C "$METADATA_BUNDLE_REPOSITORY" tag -f "$METADATA_RELEASE_TAG" "$METADATA_RELEASE_COMMIT" >/dev/null

git -C "$METADATA_BUNDLE_REPOSITORY" update-ref HEAD "$METADATA_OTHER_COMMIT"
expect_failure 'immutable release HEAD drift' run_metadata_source_verify
grep -q 'HEAD changed after release verification began' "$TEMP_ROOT/last.stderr" || \
    fail 'standalone source verification did not reject HEAD drift'
git -C "$METADATA_BUNDLE_REPOSITORY" update-ref HEAD "$METADATA_RELEASE_COMMIT"

: > "$METADATA_BUNDLE_REPOSITORY/unexpected-release-input"
expect_failure 'immutable release worktree drift' run_metadata_source_verify
grep -q 'release checkout changed after verification began' "$TEMP_ROOT/last.stderr" || \
    fail 'standalone source verification did not reject worktree drift'
rm -f "$METADATA_BUNDLE_REPOSITORY/unexpected-release-input"
pass 'standalone release source verification rejects tag, HEAD, and worktree drift'

rm -f "$METADATA_SPCTL_COUNT"
METADATA_MUTATE_ON_SPCTL=1 \
    expect_failure 'release source drift after archive verification' run_metadata_release
grep -q 'canonical release file changed after verification began: TalkText/Info.plist' \
    "$TEMP_ROOT/last.stderr" || \
    fail 'release did not fail closed when canonical metadata drifted after archive verification'
pass 'release archive derivation follows canonical metadata and immutable source drift fails closed'

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
MOCK_BACKEND_VERSION_OUTPUT='fixture version 1.9.1' \
    expect_failure 'malformed version sidecar' \
    run_resolver "$WORKING_DIRECTORY" probe-backend "$PROBE_BACKEND"
grep -q 'did not report a version' "$TEMP_ROOT/last.stderr" || \
    fail 'malformed sidecar did not fail closed'
pass 'malformed version sidecar is authoritative invalid metadata'

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
[[ "$QUARANTINE_COUNT" == 0 ]] || fail 'failed rename left a redundant quarantine behind'
grep -q 'atomic model replacement failed; existing model was left unchanged' "$TEMP_ROOT/last.stderr" || \
    fail 'failed rename did not report the preserved live destination'

ATOMIC_DESTINATION="$TEMP_ROOT/rename-failure/model.bin" \
ATOMIC_MISSING_MARKER="$RENAME_FAILURE_MISSING" \
ATOMIC_MV_FAIL_REPLACEMENT=1 \
ATOMIC_MV_LOG="$RENAME_FAILURE_LOG" \
PATH="$MV_WRAPPER_DIRECTORY:$PATH" \
REAL_MV="$REAL_MV" \
    expect_failure 'atomic rename retry failure' \
    run_install valid "$TEMP_ROOT/rename-failure/model.bin"
cmp "$TEMP_ROOT/rename-failure/original.bin" "$TEMP_ROOT/rename-failure/model.bin" >/dev/null || \
    fail 'failed retry changed the existing destination'
assert_absent "$RENAME_FAILURE_MISSING"
assert_no_download_temps "$TEMP_ROOT/rename-failure"
QUARANTINE_COUNT="$(find "$TEMP_ROOT/rename-failure" -name 'model.bin.invalid.*' | wc -l | tr -d '[:space:]')"
[[ "$QUARANTINE_COUNT" == 0 ]] || fail 'failed retry accumulated another quarantine'
pass 'failed atomic replacement cleans its quarantine and remains retry-idempotent'

NO_HARD_LINK="$TEMP_ROOT/no-hard-link"
cat > "$NO_HARD_LINK" <<'EOF'
#!/bin/bash
set -euo pipefail
exit 95
EOF
chmod 755 "$NO_HARD_LINK"
mkdir -p "$TEMP_ROOT/copy-quarantine"
printf 'invalid cache on a no-hard-link filesystem\n' > "$TEMP_ROOT/copy-quarantine/model.bin"
cp "$TEMP_ROOT/copy-quarantine/model.bin" "$TEMP_ROOT/copy-quarantine/original.bin"
INSTALL_LN_BIN="$NO_HARD_LINK" \
    run_install valid "$TEMP_ROOT/copy-quarantine/model.bin" \
    > "$TEMP_ROOT/copy-quarantine/stdout" \
    2> "$TEMP_ROOT/copy-quarantine/stderr"
cmp "$VALID_FIXTURE" "$TEMP_ROOT/copy-quarantine/model.bin" >/dev/null || \
    fail 'hard-link failure blocked verified model repair'
QUARANTINE_COUNT="$(find "$TEMP_ROOT/copy-quarantine" -name 'model.bin.invalid.*' | wc -l | tr -d '[:space:]')"
[[ "$QUARANTINE_COUNT" == 1 ]] || fail 'copy fallback did not preserve exactly one quarantine'
QUARANTINE_PATH="$(find "$TEMP_ROOT/copy-quarantine" -name 'model.bin.invalid.*' -print -quit)"
cmp "$TEMP_ROOT/copy-quarantine/original.bin" "$QUARANTINE_PATH" >/dev/null || \
    fail 'copy fallback quarantine did not preserve the invalid cache'
grep -q 'Hard-link quarantine unavailable; copied invalid model as:' "$TEMP_ROOT/copy-quarantine/stderr" || \
    fail 'hard-link fallback was not reported clearly'
assert_no_download_temps "$TEMP_ROOT/copy-quarantine"
pass 'no-hard-link filesystems fall back to a copied quarantine without blocking repair'

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
