#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -swift-version 5 -O -module-cache-path .build/ModuleCache \
  Sources/DiskCore.swift Sources/FileEvents.swift Sources/DirectoryReader.swift Sources/IndexSchema.swift Sources/DiskIndex.swift \
  Tests/StorageSmoke.swift -o .build/storage-smoke
.build/storage-smoke
python3 -B Tests/MigrationSmoke.py --reader .build/storage-smoke
