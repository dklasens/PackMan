#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

for required_tool in xcodebuild xcode-select codesign ditto plutil lipo shasum hdiutil; do
    if ! command -v "$required_tool" >/dev/null 2>&1; then
        echo "error: '$required_tool' is required." >&2
        exit 1
    fi
done

DEVELOPER_DIR="$(xcode-select -p)"
case "$DEVELOPER_DIR" in
    */Xcode.app/Contents/Developer|*/Xcode_*.app/Contents/Developer) ;;
    *)
        echo "error: Full Xcode is required. The active developer directory is: $DEVELOPER_DIR" >&2
        echo "Open Xcode once, then run: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2
        exit 1
        ;;
esac

# project.yml is the canonical release metadata; CI may explicitly override it.
DEFAULT_VERSION="$(awk '/^[[:space:]]*MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' project.yml)"
DEFAULT_BUILD="$(awk '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' project.yml)"
VERSION="${PACKMAN_VERSION:-$DEFAULT_VERSION}"
BUILD_NUMBER="${PACKMAN_BUILD_NUMBER:-$DEFAULT_BUILD}"
ARCHITECTURES="${PACKMAN_ARCHS:-arm64 x86_64}"
BUILD_ROOT="${PACKMAN_BUILD_ROOT:-$SCRIPT_DIR/.build/xcode-release}"
OUTPUT_DIR="$SCRIPT_DIR/dist"
SOURCE_APP="$BUILD_ROOT/Build/Products/Release/PackMan.app"
APP="$OUTPUT_DIR/PackMan.app"
ARCHIVE="$OUTPUT_DIR/PackMan-macOS.zip"
CHECKSUM="$ARCHIVE.sha256"
DISK_IMAGE="$OUTPUT_DIR/PackMan-macOS.dmg"
DISK_IMAGE_CHECKSUM="$DISK_IMAGE.sha256"

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "error: PACKMAN_VERSION must contain one to three numeric components (for example, 1.2.3)." >&2
    exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: PACKMAN_BUILD_NUMBER must be a positive integer." >&2
    exit 1
fi

echo "Building PackMan $VERSION ($BUILD_NUMBER) for $ARCHITECTURES..."
xcodebuild clean build \
    -project PackMan.xcodeproj \
    -scheme PackMan \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$BUILD_ROOT" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    ARCHS="$ARCHITECTURES" \
    ONLY_ACTIVE_ARCH=NO \
    CLANG_ENABLE_CODE_COVERAGE=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM=

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "error: Xcode did not produce $SOURCE_APP" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$APP"
rm -f "$ARCHIVE" "$CHECKSUM" "$DISK_IMAGE" "$DISK_IMAGE_CHECKSUM"
ditto "$SOURCE_APP" "$APP"

echo "Applying an ad-hoc signature (no Apple Developer account required)..."
codesign --force --deep --options runtime --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ACTUAL_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
ACTUAL_BUILD="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"
if [[ "$ACTUAL_VERSION" != "$VERSION" || "$ACTUAL_BUILD" != "$BUILD_NUMBER" ]]; then
    echo "error: Built app has version $ACTUAL_VERSION ($ACTUAL_BUILD), expected $VERSION ($BUILD_NUMBER)." >&2
    exit 1
fi

lipo -info "$APP/Contents/MacOS/PackMan"
for architecture in $ARCHITECTURES; do
    lipo "$APP/Contents/MacOS/PackMan" -verify_arch "$architecture"
done
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

echo "Creating the disk image..."
DMG_STAGING="$(mktemp -d)"
trap 'rm -rf "$DMG_STAGING"' EXIT
ditto "$APP" "$DMG_STAGING/PackMan.app"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -quiet -volname "PackMan" -srcfolder "$DMG_STAGING" -fs HFS+ -format UDZO "$DISK_IMAGE"
rm -rf "$DMG_STAGING"
trap - EXIT

(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$CHECKSUM")"
    shasum -a 256 "$(basename "$DISK_IMAGE")" > "$(basename "$DISK_IMAGE_CHECKSUM")"
)

echo "Created: $APP"
echo "Created: $ARCHIVE"
echo "Checksum: $CHECKSUM"
echo "Created: $DISK_IMAGE"
echo "Checksum: $DISK_IMAGE_CHECKSUM"
