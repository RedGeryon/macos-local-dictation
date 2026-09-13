#!/usr/bin/env bash
set -euo pipefail

resource_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$resource_dir/.." && pwd)"
runtime_dir="${LOCAL_DICTATION_TTS_RUNTIME_DIR:-$HOME/Library/Application Support/LocalDictation/TTSRuntime}"
python_bin="${LOCAL_DICTATION_TTS_PYTHON:-$runtime_dir/venv/bin/python}"

if [ ! -x "$python_bin" ]; then
  echo "TTS runtime is not installed. Run: bash scripts/setup-tts-runtime.sh" >&2
  exit 1
fi

exec "$python_bin" "$resource_dir/tts_worker.py" "$@"
