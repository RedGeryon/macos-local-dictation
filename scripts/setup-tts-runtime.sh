#!/usr/bin/env bash
set -euo pipefail

repo_dir="${LOCAL_DICTATION_TTS_ASSET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
runtime_dir="${LOCAL_DICTATION_TTS_RUNTIME_DIR:-$HOME/Library/Application Support/LocalDictation/TTSRuntime}"
venv_dir="$runtime_dir/venv"

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "The local TTS runtime supports Apple Silicon Macs only." >&2
  exit 1
fi
command -v python3 >/dev/null 2>&1 || { echo "Python 3 is required." >&2; exit 1; }
python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' \
  || { echo "Local TTS requires Python 3.10 or newer (for example, Homebrew Python)." >&2; exit 1; }

# Package setup must not leave a second copy in the shared pip cache.
export PIP_NO_CACHE_DIR=1
mkdir -p "$runtime_dir"
python3 -m venv "$venv_dir"
"$venv_dir/bin/python" -m pip install --upgrade pip
wheel_dir="$runtime_dir/wheels"
mkdir -p "$wheel_dir"
"$venv_dir/bin/python" -m pip download --no-deps --dest "$wheel_dir" "mlx-audio==0.5.3"
wheel_path="$(find "$wheel_dir" -maxdepth 1 -name 'mlx_audio-0.5.3-*.whl' -print -quit)"
[ -n "$wheel_path" ] || { echo "Could not obtain the mlx-audio 0.5.3 wheel." >&2; exit 1; }
expected_sha="8d920b2dcbcf37b5fd2bbb070e21a9a33442bf231a754e0d39387e65986bd830"
actual_sha="$(shasum -a 256 "$wheel_path" | awk '{print $1}')"
[ "$actual_sha" = "$expected_sha" ] || { echo "mlx-audio wheel checksum did not match the reviewed release." >&2; exit 1; }
"$venv_dir/bin/python" -m pip install -c "$repo_dir/python/requirements-tts-lock.txt" "$wheel_path"
"$venv_dir/bin/python" -m pip freeze > "$runtime_dir/requirements-resolved.txt"

echo "Installed isolated TTS runtime at $runtime_dir"
echo "Next, explicitly download the default quality model with: bash scripts/download-tts-models.sh --model custom"
