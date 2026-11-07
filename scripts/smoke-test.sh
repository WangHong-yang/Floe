#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Floe.app"
MODEL="$ROOT/vendor/sherpa-onnx-x-asr-160ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
"$APP/Contents/MacOS/Floe" --test-streaming-patches
"$APP/Contents/MacOS/Floe" --test-hotwords
"$APP/Contents/MacOS/Floe" --test-permission-restart
"$APP/Contents/MacOS/Floe" --test-idle-updates
"$APP/Contents/MacOS/Floe" --test-preferences-migration
"$APP/Contents/MacOS/Floe" --test-audio-tail
"$APP/Contents/MacOS/Floe" --test-dictation-clipboard
"$APP/Contents/MacOS/Floe" --transcribe "$MODEL"/test_wavs/*.wav
printf 'FSDP2\nUlysses\nGlobeTalk\n欢迎使用\nEnglish\n' > "$ROOT/build/test-hotwords.txt"
"$APP/Contents/MacOS/Floe" --transcribe "$MODEL"/test_wavs/*.wav --hotwords-file "$ROOT/build/test-hotwords.txt"
printf '礼拜二\n星期三\nMonday\nfrequently\n' > "$ROOT/build/test-relevant-hotwords.txt"
"$APP/Contents/MacOS/Floe" --transcribe "$MODEL/test_wavs/0.wav" \
    --hotwords-file "$ROOT/build/test-relevant-hotwords.txt" > "$ROOT/build/test-hotword-bias.txt"
rg -q '礼拜二' "$ROOT/build/test-hotword-bias.txt"
cat "$ROOT/build/test-hotword-bias.txt"
