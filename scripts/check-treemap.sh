#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -swift-version 5 -module-cache-path .build/ModuleCache \
  -target "$(uname -m)-apple-macosx13.0" \
  Sources/DiskCore.swift Sources/FileEvents.swift Sources/DirectoryReader.swift Sources/IndexSchema.swift Sources/DiskIndex.swift \
  Sources/FileActions.swift Sources/TreemapLayout.swift Sources/TreemapView.swift Tests/TreemapSmoke.swift -o .build/treemap-smoke
.build/treemap-smoke
