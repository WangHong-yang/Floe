#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Floe.app"
[[ -d "$APP" ]] || { echo "Build Floe first: bash scripts/build.sh"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
OUTPUT="$ROOT/dist/Floe-$VERSION-arm64.dmg"
mkdir -p "$ROOT/build"
STAGING=$(mktemp -d "$ROOT/build/dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
codesign --verify --deep --strict "$APP"
ditto "$APP" "$STAGING/Floe.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/Install.txt" <<'EOF'
Floe — local Chinese and English dictation

1. Drag Floe.app into Applications.
2. Eject this disk image.
3. Open Floe from Applications.
4. Enable Microphone, Input Monitoring and Accessibility when prompted.

Requires Apple Silicon and macOS 14 or later. The model is included.
This preview is ad-hoc signed and has not been Apple-notarized.
If macOS blocks the first launch:
- Try opening Floe from Applications once.
- Open System Settings > Privacy & Security > Open Anyway.
- Authenticate if asked, then confirm Open.
Only allow the app downloaded from the official Floe GitHub release.
Do not disable Gatekeeper or system-wide security protections.
Managed Macs may prevent this exception.

Source and release downloads: https://github.com/WangHong-yang/Floe
EOF
hdiutil create -ov -volname "Floe $VERSION" -srcfolder "$STAGING" -format UDZO -imagekey zlib-level=9 "$OUTPUT"
shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"
echo "Created: $OUTPUT"
