#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -swift-version 5 -O -module-cache-path .build/ModuleCache \
  Sources/DiskCore.swift Sources/FileEvents.swift Sources/DirectoryReader.swift Sources/IndexSchema.swift Sources/DiskIndex.swift \
  Tests/FirstScanSmoke.swift -o .build/first-scan-smoke
.build/first-scan-smoke
