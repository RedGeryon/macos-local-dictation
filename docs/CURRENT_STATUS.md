# Current implementation status

Updated September 12, 2026 for 0.4.1 (build 20).

| Capability | Status |
|---|---|
| Native menu-bar app and guided setup | Unified Speech to Text, Text to Speech, Shortcuts, and Models & Startup pages; each optional feature is enabled, downloaded, loaded, and started independently |
| Bundled NeMo-Speech.cpp Metal runtime | Implemented; model remains external |
| Independent Speech to Text and Read Aloud controls | Implemented; enabled state and startup loading persist separately |
| Local Read Aloud | Qwen 1.7B BF16 or 8-bit, local MLX worker, selected-text readback, clipboard readback, and RF64 export |
| Read Aloud setup and model lifecycle | In-app runtime and component downloads, explicit load/unload, parent-watchdog cleanup, and native installed-app validation |
| Saved Read Aloud voices | Ryan default, Designed Narrator, and custom local references; saved voice settings persist locally |
| Model validation, launch, readiness, restart, and shutdown | Implemented and real-process tested |
| English + multilingual model selection | Implemented; official Q8 downloads and distinct terms linked in setup |
| Managed in-app model downloads | Installed-only pickers, shared Add Model catalogs, visible progress, fixed location, cancel/retry, pinned checks, explicit load controls, and enabled-feature model switching |
| Model/language clarity | Ready is green; English-only model exposes English only; multilingual model exposes Auto Detect and locale choices |
| Spanish and multilingual language prompts | Auto Detect plus 32 out-of-box locales passed to all recognition streams |
| Native microphone capture and 16 kHz PCM16 conversion | Implemented |
| Release-tail capture and ordered final-audio commit | Implemented and final-word tested |
| Persistent stateful realtime WebSocket | Implemented and real-audio tested |
| Quick Dictation shortcut | User-configurable in Settings › Shortcuts; Hold Fn by default, with Control–Option–Space as the migrated legacy default |
| Hands-free mode and 30-minute ceiling | Implemented |
| Existing audio/video file transcription | WAV, MP3, M4A/ALAC, AAC, CAF, AIFF, FLAC, MP4, M4V, MOV; adaptive estimate before confirm; fast warm offline path; cancel and automatic text output |
| Concurrent microphone + Mac system-audio transcription | Implemented and dual-stream engine tested |
| Timestamped You/Speaker conversation text files | Pause-bounded, audio-time ordered, and real-engine tested |
| Conversation stop/save crash regression | Fixed from a macOS crash report and lifecycle tested |
| Sleep/wake and quit recovery | One cancellable model-load operation, wake-time worker recycle, stale-child protection, and five-second forced-quit deadline |
| Microphone speaker-echo suppression | Post-ASR fuzzy time-aligned filtering; no audio-route processing; unit tested |
| AirPods capture lifecycle | Unified microphone/system ScreenCaptureKit stream on macOS 15+; outputs removed atomically |
| Conversation final-word tail | 900 ms post-Stop capture, ordered PCM flush, and dual-final wait |
| System Audio permission and live capability check | Implemented; optional and independent of Quick Dictation |
| One-at-a-time privacy onboarding | Implemented; no automatic request chaining |
| Permission capability checks | Implemented for Accessibility, the live global shortcut, and live System Audio |
| Conversation toggle and menu-bar timer | User-configurable in Settings › Shortcuts, Control–Option–C by default; shortcut tested |
| Idle model unloading, login item, Recent Dictations, activity glyph, save notification | Implemented; Memory choice per feature in Models & Startup, SMAppService login item for the installed app, five-entry session history, glyph changes while listening/reading/transcribing, notification on conversation save |
| Menu-bar status for both features | Implemented; independent Speech to Text and Text to Speech status rows with a combined icon tint |
| Focus-preserving live overlay | Implemented |
| Accessibility insertion and clipboard fallback | Implemented |
| Cross-window focus acquisition and recoverable target errors | Implemented |
| Context spacing, cleanup, Paste Last, and terminal-safe Press Enter | Implemented and unit tested |
| Drag-to-Applications DMG | Implemented and validated locally |
| Staged privacy prompts and live permission checks | Implemented; approval remains a macOS user action |
| Disk-image detection, self-install, and stale TCC repair | Implemented |
| Stable local-build TCC signing requirement | Implemented; development only |
| Developer ID signing and Apple notarization | Required before public release |
| Broad manual application compatibility matrix | Requires user/release QA |

The installed 0.4.1 build 20 was atomically replaced in Applications and passed
code-sign verification. The 13 pre-existing preferences were unchanged.
Microphone and Accessibility remained available; English speech recognition
reached Ready; the 8-bit Read Aloud choice and Ryan were retained; and the two
features kept their independent startup choices. Earlier production and preview
workers were gone after replacement. This is a local installed-app check, not a
broad release QA result; the final pass did not repeat a full network download.

Automated real-engine validation uses the published Q8 model and NVIDIA's JFK
PCM sample. It starts the bundled-equivalent Metal runtime, connects through
`WS /v1/realtime`, streams the audio in 80 ms batches, commits immediately after
the final batch, checks that the expected final spoken word remains last, and verifies that no engine PID
survives shutdown.

Model startup is now a single owned operation. Selecting another model,
sleeping, waking, restarting, or quitting cancels the prior loader and reaps its
child before another can start. The process manager ignores delayed termination
callbacks from older workers. Wake recovery waits briefly for any conversation
save, then reloads the selected persisted model after macOS restores audio
devices. Quit remains available during loading and forces child cleanup after a
five-second deadline rather than leaving the menu app in an unbounded Preparing
state.

The file workflow was exercised end to end against one warm multilingual Q8
worker with eleven generated fixtures covering every advertised audio codec and
video container. All eleven produced non-empty transcripts in 7.64 seconds
total, including one model startup of roughly five seconds. A separate runtime
benchmark processed a repeated 33-second offline corpus in 0.33 seconds (about
100× realtime) on the test Apple Silicon Mac. These numbers validate the fast
path but are not universal performance claims; confirmation starts from a
conservative 25× realtime estimate and learns from each Mac.

The multilingual validation generates a temporary Spanish fixture locally,
opens the official Nemotron 3.5 Q8 with the same runtime, sends `es-ES` in the
live realtime session update, and verifies the last Spanish word survives
immediate commit. It also runs in `auto` mode during release validation. The
temporary audio is removed after the test.

The same validation opens two stateful realtime connections, sends audio to
both concurrently, commits both streams, and asserts that both transcripts keep
their final spoken word. Live ScreenCaptureKit capture still requires a manual
release test because macOS requires interactive Screen & System Audio approval.

Conversation recognizers enable the runtime's trailing-silence endpointing at
800 ms and request word timestamps. A real-engine speech-silence-speech test
verifies that a single long-lived connection emits multiple pause-bounded
segments on a monotonically increasing audio clock. The saved document is
finally sorted on that audio clock rather than callback arrival time, preserving
You/Speaker turn taking when the two decoders have different inference latency.

Conversation lines are synchronized as they arrive. Stop drains the final
system-audio tail using fresh buffer storage before finalizing both decoder
streams, and normal application quit closes an active transcript before the
speech engine exits. The raw microphone and clean system-output channels remain
fully independent, and the app does not enable Voice Processing I/O or otherwise
change call volume. A conservative word-level matcher compares temporally
adjacent You/Speaker segments, tolerates noisy-ASR differences and different
segment boundaries, and removes only matches of six or more words.

On macOS 15+, microphone and system output use the two independent output types
of a single ScreenCaptureKit stream. Stop waits 900 ms for pending capture
blocks, stops that stream, removes both outputs, flushes both PCM accumulators,
then commits each decoder in order. The app does not close the transcript until
both final decoder events have arrived. macOS 14 keeps the previous microphone
engine as a compatibility fallback.

The package has also been launched directly from its `.app` bundle and reached
the runtime's localhost readiness endpoint using the runtime inside the bundle.
Packaging relocates SentencePiece and Abseil into the app and rejects absolute
Homebrew/user load paths; the relocated runtime passed the same real streaming
test.
The installed app requests Microphone and Accessibility but never chains
privacy requests automatically. Input Monitoring is deliberately not required:
the active global shortcut event tap is covered by Accessibility, which the app
already needs for insertion. Setup exposes one Allow button and one Settings
link per permission, polls for changes, and verifies that the shortcut tap can
actually start before reporting the app ready. Accessibility also has a real
global-event-tap capability check, while a successful conversation capture keeps
System Audio green for the running app. The app no longer infers Accessibility
from whichever application happens to be frontmost, so visiting System Settings
cannot change the displayed state. On macOS 26 it uses the current Privacy &
Security extension address for the audio-only permission pane. While setup is
visible, the otherwise menu-bar-only app temporarily joins the Dock and
Command–Tab for easy return from System Settings. macOS still requires the user
to approve each switch. Broad insertion compatibility remains a release-QA task.
