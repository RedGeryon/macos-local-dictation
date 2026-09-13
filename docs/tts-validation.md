# Text-to-speech validation checklist

Status date: 2026-09-12. This checklist distinguishes observed local results
from release requirements that remain open.

## Baseline before text-to-speech validation

- The reported pre-feature Swift baseline is **45 tests executed: 39 passed, 6
  skipped, and 0 failures**. Re-run `swift test` after integrating the feature
  and record the actual count beside that result.
- `bash scripts/audit-public-repo.sh` has a known existing failure: reachable
  history contains a non-private author or committer email. This is a repository
  history issue, not evidence about the text-to-speech feature. It must still be
  resolved or explicitly accepted before a public release.
- At the baseline, no Qwen weights had been downloaded for the research or
  container checks. Later observed model checks are recorded below.

## Observed container check

On macOS 26.5.2, 2026-09-12, synthetic 24 kHz mono PCM written through
`AtomicRF64Writer` was read successfully by `afinfo`, `ffprobe`, `soxi`, and
`AVAudioFile`. A sparse 4,294,967,296-byte output also reported the expected
64-bit RF64 sizes and 2,147,483,608 frames. This validates the container writer
and Apple playback support, not model output or export UI.

## Preliminary M5 Pro runtime observation

On the target M5 Pro with 64 GB unified memory, the pinned BF16 CustomVoice
model (`52f4770fd9726457eae3d3b6aa92047a25a10776`) generated two short local
English exports with `Ryan`, `English`, seed `42`, 24 kHz output, and a 0.32 s
streaming interval. These are worker timings, not device end-to-end latency or
a listener-quality result.

| Run | Input and setting | First audio | Audio duration | Generation time | Real-time factor |
| --- | --- | ---: | ---: | ---: | ---: |
| Cold | `Local text to speech should begin quickly and read this sentence in a clear, natural English voice.`; unloaded model, no delivery instruction | 1.279 s | 6.640 s | 3.646 s | 0.549 (1.82× real time) |
| Warm | Same sentence; `Read with calm, helpful delivery.` | 0.461 s | 6.080 s | 2.622 s | 0.431 (2.32× real time) |

The RF64 outputs were parsed by `afinfo` and ffprobe during the local run; they
are not retained in the repository. The runs differ in both warm state and
delivery instruction, so they are not a controlled cold-versus-warm comparison.
They do show that BF16 stayed ahead of playback for these short samples; they do
not justify an 8-bit fallback or a published latency promise. An ASR content
comparison was not performed. The local NeMo engine and multilingual model were
available, but the original real-ASR tests were not enabled for these samples,
so no transcription-accuracy conclusion is drawn from them.

## Fresh-process memory observation

One network-blocked, fresh-process CustomVoice BF16 run on the M5 Pro (64 GB)
loaded only the pinned CustomVoice model: no other TTS model was resident. For
“The rain cleared before dawn, and the streets became quiet.” it loaded in
0.979 s, emitted first audio 1.135 s after process start, and generated 3.840 s
of audio in 1.484 s after loading. MLX peak allocated memory was 5,104,408,277
bytes (4.75 GiB); maximum resident set size was 4,756,471,808 bytes (4.43 GiB);
and macOS peak memory footprint was 5,404,299,272 bytes (5.03 GiB). This is a
single process-level measurement with outbound network denied, not a general
memory reservation, a multi-model measurement, or a device-wide memory claim.

## Preliminary Designed Narrator observation

The first use of the VoiceDesign-to-Base route used the primary alternative,
**Designed Narrator** (`voice-design-consistent`), with `English`, seed `42`,
and this fixed description: “An articulate English female narrator in her
thirties, warm, thoughtful, and clear with a steady documentary delivery.” It
rendered: “This designed narrator should remain consistent across this reading.
The second sentence verifies that the saved reference remains available for the
next paragraph.” The first HTTP `started` event arrived in 0.012 s; the first
content-audio event arrived in 4.013 s, after the route had created its saved
reference. It produced 9.120 s of audio in 7.336 s (RTF 0.804, 1.24× real
time). This is one local first-use observation, not a perceptual
voice-consistency evaluation or a general latency promise.

## Observed offline check

After the pinned local snapshot was installed, a real CustomVoice generation
completed on the target Mac while `sandbox-exec` denied outbound network access
and the worker set `HF_HUB_OFFLINE=1` plus `TRANSFORMERS_OFFLINE=1`. The direct
local MLX load and Qwen generate call yielded 7,680 samples at 24 kHz. This
establishes that the tested local request did not require the network. It does
not replace the broader release networking audit for every lifecycle path.

## Observed integration checks

- `LOCAL_DICTATION_TEST_TTS_PLAYBACK=1 swift test` executed **58 tests: 52
  passed, 6 skipped, 0 failures**. The six skips are existing ASR and file-
  integration tests. All four tests that use actual native playback passed.
- `python3 -m unittest Tests/test_tts_worker.py` passed **18 tests**. It covers
  request validation, pinned snapshot markers, bounded staged text, RF64 atomic
  output, cancellation cleanup, and live acknowledgements.
- `git diff --check` and shell-syntax checks passed. The separate public-repo
  audit still has its existing reachable-history author/committer-email failure.
- The TTS preview build and off-screen layout checks passed. The user listened
  to local samples and selected Ryan plus Designed Narrator as the initial voice
  choices; this is a product decision, not an objective voice-quality ranking.
- Global-shortcut verification initially awaited a macOS Accessibility grant;
  the later native Chrome result is recorded below.

## Most recent validation update — 2026-09-12

- `swift test` executed **75 tests: 65 passed, 10 opt-in skips, and 0
  failures**. `python3 -m unittest Tests/test_tts_worker.py`
  passed **19 tests**.
- The recovery window now exposes the actual worker error, a visible **Retry
  Text to Speech** action, and Accessibility permission help. Its layout test
  verifies that a long startup error, setup text, Retry, and the permission
  control fit at the minimum window size.
- A blank `pronunciation_overrides` value was normalized before generation; it
  had previously reached the worker as an empty list and caused a `KeyError`.
- The worker startup path now retains bounded stderr for diagnosis and hardens
  registration around its ready signal. The cause of a previous roughly
  31-second startup timeout remains unproven.
- A native preview-app Ryan readback exercised the complete worker, streamed
  chunk, and queued playback path: **Ready → Reading → Canceling → Ready** in
  about one second after cancellation. This confirms lifecycle and playback
  plumbing, not acoustic quality; no independent listening evaluation was
  performed.
- In a controlled preview with the TTS runtime absent, the menu's **Retry Text
  to Speech…** action reopened the recovery window with the same error and a
  visible Retry control. The test preview was then terminated; it did not
  replace the normal preview.
- A native Chrome readback report was traced to the preview's missing raw
  Accessibility trust: the app recorded `raw_ax_trusted=false` and
  `tap_running=false` before safely blocking selected-text capture. The fix
  presents an explicit **Enable Read Shortcuts…** menu action, an in-window
  permission explanation, and the normal macOS permission request. The raw
  trust monitor now retries the preview shortcut listener without waiting for
  ASR to start.
- The preview's current display name is **Local Dictation Preview**, while an
  existing macOS privacy entry can still show the older **Local Dictation TTS
  Preview** label. The separate preview identity, not that visible label,
  determines its distinct privacy decision. A 750 ms retry for browser
  accessibility-tree activation is ancillary hardening; it was not established
  as the cause of the Chrome report.
- Two recovery-layout tests failed during the intermediate permission-hint edit
  because a constraint was activated before its view joined the stack. The
  ordering was corrected and the final full Swift suite passed.
- After Accessibility was granted to the isolated preview, an authorized native
  Chrome smoke test passed: OSLog recorded **TTS_READ_SHORTCUT matched**, then
  raw Accessibility trust and the event tap both true, the Chrome frontmost
  app, and successful capture of 52 characters. The UI progressed through
  preparing and reading; an HID-posted Escape returned it to Ready. The clean
  local fixture left the clipboard unchanged. This verifies Control–Option–R
  and Escape for that fixture, not acoustic model quality.

## Native voice-settings workflow — 2026-09-12

- The final Swift run executed **81 tests: 75 passed, 6 existing ASR and
  integration skips, and 0 failures**.
- A fresh preview launch reloaded a saved custom-voice fixture. In the focused
  native editor, Command-A selected all 52 characters; replacement typing and
  **Save & Use Voice** succeeded without Enter or a focus change. The saved
  active configuration exactly matched the fixture.
- Choosing Ryan and then Custom voice restored their separate saved drafts. A
  57-character Audio-page draft stayed present through a Voice-to-Audio tab
  round trip. Native typing later enabled both **Listen** and **Save Audio…**.
- **Save Audio…** opened the app's native `Save Generated Speech` panel. The
  automated check could not complete its nested folder chooser, so it did not
  create an export or observe the later Saved status. Manual file-export and
  status-duration checks remain open.
- The fixture preview was stopped. Its profile blob was removed and the
  previously saved private settings were restored from a local, mode-0600
  backup. Only the fixture's generated saved-reference directory was removed;
  the Designed Narrator reference remained intact.
- Rendered fixture captures are ignored build artifacts:
  `ui-review-final-voice-min.png`, `ui-review-final-voice-expanded-min.png`,
  and `ui-review-final-audio-min.png` under `build/tts-validation/`. The
  initial capture found a clipped current-voice label; the subsequent capture
  showed the full label and accented Save button.
- A label-only follow-up build visibly showed **Settings** in both its collapsed
  and expanded forms. Its harmless unsaved fixture capture is retained as
  `ui-review-final-settings-collapsed.png` and
  `ui-review-final-settings-expanded.png`. Reselecting the active Ryan preset
  reloaded the saved profile without saving the fixture; the restored defaults
  remained unchanged and the app was left on the collapsed Voice page.

## Selectable 8-bit worker and installer checks — 2026-09-12

- The pinned CustomVoice 8-bit snapshot
  `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit@41d3337e8b7f2843a75841595fc14e4b9a7a4b96`
  was installed as the only new multi-gigabyte 8-bit component. VoiceDesign
  and Base 8-bit were not downloaded because the development Mac had about
  5.5 GiB free after the CustomVoice download.
- On the target M5 Pro, with `mlx-audio==0.5.3`, MLX 0.32.2, and outbound
  network disabled, an authenticated Ryan stream emitted first audio in
  1.437 s. It generated 6.480 s of 24 kHz mono audio in 3.115 s (RTF 0.481),
  using 21 chunks; sampled worker maximum RSS was 3.09 GiB. `afinfo` decoded
  an emitted 16-bit WAV chunk. This is one fixed-sentence throughput observation,
  not a cold/warm benchmark, device latency measurement, or listening result.
- The local model-status route reported installed choices without loading a
  model. A CustomVoice 8-bit preload for Ryan reported the warmed model and
  CustomVoice component; unload then reported no warmed component. No 8-bit
  voice-quality equivalence with BF16 is claimed.
- The worker's app-managed parent watchdog was exercised with a nonexistent
  parent PID: after its ready message, it exited within one second and reported
  that its parent had exited. Standalone worker launches leave the watchdog
  disabled.
- Mocked downloader smoke checks confirmed that an app-owned interrupted
  staging directory is resumed and atomically marked complete, free space is
  calculated from only missing verified snapshots, and a second downloader is
  rejected while the first holds the app-owned lock. They downloaded no model
  weights.
- `python3 -m unittest Tests/test_tts_worker.py` passed **23 tests** after the
  model catalog, preload/unload, reference-compatibility, and parent-watchdog
  additions. Shell syntax checks and `git diff --check` are recorded after the
  final combined review.

## Unified feature lifecycle checks — 2026-09-12, 16:57–17:10 local time

- The full Swift run completed **88 tests: 88 passed, 0 skipped, and 0
  failures**. It included real local Nemotron Metal lifecycle, realtime JFK
  transcription, conversation-channel, and file-transcription coverage, plus
  `AVAudioEngine` playback. The log is an ignored local artifact at
  `build/tts-validation/unified-full-real-tests.log`.
- A later UI-only containment run passed **5 tests**. It found and corrected a
  sidebar selection issue, then checked the minimum window and nested Read
  Aloud content height. This is layout containment evidence, not a full visual
  review of every screen.
- With Speech to Text and Text to Speech both disabled at startup, neither
  engine process started. Enabling both and changing Text to Speech to 8-bit
  also started no engine. Explicit **Load** started both: the ASR worker used
  about 1 GiB RSS and the CustomVoice 8-bit worker about 3.1 GiB RSS. Both
  later reported unloaded status.
- Turning both startup-load settings on kept those same loaded processes. After
  quit and relaunch, both restored warm and Text to Speech restored the 8-bit
  selection. Turning startup-load back off did not stop the already-loaded
  processes; the next relaunch started neither. An on-demand 8-bit **Preview
  Voice** completed at Ready while loading only Text to Speech. Quitting the
  Text-to-Speech-only run terminated its worker.
- With 8-bit selected and CustomVoice already warm, the optional Designed
  Narrator Base download was canceled 0.73 s after it began. The installer and
  its children exited, the button returned to **Download**, and the warm
  CustomVoice worker kept the same PID. No Base completion marker or final
  model directory appeared. The canceled transfer left 1,759,241 bytes in its
  app-owned `.qwen3-tts-1.7b-base-8bit.download` staging directory, unchanged
  for more than a minute and resumable by the downloader. This verifies that
  cancel stops the download without unloading the active voice; it does not
  claim immediate partial-staging cleanup.
- Native Models & Startup controls fit at their tested default and minimum
  window sizes. Final native captures of the Read Aloud Voice and Audio pages
  passed review. A Text-to-Speech-only startup run launched only the CustomVoice
  8-bit worker.
- In the reciprocal startup check, Speech to Text alone was enabled and set to
  load at startup: it launched only the ASR worker. Text to Speech was disabled
  and did not launch Python. Quitting removed both managed workers in the
  combined check.
- Final native captures show the Dictation page, the Read Aloud Voice page with
  **Save & Use Voice** and Settings visible, the Audio editor and its buttons,
  and all principal Models & Startup controls at the 820 × 640 minimum window
  size. They are ignored local artifacts:
  `build/tts-validation/unified-dictation-final.png`,
  `unified-readaloud-final.png`, `unified-audio-final.png`, and
  `unified-models-minimum.png`.
- The original private preferences were compared with a mode-0600 backup and
  restored unchanged after fixture checks. Only the added local-feature fixture
  value was removed. The canceled Base 8-bit staging fixture was removed under
  the downloader's exclusive catalog lock; no Base 8-bit snapshot was
  downloaded.
- A later full Swift rerun at 17:36:50 local time completed in 39.24 seconds:
  **92 tests executed, 92 passed, 0 skipped, and 0 failures**. Its ignored local
  log is `build/tts-validation/unified-privacy-final-tests.log`. The matching
  Python rerun passed **23 tests** in
  `build/tts-validation/unified-privacy-python-tests.log`. Shell syntax and
  `git diff --check` also passed.
- A native bare preview relaunch was also checked after quitting the prior
  preview and confirming it had terminated. Opening
  `build/Local Dictation TTS Preview.app` without launcher environment variables
  retained both enabled feature choices and both saved startup-load choices as
  off. **Models & Startup** found the ASR configuration and the downloaded BF16
  preset model; neither worker started before an explicit load. This verifies
  the stable preview identity and saved runtime/model-path fallback for that
  configuration. It does not verify persistence of a macOS privacy grant.
- A second bare preview relaunch checked the selectable 8-bit path. The native
  popup selection and persisted defaults both showed 8-bit; Speech to Text
  startup loading was off and Text to Speech startup loading was on. After quit,
  a bare launch retained that choice: Models & Startup showed 8-bit selected,
  Speech to Text as **Load now** with startup off, and Text to Speech as
  **Unload** with startup on. Exactly one Python child, the Text-to-Speech
  worker, was running at about 3.08 GiB RSS. An earlier failed picker attempt
  was traced to the test helper matching a menu item outside the popup; the
  corrected helper scopes the popup and checks the resulting defaults. It does
  not establish an app model-picker defect.
- In the same native run, the visible menu placed the Speech to Text heading and
  its actions first, followed by Text to Speech and its actions, then **Models &
  Startup…** and **Settings…**. With Speech to Text unloaded, its actions were
  disabled. **Read Selected Text** was disabled because Accessibility was off,
  while **Read Clipboard** remained enabled. This is a menu-state observation,
  not a selected-text shortcut test.
- The final signed bare preview launch opened that same menu ordering. From
  **Models & Startup**, **Review Dictation Permissions…** opened the Dictation
  page, where Microphone showed **Open Settings** and Accessibility showed
  **Allow**. Model controls were absent from that permission page, as intended.
  After the check, only the test local-feature setting was removed; the six
  saved user preference values were byte-for-byte unchanged and the durable
  preview runtime/model path values were retained. The preview was left on
  Dictation with Speech to Text enabled and set to load at startup, and Text to
  Speech enabled with BF16 selected but not set to load at startup. The
  production app was not changed. Deep strict code-sign verification and
  `git diff --check` passed.
- These checks did not download or compare VoiceDesign/Base 8-bit models, and
  they do not compare 8-bit and BF16 perceptually. A full clean-machine GUI
  runtime-install test and process-unit seam tests remain open.

## Native permission and preview observations — 2026-09-12

- On macOS 26.5.2, native app actions opened the actual **Microphone**,
  **Accessibility**, and **Screen & System Audio Recording** panes. The
  `Privacy_AudioCapture` URL alias also reached the audio-recording pane. This
  checks navigation, not permission approval: the app still reads macOS's
  permission APIs after returning from System Settings.
- In one read-only System Settings inspection, the installed Local Dictation
  app had Microphone enabled while the development preview's Microphone and
  Accessibility entries were off; the preview also reported Accessibility off.
  No consent was toggled or reset, and the cause of that state was not
  established. It is not evidence that an Accessibility approval persists over
  a relaunch.
- The development preview is a separate app identity. Its current display name
  is **Local Dictation Preview**, but an existing System Settings row can retain
  the older **Local Dictation TTS Preview** label. A bare preview launch retained
  its saved runtime/model paths; this preview-only result does not prove
  migration into an installed app.

## Installed-data migration preparation — 2026-09-12

- With neither app running, migration preparation created a fresh canonical
  `TTSRuntime` and passed its package check with Python 3.13.7,
  `mlx-audio==0.5.3`, and MLX 0.32.2. It APFS-cloned CustomVoice BF16 and 8-bit,
  VoiceDesign BF16, and Base BF16 into canonical `TTSModels`, then compared the
  complete source and destination path-and-size inventories.
- Saved voice references were copied without overwriting a destination. The
  seven existing production preference values remained unchanged; five preview
  Read Aloud values were promoted and verified. The previous app and preferences
  were backed up under
  `~/Library/Application Support/LocalDictation/Backups` before this preparation.
- The installed `/Applications/Local Dictation.app` 0.4.0 build 19 then passed
  deep strict code-sign verification and native use. Existing Microphone and
  Accessibility approval remained green without toggling or resetting consent;
  the speech engine became ready; and Ryan preview readback progressed from
  Preparing through Reading to Ready using the canonical runtime. Normal quit
  removed both managed workers. A bare reopen restored Speech to Text enabled
  and loaded at startup, Text to Speech enabled with startup loading off, BF16
  preset availability, Ryan as the active voice, and enabled selected-text and
  clipboard readback. The production settings and all five promoted Read Aloud
values still matched after the check.

## Model catalog and switching — 0.4.1 build 20

- The final local Swift run completed **105 tests: 105 passed, 0 skipped, and
  0 failures** in 40.129 seconds. The Python worker run completed **23 passed**.
  Evidence: `build/tts-validation/model-switch-realtime-tests.log` and
  `build/tts-validation/model-catalog-python-tests.log`. The release build is
  recorded in `build/tts-validation/model-switch-realtime-build.log`.
- The isolated catalog checks cover a fresh install, installed-only pickers,
  stale BF16 selection with only 8-bit weights present, missing-runtime setup
  guidance, and accessible catalog and component information controls.
- Native preview switching reached Ready with English worker 2197, then
  Multilingual 2281, then English 2355; each replacement removed the previous
  worker. BF16 switched to 8-bit worker 2387. Before the ASR callback fix,
  8-bit 97199 switched back to BF16 97831 and reached Ready with the old worker
  gone. The catalog information popovers were checked with full paragraphs and
  padding; captures are `model-info-bf16.png` and
  `model-info-voice-replay.png` in `build/tts-validation/`.
- The installed `/Applications/Local Dictation.app` 0.4.1 build 20 was
  atomically replaced and passed code-sign verification. All 13 pre-existing
  preferences were unchanged. English reached Ready in worker 2704; Text to
  Speech retained the 8-bit choice with startup loading off, Speech to Text
  retained startup loading on, and Ryan remained selected. Microphone and
  Accessibility were green in `model-catalog-installed-permissions.png`.
  Earlier production and preview workers were confirmed gone. The rollback
  backup is under `Application Support/LocalDictation/Backups/before-model-catalog-20260912-184706`.
- These are local native checks. The full download over the network was not
  repeated in this final pass.

## Required local runtime checks

- [ ] On a clean Apple Silicon Mac, run `bash scripts/setup-tts-runtime.sh` and
  record the Python, `mlx-audio`, and MLX versions installed.
- [ ] Download each chosen pinned snapshot with
  `bash scripts/download-tts-models.sh --model custom` (and `design` plus
  `base` when exercising persistent personas). Verify the model directory has
  the root tokenizer resources, `speech_tokenizer/`, `config.json`, and all
  expected safetensors before use.
- [x] With `HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1`, a host-network-
  blocked CustomVoice request completed after the local snapshot was installed.
- [ ] Repeat the network-blocked check after future model/runtime upgrades and
  inspect all process connections through model load, generation, cancellation,
  and shutdown.
- [ ] Confirm the default reader uses the BF16 1.7B CustomVoice revision
  `52f4770fd9726457eae3d3b6aa92047a25a10776`, not the smaller 0.6B fallback.
- [ ] Confirm Qwen's exact preset inputs work, including `Uncle_Fu` and
  `Ono_Anna`, while the UI may show readable display names.

## Readback acceptance

- [x] An isolated Chrome fixture: Control–Option–R captured selected text,
  entered readback, and left the clipboard unchanged. Escape returned the app
  to Ready. This does not replace broader application coverage.
- [ ] Press Escape while audio is playing and while the model is generating.
  Record observed stop latency and verify playback ends with no later chunk.
- [ ] Control–Option–P pauses and resumes without a duplicated or skipped
  chunk. While readback is active, Control–Option–R must not start a concurrent
  second job.
- [ ] Read Clipboard works when an app does not expose selected text; secure
  fields and empty selections produce the intended local error.
- [ ] Test short, punctuation-heavy, URL, acronym, name, and technical-word
  examples. Verify an editable pronunciation replacement applies only to that
  request and the source document stays unchanged.
- [ ] Measure cold/warm first-audio latency, real-time factor, peak memory,
  and audio underruns on the target M5 Pro (64 GB). Keep the exact text,
  model revision, precision, settings, and macOS version with every result.

## File-generation acceptance

- [ ] Generate a multi-paragraph English file with a preset plus delivery
  instruction. Check word preservation, sentence joins, chosen output path,
  and RF64 metadata with `afinfo` and `AVAudioFile`.
- [ ] Cancel a long render. Verify that no final output replaces an existing
  user file and that the partial file is removed.
- [ ] Generate a persistent persona: VoiceDesign makes one reference, Base uses
  the same reference and transcript for every subsequent chunk, and the result
  is audibly checked for identity drift at the joins.
- [ ] Verify temporary readback chunks are removed on success, cancel, worker
  failure, app quit, and next launch. This is a privacy-release gate.
- [ ] Confirm that a persistent VoiceDesign persona saves its reference and
  limited metadata only under `Application Support/LocalDictation/SavedVoices`,
  that **Open Saved Voices Folder** reaches it, and that removing its folder
  prevents further use of that persona. Confirm **Remove Local Data** removes
  Application Support data but does not remove user-exported audio files.

## Release gates

- [x] The latest full Swift run completed with 105 executed, 105 passed, 0
  skipped, and 0 failures; the model catalog and switching evidence is recorded
  above.
- [ ] `bash scripts/audit-public-repo.sh` passes, or its historical-email
  exception has a reviewed release decision.
- [ ] A real offline Qwen run, all model pins, license notices, and the privacy
  behavior above have been reviewed.
- [ ] The app labels file output as RF64 rather than classic WAV and does not
  advertise unmeasured latency or a universal quality ranking.
