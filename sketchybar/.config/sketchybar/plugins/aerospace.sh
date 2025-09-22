#!/bin/bash
# ~/.config/sketchybar/plugins/aerospace.sh

source "$CONFIG_DIR/colors.sh"

if [ "$1" = "$FOCUSED_WORKSPACE" ]; then
    sketchybar --set space.$1 background.drawing=on \
        label.color="$BAR_COLOR" \
        background.color="$ACCENT_COLOR"
else
    sketchybar --set space.$1 background.drawing=off \
        label.color="$WHITE"
fi
