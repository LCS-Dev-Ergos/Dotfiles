#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cat > "$test_dir/brew" <<'BREW'
#!/bin/sh
[ "$HOMEBREW_NO_AUTO_UPDATE" = 1 ] || exit 90
exit 0
BREW
chmod +x "$test_dir/brew"
"${CC:-clang}" -std=c2x -O0 "$root/tests/brew_check.c" -o "$test_dir/brew-test"
"$test_dir/brew-test" "$test_dir/brew"
"${LUA:-lua}" "$root/tests/widgets.lua" "$root/sketchybar"
"${PYTHON:-python3}" "$root/tests/media_test.py"
"${PYTHON:-python3}" "$root/tests/brew_action_test.py"
