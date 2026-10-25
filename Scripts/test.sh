#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.0 -warnings-as-errors -O \
  Sources/Models.swift Sources/KeyDisplay.swift Sources/ControlFeedback.swift Sources/Recognition.swift Sources/VisionTracking.swift Sources/Camera.swift \
  Sources/Actions.swift Sources/LibraryIO.swift Sources/Appearance.swift Sources/DesktopRipple.swift Sources/GlassFeedback.swift Sources/Store.swift Tests/Tests.swift -o .build/GesturesTests
.build/GesturesTests "$@"
