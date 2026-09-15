# Local Dictation for macOS

> Working title: public branding is intentionally undecided pending a
> trademark review.

An open-source, local-first menu-bar app that transcribes speech and reads text
aloud on your Mac. No account is required. Both features run locally after their
optional model weights are downloaded separately.

## Install or replace the app

For a build supplied as a DMG, quit Local Dictation, open the DMG, and drag
**Local Dictation** to **Applications**. Choose **Replace** if Finder asks.
Open the copy in Applications, not the copy on the DMG, before granting macOS
permissions. Development builds are ad-hoc signed and may require
Control-click → Open; a public release must be Developer ID signed and
notarized.

Replacing the installed app preserves its saved macOS preferences and leaves
`~/Library/Application Support/LocalDictation` in place for local models, the
Read Aloud runtime, and saved voice references. A development preview has a
separate identity; its data is not automatically promoted by a normal
replacement. Source-build and packaging instructions are in
[Building and releasing](docs/BUILDING_AND_RELEASE.md).

## Set up only the features you use

Open **Models & Startup**. Speech to Text and Text to Speech are separate:
each has an **Enabled** choice and a **Load at startup** choice. Opening the
page reports what is installed; it does not load a model by itself.
Enabled state, startup choices, model choice, and saved voice settings persist
locally for the installed app.

Each main model picker shows only verified downloads. If it says **No models
downloaded**, choose **Add Model…** to open the catalog. **Download** adds that
model to the installed list. It does not load it into memory. The first usable
download becomes the choice only when there is no valid choice already; adding
another model keeps the current choice. Use **Load now** when you want the
selected model ready immediately.

When a feature is enabled, selecting another verified installed model switches
to it and loads it. When the feature is disabled, a selection is saved without
loading anything; enable the feature, then choose **Load now** later (or use a
saved startup choice on the next launch). Changing a model does not change
**Load at startup**.

- **Speech to Text:** in **Add Model…**, download either the NVIDIA English Q8
  model for English dictation or the NVIDIA multilingual Q8 model for Spanish
  and other supported languages. The multilingual model supports Auto Detect
  and explicit locales.
- **Text to Speech:** use **Add Model…** to download Qwen 1.7B BF16 or 8-bit
  Preset voices. If the local Read Aloud runtime is not present, the app sets it
  up before the requested download. If weights are already installed but the
  runtime is missing, use **Set up Read Aloud** as recovery. BF16 is the initial
  model preference; no voice weights are included until you choose **Download**.
  The 8-bit
  option has a smaller download and lower memory use; it is not claimed to match
  BF16 for naturalness, pronunciation, or voice identity. VoiceDesign and Base
  are optional additional downloads for creating a new persistent custom voice.

Downloads and installation happen inside the app. The separate model terms are
linked there and summarized in [third-party notices](THIRD_PARTY_NOTICES.md).

## Daily use

The menu is organized into two sections, **Speech to Text** and **Text to
Speech**, each with its own status row and colored dot (green Ready, gray Not
loaded, blue busy, red recording, orange needs attention). Clicking a status
row opens the Settings page that explains it. Below both sections are
**Settings…**, **Models & Startup…**, and a **Help** submenu. The menu-bar icon
itself also changes color to reflect whichever feature needs the most
attention.

- For dictation, allow Microphone and Accessibility on the **Speech to Text**
  page in Settings, focus a normal text field, hold the Quick Dictation
  shortcut (Hold Fn by default), speak, and release. **Escape** cancels. Use
  the multilingual model for Spanish or other supported languages.
- For readback, choose **Read Selected Text** or press **Control–Option–R** (by
  default; change it in Settings › Shortcuts). **Read Clipboard** is available
  when an app does not expose a standard text selection. **Escape** stops
  readback and **Control–Option–P** (by default; change it in Settings ›
  Shortcuts) pauses or resumes it. Selected-text readback needs Accessibility;
  clipboard reading does not.
- For longer audio, open **Text to Speech**, choose a voice, optionally add a
  delivery instruction, then use **Save & Use Voice**. The Audio tab keeps its
  text draft separate and saves 24 kHz mono RF64 audio. Previewing a voice does
  not change the voice used for later readback or exports.

Ryan is the default English voice. **Designed Narrator** reuses a saved local
reference through the Base model; Aiden is another preset. These names are
product choices, not quality rankings. Read [the model decision and its
limits](docs/tts-model-research.md) before treating a model as a universal
quality or speed winner.

### Escape cancels anything

Escape cancels a dictation without inserting text, stops readback, and clears
a pending start while a model loads. It works in every app and is fixed on
purpose, so there is always one key that gets you out.

### Keyboard shortcuts

Open **Settings › Shortcuts** to see and change every shortcut in one place:
Quick Dictation, Conversation Transcript, Read Selected Text, and Pause or
Resume Readback. Click a shortcut field and press the keys you want; **Delete**
clears it (that action then has no shortcut), and **Escape** keeps the current
one. A shortcut must include Control, Option, or Command, or be an F-key.
Escape itself always cancels dictation or stops readback and cannot be
reassigned. The page warns you if two actions end up sharing the same
combination, and **Restore Defaults** puts everything back to Hold Fn for Quick
Dictation, Control–Option–C for the conversation transcript, Control–Option–R
for Read Selected Text, and Control–Option–P for Pause or Resume Readback. If
you previously used Control–Option–Space for push-to-talk, it is carried over
automatically as a custom Quick Dictation shortcut.

## Local data and developer preview

For the installed app, local support files are stored under
`~/Library/Application Support/LocalDictation`:

```text
Models/       Speech-to-text model files
TTSRuntime/   Read Aloud Python environment
TTSModels/    Qwen model snapshots
SavedVoices/  persistent custom-voice references
```

Generated audio and transcript files stay where the app tells you. **Help → How
to Remove… → Remove Local Data…** removes application-support data; it does not
remove exported audio or transcript documents.

`bash scripts/run-preview.sh` is for developers. It creates a separate preview
app identity, **Local Dictation Preview**. macOS may still list an older preview
entry as **Local Dictation TTS Preview**. Its privacy permissions do not apply
to the installed **Local Dictation** app.

## Dictation details

Open the **Speech to Text** page and allow Microphone and Accessibility one row
at a time. Input Monitoring is not required. The installed **Local Dictation** app is
the entry to enable in System Settings; do not approve a copy on the DMG or a
development preview instead.

Put the cursor in a normal editable field, hold the Quick Dictation shortcut
(Hold Fn by default), speak, and release. Change it to a key combination such
as Control–Option–Space in Settings › Shortcuts if Fn is unavailable. **Escape**
cancels. **Start Long Dictation (Microphone Only)** is for longer speech and
stops automatically after 30 minutes.

Only final text is inserted. The overlay's partial text never edits the target
app. “Press enter” at the end of an utterance can submit after text insertion,
but automatic Return is blocked in known terminal applications. Password fields
and custom editors that expose neither standard Accessibility insertion nor paste
are unsupported. Clipboard fallback preserves and restores pasteboard formats.

## Transcribe an existing audio or video file

Choose **Transcribe Audio or Video File…** from the menu-bar app or Settings.
After selecting a file, Local Dictation shows its format, duration, size,
selected language, automatic save location, and an estimated completion time
before **Transcribe and Save** can be confirmed. Estimates begin conservatively
and adapt to completed jobs on that Mac and selected model.

Supported inputs are:

- Audio: WAV, MP3, M4A (AAC or ALAC), AAC, CAF, AIFF, and FLAC.
- Video with an audio track: MP4, M4V, and MOV.
- Maximum duration: four hours per file.

The app decodes the selected track once to compact mono 16 kHz PCM, streams the
temporary upload from disk to the already-warm localhost model, and uses the
runtime's fast offline inference path. It does not load the whole file into
memory or reload model weights. Cancel stops both conversion and transcription.
Microphone, Accessibility, and System Audio permissions are not required for
this file-only workflow.
The temporary audio is removed afterward, and the finished text opens from:

`~/Documents/Local Dictation Transcripts/YYYY-MM-DD` (for example, `2026-09-15`).
Conversation transcripts share the same daily folders. Filenames include times.
The Mac and display stay awake during transcription, including on battery;
automatic sleep resumes when transcription ends.

## Transcribe a two-sided conversation

Press **Control–Option–C** (by default; change it in Settings › Shortcuts), or
choose **Start Conversation Transcript** from the menu-bar icon. The first use
asks macOS for **System Audio Recording** access
in addition to the existing microphone permission. This optional permission
never blocks Quick Dictation. Despite the macOS permission name, Local Dictation
registers only an audio output with
[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit);
it does not receive or store screen video.

During the session, two independent local recognition streams are labeled:

- **You** — the selected microphone.
- **Speaker** — audio playing through the Mac, including headphones.

Press the same shortcut again when finished. A tiny red menu-bar timer is the
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
- English transcription with punctuation and capitalization using the
  specialized English model.
- Optional multilingual transcription with Auto Detect or any of the 32
  out-of-box locales from Nemotron 3.5 ASR, including `es-US` and `es-ES`.
- Warm, stateful streaming inference with 80 ms transport batches and the
  runtime's 160 ms low-latency model configuration.
- User-configurable shortcuts: Quick Dictation (Hold Fn by default, or a chosen
  key combination such as Control–Option–Space), hands-free Long Dictation
  (Control–Option–L), conversation transcripts, and readback.
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
- A bundled Apache-2.0 runtime, one selected separately downloaded NVIDIA
  model, and local child-process cleanup on quit.
- Independent status dots for Speech to Text and Text to Speech in both
  Settings and the menu (green Ready, gray Not loaded, blue busy, red
  recording, orange needs attention), with English shown as the only language
  when the English-only model is selected.
- Sleep/wake recovery that cancels stale model loads, recycles the local worker
  after audio devices return, and caps quit at five seconds before force cleanup.
- Fast local file transcription for common audio and video containers, with a
  pre-confirmation adaptive time estimate, bounded-memory conversion, visible
  progress/cancel, and automatically opened `.txt` output.
- Two-channel conversation transcription from microphone and Mac system audio,
  with labeled, timestamped local text files and no persisted audio or video.
- User-configurable conversation toggle (Control–Option–C by default) with a
  compact menu-bar recording timer, brief saved confirmation, and queued rapid
  restart.
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
bash scripts/test-multilingual-model.sh
bash scripts/generate-dmg.sh
```

The opt-in real test loads the Metal model, streams PCM16 through the same
WebSocket path used by the microphone, verifies the transcript, and confirms
the worker exits cleanly.
`test-multilingual-model.sh` creates a temporary Spanish fixture with macOS's
built-in voice, sends `es-ES` through that same WebSocket path, checks the final
Spanish word, and deletes the fixture. It requires the separately downloaded
multilingual model and never commits audio or weights.

Advanced packagers who already built the runtime can run
`bash scripts/package-dmg.sh` directly. Set
`LOCAL_DICTATION_BUNDLE_ENGINE_DIR=/absolute/path/to/runtime` to package a
specific compatible runtime. Generated application and DMG files live under
the ignored `build/` and `dist/` directories.

## Project documentation

- [User guide: install and use](docs/USER_GUIDE.md)
- [Release notes](CHANGELOG.md)
- [Building and releasing](docs/BUILDING_AND_RELEASE.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Implemented status](docs/CURRENT_STATUS.md)
- [Product scope](docs/PRODUCT_SCOPE.md)
- [Privacy](PRIVACY.md)
- [Security policy](SECURITY.md)
- [Legal and licensing](docs/LEGAL_AND_LICENSING.md)
- [Bundled component record](docs/BUNDLED_COMPONENTS.md)
- [Install and remove](INSTALL_AND_REMOVE.md)
- [Text-to-speech model decision](docs/tts-model-research.md)
- [Text-to-speech validation](docs/tts-validation.md)
- [Contributing](CONTRIBUTING.md)

## Remove

Open **Models & Startup → Storage & Removal** to see exact model paths,
reveal files in Finder, or move individual downloads to the Trash. **Unload**
frees memory and keeps the files. New imports are copied into the app's model
folder; their originals are kept.

Normal models, the voice runtime, saved voices, and new download caches live in
`~/Library/Application Support/LocalDictation/`. Choose **Remove All Local Data…**
to move that folder to the Trash and clear preferences, then move Local Dictation
from Applications to the Trash. Empty the Trash to reclaim disk space. Exported
audio, transcripts, older external models, and custom runtime folders are kept.

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

The original app code is MIT licensed. NeMo-Speech.cpp and each NVIDIA model
retain their separate terms; the two model licenses differ. This project is not
affiliated with or endorsed by NVIDIA.
