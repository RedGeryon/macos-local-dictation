#!/usr/bin/env bash
set -euo pipefail

# Build and open the development preview. It deliberately does not require the
# optional local TTS runtime or a downloaded TTS model: transcription-only use
# remains available and Models & Startup can install TTS later.
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
preview_app="$repo_dir/build/Local Dictation TTS Preview.app"
if [ -n "${LOCAL_DICTATION_TTS_RUNTIME_DIR:-}" ]; then
  runtime_dir="$LOCAL_DICTATION_TTS_RUNTIME_DIR"
elif [ -x "$repo_dir/build/tts-runtime/venv/bin/python" ]; then
  runtime_dir="$repo_dir/build/tts-runtime"
else
  runtime_dir="$HOME/Library/Application Support/LocalDictation/TTSRuntime"
fi
if [ -n "${LOCAL_DICTATION_TTS_MODEL_DIR:-}" ]; then
  model_dir="$LOCAL_DICTATION_TTS_MODEL_DIR"
elif [ -d "$repo_dir/build/tts-models" ]; then
  model_dir="$repo_dir/build/tts-models"
else
  model_dir="$HOME/Library/Application Support/LocalDictation/TTSModels"
fi
model_id="${LOCAL_DICTATION_TTS_MODEL_ID:-qwen-1.7b-bf16}"

bash "$repo_dir/scripts/build-app.sh"
rm -rf "$preview_app"
ditto "$repo_dir/build/Local Dictation.app" "$preview_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier org.localdictation.app.tts-preview' "$preview_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Local Dictation Preview' "$preview_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleDisplayName' "$preview_app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Local Dictation Preview' "$preview_app/Contents/Info.plist"
codesign --force --deep --sign - --requirements '=designated => identifier "org.localdictation.app.tts-preview"' "$preview_app" >/dev/null
codesign --verify --strict "$preview_app"

open \
  --new \
  --env "LOCAL_DICTATION_TTS_RUNTIME_DIR=$runtime_dir" \
  --env "LOCAL_DICTATION_TTS_MODEL_DIR=$model_dir" \
  --env "LOCAL_DICTATION_TTS_MODEL_ID=$model_id" \
  --env "LOCAL_DICTATION_TTS_PREVIEW=1" \
  "$preview_app"
