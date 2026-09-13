#!/usr/bin/env bash
set -euo pipefail

# Kept for existing local workflows. The unified preview no longer requires TTS
# to be installed before opening.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-preview.sh" "$@"
