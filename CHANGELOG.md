# Release notes

## 0.3.11 — File transcription and multilingual setup

### New: transcribe existing audio and video

Choose **Transcribe Audio or Video File…** from the menu-bar app or Settings,
select a file, review its detected details and estimated completion time, then
confirm **Transcribe and Save**. The finished readable `.txt` file opens
automatically and remains in:

`~/Documents/Local Dictation Transcripts/File Transcripts`

Supported inputs are WAV, MP3, M4A (AAC or ALAC), AAC, CAF, AIFF, FLAC, MP4,
M4V, and MOV. A video must contain an audio track. Files up to four hours are
supported. The selected audio is converted once using bounded memory and sent
to the already-warm local model; no audio is uploaded to the internet. Jobs
can be cancelled, temporary conversion data is removed afterward, and this
file-only workflow does not need Microphone, Accessibility, or System Audio
permission.

### Choose the right language model

- **English only:** choose **English** during setup. It uses Nemotron Speech
  Streaming English 0.6B Q8 and only offers English, avoiding misleading
  language controls.
- **Spanish or more than one language:** choose **Multilingual** during setup.
  It uses Nemotron 3.5 ASR Streaming Multilingual 0.6B Q8. Choose `es-US` or
  `es-ES` for Spanish-only transcription, or choose **Auto Detect** when a
  recording may switch languages. The model supports 32 documented locales.

The app downloads the chosen model inside Settings, visibly reports progress
and its permanent location, verifies the download, selects it, and starts the
local engine. The models have distinct licenses, which are linked before
download. This app transcribes speech; it does not translate it.

### Reliability and usability updates

- Green Ready state in the menu and Settings, including reliable permission
  capability checks.
- Startup, sleep/wake, and quit handling recycles stalled local workers instead
  of leaving the app indefinitely Preparing.
- The final audio tail is drained before recognition finishes, reducing missing
  last words on release or Stop.
- Conversation transcripts preserve chronological **You** and **Speaker** turn
  taking, save one text file per session, and stop cleanly with the same
  Control–Option–C shortcut that starts them.
- AirPods and other normal macOS input-route changes follow the current system
  input without permanently taking over playback audio.

## Previous public release

The initial public release introduced local, on-device push-to-talk dictation
for Apple Silicon Macs using NVIDIA's NeMo-Speech.cpp runtime. Model weights
remain separately downloaded and are never included in the app package.
