![Floe — glass voice waveform](assets/branding/FloeBanner.png)

# Floe · Offline voice typing for Mac and Android

**[Visit website](https://wanghong-yang.github.io/Floe/)** · [Star Floe on GitHub](https://github.com/WangHong-yang/Floe)

<a href="https://www.producthunt.com/products/floe-4?embed=true&amp;utm_source=badge-featured&amp;utm_medium=badge&amp;utm_campaign=badge-floe-5" target="_blank" rel="noopener noreferrer"><img alt="Floe - Offline Voice Typing for Mac | Product Hunt" width="180" height="39" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1306421&amp;theme=dark&amp;t=1793955228554"></a>

Enjoying Floe? **[Star us on GitHub](https://github.com/WangHong-yang/Floe)** to show your support and help others find it.

Floe is a local speech-to-text and voice typing app for Mac and Android. Dictate in Chinese and English, including mixed-language speech, without a cloud transcription service. On Mac, use a keyboard shortcut. On Android, use the floating ice control.

| Platform | Download | Requirements |
| --- | --- | --- |
| Mac | [Floe 0.0.1 DMG](https://github.com/WangHong-yang/Floe/releases/download/v0.0.1/Floe-0.0.1-arm64.dmg?download=1) | Apple Silicon · macOS 14+ |
| Android | [Floe 0.0.1 APK](https://github.com/WangHong-yang/Floe/releases/download/android-v0.0.1/Floe-Android-0.0.1.apk?raw=true) | Android 8.0+ · about 218 MB |

[Release notes and SHA-256 checksums](https://github.com/WangHong-yang/Floe/releases). Both are preview builds with the offline speech model included.

Requires **Apple Silicon** and **macOS 14 or later**. The speech model is included; recognition does not need an internet connection.

## Android

[Explore Floe for Android and try the interactive demo](https://wanghong-yang.github.io/Floe/android/).

The Android preview uses the same local Chinese/English model. See [Android setup and build instructions](android/README.md). Its floating control supports tap-to-toggle and hold-to-talk; hotwords are not implemented. Android 8.0 or later is required.

Android **0.0.1** is a debug-signed preview, distributed outside Google Play. Grant microphone permission and enable Floe in Android Accessibility settings. On Android 13+, you may first need App info → menu → Allow restricted settings. Return to Floe and enable it, then focus a field and tap or hold the floating ice control. This rebuilt preview has not been tested on a phone or emulator.

## Install on macOS

1. Download and open the DMG.
2. Drag **Floe** into **Applications**.
3. Eject the disk image, then open Floe from Applications.
4. Grant Microphone, Input Monitoring and Accessibility access in System Settings. You can drag the app icon from Floe's settings into the relevant permission list.
5. If you use 🌐 as the shortcut, set **System Settings → Keyboard → Press 🌐 key to → Do Nothing**.

**Preview release:** version 0.0.1 is ad-hoc signed and has not been notarized by Apple. macOS may block the first launch. Updates to this preview can require granting permissions again. Developer ID signing and notarization are not yet configured.

## First launch on macOS

This preview is not Apple-notarized. If macOS blocks Floe:

1. Move Floe to **Applications**, then try opening it once.
2. Open **System Settings → Privacy & Security**.
3. Find the message about Floe and click **Open Anyway**. Authenticate if macOS asks, then confirm **Open**.
4. Once Floe opens, grant its Microphone, Input Monitoring and Accessibility permissions.

Only approve the copy downloaded from this repository's release. This creates an exception for Floe; do not disable Gatekeeper or system-wide security settings. Work or managed Macs may prevent this exception.

Apple's instructions: [Open a Mac app from an unknown developer](https://support.apple.com/guide/mac-help/mh40616/mac/). Future Developer ID-signed and notarized releases are intended to avoid the unidentified-developer warning.

## Mac features

- Streaming, local Chinese and English recognition, including mixed-language speech.
- Any shortcut you like: record a single modifier (Fn, Right ⌥, Left ⌃ …) or any key/combo (F5, ⌃Space …) with **Change…**. Fn and Right Option are one-click presets.
- Two recording modes: **press once to start, press again to finish** (default; Esc cancels), or classic hold-to-talk. In toggle mode a modifier only counts as a clean tap, so ⌥←, ⌃C etc. never toggle recording.
- Choose the microphone (USB, AirPods, iPhone Continuity, built-in) or follow the system default; an unplugged device falls back to the default.
- Inserts the full text once you finish; live streaming insertion (default text update interval 5 ms) is an optional toggle.
- A bottom-center HUD with a live waveform, state (Listening / Transcribing / Rewriting) and elapsed time.
- Optional local **History** (⌘Y): search, copy or delete past transcripts, including the original before rewriting.
- Optional **Bedrock paraphrasing** (off by default): sends the final transcript to an Amazon Bedrock model to remove fillers, apply self-corrections ("三点，不对，四点" → "四点") and make it read fluently. The prompt is editable in Settings and your hotwords are passed as a glossary. Toggle it from the menu bar.
- Editable hotwords and optional suggestions after corrections.
- Transient clipboard updates during dictation; one full transcript is copied at the end.

## Mac privacy

Speech recognition runs on your Mac using CPU inference. Floe never uploads or saves audio. Dictation uses the system clipboard and can therefore be visible to clipboard managers.

History is on by default and stores transcripts only on this Mac in `~/Library/Application Support/Floe/history.json` (up to 1,000 entries); turn it off in Settings or clear it from the History window.

Bedrock paraphrasing is off by default. When you enable it, the final transcript text (and your hotwords) is sent to Amazon Bedrock using your local AWS CLI credentials (`aws bedrock-runtime converse`); audio never leaves your Mac. If the request fails, the original text is inserted.

Hotword learning is enabled by default and can be disabled. It observes the text you just dictated in the focused, accessible field for up to 45 seconds. Suggested words are added after a five-second countdown unless canceled. Hotwords and preferences are stored locally; field contents and edit history are not saved.

The build script downloads dependencies and model files from GitHub. Recognition itself does not use a cloud service.

## Build the Mac app

Install Xcode Command Line Tools, then run from the repository root:

```sh
bash macos/scripts/build.sh
open macos/dist/Floe.app
```

If the default preview SDK lacks SwiftUI macro plugins, select an installed stable SDK with `FLOE_MACOS_SDK_PATH=/path/to/MacOSX.sdk bash macos/scripts/build.sh`.

The first build requires access to GitHub. Downloaded runtime and model files are SHA-256 checked and cached in `macos/vendor/`. Build output is in `macos/build/` and `macos/dist/`; these directories are ignored by Git.

To build, replace `/Applications/Floe.app` and relaunch in one step:

```sh
bash macos/scripts/install.sh
```

### Keep permissions across rebuilds

With the default ad-hoc signature macOS identifies the app by its binary hash, so every rebuild asks for Accessibility and Input Monitoring again. If a code-signing identity named `Floe Local Signing` exists (or `FLOE_SIGN_IDENTITY` names another one), `build.sh` signs with it instead and grants survive rebuilds. A self-signed certificate is enough:

```sh
cat > /tmp/floe-cert.cnf <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Floe Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/floe.key -out /tmp/floe.pem -days 3650 -config /tmp/floe-cert.cnf
openssl pkcs12 -export -legacy -inkey /tmp/floe.key -in /tmp/floe.pem -out /tmp/floe.p12 -passout pass:floe
security import /tmp/floe.p12 -k ~/Library/Keychains/login.keychain-db -P floe -T /usr/bin/codesign
rm /tmp/floe.key /tmp/floe.pem /tmp/floe.p12 /tmp/floe-cert.cnf
```

Grant permissions once after switching from ad-hoc to the certificate.

To generate a drag-to-Applications disk image:

```sh
bash macos/scripts/package-dmg.sh
```

Output: `macos/dist/Floe-0.0.1-arm64.dmg` and its SHA-256 checksum.

## Validation

```sh
bash macos/scripts/smoke-test.sh
```

The checks exercise real model inference, streaming text revisions, hotwords, audio resampling and permission-restart state. They do not open the microphone or type into other applications. A small supplied WAV test set is not a comprehensive accuracy or live-latency benchmark.

## Dependencies

- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), version 2.0.1 — Apache 2.0.
- [X-ASR](https://github.com/Gilgamesh-J/X-ASR) streaming Zipformer bilingual model — Apache 2.0.
- [ONNX Runtime](https://github.com/microsoft/onnxruntime) — MIT.

Model package: `sherpa-onnx-x-asr-160ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05`. The INT8 encoder and joiner, FP32 decoder and vocabulary are bundled in the app. Third-party license texts are included with the app.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency and asset attribution. A project-wide license for Floe's own source has not yet been selected; the dependency licenses apply to their respective components.

## Repository layout and versioning

- `macos/`: Mac app, scripts and platform resources.
- `android/`: Android app, Gradle build and platform resources.
- `assets/branding/`: shared artwork.
- `licenses/`: shared third-party license texts.
- `docs/`: GitHub Pages website.

Both platforms use `0.0.1`, `0.0.2`, `0.0.3`, and so on. Android `versionCode` must also increase on each published update; it is independent of the visible version name.
