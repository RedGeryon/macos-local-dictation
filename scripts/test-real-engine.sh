#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
support_dir="${LOCAL_DICTATION_SUPPORT_DIR:-$HOME/Library/Application Support/LocalDictation}"
engine_path="${LOCAL_DICTATION_ENGINE_PATH:-$support_dir/Engine/bin/nemo-speech}"
model_path="${LOCAL_DICTATION_MODEL_PATH:-$support_dir/Models/nemotron-speech-streaming-en-0.6b.q8_0.gguf}"
audio_path="${LOCAL_DICTATION_TEST_AUDIO:-$repo_dir/../nemo-speech-stt-lab/vendor/NeMo-Speech.cpp/test_files/asr/wav/test/jfk.wav}"

if [ ! -x "$engine_path" ] || [ ! -f "$model_path" ]; then
  sibling_lab="$repo_dir/../nemo-speech-stt-lab"
  engine_path="${LOCAL_DICTATION_ENGINE_PATH:-$sibling_lab/runtime/nemo-speech/bin/nemo-speech}"
  model_path="${LOCAL_DICTATION_MODEL_PATH:-$sibling_lab/models/nemotron-speech-streaming-en-0.6b.q8_0.gguf}"
fi

LOCAL_DICTATION_RUN_REAL_ENGINE_TESTS=1 \
LOCAL_DICTATION_ENGINE_PATH="$engine_path" \
LOCAL_DICTATION_MODEL_PATH="$model_path" \
LOCAL_DICTATION_TEST_AUDIO="$audio_path" \
  swift test --filter SpeechServerManagerTests
