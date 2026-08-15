#!/usr/bin/env bash
set -euo pipefail

support_dir="${LOCAL_DICTATION_SUPPORT_DIR:-$HOME/Library/Application Support/LocalDictation}"
model_dir="$support_dir/Models"
selected_model="english"
accepted_english=0
accepted_multilingual=0

usage() {
  cat <<'EOF'
Usage: bash scripts/download-model.sh [options]

Model selection:
  --model english       English-only model (default)
  --model multilingual  Nemotron 3.5 multilingual model, including Spanish
  --model all           Download both models

License acceptance (required for each selected model):
  --accept-nvidia-model-license  English model's NVIDIA Open Model License
  --accept-openmdw-license       Multilingual model's OpenMDW 1.1 license
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)
      [ "$#" -ge 2 ] || { echo "--model requires english, multilingual, or all." >&2; exit 2; }
      selected_model="$2"
      shift 2
      ;;
    --accept-nvidia-model-license)
      accepted_english=1
      shift
      ;;
    --accept-openmdw-license)
      accepted_multilingual=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$selected_model" in
  english|multilingual|all) ;;
  *)
    echo "Unknown model '$selected_model'. Choose english, multilingual, or all." >&2
    exit 2
    ;;
esac

if { [ "$selected_model" = "english" ] || [ "$selected_model" = "all" ]; } \
    && [ "$accepted_english" -ne 1 ]; then
  cat >&2 <<'EOF'
The English model is a separate download and is not part of this app.

Model:   https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b
License: https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/

Read the current model card and license. If you agree, rerun:
  bash scripts/download-model.sh --model english --accept-nvidia-model-license
EOF
  exit 2
fi

if { [ "$selected_model" = "multilingual" ] || [ "$selected_model" = "all" ]; } \
    && [ "$accepted_multilingual" -ne 1 ]; then
  cat >&2 <<'EOF'
The multilingual model is a separate download and is not part of this app.

Model:   https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b
License: https://openmdw.ai/license/1-1/

Read the current model card and license. If you agree, rerun:
  bash scripts/download-model.sh --model multilingual --accept-openmdw-license

To download both models, pass both acceptance flags with --model all.
EOF
  exit 2
fi

command -v python3 >/dev/null 2>&1 || { echo "Python 3 is required." >&2; exit 1; }
venv_dir="$support_dir/DownloadTools"
mkdir -p "$model_dir"
python3 -m venv "$venv_dir"
"$venv_dir/bin/python" -m pip install --quiet --upgrade pip huggingface_hub

download_model() {
  local model_repo="$1"
  local model_file="$2"
  "$venv_dir/bin/hf" download "$model_repo" "$model_file" --local-dir "$model_dir"
  echo "Model downloaded to $model_dir/$model_file"
}

if [ "$selected_model" = "english" ] || [ "$selected_model" = "all" ]; then
  download_model \
    "nvidia/nemotron-speech-streaming-en-0.6b" \
    "nemotron-speech-streaming-en-0.6b.q8_0.gguf"
fi

if [ "$selected_model" = "multilingual" ] || [ "$selected_model" = "all" ]; then
  download_model \
    "nvidia/nemotron-3.5-asr-streaming-0.6b" \
    "nemotron-3.5-asr-streaming-0.6b.q8_0.gguf"
fi
