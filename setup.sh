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

MODEL_MANIFEST="$REPOSITORY_ROOT/$MODEL_MANIFEST_RELATIVE_PATH"
if [[ -n "${TALKTEXT_MODEL_MANIFEST:-}" && "$TALKTEXT_MODEL_MANIFEST" != "$MODEL_MANIFEST" ]]; then
    echo "error: setup does not accept a model manifest override" >&2
    exit 1
fi
export TALKTEXT_MODEL_MANIFEST="$MODEL_MANIFEST"
echo "==> Installing the pinned English Parakeet v2 models..."
MODEL_PATH="${TALKTEXT_MODEL_PATH:-$REPOSITORY_ROOT/models/$MODEL_DIRECTORY_NAME}"
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
echo "==> Done! Built executable:"
printf '   %q\n' "$APP_PATH"
echo ""
echo "Build and deploy the app with bun talktext, or build a local bundle with ./bundle.sh."
echo ""
echo "Resolved dependencies:"
echo "   backend:     FluidAudio $BACKEND_VERSION (built into TalkText)"
echo "   model:       $MODEL_PATH"
echo ""
echo "NOTE: You'll need to grant Accessibility permissions in"
echo "System Settings > Privacy & Security > Accessibility"
echo "for the auto-paste feature to work."
