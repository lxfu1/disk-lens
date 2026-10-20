#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -swift-version 5 -O -module-cache-path .build/ModuleCache \
  Sources/DiskCore.swift Sources/FileEvents.swift Sources/DirectoryReader.swift Sources/IndexSchema.swift Sources/DiskIndex.swift Sources/IndexCoordinator.swift \
  Tests/PerformanceSmoke.swift -o .build/performance-smoke
.build/performance-smoke
