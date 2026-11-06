# Floe

Local Chinese & English dictation for Apple Silicon Macs. Hold 🌐 / Fn to speak, and Floe types into your focused text field as you talk.

**[Download Floe 0.0.1 for Apple Silicon](https://github.com/WangHong-yang/Floe/releases/download/v0.0.1/Floe-0.0.1-arm64.dmg)** · [Releases](https://github.com/WangHong-yang/Floe/releases)

Requires **Apple Silicon** and **macOS 14 or later**. The speech model is included; recognition does not need an internet connection.

## Install

1. Download and open the DMG.
2. Drag **Floe** into **Applications**.
3. Eject the disk image, then open Floe from Applications.
4. Grant Microphone, Input Monitoring and Accessibility access in System Settings. You can drag the app icon from Floe's settings into the relevant permission list.
5. Set **System Settings → Keyboard → Press 🌐 key to → Do Nothing**.

**Preview release:** version 0.0.1 is ad-hoc signed and has not been notarized by Apple. macOS may block the first launch. Updates to this preview can require granting permissions again. Developer ID signing and notarization are not yet configured.

## First launch on macOS

This preview is not Apple-notarized. If macOS blocks Floe:

1. Move Floe to **Applications**, then try opening it once.
2. Open **System Settings → Privacy & Security**.
3. Find the message about Floe and click **Open Anyway**. Authenticate if macOS asks, then confirm **Open**.
4. Once Floe opens, grant its Microphone, Input Monitoring and Accessibility permissions.

Only approve the copy downloaded from this repository's release. This creates an exception for Floe; do not disable Gatekeeper or system-wide security settings. Work or managed Macs may prevent this exception.

Apple's instructions: [Open a Mac app from an unknown developer](https://support.apple.com/guide/mac-help/mh40616/mac/). Future Developer ID-signed and notarized releases are intended to avoid the unidentified-developer warning.

## Features

- Streaming, local Chinese and English recognition, including mixed-language speech.
- Hold Globe/Fn to dictate; Right Option is available as an alternate shortcut.
- Live insertion into the focused field, with a default text update interval of 5 ms.
- A small glass waveform while recording.
- Editable hotwords and optional suggestions after corrections.
- Transient clipboard updates during dictation; one full transcript is copied at the end.

## Privacy

Speech recognition runs on your Mac using CPU inference. Floe does not upload or save audio or transcript history. Dictation uses the system clipboard and can therefore be visible to clipboard managers.

Hotword learning is enabled by default and can be disabled. It observes the text you just dictated in the focused, accessible field for up to 45 seconds. Suggested words are added after a five-second countdown unless canceled. Hotwords and preferences are stored locally; field contents and edit history are not saved.

The build script downloads dependencies and model files from GitHub. Recognition itself does not use a cloud service.

## Build

Install Xcode Command Line Tools, then run from the repository root:

```sh
bash scripts/build.sh
open dist/Floe.app
```

The first build requires access to GitHub. Downloaded runtime and model files are SHA-256 checked and cached in `vendor/`. Build output is in `build/` and `dist/`; these directories are ignored by Git.

To generate a drag-to-Applications disk image:

```sh
bash scripts/package-dmg.sh
```

Output: `dist/Floe-0.0.1-arm64.dmg` and its SHA-256 checksum.

## Validation

```sh
bash scripts/smoke-test.sh
```

The checks exercise real model inference, streaming text revisions, hotwords, audio resampling and permission-restart state. They do not open the microphone or type into other applications. A small supplied WAV test set is not a comprehensive accuracy or live-latency benchmark.

## Dependencies

- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), version 2.0.1 — Apache 2.0.
- [X-ASR](https://github.com/Gilgamesh-J/X-ASR) streaming Zipformer bilingual model — Apache 2.0.
- [ONNX Runtime](https://github.com/microsoft/onnxruntime) — MIT.

Model package: `sherpa-onnx-x-asr-160ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05`. The INT8 encoder and joiner, FP32 decoder and vocabulary are bundled in the app. Third-party license texts are included with the app.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency and asset attribution. A project-wide license for Floe's own source has not yet been selected; the dependency licenses apply to their respective components.
