#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$repo_dir/build/Local Dictation.app"
dist_dir="$repo_dir/dist"
dmg_path="$dist_dir/Local-Dictation-0.3.7-macOS-arm64.dmg"

bash "$repo_dir/scripts/build-app.sh"
if [ ! -x "$app_dir/Contents/Resources/Engine/bin/nemo-speech" ]; then
  echo "A distributable image must contain the separately licensed Apache-2.0 runtime." >&2
  exit 1
fi
for notice in \
  "NeMo-Speech.cpp-Apache-2.0.txt" \
  "NeMo-Speech.cpp-NOTICE.txt" \
  "NeMo-Speech.cpp-THIRD-PARTY-NOTICES.md"; do
  if [ ! -f "$app_dir/Contents/Resources/Licenses/$notice" ]; then
    echo "Missing required bundled-runtime notice: $notice" >&2
    exit 1
  fi
done

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/local-dictation-dmg.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
ditto "$app_dir" "$stage_dir/Local Dictation.app"
ln -s /Applications "$stage_dir/Applications"
cp "$repo_dir/INSTALL_AND_REMOVE.md" "$stage_dir/Install & Remove.md"

mkdir -p "$dist_dir"
hdiutil create \
  -volname "Local Dictation" \
  -srcfolder "$stage_dir" \
  -format UDZO \
  -ov \
  "$dmg_path"

echo "Packaged $dmg_path"
