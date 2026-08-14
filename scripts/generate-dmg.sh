#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
support_dir="${LOCAL_DICTATION_SUPPORT_DIR:-$HOME/Library/Application Support/LocalDictation}"
engine_dir="${LOCAL_DICTATION_BUNDLE_ENGINE_DIR:-$support_dir/Engine}"

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "DMG generation currently supports Apple Silicon Macs only." >&2
  exit 1
fi

if [ ! -x "$engine_dir/bin/nemo-speech" ]; then
  echo "NeMo-Speech.cpp runtime not found; building it once for packaging."
  LOCAL_DICTATION_SUPPORT_DIR="$support_dir" bash "$repo_dir/scripts/install-engine.sh"
fi

LOCAL_DICTATION_SUPPORT_DIR="$support_dir" \
LOCAL_DICTATION_BUNDLE_ENGINE_DIR="$engine_dir" \
  bash "$repo_dir/scripts/package-dmg.sh"
