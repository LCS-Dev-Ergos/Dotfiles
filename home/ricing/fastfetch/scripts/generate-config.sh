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

if [ ! -r "$BASE_CONFIG" ]; then
  echo "generate-config: base config not found: $BASE_CONFIG" >&2
  exit 1
fi

# fastfetch only loads a config whose name ends in .jsonc, and BSD mktemp
# leaves the X's of a template alone when a suffix follows them, so the file
# gets a private directory of its own. It is removed here only if generation
# fails; on success the caller owns it.
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fastfetch-config.XXXXXXXX")
TEMP_CONFIG="$TEMP_DIR/config.jsonc"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

# Replace only the key inside the OS module.
sed "/\"type\": \"os\"/,/\"key\":/ s|\"key\": \".*\",|\"key\": \"$OS_ICON OS\",|" "$BASE_CONFIG" >"$TEMP_CONFIG"
trap - EXIT

# Output the path to generated config.
echo "$TEMP_CONFIG"
