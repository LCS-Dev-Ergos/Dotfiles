#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================ #
# ++++++++++++++++++++++++++ DECLARED SECRETS CHECK ++++++++++++++++++++++++++ #
# ============================================================================ #
# Scans the repository for likely secret material: private-key armor,
# recognizable provider-token prefixes, literal credential assignments, and
# credentials embedded in a URL. Ordinary environment-variable references do
# not trigger the scan.
#
# Usage:
#   scripts/check-declared-secrets.sh
#
# ============================================================================ #

set -euo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
findings=0

if ! command -v rg >/dev/null 2>&1; then
  printf 'check-declared-secrets requires ripgrep.\n' >&2
  exit 2
fi

cd -- "$repo_root"

# +++++++++++++++++++++++++++++++ SCAN HELPER ++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# scan
# @internal
# @description Runs a ripgrep pattern over the repository and reports every
# matching file without ever printing the matched text itself.
# @arg $1 string Human-readable label used in the reported findings.
# @arg $2 string PCRE2 pattern to search for.
# @arg $3 string File glob to restrict the search to, or '*' for all files.
# @set findings int Set to 1 if any match is found.
# -----------------------------------------------------------------------------
scan() {
  local label="$1"
  local pattern="$2"
  local file_glob="$3"
  local matches
  local status
  local -a cmd=(
    rg --files-with-matches --hidden --pcre2
    --glob '!.git/**'
    --glob '!**/.git/**'
    --glob '!.codex-nix-cache/**'
    --glob '!result'
    --glob '!result-*'
  )

  if [[ "$file_glob" != '*' ]]; then
    cmd+=(--glob "$file_glob")
  fi
  cmd+=(-- "$pattern" .)

  if matches="$("${cmd[@]}")"; then
    status=0
  else
    status=$?
    if ((status != 1)); then
      printf 'Secret scan failed while checking %s (ripgrep status %d).\n' \
        "$label" "$status" >&2
      exit 2
    fi
  fi

  if [[ -n "$matches" ]]; then
    findings=1
    while IFS= read -r path; do
      printf 'Potential %s: %q\n' "$label" "${path#./}" >&2
    done <<<"$matches"
  fi
}

# ++++++++++++++++++++++++++++++++ SCAN RULES ++++++++++++++++++++++++++++++++ #

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

# +++++++++++++++++++++++++++++++++ SUMMARY ++++++++++++++++++++++++++++++++++ #

if ((findings)); then
  echo 'Potential secret material found; inspect locally without pasting values into logs.' >&2
  exit 1
fi

echo 'No private-key or credential literals detected.'

# ============================================================================ #
# End of check-declared-secrets.sh.
