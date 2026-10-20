#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Capture production views with synthetic data and isolated preferences.
# Requires a logged-in macOS GUI session and screen recording permission.
export DISKLENS_CAPTURE_UI=1
export DISKLENS_CAPTURE_DIR=".build/documentation-previews"
bash scripts/check-release.sh
bash scripts/check-settings.sh

xcrun swiftc -swift-version 5 -module-cache-path .build/ModuleCache \
  Sources/AppBrand.swift scripts/GenerateIcon.swift -o .build/generate-doc-icon
.build/generate-doc-icon .build/documentation-icon.iconset
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .build/ModuleCache \
  scripts/FrameScreenshot.swift -o .build/frame-screenshot

mkdir -p docs/screenshots
.build/frame-screenshot "$DISKLENS_CAPTURE_DIR/main.png" docs/preview.png
.build/frame-screenshot "$DISKLENS_CAPTURE_DIR/compact.png" docs/screenshots/directory.png
.build/frame-screenshot "$DISKLENS_CAPTURE_DIR/dark.png" docs/screenshots/dark.png
.build/frame-screenshot "$DISKLENS_CAPTURE_DIR/settings.png" docs/screenshots/settings.png
cp .build/documentation-icon.iconset/icon_256x256.png docs/icon.png
echo "Updated documentation screenshots and app icon."
