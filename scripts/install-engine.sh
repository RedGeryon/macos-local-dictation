#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
support_dir="${LOCAL_DICTATION_SUPPORT_DIR:-$HOME/Library/Application Support/LocalDictation}"
source_dir="$support_dir/Source/NeMo-Speech.cpp"
engine_dir="$support_dir/Engine"
patch_file="$repo_dir/patches/nemo-speech-macos-homebrew-abseil.patch"
nemo_revision="${LOCAL_DICTATION_NEMO_REVISION:-9bc876635af36df537d9bc6d3f57ad1b76e4f74a}"

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "The V1 app supports Apple Silicon Macs only." >&2
  exit 1
fi
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required. Install it from https://brew.sh and rerun this script." >&2
  exit 1
fi

for formula in cmake ninja sentencepiece abseil; do
  brew list --versions "$formula" >/dev/null 2>&1 || brew install "$formula"
done

mkdir -p "$support_dir/Source" "$engine_dir"
if [ ! -d "$source_dir/.git" ]; then
  mkdir -p "$source_dir"
  git -C "$source_dir" init
  git -C "$source_dir" remote add origin https://github.com/NVIDIA/NeMo-Speech.cpp.git
  git -C "$source_dir" fetch --depth 1 origin "$nemo_revision"
  git -C "$source_dir" checkout --detach FETCH_HEAD
elif [ "$(git -C "$source_dir" rev-parse HEAD)" != "$nemo_revision" ]; then
  if git -C "$source_dir" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    git -C "$source_dir" apply --reverse "$patch_file"
  fi
  if ! git -C "$source_dir" diff --quiet; then
    echo "The managed NeMo-Speech.cpp source has local changes; refusing to overwrite them." >&2
    exit 1
  fi
  git -C "$source_dir" fetch --depth 1 origin "$nemo_revision"
  git -C "$source_dir" checkout --detach FETCH_HEAD
fi

if ! git -C "$source_dir" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
  git -C "$source_dir" apply --check "$patch_file"
  git -C "$source_dir" apply "$patch_file"
fi

git -C "$source_dir" submodule update --init ggml third_party/cpp-httplib
(
  cd "$source_dir"
  CMAKE_PREFIX_PATH="$(brew --prefix abseil)" scripts/configure.sh metal-server
  cmake --build --preset metal-server
  cmake --install build/metal-server --prefix "$engine_dir"
)

"$engine_dir/bin/nemo-speech" --version
echo "NeMo-Speech.cpp revision: $nemo_revision"
echo "Engine installed at $engine_dir/bin/nemo-speech"
