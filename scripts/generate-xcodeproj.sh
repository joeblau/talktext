#!/bin/bash
set -euo pipefail

# Generates the development-only Xcode project from project.yml.
#
# project.yml is a plain spec that works with a bare `xcodegen generate`, so its
# names are written literally rather than templated. This script is the checked
# entry point: it fails when those literals drift from the canonical sources
# (TalkText/Info.plist and VERSION) rather than letting a stale project build an
# app whose identity no longer matches a release.
#
# The generated .xcodeproj is disposable build output, not tracked source.
# Releases are still built by `swift build` + ./bundle.sh.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"
SPEC="$REPOSITORY_ROOT/project.yml"
SOURCE_INFO="$REPOSITORY_ROOT/TalkText/Info.plist"

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v xcodegen >/dev/null 2>&1 || \
    fail "xcodegen is not installed. Install it with: brew install xcodegen"
command -v jq >/dev/null 2>&1 || fail "required command is unavailable: jq"
[[ -r "$SPEC" ]] || fail "project spec is not readable: $SPEC"
[[ -r "$SOURCE_INFO" ]] || fail "canonical Info.plist is not readable: $SOURCE_INFO"

canonical() {
    plutil -extract "$1" raw -expect string -o - "$SOURCE_INFO" || \
        fail "canonical Info.plist must define a string $1"
}

EXPECTED_EXECUTABLE_NAME="$(canonical CFBundleExecutable)"
EXPECTED_BUNDLE_IDENTIFIER="$(canonical CFBundleIdentifier)"
EXPECTED_MINIMUM_SYSTEM_VERSION="$(canonical LSMinimumSystemVersion)"

# Compare the resolved spec, not the raw text, so formatting cannot hide drift.
SPEC_JSON="$(cd "$REPOSITORY_ROOT" && xcodegen dump --spec project.yml --type json)" || \
    fail "could not resolve $SPEC"

spec_value() {
    jq -er "$1" <<< "$SPEC_JSON" 2>/dev/null || fail "project.yml is missing $2"
}

SPEC_PRODUCT_NAME="$(spec_value '.targets.TalkText.settings.base.PRODUCT_NAME' 'the TalkText target PRODUCT_NAME')"
SPEC_BUNDLE_IDENTIFIER="$(spec_value '.targets.TalkText.settings.base.PRODUCT_BUNDLE_IDENTIFIER' 'the TalkText target PRODUCT_BUNDLE_IDENTIFIER')"
SPEC_DEPLOYMENT_TARGET="$(spec_value '.options.deploymentTarget.macOS' 'options.deploymentTarget.macOS')"
SPEC_INFOPLIST="$(spec_value '.targets.TalkText.settings.base.INFOPLIST_FILE' 'the TalkText target INFOPLIST_FILE')"

drift() {
    fail "project.yml $1 ($2) differs from canonical Info.plist $3 ($4). Update project.yml."
}

[[ "$SPEC_PRODUCT_NAME" == "$EXPECTED_EXECUTABLE_NAME" ]] || \
    drift PRODUCT_NAME "$SPEC_PRODUCT_NAME" CFBundleExecutable "$EXPECTED_EXECUTABLE_NAME"
[[ "$SPEC_BUNDLE_IDENTIFIER" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] || \
    drift PRODUCT_BUNDLE_IDENTIFIER "$SPEC_BUNDLE_IDENTIFIER" CFBundleIdentifier "$EXPECTED_BUNDLE_IDENTIFIER"
[[ "$SPEC_DEPLOYMENT_TARGET" == "$EXPECTED_MINIMUM_SYSTEM_VERSION" ]] || \
    drift deploymentTarget.macOS "$SPEC_DEPLOYMENT_TARGET" LSMinimumSystemVersion "$EXPECTED_MINIMUM_SYSTEM_VERSION"
[[ "$SPEC_INFOPLIST" == 'TalkText/Info.plist' ]] || \
    fail "project.yml INFOPLIST_FILE ($SPEC_INFOPLIST) must be the canonical TalkText/Info.plist"

# Prove the project's version source is usable before generating.
VERSION="$("$SCRIPT_DIR/read-version.sh")"

cd "$REPOSITORY_ROOT"
xcodegen generate --spec project.yml --project .

echo
echo "==> Generated TalkText.xcodeproj (development only)"
echo "    Bundle identifier: $EXPECTED_BUNDLE_IDENTIFIER"
echo "    Version at build:  $VERSION (injected from VERSION)"
echo "    Open with: open TalkText.xcodeproj"
echo "    Release builds still come from ./bundle.sh, not this project."
