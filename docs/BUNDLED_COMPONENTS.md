# Bundled component record

This record describes the locally produced 0.4.1 (build 20) development
installer. A
release pipeline must regenerate and verify it against the signed binaries.

| Component | Version / revision | License | Source |
|---|---|---|---|
| NeMo-Speech.cpp | 1.0.0 / `9bc876635af36df537d9bc6d3f57ad1b76e4f74a` | Apache-2.0 | https://github.com/NVIDIA/NeMo-Speech.cpp |
| ggml runtime libraries | 0.12.0, from the NeMo-Speech.cpp submodule build | MIT and upstream component terms | https://github.com/ggml-org/ggml |
| Google SentencePiece | 0.2.2 | Apache-2.0 | https://github.com/google/sentencepiece |
| Google Abseil C++ | 20260107.1 | Apache-2.0 | https://github.com/abseil/abseil-cpp |

Both supported NVIDIA Nemotron GGUF models are explicitly excluded from the app
bundle and this bundled-component table. Each is obtained separately under the
distinct terms identified by its model card: NVIDIA Open Model License for the
English model and OpenMDW 1.1 for the multilingual model.

The app also contains local Read Aloud launcher and installer assets: the Python
worker launcher, its pinned-requirements file, and scripts that set up and
download the optional runtime and models. They are not a bundled Python
environment, MLX package, or Qwen model snapshot. Those components are installed
only when the user chooses Read Aloud setup and are recorded in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

`scripts/generate-dmg.sh` pins the NeMo-Speech.cpp revision above by default so
locally generated installers do not silently change when upstream `main`
advances. Advanced builders can explicitly override it with
`LOCAL_DICTATION_NEMO_REVISION` and must update this component record for their
artifact.
