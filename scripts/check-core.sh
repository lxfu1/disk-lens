#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -swift-version 5 -module-cache-path .build/ModuleCache \
  Sources/DiskCore.swift Sources/FileEvents.swift Sources/DirectoryReader.swift Sources/IndexSchema.swift Sources/DiskIndex.swift Tests/CoreSmoke.swift -o .build/core-smoke
.build/core-smoke
