#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -swift-version 5 -module-cache-path .build/ModuleCache \
  -target "$(uname -m)-apple-macosx13.0" \
  Sources/AppBrand.swift Sources/LoginStartup.swift Sources/SettingsView.swift Tests/SettingsSmoke.swift -o .build/settings-smoke
.build/settings-smoke
