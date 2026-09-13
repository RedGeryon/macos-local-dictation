# Install and remove Local Dictation

## Install or replace

This repository produces an Apple Silicon development build. Create its DMG
from source with:

```bash
bash scripts/generate-dmg.sh
```

The output is `dist/Local-Dictation-0.4.1-macOS-arm64.dmg`. The first build
creates the bundled NeMo-Speech.cpp runtime. Model weights are separate from the
DMG.

To install a supplied DMG or replace an earlier copy:

1. Quit Local Dictation.
2. Open the DMG and drag **Local Dictation** to **Applications**. Choose
   **Replace** if Finder asks.
3. Open **Local Dictation** from Applications. Do not grant permissions to the
   copy still on the DMG. Development builds are ad-hoc signed, so macOS may
   require Control-click → Open. A public release must be Developer ID signed
   and notarized.
4. Open **Models & Startup**. Enable only the features you want. Each feature
   has an independent **Load at startup** choice. Each picker lists only models
   that are already verified locally. Choose **Add Model…** to see available
   downloads. A download adds a model; **Load now** starts the selected model.
   Selecting another installed model switches and loads it when that feature is
   enabled. If the feature is disabled, the choice is saved and remains unloaded
   until you enable it, then choose **Load now** (or use a saved startup choice
   on the next launch). This does not alter **Load at startup**.
   - For Speech to Text, use **Add Model…** to download either **English** or
     **Multilingual**. The multilingual model supports Spanish, other supported
     languages, and Auto Detect.
   - For Text to Speech, use **Add Model…** to download **Qwen 1.7B (BF16)**
     or **Qwen 1.7B (8-bit)** Preset voices. The app sets up Read Aloud first
     when needed. If weights are already installed but the runtime is missing,
     use **Set up Read Aloud** as recovery. BF16 is the initial preference, not
     an included download.
     VoiceDesign and Base remain optional downloads for a new persistent custom
     voice. The 8-bit option is not claimed to match BF16 quality.
5. On the **Dictation** page, allow Microphone and Accessibility. macOS requires
   the user to approve each permission. System Audio Recording is requested only
   when starting a conversation transcript.

Replacing the installed app preserves its saved macOS preferences and leaves its
Application Support models, Read Aloud runtime, and saved voice references in
place. A development preview has a separate identity; normal replacement does
not promise to promote preview-only settings, models, or saved voices.

```text
~/Library/Application Support/LocalDictation/
├── Models/       speech-to-text models
├── TTSRuntime/   Read Aloud Python environment
├── TTSModels/    Qwen model snapshots
└── SavedVoices/  persistent custom-voice references
```

## Remove

Choose **Help → How to Remove… → Remove Local Data…** in Local Dictation, then
move `/Applications/Local Dictation.app` to the Trash. Local data includes the
speech and read-aloud models, the Read Aloud runtime, saved voice references,
and app settings. Exported audio and transcript documents are intentionally not
removed; delete them separately if needed.

Developers can instead run:

```bash
bash scripts/uninstall.sh --remove-all
```

That script moves the app and its Application Support directory to the Trash.
macOS may retain a privacy entry. Do not reset it merely to replace the app;
remove it manually in System Settings only when you intentionally want to revoke
Local Dictation access.
