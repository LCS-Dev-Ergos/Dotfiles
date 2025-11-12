#!/bin/sh
# Wrapper for fastfetch that uses dynamic OS icons

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fastfetch"
GENERATED_CONFIG=$("$CONFIG_DIR/scripts/generate-config.sh")

# Run fastfetch with the generated config
fastfetch --config "$GENERATED_CONFIG" "$@"

# Clean up generated config
rm -f "$GENERATED_CONFIG"
