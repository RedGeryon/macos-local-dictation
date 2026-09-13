# Local text-to-speech model research

Research date: 2026-09-12. This is a design record, not a claim that the
models have been perceptually benchmarked on this Mac. The later 8-bit update
records one local load and throughput check separately from voice-quality
evaluation.

## Decision

Use **Qwen3-TTS-12Hz-1.7B-CustomVoice**, in its pinned **BF16** MLX
conversion, as the first downloadable local TTS model on the target M5 Pro
with 64 GB unified memory. It is the only 1.7B Qwen option that gives this app
both named preset voices and natural-language style instructions in one loaded
model. It is Apache-2.0 licensed.

Do not use **Qwen3-TTS-12Hz-1.7B-VoiceDesign** as the default reader. It makes
a voice from a text description, but has no named presets and is not the
reliable way to keep one invented voice consistent across a long recording.
Qwen's own recommended workflow for a persistent designed persona is:

1. create a short reference with VoiceDesign;
2. load a Qwen Base model and turn that reference plus its transcript into a
   reusable clone prompt; then
3. use that cached prompt for each sentence or chunk.

That workflow is the right implementation of the requested saved, prompted
voice: make one short persona reference with VoiceDesign, save its transcript,
then use the Base model and that reference for every long-form chunk. It
requires downloading and switching between two additional 1.7B models, so the
interface must make the distinction clear: **preset + delivery prompt** uses
CustomVoice; **new persistent persona** uses VoiceDesign then Base.

The product starts with `Ryan`. Its primary alternative is **Designed Narrator**:
a fixed English female VoiceDesign description with seed `42`, saved once as a
local reference WAV, then reused through Base for later passages. `Aiden`
remains an additional English-native preset. These defaults are product choices;
they do not establish a universal naturalness or female-voice-quality ranking.

This is an evidence-backed best-for-purpose recommendation, not a universal
"best model" verdict. Qwen has the most complete Apache-2.0 feature set near
this size for the requested English, preset-voice, prompted-voice, and offline
Apple Silicon product. There is no independent, like-for-like quality and
M-series latency benchmark that proves it is objectively best at 1.7B.

## What the Qwen variants actually do

| Variant | Presets | Free-form instruction | Voice cloning | Best use here |
| --- | --- | --- | --- | --- |
| 0.6B CustomVoice | 9 | No (per Qwen's released-model table) | No | Smaller preset-only fallback |
| 1.7B CustomVoice | 9 | Yes: tone, emotion, prosody on a selected preset | No | **Initial live reader and file generator** |
| 1.7B VoiceDesign | No | Yes: creates a voice from a description | No | One-time creation of a fictional persona reference |
| 0.6B / 1.7B Base | No | No | Yes, from reference audio and transcript | Reusable persona after VoiceDesign, or a user-owned voice |

The 9 CustomVoice presets are Vivian, Serena, Uncle_Fu, Dylan, Eric, Ryan,
Aiden, Ono_Anna, and Sohee. Ryan and Aiden are the English-native choices.
For the English product, use `Ryan` as the default; make Designed Narrator the
main alternative through the persistent workflow above; keep `Aiden` as an
additional preset choice; and pass an explicit `English` language hint rather
than automatic detection.

Qwen documents all released variants as streaming and supports Chinese,
English, Japanese, Korean, German, French, Russian, Portuguese, Spanish, and
Italian. Its upstream claim of 97 ms end-to-end streaming latency was made in
its own release material; it is not a measurement on Apple Silicon and must
not be presented to users as one.

The useful English evidence in Qwen's own evaluation is narrower than a
naturalness ranking but does support the model split: on its target-speaker
English test, 12Hz 1.7B CustomVoice had 0.899 WER versus 1.188 for 12Hz 0.6B
CustomVoice. On its English instruction-control test, 12Hz 1.7B CustomVoice
scored 77.3 attribute-perception, 77.1 description-speech consistency, and
63.7 response precision. VoiceDesign scored 82.9, 82.4, and 68.4 respectively,
which is why it is the better tool for creating a new voice description. These
are Qwen's measurements, are not a listener naturalness/prosody MOS, and do
not establish Apple Silicon speed.

## Model comparison relevant to this app

| Model | Evidence that favors it | Why it is not the first engine |
| --- | --- | --- |
| **Qwen 1.7B CustomVoice** | Apache-2.0; English presets plus instructions; streaming; MLX conversions and a Swift/MLX implementation exist. | No published M5 result yet. It is materially larger than the fastest alternatives. |
| Qwen 1.7B VoiceDesign | Apache-2.0; rich text-described voice creation; streaming. | No presets. A description alone does not create a durable long-form identity; Qwen recommends the VoiceDesign-to-Base workflow above. |
| Qwen 0.6B CustomVoice | Apache-2.0; presets; all ten Qwen languages; less memory. | Qwen does not list instruction control for 0.6B, so it misses the requested prompted-voice control. |
| [Soprano 1.1-80M](https://huggingface.co/ekwek/Soprano-1.1-80M) | Apache-2.0; English-only; official MPS support and claims of under 250 ms CPU first audio, 32 kHz output, and automatic long-text splitting. | No presets, cloning, or voice prompt. Its authors warn it has only 1,000 training hours and may mispronounce uncommon words. Its speed/naturalness claims are vendor claims, not an M5 comparison. It is the fastest credible English reader benchmark candidate. |
| [Pocket TTS](https://github.com/kyutai-labs/pocket-tts) | MIT code and CC-BY-4.0 main weights; 100M; official claim of about 200 ms first audio and 6x real-time on an M4 MacBook Air CPU; streaming, long text, preset voices and cloning. | It has no free-form voice-design/style prompt. Individual preset-voice licences must also be tracked. It is a strong fast-reader fallback if Qwen fails the live target. |
| [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) | Apache-2.0; about 363 MB upstream; fixed English voices; MLX support. | No voice cloning or free-form voice design/instruction. It is useful only if a small fixed-voice reader is more important than the requested prompt control. |
| [Chatterbox Turbo](https://github.com/resemble-ai/chatterbox) | MIT; 350M English model, explicitly designed for low-latency voice agents, paralinguistic tags, and MPS is documented. | It requires a reference clip to select a target voice; it has no named preset + natural-language instruction catalog. It would add a PyTorch/MPS runtime. |
| [TADA-1B](https://huggingface.co/HumeAI/tada-1b) | English-only 1B model; its authors report token-level text/audio alignment for natural flow and reduced transcript hallucination. | We found no official MPS/MLX live path or Mac latency result; it requires a speech prompt and its weights use the Llama 3.2 Community License, not Apache-2.0. |
| [NVIDIA MagpieTTS 357M](https://huggingface.co/nvidia/magpie_tts_multilingual_357m) | Five fixed English voices, built-in normalization, custom IPA dictionaries, emotion variants, official long-form mode, and a reported 0.37% English CER. | NVIDIA Open Model License rather than Apache-2.0, no voice cloning by design, no natural-language voice-description prompt, and a different NeMo runtime. Its CER is NVIDIA's own held-out measurement and is not comparable to Qwen's WER. |
| [F5-TTS](https://github.com/SWivid/F5-TTS) | Strong research baseline with cloning and chunk inference. | Code is MIT but the published pretrained weights are CC-BY-NC, so it is unsuitable for a general-purpose distributable app. |
| [Spark-TTS-0.5B](https://github.com/SparkAudio/Spark-TTS) | Small, controllable gender/pitch/rate and cloning. | Official weights are CC-BY-NC-SA despite Apache-2.0 inference code; English/Chinese only, not Spanish. |

## Pinned MLX route for the feature branch

The model is separately downloaded to Application Support, as the existing ASR
model is. It is never bundled in the DMG. These are the reviewed, public,
ungated MLX Community conversion revisions observed on the research date:

| Purpose | Identifier and immutable revision |
| --- | --- |
| Initial quality-reference model | `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16@52f4770fd9726457eae3d3b6aa92047a25a10776` |
| Candidate smaller precision | `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit@41d3337e8b7f2843a75841595fc14e4b9a7a4b96` |
| Smaller preset-only evaluation model | `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit@049ef77fe8816b536193c0c25f9a214d17921282` |
| Advanced voice design | `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16@7d3824abff87e49756bb0f83fb5411de75d160c4` |
| Advanced persistent persona / clone | `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16@a6eb4f68e4b056f1215157bb696209bc82a6db48` |

### Selectable 8-bit update

The app can also select `qwen-1.7b-8bit`. This is the same 1.7B Qwen task
family with MLX Community's affine 8-bit conversion (`bits: 8`, `group_size:
64`), not a smaller model. It keeps the same preset and instruction product
surface, but it is a separate set of weights. The review pins are:

| Component | Immutable MLX Community snapshot | Hub-reported download size |
| --- | --- | ---: |
| CustomVoice 8-bit | `Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit@41d3337e8b7f2843a75841595fc14e4b9a7a4b96` | 3.08 GB |
| VoiceDesign 8-bit | `Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit@f90d617701d9f7f4ca499291e0b57f2b3c2fd2ee` | 3.08 GB |
| Base 8-bit | `Qwen3-TTS-12Hz-1.7B-Base-8bit@e7dd0585652209fa0d7783659aad4e8a324de11c` | 3.10 GB |

CustomVoice alone is enough for Ryan, Aiden, and the other preset voices.
Creating a new designed voice needs VoiceDesign plus Base; replaying an
already-saved designed reference needs Base and the saved WAV plus transcript.
The downloader therefore offers each component separately and an `8bit` group
only when there is enough room for all three plus staging space.

The Qwen Base interface takes a reference audio file and its text transcript.
Neither Qwen nor MLX Audio says that those two conditioning inputs are tied to
the precision of the model that made the WAV. Existing saved references are
therefore preserved and looked up before making another; changing Base
precision does not silently replace the reviewed Designed Narrator reference.
This is compatibility of the audio-conditioning inputs, not proof that BF16
and 8-bit sound identical.

On this M5 Pro development Mac, `mlx-audio==0.5.3` with MLX 0.32.2 loaded the
pinned CustomVoice 8-bit snapshot with offline environment variables and
completed one authenticated Ryan worker stream. It emitted first audio in
1.437 s, generated 6.480 s of 24 kHz mono audio in 3.115 s (RTF 0.481), and a
sampled worker RSS peak was 3.09 GiB. `afinfo` decoded an emitted Int16 WAV
chunk. This is one load/throughput observation with a fixed sentence, not a
cold/warm benchmark, device latency measurement, or listening test.

There is no official blind-listening evidence that this 8-bit conversion
matches the BF16 conversion for English naturalness, prosody, pronunciation,
or voice identity. Present it as a smaller-download option and keep BF16 as
the quality-reference choice until a controlled listening evaluation says
otherwise.

The BF16 download is 4,520,195,613 bytes. The 8-bit, 6-bit, and 4-bit
conversions are respectively 3,080,141,538, 2,696,100,432, and 2,312,059,416
bytes. Use BF16 first because it is the highest-fidelity published MLX
conversion and the target Mac has sufficient memory. There is no official
blind-listening or Apple Silicon speed comparison proving that 8-bit, 6-bit,
or 4-bit preserves English naturalness, prosody, or pronunciation. Do not
claim that it does. If BF16 misses the live target, measure 8-bit first against
the same fixed English corpus, then consider 6-bit; retain the quality sample
and result with the benchmark.

Pin `mlx-audio==0.5.3` when the worker is packaged. The published universal
wheel hash is
`sha256:8d920b2dcbcf37b5fd2bbb070e21a9a33442bf231a754e0d39387e65986bd830`.
MLX Audio is MIT, requires Apple Silicon and Python 3.10+, and its current
documentation identifies it as an Apple-Silicon runtime. Packaging must still
record all transitive runtime notices.

The MLX runtime supports one generic, model-kind-routing API:

```python
model = load_model(model_id)
for result in model.generate(
    text,
    voice="Ryan",              # CustomVoice only
    instruct="Calm, clear, and warm.",
    lang_code="English",
    temperature=0.9,
    top_k=50,
    top_p=1.0,
    repetition_penalty=1.05,
    max_tokens=4096,
    stream=True,
    streaming_interval=0.32,
):
    play_or_write(result.audio, result.sample_rate)
```

At 12.5 generated tokens per second, `0.32` seconds is about four tokens per
audio chunk. It is the starting live setting, not a guarantee: measure first
audio, underruns, and real-time factor on the target Mac. The model output is
24 kHz mono today; the app should carry each result's `sample_rate` instead of
relying on that constant. In MLX Audio 0.5.3, `speed` is documented as not
directly supported. Do not show a speed slider that is silently ignored.

The specific APIs are `generate_custom_voice(text, speaker, language, instruct,
...)` and `generate_voice_design(text, instruct, language, ...)`. The generic
API uses `lang_code`, while the specific APIs use `language`. The Base model
uses `generate(text, ref_audio, ref_text, ...)`; its MLX path caches the
reference codes only during the loaded model's lifetime. Persistent saved
personas therefore need an explicit reference audio file and transcript, not
an assumption that a process cache will survive a restart.

Do not use MLX Audio's continuous/batch TTS session for the live path until it
passes a real regression test. An open 0.4.3 report found that Qwen's batch
session failed to emit incremental chunks or a final event. Use a single warm
model and one generator/job at a time. The 0.5.3 release is newer, but it has
not yet been qualified by this repository.

## Live reading interaction

The app should obtain selected text using the same accessibility-first,
clipboard-preserving approach it already uses for insertion. If no selectable
text is available, it should explain that nothing can be read rather than read
an unknown accessibility tree.

Suggested controls:

| Control | Behavior |
| --- | --- |
| Configurable `Control–Option–R` | Read the current selection when idle. It is disabled while a TTS job is active, which prevents a second job from replacing the current read. Keep it configurable because global shortcuts can collide. |
| `Escape` while reading | Immediately stop playback, discard queued but unplayed chunks, and mark the worker job cancelled. |
| Menu item: Read Selection | Discoverable alternative when a global shortcut is unavailable. |
| Pause/resume in the small playback panel | Pause output without throwing away the selected text or restarting generation. |
| Planned follow-up: previous/next sentence | Re-generate or play sentence-sized units; useful for proofing and for a bad pronunciation. This is not part of the initial shortcut scope. |

macOS already reserves `Option–Escape` for its configurable **Speak
Selection** shortcut and uses the same shortcut to stop speech. It also offers
word/sentence highlighting, an on-screen controller, pause/resume, and
sentence navigation. Do not silently take that shortcut. The product can use
its pattern while keeping a distinct configurable default and `Escape` as the
unambiguous cancel key.

For live playback, split selected text at sentence boundaries before sending
it, stream the current sentence, and pre-generate at most the next one. This
limits wasted work after cancel and gives the user a clean sentence to replay.
Do not mutate the selected document or insert any text while reading.

## Long audio files and correction

For a long file, split normal prose into sentence-sized units, retain a stable
voice/instruction/language configuration for every unit, append 24 kHz PCM in
order, and atomically publish the final **RF64** file only on success. RF64 is
the 64-bit extended WAV container, so it avoids classic WAV's 4 GiB limit while
keeping uncompressed PCM and no extra codec dependency. The current worker
uses RF64 even for a small file; label and extend it as RF64 rather than
presenting it as a classic WAV. M4A/MP3 can be a later export option.
Queue one job at a time, display completed time and estimated remaining time,
and let Cancel retain neither a partial final file nor a partially published
asset unless the user explicitly chooses to save a draft.

There are two different correction loops that should remain separate:

1. **Words and pronunciation.** Let the user edit the exact spoken text before
   generation, then offer a per-language pronunciation dictionary that expands
   acronyms, numbers, URLs, names, and technical terms into ordinary readable
   text. Re-render only the affected sentence. Qwen's released API does not
   document SSML or a phoneme/IPA override, so do not promise either.
2. **Voice and delivery.** Let the user revise the selected preset or the
   natural-language instruction and preview one sentence. For an advanced
   designed persona, retain its reference WAV and transcript, then regenerate
   affected chunks with the Base model. Do not claim that a VoiceDesign prompt
   alone locks voice identity across chunks.

The initial interface should expose only safe, understandable settings:
language, preset voice, optional style instruction, and a preview. Keep
temperature, top-k, top-p, repetition penalty, token ceilings, and chunk
interval hidden behind a diagnostic configuration until the real-engine tests
establish useful ranges. The fixed defaults above are MLX Audio's current
defaults, not Qwen quality guidance.

## Evidence and limits

- [Qwen's official repository](https://github.com/QwenLM/Qwen3-TTS) documents
  the released-model matrix, ten languages, speaker roster, clone workflow,
  package API, and a claimed 97 ms streaming result.
- [The official VoiceDesign model card](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign)
  lists Apache-2.0 and identifies the checkpoint as 1.7B / BF16.
- [MLX Audio's Qwen guide](https://github.com/Blaizzy/mlx-audio/blob/main/docs/models/tts/qwen3-tts.md),
  [streaming guide](https://github.com/Blaizzy/mlx-audio/blob/main/docs/guides/streaming.md),
  and its [0.5.3 source](https://github.com/Blaizzy/mlx-audio/tree/v0.5.3)
  document the Apple-Silicon path, conversions, method names, result fields,
  and streaming controls. MLX Audio is a third-party implementation, so a
  model update or runtime upgrade needs a local regression test before release.
- [Qwen's own long-speech comparison](https://github.com/QwenLM/Qwen3-TTS#evaluation)
  reports 12Hz 1.7B CustomVoice content WER of 2.356 (Chinese) and 2.812
  (English); it does not establish VoiceDesign long-form identity consistency
  or Mac speed. WER measures whether the words are preserved; it does not
  measure voice naturalness, prosody, or identity.
- [Soprano's official model card](https://huggingface.co/ekwek/Soprano-1.1-80M)
  establishes its Apache-2.0 licence, English-only limitation, MPS support,
  claimed speed, and the author's warning about uncommon-word pronunciation.
- [MagpieTTS's official model card](https://huggingface.co/nvidia/magpie_tts_multilingual_357m)
  documents its five English voices, custom IPA dictionaries, long-form path,
  NVIDIA Open Model License, and its own English CER measurement.
- [TADA's official repository](https://github.com/HumeAI/tada) documents its
  1B English checkpoint, required prompt, CUDA example, and Llama 3.2 model
  licence.
- [Apple's Speak Selection guide](https://support.apple.com/guide/mac-help/have-your-mac-speak-text-thats-on-the-screen-mh27448/mac)
  is the basis for the shortcut-conflict and control recommendations.

Before release, measure cold/warm first audio, real-time factor, peak memory,
cancel latency, sentence joins, English pronunciation, long-file
completion, and model re-load behavior on the M5 Pro. If warm Qwen 1.7B cannot
keep ahead of playback, evaluate Pocket TTS as the fast fixed-voice engine
before committing to two customer-facing engines.
