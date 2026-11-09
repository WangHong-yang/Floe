# Floe Android 0.0.1 preview

Offline Chinese/English dictation using sherpa-onnx 2.0.1 and X-ASR. The app interface is English, with an always-black background, flat typography and no card-style sections. Android 8.0+; ARM64 recommended. The universal APK also includes ARMv7 and x86_64.

**[Download Floe Android 0.0.1 APK](https://github.com/WangHong-yang/Floe/releases/download/android-v0.0.1/Floe-Android-0.0.1.apk?raw=true)** · [Release notes and checksum](https://github.com/WangHong-yang/Floe/releases/tag/android-v0.0.1)

## Install and enable

Install the APK, open Floe, grant microphone permission, read the accessibility disclosure and enable Floe in Android Accessibility settings. Sideloaded apps on Android 13+ may require App info → menu → Allow restricted settings. Only allow a build you trust. Return to Floe and enable it.

The system-bound accessibility service owns the preloaded model and floating control. Standby has a silent **Floe is enabled** notification in the drawer on a new MIN-importance channel, with no foreground service. Android normally omits MIN-importance status-bar icons; notification settings and OEM behavior can affect presentation. Grant notification permission to keep the drawer notification visible. Recording uses a separate microphone foreground service and the system microphone privacy indicator. Floe never hides the system recording/privacy indicator.

This rebuilt preview has not been tested on a phone or emulator.

**Installation compatibility:** this is a debug preview, not a Play Store release. If Android rejects an in-place update because the prior signing key is unavailable, uninstalling clears local preferences and overlay position and requires granting permissions again. No recording or transcript history is stored.

## Use the ice

Focus a non-password text field. The floating control is just the original transparent Floe ice artwork: no capsule, text label or drag grip.

- **Tap** the ice to start hands-free dictation. Tap it again, or tap ✓, to finish.
- **Hold** it stationary for 300 ms to begin hold-to-talk. Release to finish.
- **Drag** the ice to move it. A drag that begins before the hold threshold does not start the microphone or request haptic feedback. If you move after starting a held session, that held session is cancelled before dragging.
- **×** cancels. Finish/cancel controls appear only during a session and open on the side with room, preserving the ice's position.
- Enabling Floe preloads the model once, with the microphone off. The ice becomes available when it is ready. A tap or hold then gives a brief haptic acknowledgment when accepted. A long release whose hold timer never started recording is ignored rather than treated as a new tap. **Wait for the red dot and a second light tick before speaking.** Haptics follow Android's system haptic settings and device support.
- The indicator is blue while the microphone is starting or the session is finishing, and red only after AudioRecord confirms recording. Releasing a hold before capture starts cancels that session.

Your normal keyboard stays in place. The saved overlay position can be reset in Floe settings. Live text uses accessibility SET_TEXT. When unsupported, final insertion tries replacement/paste, then copies for manual paste and shows a brief instruction. Clipboard managers can see fallback text. Cancellation restores only Floe's unchanged preview, preserving independent edits.

## Power and microphone lifecycle

Enabling Floe loads the speech model once on a dedicated worker owned by the accessibility service. READY is shown only after loading completes. The model and waiting worker remain in memory across finish, cancellation and screen-off. No utterance stream, AudioRecord, decoding loop or microphone foreground-service type is kept active during idle. Each recording creates a fresh short-lived stream; finish/cancel waits for microphone and stream cleanup before returning to READY. Old session callbacks cannot alter a newer session.

Disabling Floe or disconnecting its accessibility service releases the model and worker. If stopped while native model construction is underway, no microphone can start and resources are released when that non-interruptible constructor returns. Rapid re-enabling waits for the previous native model to be freed before allocating another one. Model loading failure stops Floe with an error instead of pretending to be ready.

Idle never starts a foreground service, and the app no longer requests `specialUse`. A microphone foreground service is started only for an accepted recording request; AudioRecord waits for that service to become foreground. When capture stops, the microphone foreground service is removed while the model remains available for the next session. Android/OEM background-start restrictions may still reject recording, in which case Floe reports an error and cleans up. After accessibility or process restart, Floe stays off until explicitly enabled again.

Keeping the model ready intentionally uses more idle RAM. Floe does not unload it on ordinary memory-trim callbacks, which would reintroduce cold starts. Android can still kill the process under memory pressure; a newly enabled service loads once again. Process/native allocators may retain caches after shutdown. The ONNX configuration uses one CPU thread, eliminating extra intra-op worker threads without unloading the model. This is a preventive change, not a measured claim that all phone heating is resolved. There is no idle animation, ASR loop, wake lock or periodic microphone polling. The accessibility service still handles system focus events and short settling callbacks; idle is not a promise of zero battery use.

## Privacy and compatibility

No Internet permission, account, cloud upload, saved audio, transcript history or text-field history. Only preferences and bundled model files persist. Password fields are excluded. Custom editors or application accessibility restrictions can still prevent detection/insertion. Hotwords/correction learning are not implemented.

## Build and test

JDK 17+, Android SDK 35 and Build Tools 35.0.0:

```sh
cd android
./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug :app:assembleDebugAndroidTest
# Use a dedicated synthetic emulator for actual-service tests:
./gradlew :app:connectedDebugAndroidTest
```

The preparation task downloads and SHA256-checks official AAR/model archives, then bundles model files and licenses into the APK. No phone-side model download is needed. Output: `app/build/outputs/apk/debug/app-debug.apk`.

To build and export a named debug-preview APK with its checksum, run `bash scripts/package-apk.sh` from `android/`. Output: `dist/Floe-Android-0.0.1.apk` and `.sha256`.

Build downloads require bash/curl/tar/unzip and sha256sum or shasum. Keep a stable signing key securely outside the repository and distributed source archives. Configure the build to reuse it for future in-place updates. The source archive contains no signing key, SDK, machine-local paths, downloaded model/runtime or build output.

## Versioning

Visible versions advance as `0.0.1`, `0.0.2`, `0.0.3`, and so on. Keep increasing `versionCode` for installable updates. This is a fresh first release: versionName is 0.0.1 and versionCode starts at 1.
