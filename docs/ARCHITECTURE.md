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
child process. The selected NVIDIA GGUF model is separately downloaded. Speech
to Text and Text to Speech are independently enabled and may independently be
loaded at startup; opening the app does not require either optional model to be
present. Quitting terminates managed children and releases their model memory.

## Keyboard shortcuts

`KeyboardShortcut` represents one recordable shortcut as a key code plus a
⌃⌥⇧⌘ modifier set, and matches an incoming event only on an exact combination.
`ShortcutBindings` holds every shortcut the app listens for — Quick Dictation,
Conversation Transcript, Read Selected Text, and Pause or Resume Readback — and
is persisted as JSON under the `shortcutBindings` `UserDefaults` key. Loading it
migrates the legacy `dictationShortcut` value: if that key previously held
`controlOptionSpace`, Quick Dictation becomes a custom ⌃⌥Space binding instead
of losing the user's preference. `GlobalHotkeyController` matches live keyboard
events against the current bindings and pauses (`isSuspended`) while the
Settings window's shortcut recorder is actively capturing a new combination, so
the old binding cannot fire underneath it. `FeatureStatusPresentation` is the
single source of the status labels, colors, and menu-bar icon tint shown for
Speech to Text and Text to Speech, so the menu and Settings never disagree
about what a given state means.

## Optional text-to-speech runtime

Text to speech is a separate, optional local service. It is not part of the
dictation WebSocket or the bundled NeMo runtime. Its Qwen weights and Python
environment are explicitly installed outside the application bundle and are
not included in the app or DMG.

```text
selected text or Generate Audio File
        │ Control–Option–R (default; configurable) / menu action
        ▼
AppCoordinator ── bearer-authenticated HTTP on 127.0.0.1 ──► one MLX Audio worker
        │                                                        │
        │ NDJSON: a finished short WAV chunk at a time           │ pinned local
        ▼                                                        ▼ Qwen model
AVAudioEngine player node ◄── acknowledge after playback ◄── Qwen streaming generator
```

The app starts the worker only when Text to Speech is enabled and loaded. It
passes a new bearer token and its process ID on each launch. The worker binds
only to `127.0.0.1`, rejects requests without that token, avoids logging text
or prompts, and sets Hugging Face and Transformers offline mode before model
loading. In app-managed mode, a small parent watchdog stops the worker if
macOS re-parents it after the app crashes or is force-quit. The standalone
worker leaves that watchdog off.

The initial quality-reference model is the pinned BF16 MLX conversion of
Qwen3-TTS 12Hz 1.7B CustomVoice. The user can instead select the separately
downloaded 8-bit conversion. Model status distinguishes downloaded components
from a warmed component; visiting Models & Startup does not warm a model. The
worker allows one TTS job and one loaded component at a time, which keeps
cancel and memory ownership clear.

For the installed app, persistent local data has one canonical root:

```text
~/Library/Application Support/LocalDictation/
├── Models/       Speech-to-text GGUF files
├── TTSRuntime/   Read Aloud Python environment
├── TTSModels/    pinned Qwen snapshots and completion markers
└── SavedVoices/  persistent custom-voice reference WAVs and metadata
```

The two features retain independent enabled, model-choice, and startup-load
settings. Selecting another verified installed model while its feature is
enabled unloads the old worker and loads the new selection. While disabled, the
selection is persisted without loading a worker. Explicit loading, a read-aloud
request, and that feature's saved startup-load choice also load the selected
model. A selection change does not change its startup choice. The installed-app
migration path for this feature branch is validated separately; this layout does
not promise how an earlier development preview is promoted.

The main pickers contain only verified installed models. **Add Model…** opens
the same catalog pattern for Speech to Text and Text to Speech: each candidate
has an accessible information control and a separate **Download** action.
Downloading adds a model but does not warm it or replace a valid current choice.
A first usable download becomes the saved choice only when no valid choice
exists; it remains unloaded until a separate load trigger.

For selected-text readback, the worker produces small valid WAV chunks. The
app plays one, acknowledges it, then allows the worker to get only a short
distance ahead. Escape cancels the app task, stops playback, and sends a local
cancel request. Cancellation takes effect between generated chunks, so the
remaining inference time for the current model chunk is the practical upper
bound on stop latency.

For a file render, normal prose is split at readable boundaries and each piece
is generated with the same voice, instruction, and English hint. PCM is written
incrementally to a temporary file and atomically published as RF64, the
64-bit extension of WAV. RF64 avoids the classic WAV 4 GiB limit without
retaining the full audio in memory. macOS `AVAudioFile`, `afinfo`, and ffprobe
were checked against both a small synthetic output and a sparse output above
4 GiB on 2026-09-12. Small real Qwen output from Ryan and Designed Narrator was
also parsed successfully. Listening review and a real multi-hour export remain
release checks.

The CustomVoice route uses a named preset and may add a delivery instruction.
The app keeps an explicit saved current voice configuration for daily readback,
along with the saved configuration for each voice the user has used. Voice-page
edits are a separate draft: previewing a draft never changes the current
configuration, and **Save & Use Voice** is the only action that makes a draft
the voice for selected-text readback and clipboard readback. The Audio page
uses the saved current voice, while its text stays local to that page.

When a readback or export begins, the app snapshots that saved configuration,
including its pronunciation overrides, before worker startup awaits. A later
Voice-page edit therefore applies to the next job rather than changing a job
already being prepared or generated.

For a saved custom voice, the persistent-persona route first generates a short
reference with VoiceDesign, then asks the Base model to use that reference and
its transcript for each subsequent chunk. A saved reference WAV is a local
conditioning input, so an existing reference can be reused when the user
changes Base precision; switching precision does not replace it. This does not
claim the two precisions sound identical. References and their metadata remain
local; the Read Aloud settings disclosure provides the practical file and
recovery controls.

The English GGUF uses the fixed `en-US` recognition prompt and the UI presents
English as its only language. The multilingual
GGUF carries prompt metadata for its language-locales; setup persists either an
explicit locale (including `es-US` or `es-ES`) or `auto`. That value is sent on
the quick-dictation socket and both conversation sockets. Changing language
updates the idle quick-dictation session so the next utterance uses the new
prompt; future conversation sockets inherit it. Changing model restarts the
warm worker because only one model is resident at a time.

## Managed speech-to-text model download

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
The installed-model picker contains only validated local files. The Add Model
catalog presents the two official candidates when the user asks for one. A
completed first download becomes the choice only when no valid choice exists;
loading remains a separate action.

## Managed text-to-speech runtime and model download

Models & Startup runs the bundled setup and download scripts as child processes
when the user explicitly chooses a Text to Speech component. The scripts live
inside the application resources; the virtual environment, model snapshots,
and saved references remain in Application Support. The installer accepts the
selected component (`custom`, `design`, or `base`) at the selected precision,
downloads an immutable MLX Community revision to an app-owned hidden staging
directory, checks required offline Qwen assets, and atomically marks the final
directory complete.

The downloader serializes downloads for one model directory. Canceling the
installer stops its download process without unloading an already-warmed voice
worker. A canceled or interrupted transfer can leave an app-owned partial
staging directory; it has no completion marker and the next request safely
resumes it after the operating system releases the lock. Existing unverified
final model directories are left unchanged. The app can therefore show an
actionable retry without asking the user to find a shell path or delete hidden
files.

`GET /ready` reports installed components for BF16 and 8-bit plus the one
currently warmed model/component. `POST /v1/models/preload` accepts a model ID
and active voice ID, warming CustomVoice for presets and Base for an existing
Designed Narrator or custom reference. It never generates or replaces a
reference just to warm the worker. `POST /v1/models/unload` releases the loaded
component. These local endpoints require the launch bearer token.

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

Control–Option–C (default; configurable) toggles this mode globally. The persistent UI is limited to a
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
