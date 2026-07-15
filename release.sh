#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEPENDENCY_MANIFEST="$SCRIPT_DIR/dependencies.env"
SOURCE_INFO="$SCRIPT_DIR/TalkText/Info.plist"
RELEASE_TAG="${TALKTEXT_RELEASE_TAG:-${GITHUB_REF_NAME:-}}"
DIST_DIR="$SCRIPT_DIR/dist"

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

if [[ -n "${TALKTEXT_VERSION_FILE:-}" ]]; then
    fail "release does not accept a VERSION file override"
fi
unset TALKTEXT_VERSION_FILE

if [[ -n "${TALKTEXT_DEPENDENCY_MANIFEST:-}" && "$TALKTEXT_DEPENDENCY_MANIFEST" != "$DEPENDENCY_MANIFEST" ]]; then
    fail "release does not accept a dependency manifest override"
fi
export TALKTEXT_DEPENDENCY_MANIFEST="$DEPENDENCY_MANIFEST"

VERSION="$("$SCRIPT_DIR/scripts/read-version.sh")"
EXPECTED_TAG="v$VERSION"

for command_name in git ditto codesign spctl xcrun plutil shasum; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required release command is unavailable: $command_name"
done
[[ -r "$SOURCE_INFO" ]] || fail "canonical Info.plist is not readable: $SOURCE_INFO"
plutil -lint "$SOURCE_INFO" >/dev/null
BUNDLE_NAME="$(plutil -extract CFBundleName raw -expect string -o - "$SOURCE_INFO")" || \
    fail "canonical Info.plist must define a string CFBundleName"
validate_path_component CFBundleName "$BUNDLE_NAME"

APP_PATH="$SCRIPT_DIR/$BUNDLE_NAME.app"
ZIP_NAME="$BUNDLE_NAME-$VERSION.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
CHECKSUM_PATH="$ZIP_PATH.sha256"
SUBMISSION_ZIP="$DIST_DIR/.$BUNDLE_NAME-$VERSION-notarization.zip"
NOTARY_RESULT="$DIST_DIR/.$BUNDLE_NAME-$VERSION-notarization.json"

[[ -n "${TALKTEXT_SIGNING_IDENTITY:-}" ]] || fail "TALKTEXT_SIGNING_IDENTITY is required"
[[ -n "${APPLE_TEAM_ID:-}" ]] || fail "APPLE_TEAM_ID is required for signature verification"

if [[ -z "$RELEASE_TAG" ]]; then
    RELEASE_TAG="$(git -C "$SCRIPT_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
fi
[[ "$RELEASE_TAG" == "$EXPECTED_TAG" ]] || fail "release tag must be $EXPECTED_TAG (found ${RELEASE_TAG:-none})"
[[ -n "$(git -C "$SCRIPT_DIR" tag --list "$RELEASE_TAG")" ]] || fail "release tag does not exist locally: $RELEASE_TAG"
[[ "$(git -C "$SCRIPT_DIR" rev-list -n 1 "$RELEASE_TAG")" == "$(git -C "$SCRIPT_DIR" rev-parse HEAD)" ]] || \
    fail "$RELEASE_TAG does not point at the checked-out commit"
[[ -z "$(git -C "$SCRIPT_DIR" status --porcelain --untracked-files=normal)" ]] || \
    fail "release checkout must be clean"

NOTARY_ARGUMENTS=()
if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    NOTARY_ARGUMENTS+=(--keychain-profile "$NOTARYTOOL_PROFILE")
    if [[ -n "${NOTARYTOOL_KEYCHAIN:-}" ]]; then
        NOTARY_ARGUMENTS+=(--keychain "$NOTARYTOOL_KEYCHAIN")
    fi
else
    [[ -n "${APPLE_ID:-}" ]] || fail "APPLE_ID or NOTARYTOOL_PROFILE is required"
    [[ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]] || fail "APPLE_APP_SPECIFIC_PASSWORD or NOTARYTOOL_PROFILE is required"
    NOTARY_ARGUMENTS+=(
        --apple-id "$APPLE_ID"
        --team-id "$APPLE_TEAM_ID"
        --password "$APPLE_APP_SPECIFIC_PASSWORD"
    )
fi

mkdir -p "$DIST_DIR"
rm -f -- "$ZIP_PATH" "$CHECKSUM_PATH" "$SUBMISSION_ZIP" "$NOTARY_RESULT"
EXTRACT_DIR=''
cleanup() {
    if [[ -n "$EXTRACT_DIR" ]]; then
        rm -rf -- "$EXTRACT_DIR"
    fi
    rm -f -- "$SUBMISSION_ZIP" "$NOTARY_RESULT"
}
trap cleanup EXIT HUP INT TERM

echo "==> Building and Developer ID signing $RELEASE_TAG..."
TALKTEXT_SIGNING_MODE=developer-id \
TALKTEXT_EXPECTED_TEAM_ID="$APPLE_TEAM_ID" \
    "$SCRIPT_DIR/bundle.sh"

# Submit a transport archive. The final public archive is produced only after
# the accepted ticket has been stapled to the app.
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$SUBMISSION_ZIP"

echo "==> Submitting for notarization..."
xcrun notarytool submit "$SUBMISSION_ZIP" \
    --wait \
    --output-format json \
    "${NOTARY_ARGUMENTS[@]}" >"$NOTARY_RESULT"

NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_RESULT")"
NOTARY_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT")"
if [[ "$NOTARY_STATUS" != 'Accepted' ]]; then
    xcrun notarytool log "$NOTARY_ID" "${NOTARY_ARGUMENTS[@]}" || true
    fail "notarization request $NOTARY_ID finished with status $NOTARY_STATUS"
fi

echo "==> Stapling accepted ticket $NOTARY_ID..."
xcrun stapler staple -v "$APP_PATH"
TALKTEXT_EXPECTED_SIGNATURE=developer-id \
TALKTEXT_EXPECTED_TEAM_ID="$APPLE_TEAM_ID" \
TALKTEXT_REQUIRE_NOTARIZATION=1 \
    "$SCRIPT_DIR/scripts/verify-bundle.sh" "$APP_PATH"

echo "==> Creating final release archive..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

EXTRACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/talktext-release-verify.XXXXXX")"
ditto -x -k "$ZIP_PATH" "$EXTRACT_DIR"
EXTRACTED_APP="$EXTRACT_DIR/$BUNDLE_NAME.app"
TALKTEXT_EXPECTED_SIGNATURE=developer-id \
TALKTEXT_EXPECTED_TEAM_ID="$APPLE_TEAM_ID" \
TALKTEXT_REQUIRE_NOTARIZATION=1 \
    "$SCRIPT_DIR/scripts/verify-bundle.sh" "$EXTRACTED_APP"

(CDPATH= cd -- "$DIST_DIR" && shasum -a 256 "$ZIP_NAME" >"$ZIP_NAME.sha256")

echo "==> Release artifact is signed, notarized, stapled, and archive-verified"
echo "    Tag: $RELEASE_TAG"
echo "    Artifact: $ZIP_PATH"
echo "    SHA-256: $(awk '{print $1}' "$CHECKSUM_PATH")"
