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

INSTALL
1. Drag Floe.app into Applications.
2. Eject this disk image.
3. Open Floe from Applications.

FIRST LAUNCH: IF MACOS SAYS "Floe.app Not Opened"
This preview is ad-hoc signed and has not been Apple-notarized.
1. Click Done in the warning. Do not click Move to Trash.
2. Open System Settings > Privacy & Security.
3. Scroll to the message that Floe was blocked and click Open Anyway.
4. Authenticate with your password or Touch ID, then confirm Open.
If the message is missing, try opening Floe from Applications again.
Only approve the app downloaded from the official Floe GitHub release.
Do not disable Gatekeeper or system-wide security protections.
Managed Macs may prevent this exception.

ENABLE ALL THREE PERMISSIONS
Open Floe's settings and use the Allow buttons. In System Settings >
Privacy & Security, enable Floe in each of these three sections:

1. Microphone — allows Floe to hear your voice.
2. Input Monitoring — allows Floe to detect the Globe / Fn shortcut.
3. Accessibility — allows Floe to insert text into the focused field.

For Input Monitoring and Accessibility, if Floe is not listed, drag
Floe.app from Applications into the permission list, then turn it on.
Floe's settings also offers a draggable app icon and Show in Finder.
Return to Floe to check that all three permissions show as enabled.
If macOS asks you to quit and reopen Floe, do so. If the shortcut still
does not respond after granting permissions, quit and reopen Floe.
Updates to this preview may require granting permissions again.

SET UP THE SHORTCUT
System Settings > Keyboard > Press Globe key to > Do Nothing.
Focus a text field, hold Globe / Fn to speak, then release to finish.
Right Option is available as an alternate shortcut in Floe's settings.

Requires Apple Silicon and macOS 14 or later. The model is included.
Speech recognition runs locally; audio is not uploaded or saved.

Source and release downloads: https://github.com/WangHong-yang/Floe
EOF
hdiutil create -ov -volname "Floe $VERSION" -srcfolder "$STAGING" -format UDZO -imagekey zlib-level=9 "$OUTPUT"
shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"
echo "Created: $OUTPUT"
