#!/bin/sh
# -----------------------------------------------------------------------------
# Generate fastfetch config with appropriate OS icon.

set -eu

# Determine OS icon
case $(uname -s) in
  Darwin)
    OS_ICON='│ ┌ '
    ;;
  Linux)
    if [ -f /etc/os-release ]; then
      # shellcheck source=/dev/null
      . /etc/os-release
      case ${ID:-} in
        arch | archlinux)
          OS_ICON='│ ┌󰣇 '
          ;;
        ubuntu)
          OS_ICON='│ ┌ '
          ;;
        debian)
          OS_ICON='│ ┌ '
          ;;
        fedora)
          OS_ICON='│ ┌ '
          ;;
        centos)
          OS_ICON='│ ┌ '
          ;;
        gentoo)
          OS_ICON='│ ┌ '
          ;;
        nixos)
          OS_ICON='│ ┌ '
          ;;
        *)
          OS_ICON='│ ┌ '
          ;;
      esac
    else
      OS_ICON='│ ┌ '
    fi
    ;;
  *BSD)
    OS_ICON='│ ┌ '
    ;;
  *)
    OS_ICON='│ ┌ '
    ;;
esac

# Read the base config template and replace the OS icon placeholder.
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fastfetch"
BASE_CONFIG="$CONFIG_DIR/config.jsonc"
TEMP_CONFIG=$(mktemp "${TMPDIR:-/tmp}/fastfetch-config.XXXXXXXX.jsonc")

if [ ! -r "$BASE_CONFIG" ]; then
  echo "generate-config: base config not found: $BASE_CONFIG" >&2
  exit 1
fi

# Replace only the key inside the OS module.
sed "/\"type\": \"os\"/,/\"key\":/ s|\"key\": \".*\",|\"key\": \"$OS_ICON OS\",|" "$BASE_CONFIG" >"$TEMP_CONFIG"

# Output the path to generated config.
echo "$TEMP_CONFIG"
