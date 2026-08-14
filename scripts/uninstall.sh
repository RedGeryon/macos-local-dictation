#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != "--remove-all" ]; then
  cat <<'EOF'
This removes the application plus its downloaded model, engine, and settings.
Removed files are moved to the Trash where practical.

Run again only if that is what you want:
  bash scripts/uninstall.sh --remove-all
EOF
  exit 2
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
trash_dir="$HOME/.Trash"
support_dir="$HOME/Library/Application Support/LocalDictation"
system_app="/Applications/Local Dictation.app"
user_app="$HOME/Applications/Local Dictation.app"

mkdir -p "$trash_dir"
osascript -e 'tell application id "org.localdictation.app" to quit' >/dev/null 2>&1 || true
sleep 1

move_to_trash() {
  source_path="$1"
  label="$2"
  if [ -e "$source_path" ]; then
    destination="$trash_dir/$label-$timestamp"
    mv "$source_path" "$destination"
    echo "Moved to Trash: $destination"
  fi
}

move_to_trash "$system_app" "Local Dictation.app"
move_to_trash "$user_app" "Local Dictation.app"
move_to_trash "$support_dir" "LocalDictation-data"

defaults delete org.localdictation.app >/dev/null 2>&1 || true
echo "Local Dictation was removed. Empty the Trash when you no longer need recovery."
