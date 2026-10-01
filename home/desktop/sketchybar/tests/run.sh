#!/bin/bash
# Regression checks for the SketchyBar helpers and Lua widgets.
#
# Usage: bash home/desktop/sketchybar/tests/run.sh
# Honours LUA and PYTHON. SketchyBar itself is tested in the CI of the
# LCS-Dev-Ergos fork; its window order check needs the running GUI session and
# is run by hand (see helpers/README.md).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

"${LUA:-lua}" "$root/tests/widgets.lua" "$root/sketchybar"
"${LUA:-lua}" "$root/tests/statwell.lua" "$root/sketchybar"
"${PYTHON:-python3}" "$root/tests/media_test.py"
"${PYTHON:-python3}" "$root/tests/brew_action_test.py"

# This acceptance check needs the user's running bar and creates temporary items.
if [[ "${SKETCHYBAR_LIVE_TESTS:-0}" == "1" ]]; then
  "${PYTHON:-python3}" "$root/tests/network_geometry_test.py"
fi
