# Privacy

- Microphone capture starts only when push-to-talk or hands-free dictation is
  active and stops on release, completion, or cancellation.
- In conversation mode, microphone and Mac system-audio capture remain active
  until the user chooses Stop and Save. ScreenCaptureKit is configured with an
  audio output only; screen video is neither delivered to nor stored by the app.
- Live microphone and system audio is converted and streamed in memory to
  `127.0.0.1`; the app does not write those live recordings to disk.
- For user-selected file transcription, the chosen audio track is converted in
  one pass to a temporary compact upload on macOS temporary storage. It is sent
  only to the warm `127.0.0.1` engine and deleted on completion or cancellation;
  crash leftovers with the app-specific temporary name are cleaned on launch.
  The original audio or video file is never modified.
  This workflow does not require Microphone, Accessibility, or System Audio
  permission.
- Transcript text is excluded from application logs.
- Only the last five quick dictations are retained in memory for Paste Last and
  Recent Dictations. They are not written to disk and are gone when the app
  quits.
- Conversation mode and user-confirmed file transcription intentionally write
  `.txt` files to `~/Documents/Local Dictation Transcripts`. Conversation text
  is labeled and timestamped; file results are stored in `File Transcripts`.
  These user documents remain if the app or model data is removed and must be
  deleted by the user if no longer wanted.
- The app has no account, analytics, telemetry, advertising, or cloud inference.
- The model and source download steps require internet access. Normal dictation
  is designed to work offline after installation.
- The app reads only a small text window around the cursor for boundary spacing.
  That context stays in process and is not logged or transmitted beyond the
  local app.

## Permissions

- macOS is the source of truth for permission state. The app refreshes visible
  Microphone and Accessibility status instead of storing a permanent “allowed”
  result. A running global shortcut listener is not treated as proof that the
  separate Accessibility API permission needed to read selected text is allowed.
- Microphone requests that macOS has already denied lead the user to the
  Microphone pane. Accessibility stays an explicit user choice. System Audio
  Recording is optional and is confirmed only when a conversation capture is
  actually started; a general screen-capture preflight is not presented as a
  permanent audio-only approval.
- For everyday use, grant permissions to **Local Dictation** in Applications.
  A developer preview has a separate macOS identity and separate permissions;
  it is not the installed app. Test observations about pane routing and preview
  identity are kept in [the validation record](docs/tts-validation.md).

## Text to speech

- Selected text, pasted text, a delivery instruction, and per-request
  pronunciation replacements are sent only from the app to its
  bearer-protected `127.0.0.1` text-to-speech child process. They are not sent
  to an account, analytics service, or cloud inference endpoint, and the worker
  avoids logging them.
- A user who chooses **Create Audio File…** and then **Save Audio…** intentionally
  writes the finished RF64 audio file to the location they choose. That file
  remains until the user deletes it.
- The Qwen model download and MLX Python-package installation need internet
  access. The worker sets Hugging Face and Transformers offline mode before
  loading a model. A network-disabled real synthesis check has passed; the
  broader release networking audit remains required.
- Live-readback chunks are temporary audio data. Their cleanup on success,
  cancel, process failure, quit, and next launch is a release gate in
  [the validation checklist](docs/tts-validation.md). Until that check passes,
  do not treat temporary TTS audio as guaranteed to be removed.
- An advanced persistent VoiceDesign persona deliberately saves a generated
  reference WAV and its model, language, seed, and fixed reference-transcript
  metadata under `~/Library/Application Support/LocalDictation/SavedVoices`.
  The folder name uses a hash of the description. Saved voice choices, delivery
  prompts, and pronunciation replacements are also stored locally in the app's
  preferences so they can be reused. They are not encrypted by the app and are
  not sent to a cloud service. **Open Saved Voices Folder** exposes the location
  in Finder; removing a saved-voice folder removes that reference. **Remove
  Local Data** also removes Application Support data, while audio files the user
  exported to Documents remain their responsibility to delete.

The NeMo server binds to a dynamically selected `127.0.0.1` port. A release
privacy test must still verify these claims with networking disabled and inspect
all process connections before public marketing uses “fully local” language.
