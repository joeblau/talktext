#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"
SOURCE_INFO="$REPOSITORY_ROOT/TalkText/Info.plist"
OUTPUT_FILE="${1:-${GITHUB_ENV:-}}"

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

command -v plutil >/dev/null 2>&1 || fail "required command is unavailable: plutil"
[[ -r "$SOURCE_INFO" ]] || fail "canonical Info.plist is not readable: $SOURCE_INFO"
[[ -n "$OUTPUT_FILE" ]] || fail "output path argument or GITHUB_ENV is required"
plutil -lint "$SOURCE_INFO" >/dev/null

BUNDLE_NAME="$(plutil -extract CFBundleName raw -expect string -o - "$SOURCE_INFO")" || \
    fail "canonical Info.plist must define a string CFBundleName"
EXECUTABLE_NAME="$(plutil -extract CFBundleExecutable raw -expect string -o - "$SOURCE_INFO")" || \
    fail "canonical Info.plist must define a string CFBundleExecutable"
MINIMUM_SYSTEM_VERSION="$(plutil -extract LSMinimumSystemVersion raw -expect string -o - "$SOURCE_INFO")" || \
    fail "canonical Info.plist must define a string LSMinimumSystemVersion"

validate_path_component CFBundleName "$BUNDLE_NAME"
validate_path_component CFBundleExecutable "$EXECUTABLE_NAME"
[[ "$MINIMUM_SYSTEM_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || \
    fail "canonical LSMinimumSystemVersion is not a numeric version: $MINIMUM_SYSTEM_VERSION"

{
    printf 'TALKTEXT_BUNDLE_NAME=%s\n' "$BUNDLE_NAME"
    printf 'TALKTEXT_EXECUTABLE_NAME=%s\n' "$EXECUTABLE_NAME"
    printf 'TALKTEXT_MINIMUM_SYSTEM_VERSION=%s\n' "$MINIMUM_SYSTEM_VERSION"
} >> "$OUTPUT_FILE"
