# Local Dictation for macOS

> Working title: public branding is intentionally undecided pending a
> trademark review.

An open-source, local-first menu-bar app for English dictation in normal macOS
text fields. Hold a key, speak, release, and the final transcript is inserted
at the cursor.

The app uses NVIDIA's Apache-2.0
[NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp) runtime and the
separately downloaded
[Nemotron Speech Streaming English 0.6B Q8 model](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b).
Model weights are never included in this repository or application package.

## Install the current Mac build

Generate the installer with `bash scripts/generate-dmg.sh`, open
`dist/Local-Dictation-0.3.7-macOS-arm64.dmg`, and drag **Local Dictation** to
**Applications**. This development build is ad-hoc signed; a public download
must be Developer ID signed and notarized.

The generator supports Apple Silicon Macs and requires the Xcode Command Line
Tools plus [Homebrew](https://brew.sh). On its first run it builds the
Apache-2.0 NeMo-Speech.cpp runtime locally, bundles that runtime and its license
notices, signs the development app, and creates the DMG. The separately licensed
model is not placed in the installer. Later runs reuse the local runtime. The
runtime source revision is pinned in
[the bundled-component record](docs/BUNDLED_COMPONENTS.md) for reproducible
packaging.

On a new Mac, read the
[NVIDIA Open Model License Agreement](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/),
then download the model:

```bash
bash scripts/download-model.sh --accept-nvidia-model-license
```

Alternatively, download `nemotron-speech-streaming-en-0.6b.q8_0.gguf` from the
official model page and choose it in the app's setup window. The packaged app
contains the small NeMo-Speech.cpp runtime and its required notices, but not the
approximately 700 MB model.

## Dictate

1. Open Local Dictation from Applications and open **Settings…**. Approve
   Microphone and Accessibility one row at a time. The app
   never starts another privacy request automatically. Each green check reflects
   macOS approval. Input Monitoring is not required: Accessibility authorizes
   both the global shortcut listener and insertion into other apps.

While Settings is open, Local Dictation temporarily appears in the Dock and
Command–Tab so it is easy to return after macOS brings System Settings forward.
Closing Settings returns it to a menu-bar-only app.

If the app is opened directly from the DMG, setup requires installation first
and offers **Install in Applications and Relaunch**. This prevents macOS from
granting privacy access to a temporary disk-image path. If an ad-hoc rebuild
leaves an older entry enabled but undetected, use **Repair Stale Permission
Registration…** to reset only this app and repeat the native prompts.
2. Put the cursor in a normal editable field in Notes, Mail, a browser, Slack,
   an editor, or another app.
3. Hold **Fn**, speak, and release. Press **Esc** to cancel.
4. If Fn is unavailable, choose **Control–Option–Space** in Dictation Settings.
5. Use **Start Long Dictation (Microphone Only)** for longer speech, then choose
   Stop and Insert. Long dictation stops automatically after 30 minutes.

Only the final transcript is inserted. The overlay's partial text never edits
the target app. “Press enter” at the end of an utterance can submit after text
insertion, but automatic Return is blocked in known terminal applications.

Password fields and custom editors that expose neither standard Accessibility
text insertion nor paste are intentionally unsupported. Clipboard fallback
preserves and restores all pasteboard representations.

## Transcribe a two-sided conversation

Press **Control–Option–C**, or choose **Start Conversation Transcript** from the
menu-bar icon. The first use asks macOS for **System Audio Recording** access
in addition to the existing microphone permission. This optional permission
never blocks Quick Dictation. Despite the macOS permission name, Local Dictation
registers only an audio output with
[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit);
it does not receive or store screen video.

During the session, two independent local recognition streams are labeled:

- **You** — the selected microphone.
- **Speaker** — audio playing through the Mac, including headphones.

Press **Control–Option–C** again when finished. A tiny red menu-bar timer is the
persistent recording indicator; the large dictation overlay stays hidden. The
app completes both streams before showing Ready and writes timestamped text continuously to
`Documents/Local Dictation Transcripts`. Each start creates a separate `.txt`
file. The menu provides Open Last and Open Folder without opening a window after
every stop. No audio recording is saved. Obtain every participant's permission before recording.
If a new start is requested while the previous file is still finalizing, it is
queued and begins automatically as soon as that file is safe.
After Stop, capture remains open for 900 ms to drain ScreenCaptureKit's buffered
audio blocks and the final spoken word. The file closes only after both local
decoders return their final result.
Natural pauses of about 800 ms close an individual turn while recording remains
active. Each decoder result carries word-level audio timestamps, and Stop
rewrites the synchronized live journal into audio-time order. Alternating You
and Speaker turns therefore remain chronological even if one decoder finishes
later than the other.
If Local Dictation is quit while a conversation is active, it stops and closes
that transcript before exiting. Already recognized lines are synchronized to
disk as they arrive, rather than being held only in memory.

Conversation mode uses whichever input macOS currently considers the default—
AirPods, the MacBook microphone, or another selected device—without substituting
a different microphone. On macOS 15 and newer, one ScreenCaptureKit session
captures the raw default microphone and clean Mac output as separate channels,
then releases both together so Bluetooth playback can resume cleanly. A
time-aligned fuzzy text filter then removes longer near-duplicate **Speaker**
phrases that acoustically leak into **You**, while retaining unrelated user
speech and short common phrases.
All remote voices share the **Speaker** label in this version; speaker
diarization within the system-audio channel is not supported.

## Implemented support

- Apple Silicon and macOS 14 or newer.
- English transcription with punctuation and capitalization.
- Warm, stateful streaming inference with 80 ms transport batches and the
  runtime's 160 ms low-latency model configuration.
- Fn or Control–Option–Space push-to-talk; menu-controlled long-dictation mode.
- Live, non-focus-stealing preview; Escape cancellation; Paste Last.
- Context-aware spacing, conservative filler/repetition cleanup, and final
  command parsing.
- Direct Accessibility insertion plus clipboard-preserving paste fallback.
- App-scoped paste fallback for the ChatGPT/Codex composer, which accepts paste
  but does not currently expose its focused editor through macOS Accessibility.
  The fallback only remains active while that same app is frontmost.
- Reliable cross-window focus capture with short Accessibility retries; Fn is
  consumed while dictating so macOS cannot redirect it to another system action.
- A 180 ms release tail, synchronized microphone shutdown, and ordered WebSocket
  sends ensure the last spoken words reach the decoder before finalization.
- A bundled Apache-2.0 runtime, separately downloaded NVIDIA model, and local
  child-process cleanup on quit.
- Two-channel conversation transcription from microphone and Mac system audio,
  with labeled, timestamped local text files and no persisted audio or video.
- Control–Option–C conversation toggle with a compact menu-bar recording timer,
  brief saved confirmation, and queued rapid restart.
- Independent raw microphone and clean system-output streams, with conservative,
  time-aligned fuzzy removal of leaked Speaker phrases from the You channel.
- Unified macOS 15+ capture ownership for clean AirPods route release, plus a
  900 ms Stop tail before both decoders finalize.
- Crash-safe conversation stop buffering and save-on-quit finalization.

Intel Macs, Windows, Linux, cloud recognition, translation, diarization,
accounts, and AI rewriting are not supported by this version.

## Build and verify

```bash
swift test
bash scripts/audit-public-repo.sh
bash scripts/test-real-engine.sh
bash scripts/generate-dmg.sh
```

The opt-in real test loads the Metal model, streams PCM16 through the same
WebSocket path used by the microphone, verifies the transcript, and confirms
the worker exits cleanly.

Advanced packagers who already built the runtime can run
`bash scripts/package-dmg.sh` directly. Set
`LOCAL_DICTATION_BUNDLE_ENGINE_DIR=/absolute/path/to/runtime` to package a
specific compatible runtime. Generated application and DMG files live under
the ignored `build/` and `dist/` directories.

## Project documentation

- [Building and releasing](docs/BUILDING_AND_RELEASE.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Implemented status](docs/CURRENT_STATUS.md)
- [Product scope](docs/PRODUCT_SCOPE.md)
- [Privacy](PRIVACY.md)
- [Security policy](SECURITY.md)
- [Legal and licensing](docs/LEGAL_AND_LICENSING.md)
- [Bundled component record](docs/BUNDLED_COMPONENTS.md)
- [Install and remove](INSTALL_AND_REMOVE.md)
- [Contributing](CONTRIBUTING.md)

## Remove

From the menu-bar app choose **How to Remove… → Remove Local Data**, then move
Local Dictation from Applications to the Trash. This removes the model,
external development engine, and preferences; the app bundle is removed by
moving it to Trash.

If you previously followed the terminal setup guide, run:

```bash
bash scripts/uninstall.sh --remove-all
```

The script moves the application and
`~/Library/Application Support/LocalDictation` to the Trash. See
[Install and remove](INSTALL_AND_REMOVE.md) for details.

## Privacy and licensing

Audio is captured only during dictation, streamed in memory to `127.0.0.1`, and
is not intentionally written to disk. No account, analytics, or cloud service
is used. See [Privacy](PRIVACY.md), [legal and licensing](docs/LEGAL_AND_LICENSING.md),
and [third-party notices](THIRD_PARTY_NOTICES.md).

The original app code is MIT licensed. NeMo-Speech.cpp and the NVIDIA model
retain their separate terms. This project is not affiliated with or endorsed
by NVIDIA.
