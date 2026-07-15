#!/bin/bash
set -euo pipefail

# Injects the canonical VERSION into the Info.plist of an Xcode-built product.
#
# The tracked TalkText/Info.plist deliberately carries no version keys, because
# VERSION is canonical and bundle.sh injects them during release assembly. This
# mirrors that behavior for Xcode builds so a development build reports the same
# version as a released one, without a second copy of the version in the project.
#
# Xcode runs this as a build phase and provides TARGET_BUILD_DIR and
# INFOPLIST_PATH. It runs before the CodeSign step, so the signature seals the
# finished plist.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

fail() {
    echo "error: $*" >&2
    exit 1
}

[[ -n "${TARGET_BUILD_DIR:-}" ]] || fail "TARGET_BUILD_DIR is unset; run this from an Xcode build phase"
[[ -n "${INFOPLIST_PATH:-}" ]] || fail "INFOPLIST_PATH is unset; run this from an Xcode build phase"

BUILT_INFO="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
[[ -f "$BUILT_INFO" ]] || fail "built Info.plist is missing: $BUILT_INFO"

VERSION="$("$SCRIPT_DIR/read-version.sh")"

set_version_key() {
    local key="$1"
    if /usr/libexec/PlistBuddy -c "Print :$key" "$BUILT_INFO" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :$key $VERSION" "$BUILT_INFO"
    else
        /usr/libexec/PlistBuddy -c "Add :$key string $VERSION" "$BUILT_INFO"
    fi
}

set_version_key CFBundleVersion
set_version_key CFBundleShortVersionString
plutil -lint "$BUILT_INFO" >/dev/null

echo "Injected version $VERSION into $INFOPLIST_PATH"
