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

## Optional Qwen text-to-speech models

- Model family and source: https://github.com/QwenLM/Qwen3-TTS
- Initial model card: https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice
- Upstream code and model license: Apache License 2.0

The optional Qwen models are separately downloaded into the user's Application
Support directory. They are not in this repository or the DMG and are not
covered by this application's MIT License. The feature uses an MLX Community
conversion at a pinned revision; release engineering must recheck the model
card and preserve any conversion-specific notice before distributing or
mirroring that conversion.

## MLX Audio text-to-speech runtime

- Source: https://github.com/Blaizzy/mlx-audio
- License: MIT
- Pinned package: `mlx-audio==0.5.3`

The app bundles launcher and installer assets, not this runtime. When the user
chooses Read Aloud setup, the installer creates a separate local Python
environment under Application Support. Qwen snapshots are also downloaded
separately and are not in the app or DMG. A release that bundles this runtime or
any Python dependency must inventory the exact resolved package versions and
include every required third-party notice in its SBOM.
