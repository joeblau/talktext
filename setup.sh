#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEPENDENCY_TOOL="$REPOSITORY_ROOT/scripts/dependency-tool.sh"
DEPENDENCY_MANIFEST="$REPOSITORY_ROOT/dependencies.env"
if [[ -n "${TALKTEXT_DEPENDENCY_MANIFEST:-}" && "$TALKTEXT_DEPENDENCY_MANIFEST" != "$DEPENDENCY_MANIFEST" ]]; then
    echo "error: setup does not accept a dependency manifest override" >&2
    exit 1
fi
export TALKTEXT_DEPENDENCY_MANIFEST="$DEPENDENCY_MANIFEST"
# shellcheck source=dependencies.env
source "$DEPENDENCY_MANIFEST"

echo "==> Resolving the supported whisper.cpp backend..."
if ! BACKEND_PATH="$("$DEPENDENCY_TOOL" resolve-backend)"; then
    if [[ -n "${TALKTEXT_WHISPER_CLI:-}" ]]; then
        echo "error: fix or unset TALKTEXT_WHISPER_CLI before running setup" >&2
        exit 1
    fi
    command -v brew >/dev/null 2>&1 || {
        echo "error: Homebrew is required to install $BACKEND_FORMULA" >&2
        exit 1
    }
    echo "    Installing $BACKEND_FORMULA via Homebrew..."
    brew install "$BACKEND_FORMULA"
    hash -r
    BACKEND_PATH="$("$DEPENDENCY_TOOL" resolve-backend)"
fi
"$DEPENDENCY_TOOL" probe-backend "$BACKEND_PATH" | sed 's/^/    /'

echo "==> Installing the pinned base.en model..."
MODEL_PATH="$REPOSITORY_ROOT/models/$MODEL_FILE_NAME"
"$DEPENDENCY_TOOL" install-model "$MODEL_PATH"

echo "==> Building app..."
swift build --package-path "$REPOSITORY_ROOT/TalkText" -c release
METADATA_FILE="$(mktemp "${TMPDIR:-/tmp}/talktext-canonical-metadata.XXXXXX")"
cleanup_metadata() {
    rm -f -- "$METADATA_FILE"
}
trap cleanup_metadata EXIT HUP INT TERM
"$REPOSITORY_ROOT/scripts/export-canonical-metadata.sh" "$METADATA_FILE"
EXECUTABLE_NAME=''
while IFS='=' read -r key value; do
    if [[ "$key" == 'TALKTEXT_EXECUTABLE_NAME' ]]; then
        EXECUTABLE_NAME="$value"
        break
    fi
done < "$METADATA_FILE"
[[ -n "$EXECUTABLE_NAME" ]] || {
    echo "error: canonical metadata export did not define TALKTEXT_EXECUTABLE_NAME" >&2
    exit 1
}
rm -f -- "$METADATA_FILE"
trap - EXIT HUP INT TERM

APP_PATH="$REPOSITORY_ROOT/TalkText/.build/release/$EXECUTABLE_NAME"
[[ -x "$APP_PATH" ]] || {
    echo "error: Swift build completed without producing $APP_PATH" >&2
    exit 1
}

echo ""
echo "==> Done! Run with:"
printf '   %q\n' "$APP_PATH"
echo ""
echo "Resolved dependencies:"
echo "   whisper-cli: $BACKEND_PATH"
echo "   model:       $MODEL_PATH"
echo ""
echo "NOTE: You'll need to grant Accessibility permissions in"
echo "System Settings > Privacy & Security > Accessibility"
echo "for the auto-paste feature to work."
