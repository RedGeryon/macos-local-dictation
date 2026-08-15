#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
support_dir="${LOCAL_DICTATION_SUPPORT_DIR:-$HOME/Library/Application Support/LocalDictation}"
engine_path="${LOCAL_DICTATION_ENGINE_PATH:-$support_dir/Engine/bin/nemo-speech}"
model_path="${LOCAL_DICTATION_MODEL_PATH:-$support_dir/Models/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf}"
language_code="${LOCAL_DICTATION_LANGUAGE:-es-ES}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "The Spanish voice fixture requires macOS's built-in speech tools." >&2
  exit 1
fi
if [ ! -x "$engine_path" ]; then
  echo "NeMo-Speech.cpp runtime not found at $engine_path" >&2
  exit 1
fi
if [ ! -f "$model_path" ]; then
  cat >&2 <<EOF
Multilingual model not found at:
  $model_path

Download it after reviewing its model card and OpenMDW 1.1 license:
  bash scripts/download-model.sh --model multilingual --accept-openmdw-license
EOF
  exit 1
fi

fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/local-dictation-spanish.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT

say -v "Mónica" \
  "Hola, esta es una prueba de dictado en español para esta computadora." \
  -o "$fixture_dir/spanish.aiff"
afconvert \
  -f WAVE \
  -d LEI16@16000 \
  -c 1 \
  "$fixture_dir/spanish.aiff" \
  "$fixture_dir/spanish.wav"

LOCAL_DICTATION_RUN_REAL_ENGINE_TESTS=1 \
LOCAL_DICTATION_ENGINE_PATH="$engine_path" \
LOCAL_DICTATION_MODEL_PATH="$model_path" \
LOCAL_DICTATION_TEST_AUDIO="$fixture_dir/spanish.wav" \
LOCAL_DICTATION_LANGUAGE="$language_code" \
LOCAL_DICTATION_EXPECTED_FINAL_WORD="computadora" \
LOCAL_DICTATION_TEST_LANGUAGE_UPDATE=1 \
  swift test --filter \
    SpeechServerManagerTests/testRealRealtimeWebSocketTranscribesPCMAndCommits
