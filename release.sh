#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

VERSION="$(tr -d '\n' < VERSION)"
DIST_DIR="dist"
ZIP_NAME="TalkText-${VERSION}.zip"
ZIP_PATH="${DIST_DIR}/${ZIP_NAME}"

mkdir -p "$DIST_DIR"

./bundle.sh

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "TalkText.app" "$ZIP_PATH"

echo ""
echo "Created: $ZIP_PATH"
echo "SHA256: $(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
