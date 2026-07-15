#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"
VERSION_FILE="${TALKTEXT_VERSION_FILE:-$REPOSITORY_ROOT/VERSION}"

fail() {
    echo "error: $*" >&2
    exit 1
}

[[ -f "$VERSION_FILE" && -r "$VERSION_FILE" ]] || fail "VERSION is not a readable file: $VERSION_FILE"
[[ "$(awk 'END { print NR }' "$VERSION_FILE")" == '1' ]] || fail "VERSION must contain exactly one line"

VERSION="$(sed -n '1p' "$VERSION_FILE")"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    fail "VERSION must be a three-component numeric semantic version (for example, 1.2.3)"
fi

printf '%s\n' "$VERSION"
