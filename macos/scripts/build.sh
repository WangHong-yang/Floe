#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RUNTIME="sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib"
MODEL="sherpa-onnx-x-asr-160ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05"
download() {
    local url="$1" file="$2" digest="$3"
    if [[ ! -f "$file" ]]; then
        curl --fail --location --retry 3 "$url" -o "$file.part"
        mv "$file.part" "$file"
    fi
    printf '%s  %s\n' "$digest" "$file" | shasum -a 256 -c
}
[[ "$(uname -m)" == "arm64" ]] || { echo "此版本面向 Apple Silicon Mac。"; exit 1; }
mkdir -p vendor build dist
download "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/$RUNTIME.tar.bz2" \
    vendor/runtime.tar.bz2 ac5594ad237db56ec4a6c4b3fc48700441b33a07bb71c235f35530a52a93f2e3
download "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$MODEL.tar.bz2" \
    vendor/model.tar.bz2 8a6fca056e1a342546edd78be4d50274e2c01898e7b8ae8fc336f6410319c399
if [[ ! -d "vendor/$RUNTIME" ]]; then tar -xjf vendor/runtime.tar.bz2 -C vendor; fi
if [[ ! -d "vendor/$MODEL" ]]; then tar -xjf vendor/model.tar.bz2 -C vendor; fi
download "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v2.0.1/sherpa-onnx/c-api/c-api.h" \
    vendor/sherpa-onnx.h 5698f38ba09ad2bdf085c56a6cbbd7741acf15e25f4ce5c7097b9702cadf437f
if [[ ! -f vendor/LICENSE-sherpa-onnx ]]; then
    curl --fail --location https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v2.0.1/LICENSE -o vendor/LICENSE-sherpa-onnx
fi
if [[ ! -f vendor/LICENSE-X-ASR ]]; then
    curl --fail --location https://raw.githubusercontent.com/Gilgamesh-J/X-ASR/main/LICENSE -o vendor/LICENSE-X-ASR
fi
if [[ ! -f vendor/LICENSE-onnxruntime ]]; then
    curl --fail --location https://raw.githubusercontent.com/microsoft/onnxruntime/main/LICENSE -o vendor/LICENSE-onnxruntime
fi
APP="$ROOT/dist/Floe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Model"
cp Info.plist "$APP/Contents/Info.plist"
cp "vendor/$RUNTIME/lib/libsherpa-onnx-c-api.dylib" "vendor/$RUNTIME/lib/libonnxruntime.dylib" "$APP/Contents/Frameworks/"
cp "vendor/$MODEL/encoder.int8.onnx" "vendor/$MODEL/decoder.onnx" \
    "vendor/$MODEL/joiner.int8.onnx" "vendor/$MODEL/tokens.txt" "$APP/Contents/Resources/Model/"
cp vendor/LICENSE-sherpa-onnx vendor/LICENSE-X-ASR vendor/LICENSE-onnxruntime "$APP/Contents/Resources/"
cp "vendor/$MODEL/README.md" "$APP/Contents/Resources/Model/"
printf '%s  %s\n' 28fc94d67aae53d8c58010fcfb16fc8c2f8dd263e03f3490c98210e354e8f914 Resources/bpe.vocab | shasum -a 256 -c
rm -f "$APP/Contents/Resources/ViveLogo.png" "$APP/Contents/Resources/ViveIcon.icns"
cp ../assets/branding/FloeLogo.png "$APP/Contents/Resources/"
cp Resources/bpe.vocab "$APP/Contents/Resources/Model/"
SDK="${FLOE_MACOS_SDK_PATH:-$(xcrun --show-sdk-path)}"
export CLANG_MODULE_CACHE_PATH="$ROOT/build/module-cache"
export SWIFT_MODULECACHE_PATH="$ROOT/build/module-cache"
xcrun swiftc -O -sdk "$SDK" -module-cache-path "$ROOT/build/module-cache" \
    Sources/GlassArtwork.swift scripts/render-icons.swift -o build/render-icons
build/render-icons build/AppIcon.iconset ../assets/branding/FloeLogo.png
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/FloeIcon.icns"
xcrun clang -O2 -arch arm64 -mmacosx-version-min=14.0 -I vendor -I Sources \
    -c Sources/ASRBridge.c -o build/ASRBridge.o
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$SDK" \
    -module-cache-path "$ROOT/build/module-cache" \
    -import-objc-header Sources/ASRBridge.h Sources/*.swift build/ASRBridge.o \
    -L "vendor/$RUNTIME/lib" -lsherpa-onnx-c-api \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$APP/Contents/MacOS/Floe"
# A stable certificate keeps macOS privacy grants (Accessibility, Input
# Monitoring) across rebuilds; ad-hoc signatures change with every build.
SIGN_ID="${FLOE_SIGN_IDENTITY:-Floe Local Signing}"
if ! security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
    echo "未找到签名证书 \"$SIGN_ID\"，使用 ad-hoc 签名（每次重建都需重新授权）。"
    SIGN_ID="-"
fi
codesign --force --sign "$SIGN_ID" "$APP/Contents/Frameworks/libonnxruntime.dylib"
codesign --force --sign "$SIGN_ID" "$APP/Contents/Frameworks/libsherpa-onnx-c-api.dylib"
codesign --force --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"
echo "已构建：$APP"
