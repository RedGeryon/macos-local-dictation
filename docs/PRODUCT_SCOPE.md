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
- Fn push-to-talk with Control–Option–Space fallback.
- Long microphone-only dictation with explicit stop and a 30-minute safety limit.
- Two-channel conversation transcription with explicit Stop and Save.
- Text output under Documents with elapsed timestamps and You/Speaker labels.
- Independent raw-microphone and clean system-output transcription without
  forcing an input device, followed by conservative time-aligned removal of
  longer near-duplicate ASR phrases from the You channel. The microphone follows
  the device currently selected by macOS.
- Atomic microphone/system capture shutdown on macOS 15+, allowing an AirPods
  output route to recover after conversation capture without a retained client.
- A 900 ms post-Stop tail and dual-decoder completion barrier before the
  transcript footer is saved.
- Control–Option–C toggling, compact menu-bar elapsed timer, and rapid restart
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

The package includes the Apache-2.0 runtime and its notices. The model is not
included. Setup links the official model card and license, validates a chosen
GGUF, and explains the three dictation permissions plus optional System Audio
in plain language. Requests are user-initiated one at a time and never chain
automatically.

### Final text is authoritative

Streaming partials may change. They remain in the overlay and never touch the
target field. Release keeps capture open for a 180 ms tail, synchronously flushes
the converter, and queues commit after every PCM send; only the final transcript
goes through cleanup and insertion.

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

Intel Macs, Windows, Linux, multilingual models, cloud recognition, accounts,
sync, translation, diarization, custom vocabulary, AI rewriting, mobile apps,
and Mac App Store distribution are outside this version.

## Public-release gates

- Complete a native/browser/Electron compatibility matrix.
- Measure P50/P95 release-to-insert latency with real microphone input.
- Run a 500-session mixed quick/long/conversation soak test.
- Verify offline behavior and inspect network connections.
- Sign with Apple Developer ID and notarize the DMG.
- Recheck dependency/model terms and generate an SBOM.
- Clear the final product name and icon with trademark/legal review.
