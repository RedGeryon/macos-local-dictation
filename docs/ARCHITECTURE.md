# Architecture

## Runtime boundary

```text
macOS event tap
   │ Fn down / Fn up / Esc
   ▼
AVAudioEngine (~10 ms hardware callbacks)
   │ sample-rate conversion
   ▼
mono 16 kHz PCM16 accumulator
   │ 80 ms transport batches
   ▼
one persistent localhost WebSocket
   │ one stateful recognition stream per utterance
   ▼
warm NeMo-Speech.cpp process
   │ cached FastConformer/RNNT decoding, 160 ms operating point
   ▼
partials → overlay only
final → deterministic processing → Accessibility/paste insertion
```

The app bundles the small Apache-2.0 NeMo-Speech.cpp runtime and owns it as a
child process. The selected NVIDIA GGUF model is separately downloaded and
loaded once at application startup. Quitting terminates the child and releases
model memory.

The English GGUF uses the fixed `en-US` recognition prompt and the UI presents
English as its only language. The multilingual
GGUF carries prompt metadata for its language-locales; setup persists either an
explicit locale (including `es-US` or `es-ES`) or `auto`. That value is sent on
the quick-dictation socket and both conversation sockets. Changing language
updates the idle quick-dictation session so the next utterance uses the new
prompt; future conversation sockets inherit it. Changing model restarts the
warm worker because only one model is resident at a time.

## Managed model download

Setup downloads model weights with a native `URLSession` download task, so the
browser is not part of the transfer. Progress remains visible in Setup and is
summarized in the menu. The destination is deterministic:

```text
~/Library/Application Support/LocalDictation/Models/<official-file>.gguf
```

The source URL is pinned to a reviewed Hugging Face repository revision. The
download first lands at a hidden staging path. Before replacing a managed model,
the app checks the expected byte count, pinned SHA-256 digest, and GGUF magic.
Failed, canceled, or mismatched staging files are discarded. Only a verified
file is moved to its final path, persisted as the selected model, and passed to
the worker. The separately licensed weights remain outside the app and DMG.
First-run setup presents the two official choices only when no valid persisted
model is available. A completed managed download selects the file and starts
the worker without a separate Refresh step.

## Sleep, wake, and termination lifecycle

Only one model startup or restart task can exist. A newer request cancels and
awaits cleanup of the older request before launching another worker. Process
termination callbacks carry the worker PID, so a late callback from an old
process cannot clear the active worker's state.

Before sleep the app marks the realtime connection unavailable and cancels any
in-progress model load. After wake it gives macOS time to restore audio routes,
briefly allows an active conversation journal to finish, then recycles the
worker and reconnects the stateful stream with the saved model and language.
Quit cancels startup and wake recovery. Normal graceful cleanup is attempted,
but a five-second termination deadline force-reaps the child so a stalled model
or transcript finalizer cannot make the menu-bar app impossible to quit.

## Conversation transcription

Conversation mode owns two stateful WebSockets and keeps the audio channels
separate for the entire session:

```text
ScreenCaptureKit microphone ─► ASR stream 1 ─► "You"
ScreenCaptureKit system audio ─► ASR stream 2 ─► "Speaker"
                                       │
                                       ▼
                   time-aligned echo filter
                                       │
                                       ▼
                   audio-clock timeline merge
                                       │
                                       ▼
                   timestamped text in Documents
```

On macOS 15 and newer, ScreenCaptureKit registers separate `.audio` and
`.microphone` outputs, requests 16 kHz mono system audio, and excludes Local
Dictation's own process audio. The microphone arrives in its native format.
Each source is independently converted and batched as 16 kHz PCM16. No screen
frames or audio recordings are persisted.

The microphone device ID remains nil so macOS supplies the current default input
rather than the app forcing a physical device. Owning and removing both stream
outputs together avoids a second audio engine competing for an AirPods route or
retaining its call profile after Stop. macOS 14 retains the separate
AVAudioEngine fallback. The raw microphone always reaches its own stateful
decoder while the clean Mac output reaches the other. You segments are
briefly held while nearby Speaker segments arrive. A fast semi-global word
alignment removes time-correlated phrases of at least six words, tolerating
different ASR boundaries and noisy substitutions; it can remove only an echoed
prefix or suffix while retaining genuine user speech beside it. Short common
phrases, middle-only incidental overlap, and unrelated speech are preserved.

Pressing Stop enters the Saving state but leaves both inputs open for another
900 ms. This drains ScreenCaptureKit's buffered sample blocks and preserves the
end of the final word. The unified stream is then stopped, both sub-80 ms PCM
tails are queued, and only afterward are the two ordered WebSocket commits sent.
The transcript footer is written after both decoder-final events arrive.

The runtime's token-silence endpointer closes a recognition segment after about
800 ms of pause without closing its WebSocket. Word timestamps remain on the
absolute stream clock across those decoder boundaries. Lines are synchronized
as a live crash-recovery journal, then the completed file is atomically rebuilt
from both channels sorted by word start time. Decoder callback latency can
therefore never collapse each participant into a session-length block or invert
an alternating turn.

The system-audio tail is copied, the accumulator is replaced with fresh storage,
and only then is the tail sent. This avoids mutating storage still retained by
the final callback. Every appended transcript line is synchronized to disk, and
normal application termination finishes the active text file before shutting
down the model process.

Control–Option–C toggles this mode globally. The persistent UI is limited to a
red dot and elapsed time in the menu bar. Stopping briefly shows a saved state;
it does not open the text file. If the shortcut is pressed while both decoders
are finalizing, the next session is queued and receives its own new file as soon
as finalization completes.

## Existing media-file transcription

```text
user-selected audio/video
        │ AVFoundation reads first audio track
        ▼
one-pass 16 kHz mono PCM conversion
        │ one temporary multipart file, bounded memory
        ▼
POST /v1/audio/transcriptions on 127.0.0.1
        │ warm model, offline batched inference
        ▼
atomic readable .txt in Documents/File Transcripts
```

The picker accepts macOS audio/movie types but the promised compatibility
matrix is WAV, MP3, M4A with AAC or ALAC, AAC, CAF, AIFF, FLAC, MP4, M4V, and
MOV. Video must contain an audio track; one job may be at most four hours. A
single `AVAssetReader` pass performs decode, resample, downmix, PCM encoding, and
multipart construction directly into one temporary file. The app never holds a
whole recording in RAM or creates a second WAV copy. `URLSession` uploads that
file to the existing warm worker, avoiding model startup and realtime pacing.

The confirmation estimate uses a conservative initial real-time factor and a
clamped exponential moving average of observed duration-to-wall-time for each
model variant. Conversion progress is derived from media timestamps; offline
recognition progress advances against the confirmed estimate and is capped
until the server returns. Cancellation propagates through both AVFoundation and
the upload task. Temporary uploads are removed in every normal exit path and
app-prefixed leftovers are cleaned at startup.

## Why the hot path remains WebSocket

The upstream runtime's realtime API already provides the desired stream
semantics: one socket owns one decoder stream, binary PCM16 messages append
audio, `input_audio_buffer.commit` immediately finalizes the remaining tail,
and clear/cancel resets stream state. It does not perform stateless transcription
per message or serialize WAV files.

Replacing this with a project-specific Unix socket would require maintaining a
runtime fork while removing negligible loopback framing overhead. Audio capture,
transport batching, and inference cadence are deliberately independent:

```text
capture callback    hardware cadence, normally about 10–20 ms
transport batch     80 ms
model cadence       160 ms low-latency configuration
release             capture 180 ms tail, flush callback, then ordered commit
```

The model and socket remain warm between utterances. Decoder stream state is
reset between utterances without reloading model tensors.

## State and cancellation

`AppState` is the UI authority:

```text
starting → loadingModel → permissionRequired → ready
ready → recording(pushToTalk | handsFree)
recording → finalizing → inserting → ready
recording/finalizing → canceling → clear acknowledged → ready
ready → inspectingMedia → transcribingFile → ready
```

The client waits for each asynchronous WebSocket send to complete before
sending the next PCM or control message, so commit cannot overtake audio. On
release, capture remains open for 180 ms to collect the final hardware buffer;
shutdown then waits for any in-flight converter callback before flushing the
sub-80 ms accumulator. After cancellation, a new session is not allowed to start until
the server acknowledges `input_audio_buffer.cleared`; this prevents late events
from an old utterance entering a new one.

## Audio and privacy choice

The microphone is opened on key-down and closed 180 ms after release, or
immediately on cancel. A continuous
200 ms pre-roll buffer was considered but is not enabled because it would keep
the macOS microphone indicator active while idle. The warm model, persistent
socket, and immediate audio-engine start provide the low-latency path without
continuous capture. Pre-roll can be revisited only as an explicit opt-in after
measuring first-phoneme clipping.

## Transcript and insertion pipeline

Partials are visible only in the non-activating overlay. The final result passes
through deterministic stages:

1. Unicode and whitespace normalization.
2. End-only `press enter` extraction and `new paragraph` expansion.
3. Optional conservative `um`/`uh` and adjacent-repeat removal.
4. Spacing based on a small Accessibility window around the original cursor.
5. Selected-text Accessibility insertion, then a clipboard-preserving paste
   fallback if necessary.
6. Optional Return after successful insertion, blocked in known terminals.

The target Accessibility element is captured before recording, so the overlay
and menu app never need to steal focus. Secure/password fields are rejected.

## Local server protocol

- `GET /ready`: model readiness.
- `WS /v1/realtime`: stateful little-endian PCM16 streaming.
- `POST /v1/audio/transcriptions`: offline transcription of a prepared WAV
  multipart upload using the already-loaded model.
- `session.update`: 16 kHz audio plus the selected locale or `auto`;
  conversation streams additionally request 800 ms endpointing and word
  timestamps.
- binary messages: PCM16 audio.
- `input_audio_buffer.commit`: flush and finalize.
- `input_audio_buffer.clear`: cancel and reset.

The server binds to `127.0.0.1` on a dynamically selected port. No audio or
transcript is logged by the app.
