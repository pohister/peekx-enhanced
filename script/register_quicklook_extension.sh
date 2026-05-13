#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  script/register_quicklook_extension.sh [Debug|Release] [--no-build]

Builds PeekX into a stable DerivedData directory, removes old PeekX Quick Look
extension registrations, registers the freshly built extension, and refreshes
Quick Look caches.
USAGE
}

CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    Debug|Release)
      CONFIGURATION="$1"
      ;;
    --no-build)
      BUILD=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$PROJECT_ROOT/PeekX.xcodeproj"
SCHEME="PeekX"
BUNDLE_ID="com.pohister.PeekX.PeekXExt"
DERIVED_DATA_PATH="${PEEKX_DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/PeekX-Registered}"
XCODE_DEVELOPER_DIR="${PEEKX_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/PeekX.app"
APPEX_PATH="$APP_PATH/Contents/PlugIns/PeekXExt.appex"

if [[ "$CONFIGURATION" != "Debug" && "$CONFIGURATION" != "Release" ]]; then
  echo "Configuration must be Debug or Release, got: $CONFIGURATION" >&2
  exit 2
fi

cd "$PROJECT_ROOT"

if [[ "$BUILD" -eq 1 ]]; then
  echo "Building $SCHEME ($CONFIGURATION) into $DERIVED_DATA_PATH"
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      build
fi

if [[ ! -d "$APPEX_PATH" ]]; then
  echo "Built extension not found: $APPEX_PATH" >&2
  exit 1
fi

echo "Removing old registrations for $BUNDLE_ID"
registered_paths_file="$(mktemp)"
trap 'rm -f "$registered_paths_file"' EXIT

/usr/bin/pluginkit -m -A -D -vvv |
  awk -v id="$BUNDLE_ID" '
    index($0, id) > 0 { wantPath = 1; next }
    wantPath && /Path = / {
      sub(/^.*Path = /, "")
      print
      wantPath = 0
    }
  ' |
  sort -u > "$registered_paths_file"

while IFS= read -r registered_path; do
  if [[ -n "$registered_path" ]]; then
    echo "  unregister $registered_path"
    /usr/bin/pluginkit -r "$registered_path" 2>/dev/null || true
  fi
done < "$registered_paths_file"

echo "Registering $APPEX_PATH"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
  -f -R -trusted "$APP_PATH"
/usr/bin/pluginkit -a "$APPEX_PATH"
/usr/bin/pluginkit -e use -i "$BUNDLE_ID"

echo "Refreshing Quick Look caches"
/usr/bin/pkill -x qlmanage 2>/dev/null || true
/usr/bin/killall quicklookd 2>/dev/null || true
/usr/bin/killall QuickLookUIService 2>/dev/null || true
/usr/bin/killall QuickLookSatellite 2>/dev/null || true
/usr/bin/qlmanage -r >/dev/null 2>&1 || true
/usr/bin/qlmanage -r cache >/dev/null 2>&1 || true

echo "Current PeekX registrations:"
/usr/bin/pluginkit -m -A -D -v |
  awk -v id="$BUNDLE_ID" 'index($0, id) > 0 { print }'
