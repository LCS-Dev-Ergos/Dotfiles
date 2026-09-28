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
"${PYTHON:-python3}" "$root/tests/media_test.py"
"${PYTHON:-python3}" "$root/tests/brew_action_test.py"
