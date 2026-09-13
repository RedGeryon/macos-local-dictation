#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

failed=0

fail() {
  echo "Public-repository audit failed: $1" >&2
  failed=1
}

if git ls-files | rg -qi '(^|/)(build|dist|DerivedData|\.build)(/|$)'; then
  fail "generated build or distribution output is tracked"
fi

if git ls-files | rg -qi '(\.m4a|\.wav|\.mp3|\.flac|\.gguf|\.pem|\.p12|\.key|\.mobileprovision)$|(^|/)\.env($|\.)'; then
  fail "audio, model, credential, certificate, or environment files are tracked"
fi

secret_pattern='(-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})'
if git grep -I -q -E "$secret_pattern"; then
  fail "content resembles a private key, access token, or secret"
fi

if [ -n "${HOME:-}" ] && git grep -I -q -F "$HOME"; then
  fail "a tracked file contains this build machine's home-directory path"
fi

while IFS= read -r email; do
  [ -z "$email" ] && continue
  case "$email" in
    noreply@github.com|*@users.noreply.github.com|*@noreply.github.com|*.invalid) ;;
    *) fail "reachable Git history contains a non-private author or committer email" ;;
  esac
done < <(git log HEAD --format='%ae%n%ce' | sort -u)

for identity_kind in GIT_AUTHOR_IDENT GIT_COMMITTER_IDENT; do
  identity="$(git var "$identity_kind")"
  email="$(printf '%s' "$identity" | sed -n 's/.*<\([^>]*\)>.*/\1/p')"
  case "$email" in
    *@users.noreply.github.com|*@noreply.github.com|*.invalid) ;;
    *) fail "active $identity_kind uses a non-private email address" ;;
  esac
done

if ! rg -q '^build/$' .gitignore || ! rg -q '^dist/$' .gitignore; then
  fail ".gitignore does not exclude both build/ and dist/"
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "Public-repository audit passed."
