#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="${1:-$PWD/.build}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
app="$output/Gestures.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" .build
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.0 -warnings-as-errors -O -whole-module-optimization \
  -module-name Gestures -Xlinker -dead_strip Sources/*.swift -o "$app/Contents/MacOS/Gestures"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppleRipple-LICENSE.txt "$app/Contents/Resources/AppleRipple-LICENSE.txt"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
xcrun swift Scripts/MakeIcon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
identity="${SIGNING_IDENTITY:--}"
signing_options=(--force --sign "$identity" --options runtime --entitlements Resources/Gestures.entitlements)
if [[ "$identity" != "-" ]]; then signing_options+=(--timestamp); fi
codesign "${signing_options[@]}" "$app"
codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
