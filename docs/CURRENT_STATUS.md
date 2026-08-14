# Current implementation status

Updated August 12, 2026.

| Capability | Status |
|---|---|
| Native menu-bar app and guided setup | Implemented |
| Bundled NeMo-Speech.cpp Metal runtime | Implemented; model remains external |
| Model validation, launch, readiness, restart, and shutdown | Implemented and real-process tested |
| Native microphone capture and 16 kHz PCM16 conversion | Implemented |
| Release-tail capture and ordered final-audio commit | Implemented and final-word tested |
| Persistent stateful realtime WebSocket | Implemented and real-audio tested |
| Fn and Control–Option–Space push-to-talk | Implemented |
| Hands-free mode and 30-minute ceiling | Implemented |
| Concurrent microphone + Mac system-audio transcription | Implemented and dual-stream engine tested |
| Timestamped You/Speaker conversation text files | Pause-bounded, audio-time ordered, and real-engine tested |
| Conversation stop/save crash regression | Fixed from a macOS crash report and lifecycle tested |
| Microphone speaker-echo suppression | Post-ASR fuzzy time-aligned filtering; no audio-route processing; unit tested |
| AirPods capture lifecycle | Unified microphone/system ScreenCaptureKit stream on macOS 15+; outputs removed atomically |
| Conversation final-word tail | 900 ms post-Stop capture, ordered PCM flush, and dual-final wait |
| System Audio permission and live capability check | Implemented; optional and independent of Quick Dictation |
| One-at-a-time privacy onboarding | Implemented; no automatic request chaining |
| Permission capability checks | Implemented for Accessibility, the live global shortcut, and live System Audio |
| Control–Option–C conversation toggle and menu-bar timer | Implemented and shortcut tested |
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

Automated real-engine validation uses the published Q8 model and NVIDIA's JFK
PCM sample. It starts the bundled-equivalent Metal runtime, connects through
`WS /v1/realtime`, streams the audio in 80 ms batches, commits immediately after
the final batch, checks that the expected final spoken word remains last, and verifies that no engine PID
survives shutdown.

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
