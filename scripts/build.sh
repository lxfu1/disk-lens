#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_bundle="${1:-dist/DiskLens.app}"
mkdir -p .build "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
xcrun swiftc -swift-version 5 -O -module-cache-path .build/ModuleCache \
  -target "$(uname -m)-apple-macosx13.0" \
  Sources/DiskCore.swift Sources/FileEvents.swift Sources/DirectoryReader.swift Sources/IndexSchema.swift Sources/DiskIndex.swift Sources/IndexCoordinator.swift Sources/AppBrand.swift Sources/LoginStartup.swift Sources/SettingsView.swift Sources/AppModel.swift Sources/FileActions.swift Sources/TreemapLayout.swift Sources/TreemapView.swift Sources/ContentView.swift Sources/DiskLensApp.swift \
  -o .build/DiskLens
xcrun swiftc -swift-version 5 -module-cache-path .build/ModuleCache \
  Sources/AppBrand.swift scripts/GenerateIcon.swift -o .build/generate-icon
.build/generate-icon .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$app_bundle/Contents/Resources/AppIcon.icns"
# Replace the inode so an already-running app can keep executing its old binary.
cp .build/DiskLens "$app_bundle/Contents/MacOS/DiskLens.new"
mv -f "$app_bundle/Contents/MacOS/DiskLens.new" "$app_bundle/Contents/MacOS/DiskLens"
cp Info.plist "$app_bundle/Contents/Info.plist"
codesign --force --sign - "$app_bundle"
echo "Built: $app_bundle"
