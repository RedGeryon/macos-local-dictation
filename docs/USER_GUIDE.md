# Local Dictation: install and use

Local Dictation is a menu-bar app for Apple Silicon Macs. It turns speech into
text and text into speech on your Mac. Nothing is sent to the internet after the
one-time model downloads.

## Install

Requirements: macOS 14 or later on an Apple Silicon Mac, about 1 GB of disk for
a speech model, and 3 to 5 GB more if you want text to speech.

1. Quit any running copy of Local Dictation.
2. Open the DMG and drag **Local Dictation** to **Applications**. Choose
   **Replace** if Finder asks. Your models and settings are kept.
3. Open Local Dictation from Applications, not from the DMG. Development builds
   are not notarized, so macOS may require Control-click → **Open** the first
   time.
4. Click the waveform icon in the menu bar and choose **Models & Startup…**.
   - Under **Speech to Text**, choose **Add Model…** and download **English**
     (about 700 MB) or **Multilingual** (about 742 MB, Spanish and 30 more
     languages). Then choose **Load Now**.
   - Under **Text to Speech**, choose **Add Model…** and download **Qwen 1.7B
     (8-bit)** (3.1 GB, smaller and faster) or **BF16** (4.5 GB, highest
     quality). Skip this if you only want dictation.
   - Leave **Load at startup** on for the features you use daily.
5. In the menu choose **Settings…** → **Speech to Text** and allow
   **Microphone** and **Accessibility**. Both are required for dictation.
   **Screen & System Audio Recording** is optional and is only asked for when
   you start a conversation transcript.

To build from source instead of using a DMG, see
[BUILDING_AND_RELEASE.md](BUILDING_AND_RELEASE.md).

## Use

The menu-bar icon shows status at a glance: green means ready, blue means busy,
red means recording, and orange means something needs attention. Click it for
the menu. Each feature has a status row; click the row to open the page that
explains it.

### Escape cancels anything

**Escape** is the one key to remember. It cancels a dictation in progress
without inserting anything, stops readback mid-sentence, dismisses a pending
start while a model is loading, and clears the on-screen hint. It works from
any app, even while the menu is open, and it cannot be reassigned.

### Dictate into any app

1. Put the cursor in a text field.
2. Hold **Fn**, speak, and release. The text is inserted where the cursor was.
3. Press **Escape** at any point to cancel; nothing is inserted.

For longer passages, press **Control–Option–L** (or **Space** while holding
**Fn**), or choose **Start Long Dictation** from the menu. Speak as long as you
like (up to 30 minutes), then press the shortcut again to insert, or **Escape**
to throw it away. The menu keeps
the last five results of the session under **Recent Dictations**; choose one to
insert it again.

### Transcribe a conversation

Press **Control–Option–C** or choose **Start Conversation Transcript**. Your
microphone is written as "You" and the Mac's audio output as "Speaker". A red
timer appears in the menu bar. Press the shortcut again to stop and save.
A notification confirms the save; click it to open the file. Transcripts are
saved in dated folders under **Documents › Local Dictation Transcripts** and are listed under
**Transcripts** in the menu.

### Transcribe an audio or video file

Choose **Transcribe Audio or Video File…**, pick a file, review the estimated
time, and confirm. Supported: WAV, MP3, M4A, AAC, CAF, AIFF, FLAC, MP4, M4V,
MOV. The finished text file opens automatically and is saved in
**Documents › Local Dictation Transcripts › YYYY-MM-DD** (for example,
**2026-09-15**). Conversation and file transcripts share each day’s folder;
filenames include times. Existing files stay where they were saved.

During transcription, the app keeps the Mac and display awake, including on
battery. Normal automatic sleep resumes when the job ends. Closing the lid
or explicitly choosing Sleep can still suspend the Mac.

### Read text aloud

- Select text in any app and press **Control–Option–R**, or choose **Read
  Selected Text**. **Read Clipboard** reads whatever you last copied.
- **Control–Option–P** pauses and resumes. **Escape** stops immediately.
- Choose a voice from the **Voice** submenu. Ryan (male) and Vivian (female)
  are the defaults; more presets are listed below them. **Voice Settings…**
  lets you add a delivery instruction such as "speak slowly" or describe a
  custom voice.
- **Create Audio File…** turns typed or pasted text into an audio file.

### Change shortcuts

Open **Settings…** → **Shortcuts**. Click a field, press the keys you want, and
you are done. A shortcut needs Control, Option, or Command, or an F-key.
**Delete** removes a shortcut. **Restore Defaults** brings back Fn,
Control–Option–L, Control–Option–C, Control–Option–R, and Control–Option–P.
Escape always cancels and cannot be changed.

### Preferences worth knowing

In **Settings…** → **Speech to Text**: transcription language (multilingual
model only), automatic punctuation, the live transcript overlay, and removal of
"um" and "uh". In **Models & Startup**: **Open Local Dictation when you log
in**, **Load at startup** per feature, and **Memory**, which unloads a model
after a quiet period and loads it again on the next use. **Unload** frees a
model's memory right away; **Load Now** brings it back.

## Troubleshooting

| Symptom | What to do |
|---|---|
| Menu shows **Permissions required** | Settings → Speech to Text → allow Microphone and Accessibility. If macOS shows the permission as on but it still fails, quit and reopen the app. |
| Fn does nothing in one app | Some apps use secure text fields or block Accessibility insertion. Dictate elsewhere, then paste. |
| Text to Speech shows **Needs setup** | Models & Startup → Text to Speech → **Add Model…**, then **Load Now**. |
| Status stays orange after a download | Choose the model in the picker, then **Load Now**. |
| The Mac feels slow | Set **Memory** to unload after a few idle minutes, or choose **Unload** for the feature you are not using. |
| The first dictation after a pause says "Loading" | The model was unloaded while idle. Keep holding Fn and dictation starts as soon as it is ready (about five seconds); Long Dictation and conversation shortcuts start on their own too. Set **Memory** to **Keep loaded** to avoid the wait. |

## Remove

Choose **Help › How to Remove…** in the menu. It explains how to delete the app
and, optionally, the downloaded models. Details are in
[INSTALL_AND_REMOVE.md](../INSTALL_AND_REMOVE.md).
