#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$repo_dir/build/Local Dictation.app"
contents_dir="$app_dir/Contents"
support_dir="${LOCAL_DICTATION_SUPPORT_DIR:-$HOME/Library/Application Support/LocalDictation}"
engine_dir="${LOCAL_DICTATION_BUNDLE_ENGINE_DIR:-$support_dir/Engine}"
nemo_source_dir="${LOCAL_DICTATION_NEMO_SOURCE_DIR:-$support_dir/Source/NeMo-Speech.cpp}"
tts_source_dir="$repo_dir/python"
tts_assets_dir="$contents_dir/Resources/TTSAssets"

bundle_host_dependencies() {
  runtime_root="$1"
  runtime_lib="$runtime_root/lib"
  roots_file="$(mktemp "${TMPDIR:-/tmp}/local-dictation-dependency-roots.XXXXXX")"

  while IFS= read -r -d '' binary; do
    if ! file "$binary" | grep -q 'Mach-O'; then
      continue
    fi
    codesign --remove-signature "$binary" >/dev/null 2>&1 || true
    while IFS= read -r dependency; do
      case "$dependency" in
        /opt/homebrew/*|/usr/local/*)
          cp -L "$dependency" "$runtime_lib/$(basename "$dependency")"
          dirname "$dependency" >> "$roots_file"
          ;;
      esac
    done < <(otool -l "$binary" | awk '/cmd LC_(LOAD|LOAD_WEAK|REEXPORT)_DYLIB/{getline; getline; print $2}')
  done < <(find "$runtime_root/bin" "$runtime_lib" -type f -print0)

  sort -u "$roots_file" -o "$roots_file"
  copied_missing=1
  while [ "$copied_missing" -eq 1 ]; do
    copied_missing=0
    while IFS= read -r -d '' binary; do
      if ! file "$binary" | grep -q 'Mach-O'; then
        continue
      fi
      while IFS= read -r dependency; do
        case "$dependency" in
          @rpath/*)
            dependency_name="$(basename "$dependency")"
            if [ -e "$runtime_lib/$dependency_name" ]; then
              continue
            fi
            while IFS= read -r dependency_root; do
              if [ -f "$dependency_root/$dependency_name" ]; then
                cp -L "$dependency_root/$dependency_name" "$runtime_lib/$dependency_name"
                copied_missing=1
                break
              fi
            done < "$roots_file"
            ;;
        esac
      done < <(otool -l "$binary" | awk '/cmd LC_(LOAD|LOAD_WEAK|REEXPORT)_DYLIB/{getline; getline; print $2}')
    done < <(find "$runtime_root/bin" "$runtime_lib" -type f -print0)
  done

  while IFS= read -r -d '' binary; do
    if ! file "$binary" | grep -q 'Mach-O'; then
      continue
    fi
    while IFS= read -r dependency; do
      case "$dependency" in
        /opt/homebrew/*|/usr/local/*)
          install_name_tool -change "$dependency" "@rpath/$(basename "$dependency")" "$binary" 2>/dev/null
          ;;
      esac
    done < <(otool -l "$binary" | awk '/cmd LC_(LOAD|LOAD_WEAK|REEXPORT)_DYLIB/{getline; getline; print $2}')
    case "$binary" in
      *.dylib) install_name_tool -id "@rpath/$(basename "$binary")" "$binary" 2>/dev/null ;;
    esac
  done < <(find "$runtime_root/bin" "$runtime_lib" -type f -print0)

  rm -f "$roots_file"
}

validate_portable_runtime() {
  runtime_root="$1"
  failures=0
  while IFS= read -r -d '' binary; do
    if ! file "$binary" | grep -q 'Mach-O'; then
      continue
    fi
    while IFS= read -r dependency; do
      case "$dependency" in
        /opt/homebrew/*|/usr/local/*|/Users/*)
          echo "Non-portable runtime dependency: $binary -> $dependency" >&2
          failures=1
          ;;
        @rpath/*)
          dependency_name="$(basename "$dependency")"
          if [ ! -e "$runtime_root/lib/$dependency_name" ]; then
            echo "Missing bundled runtime dependency: $dependency_name" >&2
            failures=1
          fi
          ;;
      esac
    done < <(otool -l "$binary" | awk '/cmd LC_(LOAD|LOAD_WEAK|REEXPORT)_DYLIB/{getline; getline; print $2}')
  done < <(find "$runtime_root/bin" "$runtime_root/lib" -type f -print0)
  [ "$failures" -eq 0 ]
}

sign_runtime() {
  runtime_root="$1"
  while IFS= read -r -d '' binary; do
    if file "$binary" | grep -q 'Mach-O'; then
      codesign --force --sign - "$binary" >/dev/null 2>&1
      codesign --verify --strict "$binary" >/dev/null 2>&1
    fi
  done < <(find "$runtime_root/bin" "$runtime_root/lib" -type f -print0)
}

if [ ! -x "$engine_dir/bin/nemo-speech" ]; then
  sibling_engine="$repo_dir/../nemo-speech-stt-lab/runtime/nemo-speech"
  if [ -x "$sibling_engine/bin/nemo-speech" ]; then
    engine_dir="$sibling_engine"
  fi
fi

if [ ! -f "$nemo_source_dir/LICENSE" ]; then
  sibling_source="$repo_dir/../nemo-speech-stt-lab/vendor/NeMo-Speech.cpp"
  if [ -f "$sibling_source/LICENSE" ]; then
    nemo_source_dir="$sibling_source"
  fi
fi

cd "$repo_dir"
swift build -c release

rm -rf "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources/Licenses"
cp "$repo_dir/.build/release/LocalDictation" "$contents_dir/MacOS/LocalDictation"
cp "$repo_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$repo_dir/LICENSE" "$contents_dir/Resources/Licenses/Local-Dictation-MIT.txt"
cp "$repo_dir/THIRD_PARTY_NOTICES.md" "$contents_dir/Resources/THIRD_PARTY_NOTICES.md"
cp "$repo_dir/docs/BUNDLED_COMPONENTS.md" "$contents_dir/Resources/BUNDLED_COMPONENTS.md"

if [ -x "$tts_source_dir/run-tts-server.sh" ] && [ -f "$tts_source_dir/tts_worker.py" ]; then
  ditto "$tts_source_dir" "$contents_dir/Resources/TTSEngine"
  rm -rf "$contents_dir/Resources/TTSEngine/__pycache__"
  chmod 755 "$contents_dir/Resources/TTSEngine/run-tts-server.sh"
  mkdir -p "$tts_assets_dir/scripts" "$tts_assets_dir/python"
  cp "$repo_dir/python/requirements-tts-lock.txt" "$tts_assets_dir/python/requirements-tts-lock.txt"
  cp "$repo_dir/scripts/setup-tts-runtime.sh" "$repo_dir/scripts/download-tts-models.sh" "$tts_assets_dir/scripts/"
  chmod 755 "$tts_assets_dir/scripts/setup-tts-runtime.sh" "$tts_assets_dir/scripts/download-tts-models.sh"
  echo "Bundled local TTS worker launcher"
fi

if [ -x "$engine_dir/bin/nemo-speech" ]; then
  ditto "$engine_dir" "$contents_dir/Resources/Engine"
  bundle_host_dependencies "$contents_dir/Resources/Engine"
  validate_portable_runtime "$contents_dir/Resources/Engine"
  sign_runtime "$contents_dir/Resources/Engine"
  if [ -f "$nemo_source_dir/LICENSE" ]; then
    cp "$nemo_source_dir/LICENSE" "$contents_dir/Resources/Licenses/NeMo-Speech.cpp-Apache-2.0.txt"
  fi
  if [ -f "$nemo_source_dir/NOTICE" ]; then
    cp "$nemo_source_dir/NOTICE" "$contents_dir/Resources/Licenses/NeMo-Speech.cpp-NOTICE.txt"
  fi
  if [ -f "$nemo_source_dir/THIRD_PARTY_NOTICES.md" ]; then
    cp "$nemo_source_dir/THIRD_PARTY_NOTICES.md" "$contents_dir/Resources/Licenses/NeMo-Speech.cpp-THIRD-PARTY-NOTICES.md"
  fi
  echo "Bundled NeMo-Speech.cpp runtime from $engine_dir"
else
  echo "Warning: no runtime was bundled; the app will ask for an external engine." >&2
fi

signing_identity="${LOCAL_DICTATION_SIGN_IDENTITY:--}"
if [ "$signing_identity" = "-" ]; then
  # A plain ad-hoc signature defaults to a changing cdhash requirement, which
  # makes every local rebuild look like a different app to TCC. This explicit
  # development-only requirement keeps privacy approvals stable by bundle ID.
  # Public artifacts must set a Developer ID identity and be notarized.
  codesign \
    --force \
    --deep \
    --sign - \
    --requirements '=designated => identifier "org.localdictation.app"' \
    "$app_dir" >/dev/null 2>&1
else
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$signing_identity" \
    "$app_dir" >/dev/null 2>&1
fi
codesign --verify --deep --strict "$app_dir" >/dev/null 2>&1
echo "Built $app_dir"
