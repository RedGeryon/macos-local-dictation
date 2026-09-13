# Building and release guide

## Supported build host

The current application and packaging scripts support:

- Apple Silicon Mac
- macOS 14 or newer
- Xcode Command Line Tools
- Homebrew
- Internet access for the first runtime build

The app uses Swift Package Manager. No Xcode project or paid Apple developer
account is required for a local development build.

## Verify the source

From the repository root:

```bash
swift test
bash scripts/audit-public-repo.sh
```

The normal unit suite does not download a model. The opt-in real-engine tests
are described in [CURRENT_STATUS.md](CURRENT_STATUS.md) and can be run with:

```bash
bash scripts/test-real-engine.sh
```

After separately downloading the multilingual model, validate its explicit
Spanish prompt and final-audio commit with:

```bash
bash scripts/test-multilingual-model.sh
```

This creates and removes a temporary macOS Spanish speech fixture; neither the
fixture nor model weights belong in the repository.

## Generate a development DMG

Run:

```bash
bash scripts/generate-dmg.sh
```

On its first run, the generator:

1. Installs the required Homebrew build dependencies if missing.
2. Fetches the pinned NeMo-Speech.cpp revision recorded in
   [BUNDLED_COMPONENTS.md](BUNDLED_COMPONENTS.md).
3. Applies the repository's macOS portability patch.
4. Builds the Metal runtime.
5. Builds and ad-hoc signs `Local Dictation.app`.
6. Bundles the runtime and required third-party notices.
7. Creates `dist/Local-Dictation-0.4.1-macOS-arm64.dmg`.

The generated app and DMG are ignored by Git. NVIDIA model weights are never
placed in either artifact. Later runs reuse the runtime under
`~/Library/Application Support/LocalDictation`.

To use a compatible runtime from another location:

```bash
LOCAL_DICTATION_BUNDLE_ENGINE_DIR=/absolute/path/to/runtime \
  bash scripts/package-dmg.sh
```

## Verify the artifact

```bash
codesign --verify --deep --strict "build/Local Dictation.app"
hdiutil verify "dist/Local-Dictation-0.4.1-macOS-arm64.dmg"
```

Mount the DMG, drag the app to `/Applications`, confirm the model is still
requested separately, and exercise the permission, quick-dictation,
conversation, AirPods-route, file-transcription estimate/cancel/output, Stop,
and uninstall flows from the installed copy.

## Public release requirements

The repository can be public, but the generated development DMG is not a
production release. Before distributing a binary:

1. Run `scripts/audit-public-repo.sh` and review the complete Git diff.
2. Re-run unit tests, real-engine tests, artifact verification, and manual
   permission/audio-route tests.
3. Recheck the live licenses and model terms linked in
   [LEGAL_AND_LICENSING.md](LEGAL_AND_LICENSING.md).
4. Generate an SBOM for the exact bundled runtime and libraries.
5. Update [BUNDLED_COMPONENTS.md](BUNDLED_COMPONENTS.md) if any dependency or
   revision changes.
6. Set `LOCAL_DICTATION_SIGN_IDENTITY` to a valid Developer ID Application
   identity, sign every nested executable, and sign the application.
7. Notarize and staple the application and final DMG using Apple's current
   release process.
8. Repeat privacy and network inspection against the exact notarized artifact.
9. Publish checksums and the source commit corresponding to the artifact.

Never commit model weights, build outputs, DMGs, recordings, transcripts,
permission databases, credentials, certificates, provisioning profiles, or
user-specific paths.
