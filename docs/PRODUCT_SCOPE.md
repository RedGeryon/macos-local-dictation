# Product scope and UX decisions

## Product promise

Place the cursor in a normal Mac text field, hold a configurable shortcut,
speak, and release. The app displays live feedback without changing the target
application, then inserts only the finalized transcript. A menu-controlled
long-dictation mode handles longer microphone-only passages.

Conversation mode separately transcribes the selected microphone as **You** and
Mac system output as **Speaker**, then saves a timestamped local text file. It
does not save audio or video, and it does not diarize multiple voices within the
Speaker channel.

## Supported in this build

- Apple Silicon Macs running macOS 14 or newer.
- English speech using Nemotron Speech Streaming English 0.6B Q8.
- Optional multilingual speech using Nemotron 3.5 ASR Streaming 0.6B Q8,
  with automatic detection or an explicit choice among its 32 out-of-box
  locales, including Spanish (`es-US` and `es-ES`).
- One selected model is loaded at a time; changing models restarts the local
  worker, while changing language updates the warm recognition session without
  reloading model weights.
- Fn push-to-talk by default, with Control–Option–Space as a configurable
  fallback; the shortcut is user-configurable in Settings › Shortcuts.
- Long microphone-only dictation with explicit stop and a 30-minute safety limit.
- Two-channel conversation transcription with explicit Stop and Save.
- Text output under Documents with elapsed timestamps and You/Speaker labels.
- User-confirmed file transcription for WAV, MP3, M4A/ALAC, AAC, CAF, AIFF,
  FLAC, MP4, M4V, and MOV inputs up to four hours. The selection confirmation
  shows format, duration, language, output path, and an adaptive time estimate.
- Independent raw-microphone and clean system-output transcription without
  forcing an input device, followed by conservative time-aligned removal of
  longer near-duplicate ASR phrases from the You channel. The microphone follows
  the device currently selected by macOS.
- Atomic microphone/system capture shutdown on macOS 15+, allowing an AirPods
  output route to recover after conversation capture without a retained client.
- A 900 ms post-Stop tail and dual-decoder completion barrier before the
  transcript footer is saved.
- Control–Option–C toggling by default (configurable in Settings › Shortcuts),
  compact menu-bar elapsed timer, and rapid restart
  queued while the previous file finalizes.
- Normal Accessibility-aware native, browser, and Electron text fields.
- The ChatGPT/Codex composer through a frontmost-app paste fallback because its
  editor does not currently publish a focused Accessibility text element.
- Clipboard-preserving paste fallback for apps that reject direct insertion.
- Cancellation, Paste Last, deterministic cleanup, context-aware spacing, and
  terminal-safe command handling.
- Fully local dictation after the user separately obtains the model.

“Any app” means ordinary editable text controls. Password fields, protected
processes, remote desktops that intercept the shortcut, games, canvas-only
editors, and controls that expose neither Accessibility text APIs nor paste are
not supported.

## UX decisions

### Setup explains every external boundary

The package includes the Apache-2.0 runtime and its notices. Models are not
included. Setup downloads either pinned official Q8 file with visible progress,
Cancel, and a fixed Application Support destination. It links the distinct
licenses, verifies size, SHA-256, and GGUF format before installation, selects
the model automatically, and chooses the appropriate default language. Manual
file selection remains available. Permission requests are user-initiated one at
a time and never chain automatically.

The English-specific model is fixed to `en-US`. The multilingual model defaults
to language auto-detection and offers every transcription-ready and
broad-coverage locale NVIDIA identifies as working out of the box. A selected
locale is used consistently for quick dictation and both conversation channels.
The app does not translate between languages.

### Final text is authoritative

Streaming partials may change. They remain in the overlay and never touch the
target field. Release keeps capture open for a 180 ms tail, synchronously flushes
the converter, and queues commit after every PCM send; only the final transcript
goes through cleanup and insertion.

### Existing media uses the offline fast path

The selected audio track is decoded once into a temporary 16 kHz mono PCM
multipart body. The file is uploaded from disk to the already-warm local HTTP
server instead of being retained in memory or replayed at realtime speed. The
runtime's offline inference path handles the file; the chosen model is not
reloaded. The temporary body is removed on success, error, or cancellation and
stale crash remnants are cleaned on a later launch. The resulting readable
`.txt` document is saved automatically in the File Transcripts subfolder.
Because the user selects an existing file, this path does not require
Microphone, Accessibility, or System Audio permission.

Before confirmation, the app estimates duration using a conservative 25×
realtime baseline. It stores a bounded moving average of completed local jobs
separately for each model variant, so later estimates reflect the actual Mac.

### Permissions are purposeful

- Microphone: capture only while dictating.
- Accessibility: recognize the global shortcut, insert at the original cursor,
  and post paste/Return fallback events. A separate Input Monitoring approval is
  not required.
- System Audio Recording: receive Mac output audio in conversation mode. It is
  tested by starting the real audio-only stream, is optional for Quick
  Dictation, and registers no screen-video output.

The app provides direct links back to each System Settings pane and a Refresh
button because macOS may require the application to be reopened after approval.
The setup window temporarily behaves like a regular Dock/Command–Tab window so
it remains easy to recover while System Settings is in front.

### Recovery is built in

The most recent raw transcript remains available as Paste Last. Clipboard
fallback snapshots and restores all representations. Paste Last never repeats
the spoken Return command.

Conversation text is written and synchronized incrementally. Pressing
Control–Option–C a second time always means Stop and Save; quitting normally
while recording also finalizes the active transcript before the model exits.

### Safety wins over cleverness

Cleanup is deterministic and optional where subjective. Automatic Return is
blocked in known terminal apps. Password fields are refused. No AI rewriting,
semantic cursor context, continuous idle microphone, or cloud fallback exists.

## Not supported

Intel Macs, Windows, Linux, cloud recognition, accounts, sync, translation,
adaptation-only languages without model fine-tuning, diarization, custom
vocabulary, AI rewriting, mobile apps, and Mac App Store distribution are
outside this version.

## Public-release gates

- Complete a native/browser/Electron compatibility matrix.
- Measure P50/P95 release-to-insert latency with real microphone input.
- Run a 500-session mixed quick/long/conversation soak test.
- Verify offline behavior and inspect network connections.
- Sign with Apple Developer ID and notarize the DMG.
- Recheck dependency/model terms and generate an SBOM.
- Clear the final product name and icon with trademark/legal review.
