#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"
APP_PATH="${1:-}"
SOURCE_INFO="$REPOSITORY_ROOT/TalkText/Info.plist"
SOURCE_ENTITLEMENTS="$REPOSITORY_ROOT/TalkText/TalkText.entitlements"
DEPENDENCY_MANIFEST="${TALKTEXT_DEPENDENCY_MANIFEST:-$REPOSITORY_ROOT/dependencies.env}"
EXPECTED_SIGNATURE="${TALKTEXT_EXPECTED_SIGNATURE:-adhoc}"
EXPECTED_ARCHITECTURES=(arm64 x86_64)

fail() {
    echo "error: $*" >&2
    exit 1
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

plist_string() {
    plutil -extract "$2" raw -expect string -o - "$1"
}

normalize_architectures() {
    tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort | paste -sd ' ' -
}

for command_name in codesign lipo plutil file vtool; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command is unavailable: $command_name"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail "/usr/libexec/PlistBuddy is unavailable"
[[ -r "$SOURCE_INFO" ]] || fail "canonical Info.plist is missing"
[[ -r "$SOURCE_ENTITLEMENTS" ]] || fail "canonical entitlements are missing"
plutil -lint "$SOURCE_INFO" "$SOURCE_ENTITLEMENTS" >/dev/null

EXPECTED_EXECUTABLE_NAME="$(plist_string "$SOURCE_INFO" CFBundleExecutable)" || \
    fail "canonical Info.plist is missing CFBundleExecutable"
EXPECTED_BUNDLE_NAME="$(plist_string "$SOURCE_INFO" CFBundleName)" || \
    fail "canonical Info.plist is missing CFBundleName"
EXPECTED_BUNDLE_IDENTIFIER="$(plist_string "$SOURCE_INFO" CFBundleIdentifier)" || \
    fail "canonical Info.plist is missing CFBundleIdentifier"
EXPECTED_PACKAGE_TYPE="$(plist_string "$SOURCE_INFO" CFBundlePackageType)" || \
    fail "canonical Info.plist is missing CFBundlePackageType"
EXPECTED_MINIMUM_SYSTEM_VERSION="$(plist_string "$SOURCE_INFO" LSMinimumSystemVersion)" || \
    fail "canonical Info.plist is missing LSMinimumSystemVersion"

if [[ -z "$APP_PATH" ]]; then
    APP_PATH="$REPOSITORY_ROOT/$EXPECTED_BUNDLE_NAME.app"
fi
[[ -d "$APP_PATH" ]] || fail "app bundle is missing: $APP_PATH"

VERSION="$("$SCRIPT_DIR/read-version.sh")"
FINAL_INFO="$APP_PATH/Contents/Info.plist"
[[ -r "$FINAL_INFO" ]] || fail "final Info.plist is missing"
plutil -lint "$FINAL_INFO" >/dev/null

for version_key in CFBundleVersion CFBundleShortVersionString; do
    if plist_value "$SOURCE_INFO" "$version_key" >/dev/null 2>&1; then
        fail "$SOURCE_INFO duplicates $version_key; VERSION must be canonical"
    fi
    [[ "$(plist_value "$FINAL_INFO" "$version_key")" == "$VERSION" ]] || \
        fail "$version_key does not match VERSION ($VERSION)"
done

CANONICAL_KEYS=(
    CFBundleDevelopmentRegion
    CFBundleDisplayName
    CFBundleInfoDictionaryVersion
    LSUIElement
    NSHighResolutionCapable
    NSMicrophoneUsageDescription
)
for key in "${CANONICAL_KEYS[@]}"; do
    source_value="$(plist_value "$SOURCE_INFO" "$key")" || fail "canonical Info.plist is missing $key"
    final_value="$(plist_value "$FINAL_INFO" "$key")" || fail "final Info.plist is missing $key"
    [[ "$source_value" == "$final_value" ]] || fail "final $key differs from canonical Info.plist"
done

EXECUTABLE_NAME="$(plist_string "$FINAL_INFO" CFBundleExecutable)" || fail "final Info.plist is missing CFBundleExecutable"
BUNDLE_NAME="$(plist_string "$FINAL_INFO" CFBundleName)" || fail "final Info.plist is missing CFBundleName"
BUNDLE_IDENTIFIER="$(plist_string "$FINAL_INFO" CFBundleIdentifier)" || fail "final Info.plist is missing CFBundleIdentifier"
PACKAGE_TYPE="$(plist_string "$FINAL_INFO" CFBundlePackageType)" || fail "final Info.plist is missing CFBundlePackageType"
MINIMUM_SYSTEM_VERSION="$(plist_string "$FINAL_INFO" LSMinimumSystemVersion)" || \
    fail "final Info.plist is missing LSMinimumSystemVersion"

[[ "$EXECUTABLE_NAME" == "$EXPECTED_EXECUTABLE_NAME" ]] || \
    fail "final CFBundleExecutable differs from canonical Info.plist"
[[ "$BUNDLE_NAME" == "$EXPECTED_BUNDLE_NAME" ]] || \
    fail "final CFBundleName differs from canonical Info.plist"
[[ "$BUNDLE_IDENTIFIER" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] || \
    fail "final CFBundleIdentifier differs from canonical Info.plist"
[[ "$PACKAGE_TYPE" == "$EXPECTED_PACKAGE_TYPE" ]] || \
    fail "final CFBundlePackageType differs from canonical Info.plist"
[[ "$MINIMUM_SYSTEM_VERSION" == "$EXPECTED_MINIMUM_SYSTEM_VERSION" ]] || \
    fail "final LSMinimumSystemVersion differs from canonical Info.plist"
[[ "$(plist_value "$FINAL_INFO" LSUIElement)" == 'true' ]] || fail "TalkText must remain a menu-bar-only app"
[[ -n "$(plist_value "$FINAL_INFO" NSMicrophoneUsageDescription)" ]] || fail "microphone usage text is empty"

EXECUTABLE="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
[[ -f "$EXECUTABLE" && -x "$EXECUTABLE" ]] || fail "bundle executable is missing or not executable"
file "$EXECUTABLE" | grep -Fq 'Mach-O universal binary' || fail "bundle executable is not a universal Mach-O"

ACTUAL_ARCHITECTURES="$(lipo -archs "$EXECUTABLE" | normalize_architectures)"
EXPECTED_ARCHITECTURES_NORMALIZED="$(printf '%s\n' "${EXPECTED_ARCHITECTURES[*]}" | normalize_architectures)"
[[ "$ACTUAL_ARCHITECTURES" == "$EXPECTED_ARCHITECTURES_NORMALIZED" ]] || \
    fail "architecture policy mismatch (expected $EXPECTED_ARCHITECTURES_NORMALIZED, found $ACTUAL_ARCHITECTURES)"
for architecture in "${EXPECTED_ARCHITECTURES[@]}"; do
    BUILD_VERSION="$(vtool -show-build -arch "$architecture" "$EXECUTABLE")"
    grep -Eq '^[[:space:]]*platform MACOS$' <<< "$BUILD_VERSION" || fail "$architecture slice is not a macOS executable"
    SLICE_MINIMUM_SYSTEM_VERSION="$(awk '$1 == "minos" { print $2; exit }' <<< "$BUILD_VERSION")"
    [[ "$SLICE_MINIMUM_SYSTEM_VERSION" == "$EXPECTED_MINIMUM_SYSTEM_VERSION" ]] || \
        fail "$architecture slice minimum system version differs from canonical Info.plist"
done

# Source the canonical dependency name, then independently verify the model
# inside the bundle (size, format, and digest).
[[ -r "$DEPENDENCY_MANIFEST" ]] || fail "dependency manifest is missing: $DEPENDENCY_MANIFEST"
# shellcheck source=/dev/null
source "$DEPENDENCY_MANIFEST"
[[ -n "${MODEL_FILE_NAME:-}" ]] || fail "dependency manifest does not define MODEL_FILE_NAME"
BUNDLED_MODEL="$APP_PATH/Contents/Resources/models/$MODEL_FILE_NAME"
TALKTEXT_DEPENDENCY_MANIFEST="$DEPENDENCY_MANIFEST" \
    "$SCRIPT_DIR/dependency-tool.sh" verify-model "$BUNDLED_MODEL"

codesign --verify --deep --strict --verbose=4 "$APP_PATH"
SIGNATURE_DETAILS="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
grep -Fq "Identifier=$BUNDLE_IDENTIFIER" <<< "$SIGNATURE_DETAILS" || fail "signature identifier does not match Info.plist"
grep -Eq 'flags=0x[0-9a-f]+\(.*runtime.*\)' <<< "$SIGNATURE_DETAILS" || fail "hardened runtime flag is missing"
grep -Eq 'Info.plist entries=[1-9][0-9]*' <<< "$SIGNATURE_DETAILS" || fail "Info.plist is not bound into the signature"
grep -Eq 'Sealed Resources version=2 rules=[1-9][0-9]* files=[1-9][0-9]*' <<< "$SIGNATURE_DETAILS" || \
    fail "bundle resources are not sealed"

case "$EXPECTED_SIGNATURE" in
    adhoc)
        grep -Fq 'Signature=adhoc' <<< "$SIGNATURE_DETAILS" || fail "CI bundle is not ad hoc signed"
        grep -Fq 'TeamIdentifier=not set' <<< "$SIGNATURE_DETAILS" || fail "unexpected team identifier on ad hoc bundle"
        ;;
    developer-id)
        grep -Fq 'Authority=Developer ID Application:' <<< "$SIGNATURE_DETAILS" || fail "Developer ID authority is missing"
        grep -Eq '^Timestamp=' <<< "$SIGNATURE_DETAILS" || fail "secure signing timestamp is missing"
        EXPECTED_TEAM_ID="${TALKTEXT_EXPECTED_TEAM_ID:-}"
        [[ -n "$EXPECTED_TEAM_ID" ]] || fail "TALKTEXT_EXPECTED_TEAM_ID is required for release verification"
        grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" <<< "$SIGNATURE_DETAILS" || fail "signature TeamIdentifier does not match"
        ;;
    *)
        fail "TALKTEXT_EXPECTED_SIGNATURE must be 'adhoc' or 'developer-id'"
        ;;
esac

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/talktext-verify.XXXXXX")"
cleanup() {
    rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT HUP INT TERM

codesign --display --entitlements - --xml "$APP_PATH" >"$TEMP_DIR/embedded-entitlements.plist" 2>/dev/null
plutil -convert xml1 -o "$TEMP_DIR/source-entitlements.xml" "$SOURCE_ENTITLEMENTS"
plutil -convert xml1 -o "$TEMP_DIR/embedded-entitlements.xml" "$TEMP_DIR/embedded-entitlements.plist"
cmp -s "$TEMP_DIR/source-entitlements.xml" "$TEMP_DIR/embedded-entitlements.xml" || \
    fail "embedded signing entitlements differ from TalkText/TalkText.entitlements"

if [[ "${TALKTEXT_REQUIRE_NOTARIZATION:-0}" == '1' ]]; then
    xcrun stapler validate -v "$APP_PATH"
    spctl --assess --type execute --verbose=4 "$APP_PATH"
fi

if [[ "${TALKTEXT_X86_64_SMOKE_TEST:-0}" == '1' ]]; then
    SMOKE_LOG="$TEMP_DIR/x86_64-smoke.log"
    /usr/bin/arch -x86_64 "$EXECUTABLE" >"$SMOKE_LOG" 2>&1 &
    smoke_pid=$!
    sleep 3
    if ! kill -0 "$smoke_pid" >/dev/null 2>&1; then
        wait "$smoke_pid" || true
        sed -n '1,160p' "$SMOKE_LOG" >&2
        fail "x86_64 executable did not remain alive during the launch smoke test"
    fi
    kill -TERM "$smoke_pid" >/dev/null 2>&1 || true
    wait "$smoke_pid" >/dev/null 2>&1 || true
fi

echo "Verified $APP_PATH"
echo "  bundle identifier: $BUNDLE_IDENTIFIER"
echo "  version: $VERSION"
echo "  architectures: $ACTUAL_ARCHITECTURES"
echo "  signature: $EXPECTED_SIGNATURE with hardened runtime"
