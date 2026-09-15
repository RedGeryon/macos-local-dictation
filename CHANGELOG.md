# Release notes

## Unreleased — Menu, Settings, and custom shortcuts

- Active transcription keeps the Mac and display awake, including on battery,
  and releases the hold when the task ends.
- Conversation and media-file transcripts now share one folder per day under
  Documents › Local Dictation Transcripts (for example, 2026-09-15).
  Filenames include times, and duplicates receive a numbered suffix.
  Existing transcripts remain in their original locations.
- Speech to Text defaults to Keep loaded; an explicitly saved idle timeout
  still takes precedence.

- Every shortcut (Quick Dictation, Conversation Transcript, Read Selected Text,
  Pause or Resume Readback) is now user-configurable from a new Settings ›
  Shortcuts page, with conflict warnings and a Restore Defaults button. A
  previously saved Control–Option–Space push-to-talk choice is migrated
  automatically.
- The menu bar and the menu-bar icon now show status for Speech to Text and
  Text to Speech independently, each with its own colored dot (green Ready,
  gray Not loaded, blue busy, red recording, orange needs attention); clicking
  a status row opens the Settings page that explains it.
- The menu-bar menu is reorganized into "Speech to Text" and "Text to Speech"
  sections with native section headers, replacing the old bold title row; the
  old "Quick Dictation Settings" submenu is removed (those toggles now live in
  Settings › Speech to Text), and "Voice Settings…" moved inside the new Voice
  submenu.
- The Settings window now uses a consistent layout across all four pages
  (Speech to Text, Text to Speech, Shortcuts, Models & Startup), each with a
  page title, description, and titled panels.
- The Settings window remembers its size and position between openings instead
  of re-centering every time.
- Settings, the Text to Speech editor, and the menu-bar menu now refresh when
  app state changes instead of polling on a timer, so a status such as
  "Loading…" updates the moment the model is ready.
- Screen & System Audio Recording shows as allowed as soon as macOS reports the
  permission, not only after the first conversation transcript.
- Vivian, a warm female preset voice, is now the second default voice next to
  Ryan. The designed narrator stays available in the full voice list but is no
  longer a default, because it needs extra model passes before it can speak.
- Models & Startup gains a **Memory** choice per feature: keep the model loaded
  or unload it after 5, 15, 30, or 60 idle minutes. It loads again on the next
  use.
- Shortcuts work while a model is unloaded: holding Fn, or pressing the Long
  Dictation or conversation shortcut, loads the speech model and then starts
  the requested action automatically. Reading aloud already loaded on demand.
- Long Dictation has its own shortcut (⌃⌥L by default) so hands-free dictation
  is reachable from any Quick Dictation trigger, not only Fn+Space.
- **Open Local Dictation when you log in** is available in Models & Startup for
  the installed app.
- The menu keeps the last five dictations of the session under **Recent
  Dictations**; choosing one inserts it again.
- The menu-bar icon changes shape with activity: a microphone while listening,
  a speaker while reading aloud, a document while transcribing a file.
- Saving a conversation transcript posts a notification; clicking it opens the
  file.
- The Text to Speech disclosure inside Settings is now called **More Options**.
- The speech engine is now guarded by a watchdog: if the app is force-quit or
  crashes, the engine is stopped within a few seconds instead of lingering in
  memory. Any engine orphaned by an earlier instance is cleaned up at launch.

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
