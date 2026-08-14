# Install and remove Local Dictation

## Generate the DMG from source

On an Apple Silicon Mac with the Xcode Command Line Tools and Homebrew, run:

```bash
bash scripts/generate-dmg.sh
```

The first run builds NeMo-Speech.cpp locally; subsequent runs reuse it. The
finished installer is written to
`dist/Local-Dictation-0.3.7-macOS-arm64.dmg`. Model weights are never bundled.

## Install

1. Open the DMG.
2. Drag **Local Dictation** to **Applications**.
3. Open it from Applications. The first local build is ad-hoc signed, so macOS
   may require Control-click → Open. Public releases must be Developer ID signed
   and notarized.
   If you accidentally open the app from the DMG, it offers to copy itself to
   Applications and relaunch before requesting privacy access.
4. Download the model from the official
   [Hugging Face model page](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b),
   read the NVIDIA model license, and choose the Q8 GGUF in setup.
5. Open **Settings…** and approve Microphone and Accessibility one row at a
   time. Input Monitoring is not required. Accessibility covers both the global
   shortcut and text insertion. The app does not launch the next privacy
   request automatically. Use the adjacent Settings link only when macOS does
   not show its normal approval surface, then choose Refresh Status.
   While setup is open, the app temporarily appears in the Dock and Command–Tab,
   making it easy to return from System Settings.
6. To use two-sided conversation transcripts, press **Control–Option–C** and
   approve the additional **System Audio Recording** request. The app
   captures audio only, not screen video. Press the shortcut again to stop and
   save a new file under Documents → Local Dictation Transcripts.

macOS does not allow an app to turn these switches on for you. If a check stays
gray after you enabled it, make sure the listed item is the copy in
`/Applications`, quit and reopen Local Dictation, then click **Request…** on
that row. Ad-hoc development builds have a new security identity after some
rebuilds and can require approval again; Developer ID signing prevents that in
public updates. Development builds produced by this repository use a stable
bundle-identifier requirement so approvals persist across subsequent local
rebuilds after one final approval of the 0.3.7 build.

For stale entries left by an older ad-hoc build or a copy launched from the
DMG, choose **Repair Stale Permission Registration…**. After confirmation, the
app resets only its own relevant records, relaunches from Applications, and starts
the request sequence again.

The Apache-2.0 NeMo-Speech.cpp runtime is included in the app bundle. NVIDIA
model weights are not included.

## Remove

Open the menu-bar icon and choose **How to Remove…**. Use **Remove Local Data**
to delete the model, external engine, and settings, then move the application
from Applications to the Trash.

Developers who installed using the repository scripts can instead run:

```bash
bash scripts/uninstall.sh --remove-all
```

The script moves the application and support directory to the Trash. macOS may
retain privacy permission entries; these can be removed manually from System
Settings → Privacy & Security if desired.

Saved conversation text files are user documents and are intentionally not
removed with the model or app. Delete `~/Documents/Local Dictation Transcripts`
separately if you no longer want them.
