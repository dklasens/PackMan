#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="dist/PackMan.app"

echo "Building release binary..."
swift build -c release

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PackMan "$APP/Contents/MacOS/PackMan"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "Ad-hoc code signing..."
codesign --force --sign - "$APP"

echo "Done: $APP"
