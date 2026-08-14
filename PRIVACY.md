# Privacy

- Microphone capture starts only when push-to-talk or hands-free dictation is
  active and stops on release, completion, or cancellation.
- In conversation mode, microphone and Mac system-audio capture remain active
  until the user chooses Stop and Save. ScreenCaptureKit is configured with an
  audio output only; screen video is neither delivered to nor stored by the app.
- Audio is converted and streamed in memory to `127.0.0.1`; the app does not
  intentionally write recordings to disk.
- Transcript text is excluded from application logs.
- Only the most recent transcript is retained in memory for Paste Last. It is
  not persisted across launches.
- Conversation mode intentionally writes labeled, timestamped `.txt` files to
  `~/Documents/Local Dictation Transcripts`. It does not write audio files.
  These user documents remain if the app or its model data is removed and must
  be deleted by the user if no longer wanted.
- The app has no account, analytics, telemetry, advertising, or cloud inference.
- The model and source download steps require internet access. Normal dictation
  is designed to work offline after installation.
- The app reads only a small text window around the cursor for boundary spacing.
  That context stays in process and is not logged or transmitted beyond the
  local app.

The NeMo server binds to a dynamically selected `127.0.0.1` port. A release
privacy test must still verify these claims with networking disabled and inspect
all process connections before public marketing uses “fully local” language.
