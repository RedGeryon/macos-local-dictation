#!/usr/bin/env bash
set -euo pipefail

support_dir="${LOCAL_DICTATION_SUPPORT_DIR:-$HOME/Library/Application Support/LocalDictation}"
model_dir="$support_dir/Models"
model_repo="nvidia/nemotron-speech-streaming-en-0.6b"
model_file="nemotron-speech-streaming-en-0.6b.q8_0.gguf"
accepted=0

if [ "${1:-}" = "--accept-nvidia-model-license" ]; then
  accepted=1
fi

if [ "$accepted" -ne 1 ]; then
  cat >&2 <<'EOF'
This downloads NVIDIA's separately licensed model; it is not part of this app.

Model:   https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b
License: https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/

Read the current model card and license. If you agree, rerun:
  bash scripts/download-model.sh --accept-nvidia-model-license
EOF
  exit 2
fi

command -v python3 >/dev/null 2>&1 || { echo "Python 3 is required." >&2; exit 1; }
venv_dir="$support_dir/DownloadTools"
mkdir -p "$model_dir"
python3 -m venv "$venv_dir"
"$venv_dir/bin/python" -m pip install --quiet --upgrade pip huggingface_hub
"$venv_dir/bin/hf" download "$model_repo" "$model_file" --local-dir "$model_dir"

echo "Model downloaded to $model_dir/$model_file"

