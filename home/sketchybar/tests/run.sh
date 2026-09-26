#!/bin/bash
# Regression checks for the SketchyBar helpers and Lua widgets.
#
# Usage: bash home/sketchybar/tests/run.sh
# Honours CC, LUA and PYTHON. The native display patch is checked by
# display_reconcile_test.py in the package build; window_order.m needs the
# running GUI session and is run by hand (see helpers/README.md).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

# brew_check must run brew without auto-update; this fake fails otherwise.
cat >"$test_dir/brew" <<'BREW'
#!/bin/sh
[ "$HOMEBREW_NO_AUTO_UPDATE" = 1 ] || exit 90
exit 0
BREW
chmod +x "$test_dir/brew"

cc=${CC:-clang}
"$cc" -std=c2x -O0 "$root/tests/brew_check.c" -o "$test_dir/brew-test"
"$test_dir/brew-test" "$test_dir/brew"

"${LUA:-lua}" "$root/tests/widgets.lua" "$root/sketchybar"
"${PYTHON:-python3}" "$root/tests/media_test.py"
"${PYTHON:-python3}" "$root/tests/brew_action_test.py"
