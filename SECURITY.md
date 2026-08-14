# Security policy

## Supported version

Security and privacy fixes are applied to the latest commit on `main`. There
are no supported binary releases yet; generated DMGs are development builds
until they are Developer ID signed and notarized.

## Report a vulnerability privately

Use this repository's **Security → Report a vulnerability** flow. Do not open a
public issue for a suspected vulnerability, exposed credential, private
transcript, or recording. Remove personal text, audio, account names, machine
paths, and permission-database contents from diagnostic material before
submitting it.

Useful reports identify the affected macOS version, application version, and a
minimal reproduction without real private speech. The project does not need
audio samples or personal transcripts to investigate most defects.

## Security boundaries

- Inference is served by a child process bound to `127.0.0.1`.
- Microphone and system audio are processed in memory; audio recordings are not
  intentionally persisted.
- Conversation transcripts are user-requested documents stored under
  `~/Documents/Local Dictation Transcripts`.
- Model weights are downloaded separately and are not part of this repository
  or its DMG.
- Accessibility, Microphone, and System Audio Recording are sensitive macOS
  permissions. Public releases must be signed, notarized, and tested from the
  final installed application bundle.

See [PRIVACY.md](PRIVACY.md) for the complete data-handling statement.
