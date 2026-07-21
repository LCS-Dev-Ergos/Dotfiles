#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
findings=0

cd -- "$repo_root"

scan() {
  local label="$1"
  local pattern="$2"
  local file_glob="$3"
  local -a glob_args=()
  local matches

  if [[ "$file_glob" != '*' ]]; then
    glob_args=(--glob "$file_glob")
  fi

  matches="$(rg --files-with-matches --hidden --pcre2 \
    --glob '!**/.git/**' \
    --glob '!.codex-nix-cache/**' \
    --glob '!result' \
    --glob '!result-*' \
    "${glob_args[@]}" \
    -- "$pattern" . || true)"

  if [[ -n "$matches" ]]; then
    findings=1
    while IFS= read -r path; do
      printf 'Potential %s: %s\n' "$label" "${path#./}" >&2
    done <<<"$matches"
  fi
}

# Keep output deliberately value-free: CI logs identify the rule and file but
# never echo a credential candidate. The patterns require either private-key
# armor, a recognizable provider prefix, a literal credential assignment, or
# credentials embedded in a URL; ordinary environment-variable references do
# not trigger the scan.
scan 'private-key material' \
  '-----BEGIN (?:OPENSSH|RSA|EC|DSA|PGP) PRIVATE KEY-----' \
  '*'
scan 'provider-token literal' \
  '(?i)(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|(?<![A-Za-z0-9])sk-(?:proj-)?[A-Za-z0-9_-]{32,})' \
  '*'
scan 'credential literal assignment' \
  '(?i)(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|password)\s*[=:]\s*"(?!\s*(?:"|REDACTED|CHANGEME|EXAMPLE))[^"]{8,}"' \
  '*.nix'
scan 'credential-bearing URL' \
  'https?://[^/[:space:]@]+:[^/[:space:]@]+@' \
  '*'

if ((findings)); then
  echo 'Potential secret material found; inspect locally without pasting values into logs.' >&2
  exit 1
fi

echo 'No private-key or credential literals detected.'
