#!/bin/bash

# Full path to yabai and jq (just for safety)
YABAI_PATH="/opt/homebrew/bin/yabai"
JQ_PATH="/opt/homebrew/bin/jq"

# Focus the specified space
$YABAI_PATH -m space --focus $1

# Check if there are any windows in that space
window_count=$($YABAI_PATH -m query --windows --space $1 | $JQ_PATH '. | length')
# If there are windows, try to focus the first non-floating, non-minimized one
if [ "$window_count" -gt 0 ]; then
    # Get all windows
    windows=$($YABAI_PATH -m query --windows --space $1)
    # Try to find a suitable window to focus
    window_id=$(echo "$windows" | $JQ_PATH -r '.[0].id')
    # Focus the window if found
    if [ -n "$window_id" ]; then
        $YABAI_PATH -m window --focus "$window_id"
    fi
fi

exit 0