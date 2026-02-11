#!/bin/sh
# -----------------------------------------------------------------------------
# Wrapper for fastfetch that uses dynamic OS icons.

set -eu

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fastfetch"
GENERATOR_SCRIPT="$CONFIG_DIR/scripts/generate-config.sh"
GENERATED_CONFIG=""

cleanup() {
  [ -n "${GENERATED_CONFIG:-}" ] && rm -f -- "$GENERATED_CONFIG"
}
trap cleanup EXIT INT TERM

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
