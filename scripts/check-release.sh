#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
sources=()
for source in Sources/*.swift; do
  if [[ "$source" != "Sources/DiskLensApp.swift" ]]; then sources+=("$source"); fi
done
xcrun swiftc -swift-version 5 -module-cache-path .build/ModuleCache \
  -target "$(uname -m)-apple-macosx13.0" "${sources[@]}" Tests/ReleaseSmoke.swift -o .build/release-smoke
.build/release-smoke
