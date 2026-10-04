#!/usr/bin/env bash
# shellcheck shell=bash
# Lint Markdown with the personal markdownlint rules. Reports by default; the reduced set is the
# one the editor uses. --extended adds the full style rules, which are for reports only because
# several of their fixers change content.
set -euo pipefail

config_dir="${MDLINT_CONFIG_DIR:?MDLINT_CONFIG_DIR is not set}"
config="$config_dir/config.jsonc"
extended=false
fix=false
args=()

for arg in "$@"; do
  case "$arg" in
    --extended) extended=true ;;
    --fix)
      fix=true
      args+=("$arg")
      ;;
    -h | --help)
      cat <<'USAGE'
usage: mdlint [--extended] [markdownlint-cli2 options] PATH-OR-GLOB...

  (default)   reduced rule set, the one the editor uses
  --extended  reduced set plus the full style rules (report only)

To rewrite many files safely use the mdfix script (Markdown-Tools) instead of mdlint --fix.
USAGE
      exit 0
      ;;
    *) args+=("$arg") ;;
  esac
done

if $extended; then
  if $fix; then
    echo "mdlint: --fix is not allowed with --extended; its fixers can change content." >&2
    exit 2
  fi
  config="$config_dir/extended.jsonc"
fi

exec markdownlint-cli2 --config "$config" "${args[@]}"
