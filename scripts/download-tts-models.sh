#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_dir="${LOCAL_DICTATION_TTS_RUNTIME_DIR:-$HOME/Library/Application Support/LocalDictation/TTSRuntime}"
python_bin="${LOCAL_DICTATION_TTS_PYTHON:-$runtime_dir/venv/bin/python}"
model_dir="${LOCAL_DICTATION_TTS_MODEL_DIR:-$HOME/Library/Application Support/LocalDictation/TTSModels}"
selected="custom"

usage() {
  cat <<'EOF'
Usage: bash scripts/download-tts-models.sh [--model custom|custom8|design|design8|base|base8|bf16|8bit|all]

Downloads pinned MLX Qwen TTS snapshots to the app-support model directory.
The worker never downloads models while serving requests. Models are not added
to the application bundle or this repository.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; selected="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$selected" in custom|custom8|design|design8|base|base8|bf16|8bit|all) ;; *) echo "Unknown model: $selected" >&2; exit 2 ;; esac
[ -x "$python_bin" ] || { echo "Run scripts/setup-tts-runtime.sh first." >&2; exit 1; }

# Keep Hugging Face/Xet caches beside these downloads, never in a shared home cache.
export HF_HOME="$model_dir/.cache/huggingface"
export HF_HUB_CACHE="$HF_HOME/hub"
export HF_XET_CACHE="$HF_HOME/xet"
export HF_HUB_DISABLE_XET=1
mkdir -p "$model_dir"
MODEL_DIR="$model_dir" SELECTED_MODEL="$selected" "$python_bin" - <<'PY'
from pathlib import Path
import json
import os
import shutil
import signal
import fcntl
from huggingface_hub import snapshot_download

catalog = {
    # Approximate snapshot bytes for a conservative free-space preflight.
    "custom": ("mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", "52f4770fd9726457eae3d3b6aa92047a25a10776", "qwen3-tts-1.7b-customvoice-bf16", 4_600_000_000),
    "custom8": ("mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit", "41d3337e8b7f2843a75841595fc14e4b9a7a4b96", "qwen3-tts-1.7b-customvoice-8bit", 3_100_000_000),
    "design": ("mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", "7d3824abff87e49756bb0f83fb5411de75d160c4", "qwen3-tts-1.7b-voicedesign-bf16", 4_600_000_000),
    "design8": ("mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit", "f90d617701d9f7f4ca499291e0b57f2b3c2fd2ee", "qwen3-tts-1.7b-voicedesign-8bit", 3_100_000_000),
    "base": ("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", "a6eb4f68e4b056f1215157bb696209bc82a6db48", "qwen3-tts-1.7b-base-bf16", 4_600_000_000),
    "base8": ("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit", "e7dd0585652209fa0d7783659aad4e8a324de11c", "qwen3-tts-1.7b-base-8bit", 3_100_000_000),
}
selection = os.environ["SELECTED_MODEL"]
groups = {
    "bf16": ("custom", "design", "base"),
    "8bit": ("custom8", "design8", "base8"),
    "all": tuple(catalog),
}
keys = groups.get(selection, (selection,))
selected = {key: catalog[key] for key in keys}
model_dir = Path(os.environ["MODEL_DIR"])

# A single app-support directory can have only one downloader at a time.  The
# advisory lock is released by macOS even if a process is killed, so a later
# retry can safely use its own staging directory without asking the user to
# find or delete hidden files.
lock_path = model_dir / ".local-dictation-download.lock"
lock_file = lock_path.open("a+", encoding="utf-8")
try:
    fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError as error:
    raise SystemExit("Another TTS model download is already running. Wait for it to finish or cancel it, then try again.") from error
lock_file.seek(0)
lock_file.truncate()
lock_file.write(f"{os.getpid()}\\n")
lock_file.flush()

def already_complete(repo, revision, directory):
    marker = model_dir / directory / ".local-dictation-complete.json"
    try:
        return json.loads(marker.read_text(encoding="utf-8")) == {"repository": repo, "revision": revision}
    except (OSError, json.JSONDecodeError):
        return False

to_download = [item for item in selected.values() if not already_complete(*item[:3])]
if to_download:
    required = sum(item[3] for item in to_download) + 1_000_000_000
    free = shutil.disk_usage(os.environ["MODEL_DIR"]).free
    if free < required:
        raise SystemExit(
            f"Not enough free space for {selection}: need about {required / 1e9:.1f} GB free "
            f"including staging headroom; found {free / 1e9:.1f} GB."
        )

active_staging: Path | None = None
def cancel_download(_signal, _frame):
    if active_staging and active_staging.exists():
        shutil.rmtree(active_staging)
    raise KeyboardInterrupt("download cancelled")
signal.signal(signal.SIGTERM, cancel_download)
signal.signal(signal.SIGINT, cancel_download)

for key, (repo, revision, directory, estimated_bytes) in selected.items():
    target = model_dir / directory
    marker = target / ".local-dictation-complete.json"
    if marker.is_file():
        try:
            complete = json.loads(marker.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            complete = None
        if complete == {"repository": repo, "revision": revision}:
            print(f"Pinned {key} model is already installed at {target}", flush=True)
            continue
        raise SystemExit(f"{target} has a completion marker for another model revision. Remove that directory, then rerun this download.")
    if target.exists():
        raise SystemExit(f"{target} is not a verified Local Dictation model installation. It was left unchanged.")
    staging = target.with_name(f".{directory}.download")
    if staging.exists() and not staging.is_dir():
        raise SystemExit(f"{staging} is not a download directory. It was left unchanged.")
    if staging.exists():
        print(f"Resuming pinned {key} model download at {staging}", flush=True)
    else:
        print(f"Downloading pinned {key} model (~{estimated_bytes / 1e9:.1f} GB) to staging directory {staging}", flush=True)
    active_staging = staging
    try:
        snapshot_download(repo_id=repo, revision=revision, local_dir=staging)
        if not ((staging / "config.json").is_file() and any(staging.glob("*.safetensors")) and (staging / "speech_tokenizer").is_dir() and (staging / "tokenizer_config.json").is_file() and (staging / "vocab.json").is_file() and (staging / "merges.txt").is_file()):
            raise SystemExit("Downloaded snapshot is missing required offline Qwen TTS assets.")
        (staging / ".local-dictation-complete.json").write_text(json.dumps({"repository": repo, "revision": revision}), encoding="utf-8")
        os.replace(staging, target)
    except KeyboardInterrupt:
        # A user-requested cancellation reclaims only this downloader's hidden
        # staging directory. A kill -9 cannot run this handler; its released
        # file lock lets the next attempt resume safely from the same staging
        # directory.
        if staging.exists():
            shutil.rmtree(staging)
        raise
    finally:
        active_staging = None
    print(f"Installed pinned {key} model at {target}", flush=True)
PY

echo "TTS model download complete: $model_dir"
