#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
CACHE="${FLOE_DEPENDENCY_CACHE:-$ROOT/.cache}"
MODEL="sherpa-onnx-x-asr-160ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05"
mkdir -p "$CACHE" "$ROOT/app/libs" "$ROOT/app/src/main/assets/model" "$ROOT/app/src/main/assets/licenses"
verify() {
    if command -v sha256sum >/dev/null; then printf '%s  %s\n' "$2" "$1" | sha256sum -c -;
    else printf '%s  %s\n' "$2" "$1" | shasum -a 256 -c -; fi
}
download() {
    local url="$1" path="$2" digest="$3"
    if [[ ! -f "$path" ]]; then
        curl --fail --location --retry 3 --connect-timeout 30 "$url" -o "$path.part"
        verify "$path.part" "$digest"
        mv "$path.part" "$path"
    else verify "$path" "$digest"; fi
}
download "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-2.0.1.aar" \
    "$ROOT/app/libs/sherpa-onnx-2.0.1.aar" a8d09d1d32f3eb8520482c6d3d43fae674681c5b050385967c70a3c2c9bf0ee7
download "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$MODEL.tar.bz2" \
    "$CACHE/$MODEL.tar.bz2" 8a6fca056e1a342546edd78be4d50274e2c01898e7b8ae8fc336f6410319c399
STAGING="$(mktemp -d "$CACHE/model.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
tar -xjf "$CACHE/$MODEL.tar.bz2" -C "$STAGING" \
    "$MODEL/encoder.int8.onnx" "$MODEL/decoder.onnx" \
    "$MODEL/joiner.int8.onnx" "$MODEL/tokens.txt"
for file in encoder.int8.onnx decoder.onnx joiner.int8.onnx tokens.txt; do
    cp "$STAGING/$MODEL/$file" "$ROOT/app/src/main/assets/model/$file"
done
for file in LICENSE-sherpa-onnx LICENSE-X-ASR LICENSE-onnxruntime; do
    cp "$REPO/licenses/$file" "$ROOT/app/src/main/assets/licenses/"
done
cp "$REPO/THIRD_PARTY_NOTICES.md" "$ROOT/app/src/main/assets/licenses/"
echo "Offline speech runtime, model, and licenses prepared."
