#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
./gradlew :app:assembleDebug
VERSION=$(sed -n 's/.*versionName = "\([^"]*\)".*/\1/p' app/build.gradle.kts)
[[ -n "$VERSION" ]] || { echo 'Missing Android versionName'; exit 1; }
mkdir -p dist
OUTPUT="dist/Floe-Android-$VERSION.apk"
cp app/build/outputs/apk/debug/app-debug.apk "$OUTPUT"
(cd dist && shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256")
echo "Created: $ROOT/$OUTPUT (debug preview)"
