#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -swift-version 5 -module-cache-path .build/ModuleCache \
  Sources/DiskCore.swift Sources/FileEvents.swift Sources/DirectoryReader.swift Sources/IndexSchema.swift Sources/DiskIndex.swift Sources/IndexCoordinator.swift \
  Tests/EventSmoke.swift -o .build/event-smoke
.build/event-smoke
