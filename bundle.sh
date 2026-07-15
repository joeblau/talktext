#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PACKAGE_DIR="$SCRIPT_DIR/TalkText"
INFO_TEMPLATE="$PACKAGE_DIR/Info.plist"
ENTITLEMENTS="$PACKAGE_DIR/TalkText.entitlements"
DEPENDENCY_MANIFEST="${TALKTEXT_DEPENDENCY_MANIFEST:-$SCRIPT_DIR/dependencies.env}"
SIGNING_MODE="${TALKTEXT_SIGNING_MODE:-adhoc}"
ARCHITECTURES=(arm64 x86_64)

fail() {
    echo "error: $*" >&2
    exit 1
}

validate_path_component() {
    local key="$1"
    local value="$2"
    case "$value" in
        '' | '.' | '..' | */* | *$'\n'* | *$'\r'*)
            fail "canonical $key is not a safe path component: $value"
            ;;
    esac
}

for command_name in swift lipo plutil codesign xattr; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command is unavailable: $command_name"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail "/usr/libexec/PlistBuddy is unavailable"
[[ -r "$INFO_TEMPLATE" ]] || fail "canonical Info.plist is not readable: $INFO_TEMPLATE"
[[ -r "$DEPENDENCY_MANIFEST" ]] || fail "dependency manifest is not readable: $DEPENDENCY_MANIFEST"
plutil -lint "$INFO_TEMPLATE" >/dev/null

EXECUTABLE_NAME="$(plutil -extract CFBundleExecutable raw -expect string -o - "$INFO_TEMPLATE")" || \
    fail "canonical Info.plist must define a string CFBundleExecutable"
BUNDLE_NAME="$(plutil -extract CFBundleName raw -expect string -o - "$INFO_TEMPLATE")" || \
    fail "canonical Info.plist must define a string CFBundleName"
MINIMUM_SYSTEM_VERSION="$(plutil -extract LSMinimumSystemVersion raw -expect string -o - "$INFO_TEMPLATE")" || \
    fail "canonical Info.plist must define a string LSMinimumSystemVersion"
validate_path_component CFBundleExecutable "$EXECUTABLE_NAME"
validate_path_component CFBundleName "$BUNDLE_NAME"
[[ "$MINIMUM_SYSTEM_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || \
    fail "canonical LSMinimumSystemVersion is not a numeric version: $MINIMUM_SYSTEM_VERSION"
BUNDLE_PATH="$SCRIPT_DIR/$BUNDLE_NAME.app"

# shellcheck source=/dev/null
source "$DEPENDENCY_MANIFEST"
[[ -n "${MODEL_FILE_NAME:-}" ]] || fail "dependency manifest does not define MODEL_FILE_NAME"

VERSION="$("$SCRIPT_DIR/scripts/read-version.sh")"
MODEL_PATH="${TALKTEXT_MODEL_PATH:-$SCRIPT_DIR/models/$MODEL_FILE_NAME}"

case "$SIGNING_MODE" in
    adhoc)
        SIGNING_IDENTITY='-'
        TIMESTAMP_ARGUMENT='--timestamp=none'
        ;;
    developer-id)
        SIGNING_IDENTITY="${TALKTEXT_SIGNING_IDENTITY:-}"
        [[ -n "$SIGNING_IDENTITY" ]] || fail "TALKTEXT_SIGNING_IDENTITY is required for Developer ID signing"
        TIMESTAMP_ARGUMENT='--timestamp'
        ;;
    *)
        fail "TALKTEXT_SIGNING_MODE must be 'adhoc' or 'developer-id'"
        ;;
esac

build_product() {
    local architecture="$1"
    local scratch_path="$PACKAGE_DIR/.build/release-$architecture"
    local triple="$architecture-apple-macosx$MINIMUM_SYSTEM_VERSION"
    local bin_path

    if ! swift build \
        --package-path "$PACKAGE_DIR" \
        --configuration release \
        --triple "$triple" \
        --scratch-path "$scratch_path" \
        -Xswiftc -warnings-as-errors >&2; then
        fail "release build failed for $architecture"
    fi

    if ! bin_path="$(swift build \
        --package-path "$PACKAGE_DIR" \
        --configuration release \
        --triple "$triple" \
        --scratch-path "$scratch_path" \
        --show-bin-path)"; then
        fail "could not resolve SwiftPM product path for $architecture"
    fi
    [[ -x "$bin_path/$EXECUTABLE_NAME" ]] || fail "SwiftPM did not produce $bin_path/$EXECUTABLE_NAME"
    printf '%s\n' "$bin_path/$EXECUTABLE_NAME"
}

echo "==> Building warnings-as-errors Universal 2 release..."
ARM64_PRODUCT="$(build_product arm64)"
X86_64_PRODUCT="$(build_product x86_64)"

# Verify the exact dependency immediately before bundle assembly. The CI path
# supplies a tiny pinned fixture manifest; distributable releases use the
# production manifest and therefore verify the complete model digest.
TALKTEXT_DEPENDENCY_MANIFEST="$DEPENDENCY_MANIFEST" \
    "$SCRIPT_DIR/scripts/dependency-tool.sh" verify-model "$MODEL_PATH"

WORK_DIR="$(mktemp -d "$SCRIPT_DIR/.talktext-bundle.XXXXXX")"
cleanup() {
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

WORK_BUNDLE="$WORK_DIR/$BUNDLE_NAME.app"
CONTENTS="$WORK_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
mkdir -p "$MACOS" "$RESOURCES/models"

echo "==> Assembling canonical bundle metadata and resources..."
lipo -create "$ARM64_PRODUCT" "$X86_64_PRODUCT" -output "$MACOS/$EXECUTABLE_NAME"
chmod 755 "$MACOS/$EXECUTABLE_NAME"
cp -- "$MODEL_PATH" "$RESOURCES/models/$MODEL_FILE_NAME"
TALKTEXT_DEPENDENCY_MANIFEST="$DEPENDENCY_MANIFEST" \
    "$SCRIPT_DIR/scripts/dependency-tool.sh" verify-model "$RESOURCES/models/$MODEL_FILE_NAME"

cp -- "$INFO_TEMPLATE" "$CONTENTS/Info.plist"
if /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$CONTENTS/Info.plist" >/dev/null 2>&1 || \
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONTENTS/Info.plist" >/dev/null 2>&1; then
    fail "TalkText/Info.plist must not duplicate versions; VERSION is canonical"
fi
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist" >/dev/null

# Signing is deliberately last: the executable, model, and final Info.plist are
# all present before the code directory and resource seal are created.
echo "==> Signing finalized bundle ($SIGNING_MODE, hardened runtime)..."
xattr -cr "$WORK_BUNDLE"
codesign \
    --force \
    --verbose \
    --options runtime \
    "$TIMESTAMP_ARGUMENT" \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" \
    "$WORK_BUNDLE"

TALKTEXT_DEPENDENCY_MANIFEST="$DEPENDENCY_MANIFEST" \
TALKTEXT_EXPECTED_SIGNATURE="$SIGNING_MODE" \
    "$SCRIPT_DIR/scripts/verify-bundle.sh" "$WORK_BUNDLE"

rm -rf -- "$BUNDLE_PATH"
mv -- "$WORK_BUNDLE" "$BUNDLE_PATH"
trap - EXIT HUP INT TERM
rm -rf -- "$WORK_DIR"

echo "==> App bundle created: $BUNDLE_PATH"
echo "    Version: $VERSION"
echo "    Architectures: ${ARCHITECTURES[*]}"
if [[ "$SIGNING_MODE" == 'adhoc' ]]; then
    echo "    Signature: ad hoc CI/development signature (not distributable)"
else
    echo "    Signature: $SIGNING_IDENTITY"
fi
