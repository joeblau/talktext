#!/bin/bash
set -euo pipefail

SWIFTLINT_VERSION='0.57.1'
SWIFTLINT_SHA256='aa2e0f8f8272545e5593ebedd7872db51132fcec4ead76d001bbe17af69c7ae5'
SWIFTLINT_URL="https://github.com/realm/SwiftLint/releases/download/$SWIFTLINT_VERSION/portable_swiftlint.zip"
SWIFTFORMAT_VERSION='0.55.4'
SWIFTFORMAT_SHA256='c252ba7109b247ad4e172a7a20ced02f0f9132ffdf379ca1cd8e360272950836'
SWIFTFORMAT_URL="https://github.com/nicklockwood/SwiftFormat/releases/download/$SWIFTFORMAT_VERSION/swiftformat.zip"

CACHE_ROOT="${TALKTEXT_CI_TOOL_CACHE:-${HOME:?}/.cache/talktext-tools}"
INSTALL_ROOT="$CACHE_ROOT/swiftlint-$SWIFTLINT_VERSION-swiftformat-$SWIFTFORMAT_VERSION"
BIN_DIR="$INSTALL_ROOT/bin"

for command_name in curl shasum unzip; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "error: required installer command is unavailable: $command_name" >&2
        exit 1
    }
done

tools_are_valid() {
    [[ -x "$BIN_DIR/swiftlint" && -x "$BIN_DIR/swiftformat" ]] || return 1
    [[ "$("$BIN_DIR/swiftlint" version)" == "$SWIFTLINT_VERSION" ]] || return 1
    [[ "$("$BIN_DIR/swiftformat" --version)" == "$SWIFTFORMAT_VERSION" ]] || return 1
}

if tools_are_valid; then
    printf '%s\n' "$BIN_DIR"
    exit 0
fi

rm -rf -- "$INSTALL_ROOT"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/talktext-ci-tools.XXXXXX")"
cleanup() {
    rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT HUP INT TERM

download_and_verify() {
    local url="$1"
    local expected_sha256="$2"
    local destination="$3"
    local actual_sha256

    curl --fail --location --retry 3 --retry-all-errors --silent --show-error \
        --output "$destination" "$url"
    actual_sha256="$(shasum -a 256 "$destination" | awk '{print $1}')"
    [[ "$actual_sha256" == "$expected_sha256" ]] || {
        echo "error: checksum mismatch for $url" >&2
        return 1
    }
}

download_and_verify "$SWIFTLINT_URL" "$SWIFTLINT_SHA256" "$TEMP_DIR/swiftlint.zip"
download_and_verify "$SWIFTFORMAT_URL" "$SWIFTFORMAT_SHA256" "$TEMP_DIR/swiftformat.zip"
unzip -q -j "$TEMP_DIR/swiftlint.zip" swiftlint -d "$TEMP_DIR/bin"
unzip -q -j "$TEMP_DIR/swiftformat.zip" swiftformat -d "$TEMP_DIR/bin"
chmod 755 "$TEMP_DIR/bin/swiftlint" "$TEMP_DIR/bin/swiftformat"

mkdir -p "$CACHE_ROOT"
mkdir -p "$INSTALL_ROOT"
mv -- "$TEMP_DIR/bin" "$BIN_DIR"
tools_are_valid || {
    rm -rf -- "$INSTALL_ROOT"
    echo "error: installed lint tools did not report their pinned versions" >&2
    exit 1
}

printf '%s\n' "$BIN_DIR"
