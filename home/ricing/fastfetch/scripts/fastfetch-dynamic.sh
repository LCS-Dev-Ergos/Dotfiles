#!/bin/sh
# -----------------------------------------------------------------------------
# Wrapper for fastfetch that uses dynamic OS icons.

set -eu

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fastfetch"
GENERATOR_SCRIPT="$CONFIG_DIR/scripts/generate-config.sh"
GENERATED_CONFIG=""

# The generator puts the config alone in a private temporary directory.
cleanup() {
  if [ -n "${GENERATED_CONFIG:-}" ]; then
    rm -f -- "$GENERATED_CONFIG"
    rmdir -- "${GENERATED_CONFIG%/*}" 2>/dev/null || true
  fi
}
# A signal handler replaces the default action, so exit explicitly; the EXIT
# trap then removes the generated config.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -x "$GENERATOR_SCRIPT" ]; then
  echo "fastfetch-dynamic: missing generator script: $GENERATOR_SCRIPT" >&2
  exit 1
fi

GENERATED_CONFIG=$("$GENERATOR_SCRIPT")

if [ -z "$GENERATED_CONFIG" ] || [ ! -f "$GENERATED_CONFIG" ]; then
  echo "fastfetch-dynamic: failed to generate fastfetch config." >&2
  exit 1
fi

# Run fastfetch with the generated config.
fastfetch --config "$GENERATED_CONFIG" "$@"
