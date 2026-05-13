#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$PROJECT_ROOT/PeekX.xcodeproj"
SCHEME="${PEEKX_SCHEME:-PeekX}"
CONFIGURATION="${PEEKX_CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${PEEKX_PACKAGE_DERIVED_DATA_PATH:-$PROJECT_ROOT/build/PackageDerivedData}"
XCODE_DEVELOPER_DIR="${PEEKX_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP_NAME="${PEEKX_APP_NAME:-PeekX}"
DMG_NAME="${PEEKX_DMG_NAME:-PeekX-enhanced}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
DIST_DIR="$PROJECT_ROOT/dist"
DIST_APP_PATH="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$DMG_NAME.dmg"

usage() {
  cat <<'USAGE'
Usage:
  script/package_dmg.sh

Environment overrides:
  PEEKX_CONFIGURATION=Release|Debug
  PEEKX_PACKAGE_DERIVED_DATA_PATH=/path/to/derived-data
  PEEKX_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  PEEKX_DMG_NAME=PeekX-enhanced
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -d "$XCODE_DEVELOPER_DIR" ]]; then
  echo "Xcode developer directory not found: $XCODE_DEVELOPER_DIR" >&2
  exit 1
fi

cd "$PROJECT_ROOT"

echo "Building $SCHEME ($CONFIGURATION)"
DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    clean build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found: $APP_PATH" >&2
  exit 1
fi

echo "Verifying code signature"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

mkdir -p "$DIST_DIR"
rm -rf "$DIST_APP_PATH"
rm -f "$DMG_PATH"

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/peekx-dmg.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT

echo "Copying app to $DIST_APP_PATH"
/usr/bin/ditto "$APP_PATH" "$DIST_APP_PATH"

echo "Staging app bundle"
/usr/bin/ditto "$DIST_APP_PATH" "$STAGE_DIR/$APP_NAME.app"
/bin/ln -s /Applications "$STAGE_DIR/Applications"

echo "Creating $DMG_PATH"
/usr/bin/hdiutil create \
  -volname "$DMG_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "Verifying DMG"
/usr/bin/hdiutil verify "$DMG_PATH"

echo "Packaged app: $DIST_APP_PATH"
echo "DMG: $DMG_PATH"
