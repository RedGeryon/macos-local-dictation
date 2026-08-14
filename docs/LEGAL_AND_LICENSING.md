# Legal and licensing notes

This is engineering guidance, not legal advice.

## Original application code

Original source in this repository is offered under the MIT License. “Local
Dictation” is a descriptive working name, not a claim of trademark clearance.

## Bundled NeMo-Speech.cpp runtime

The DMG's application bundle contains a locally built copy of
[NVIDIA/NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp). NVIDIA
publishes that runtime under Apache License 2.0 and supplies additional
third-party notices. Packaging copies the upstream `LICENSE`, `NOTICE`, and
`THIRD_PARTY_NOTICES.md` into `Local Dictation.app/Contents/Resources/Licenses`.
The current macOS build also bundles its dynamically linked Apache-2.0
SentencePiece and Abseil C++ libraries; they are identified in the third-party
notices and must appear in the release SBOM.

This is factual compatibility identification; the app is not affiliated with
or endorsed by NVIDIA. Release automation must fail if these notices cannot be
found, and a public build should generate an SBOM for the exact runtime binary.
The current development package has a checked-in
[bundled component record](BUNDLED_COMPONENTS.md).

## Separately downloaded NVIDIA model

The application supports the
[Nemotron Speech Streaming English 0.6B model](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b),
specifically `nemotron-speech-streaming-en-0.6b.q8_0.gguf`. Its model card names
the [NVIDIA Open Model License Agreement](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/)
as the governing terms.

Model weights are not part of the MIT application, are not placed in the DMG,
and must not be described as MIT licensed. Users obtain the model from NVIDIA's
Hugging Face repository after reviewing the current terms. The repository's
download helper requires an explicit license-acceptance flag.

The current model card describes the model as ready for commercial and
non-commercial use, but that statement and the live terms must be rechecked at
release time.

## Marks and release review

NVIDIA, NeMo, and Nemotron are used only to identify the separately licensed
technology. Do not use NVIDIA branding as the application's identity.

Before public distribution:

1. Recheck every live license and required notice.
2. Audit the runtime binary and generate an SBOM.
3. Complete final name/icon trademark clearance.
4. Obtain appropriate review for privacy, patent, export-control, and model-use
   questions.
5. Developer ID sign and notarize the final app and DMG.
