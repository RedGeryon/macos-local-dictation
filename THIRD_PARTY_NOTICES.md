# Third-party notices

## NVIDIA NeMo-Speech.cpp runtime

- Source: https://github.com/NVIDIA/NeMo-Speech.cpp
- Upstream license: https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/LICENSE
- Upstream notice: https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/NOTICE
- Upstream third-party notices:
  https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/THIRD_PARTY_NOTICES.md

The DMG bundles a locally built Apple Silicon runtime. Packaging copies the
upstream license, notice, and third-party notices into the app's Resources
directory. These files remain governed by their respective terms.

The current macOS runtime build also dynamically links these Apache-2.0
components, which packaging relocates into the application bundle:

- Google SentencePiece — https://github.com/google/sentencepiece
- Google Abseil C++ — https://github.com/abseil/abseil-cpp

Their copyrights and license terms remain with their respective authors. The
Apache License 2.0 text distributed with the runtime applies to these
Apache-2.0 components as well. Release engineering must record the exact
versions in the software bill of materials.

## NVIDIA Nemotron Speech Streaming English 0.6B

- Model card and download:
  https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b
- Governing terms identified by the model card:
  https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/

The model is downloaded separately by the user, is not present in this
repository or DMG, and is not covered by this application's MIT License.

## NVIDIA Nemotron 3.5 ASR Streaming Multilingual 0.6B

- Model card and download:
  https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b
- Governing terms identified by the model card:
  https://openmdw.ai/license/1-1/

The model is downloaded separately by the user, is not present in this
repository or DMG, and is not covered by this application's MIT License. Its
OpenMDW 1.1 terms are distinct from the English model's license.
