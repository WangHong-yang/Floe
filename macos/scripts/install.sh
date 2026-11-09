#!/bin/bash
# Build, replace /Applications/Floe.app in place, and relaunch.
# Signed with the stable "Floe Local Signing" certificate, so existing
# Accessibility / Input Monitoring grants survive the update.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/scripts/build.sh"
osascript -e 'quit app "Floe"' 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -x Floe >/dev/null || break; sleep 1; done
rm -rf /Applications/Floe.app
ditto "$ROOT/dist/Floe.app" /Applications/Floe.app
# Refresh LaunchServices / Spotlight so ⌘Space finds the installed copy,
# and drop the build-output copy so it does not shadow it.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$ROOT/dist/Floe.app" 2>/dev/null || true
"$LSREGISTER" -f /Applications/Floe.app
mdimport /Applications/Floe.app 2>/dev/null || true
open /Applications/Floe.app
echo "已安装并启动：/Applications/Floe.app"
