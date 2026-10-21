#!/bin/bash
set -euo pipefail

BRANDING_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ICON_TOOL='/Applications/Icon Composer.app/Contents/Executables/ictool'
[[ -x "$ICON_TOOL" ]] || { echo 'Icon Composer 2 is required to regenerate previews.' >&2; exit 1; }
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Compile once on a current Xcode. Checked-in results keep release/CI builds
# compatible with the project's Xcode 16.4 toolchain.
xcrun actool "$BRANDING_DIR/AppIcon.icon" \
    --compile "$WORK_DIR" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$WORK_DIR/partial.plist" \
    --output-format human-readable-text

mkdir -p "$BRANDING_DIR/Compiled" "$BRANDING_DIR/Previews"
cp -- "$WORK_DIR/AppIcon.icns" "$WORK_DIR/Assets.car" "$BRANDING_DIR/Compiled/"
for appearance in Default Dark TintedDark; do
    "$ICON_TOOL" "$BRANDING_DIR/AppIcon.icon" \
        --export-image \
        --output-file "$BRANDING_DIR/Previews/$appearance.png" \
        --platform macOS --rendition "$appearance" \
        --width 1024 --height 1024 --scale 1 --design-generation 27
done
