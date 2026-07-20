#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++ CPP-TOOLS TEST SUITE +++++++++++++++++++++++++++ #
# ============================================================================ #
# Focused regression tests for UI modes, command contracts, exit statuses,
# workspace boundaries, and filesystem safety. All writes stay in a validated
# temporary directory below this test folder.
# ============================================================================ #

emulate -L zsh
setopt pipefail

typeset test_dir="${0:A:h}"
typeset project_root="${test_dir:h}"
typeset test_tmp
test_tmp=$(mktemp -d "$test_dir/.tmp.XXXXXX") || {
  print -u2 -r -- "FAIL: unable to create the test directory"
  exit 1
}

_cleanup_cpp_tools_tests() {
  [[ "$test_tmp" == "$test_dir"/.tmp.* ]] || return 1
  rm -rf -- "$test_tmp"
}
trap _cleanup_cpp_tools_tests EXIT INT TERM HUP

typeset -i assertions=0

_assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$actual" != "$expected" ]]; then
    print -u2 -r -- \
      "FAIL: $label (expected '$expected', received '$actual')"
    exit 1
  fi
  (( ++assertions ))
}

_assert_contains() {
  local value="$1" expected="$2" label="$3"
  if [[ "$value" != *"$expected"* ]]; then
    print -u2 -r -- "FAIL: $label (missing '$expected')"
    exit 1
  fi
  (( ++assertions ))
}

_assert_not_contains() {
  local value="$1" rejected="$2" label="$3"
  if [[ "$value" == *"$rejected"* ]]; then
    print -u2 -r -- "FAIL: $label (unexpected '$rejected')"
    exit 1
  fi
  (( ++assertions ))
}

typeset workspace="$test_tmp/workspace"
typeset outside="$test_tmp/workspace-escape"
mkdir -p "$workspace/Algorithms" "$outside"

export TMPDIR="$test_tmp"
export TMPPREFIX="$test_tmp/zsh"
export CP_WORKSPACE_ROOT="$workspace"
export CP_ALGORITHMS_DIR="$workspace/Algorithms"
export CP_QUIET_LOAD=1
export CP_UI_STYLE=plain
unset NO_COLOR CP_NO_GUM
unset GUM_SPIN_SPINNER_FOREGROUND GUM_SPIN_TITLE_FOREGROUND
unset GUM_CONFIRM_PROMPT_FOREGROUND GUM_CONFIRM_SELECTED_BACKGROUND
unset GUM_CHOOSE_CURSOR_FOREGROUND GUM_CHOOSE_HEADER_FOREGROUND

source "$project_root/competitive.sh" || {
  print -u2 -r -- "FAIL: unable to source competitive.sh"
  exit 1
}

# UI mode resolution and environment isolation.
_assert_eq "plain" "$(_cp_ui_mode plain)" "plain UI mode"
_assert_eq "ansi" "$(_cp_ui_mode ansi)" "ANSI UI mode"

CP_UI_STYLE=invalid
_cp_ui_mode >/dev/null 2>&1
_assert_eq "2" "$?" "invalid UI mode status"

CP_UI_STYLE=gum
CP_NO_GUM=1
_assert_eq "ansi" "$(_cp_ui_mode)" "Gum fallback mode"
unset CP_NO_GUM

NO_COLOR=1
_assert_eq "plain" "$(_cp_ui_mode gum)" "NO_COLOR override"
unset NO_COLOR
CP_UI_STYLE=plain

_assert_eq "0" "${+parameters[GUM_SPIN_TITLE_FOREGROUND]}" \
  "Gum spinner environment isolation"
_assert_eq "0" "${+parameters[GUM_CONFIRM_PROMPT_FOREGROUND]}" \
  "Gum confirmation environment isolation"

_cp_ui_sanitize_text $'safe\e]8;;bad\a'
_assert_not_contains "$REPLY" $'\e' "terminal control sanitization"
_assert_contains "$REPLY" '\x1b' "escaped terminal control marker"

# The help page must be complete, plain-safe, and backed by one registry.
typeset help_output
help_output="$(COLUMNS=80 cpphelp)"
_assert_not_contains "$help_output" $'\e' "plain help escape safety"
_assert_contains "$help_output" "CPP-TOOLS" "help title"
_assert_contains "$help_output" "Workspace" "help workspace section"

typeset help_line
help_output="$(COLUMNS=110 cpphelp)"
for help_line in "${(@f)help_output}"; do
  if (( ${#help_line} > 110 )); then
    print -u2 -r -- "FAIL: responsive help width (${#help_line} columns)"
    exit 1
  fi
done
(( ++assertions ))

typeset help_row help_command
typeset -a help_fields
for help_row in "${_CP_HELP_ROWS[@]}"; do
  help_fields=("${(@ps:\t:)help_row}")
  help_command="${help_fields[2]-}"
  _assert_contains "$help_output" "$help_command" \
    "help registry command $help_command"
done

cpphelp unexpected >/dev/null 2>&1
_assert_eq "64" "$?" "help argument validation"

typeset entrypoint_output
entrypoint_output=$(CP_QUIET_LOAD=1 CP_UI_STYLE=plain \
  CP_WORKSPACE_ROOT="$workspace" \
  CP_ALGORITHMS_DIR="$workspace/Algorithms" \
  zsh "$project_root/cpptools" help)
_assert_eq "0" "$?" "help entrypoint status"
_assert_contains "$entrypoint_output" "CPP-TOOLS" "help entrypoint output"

CP_QUIET_LOAD=1 CP_UI_STYLE=plain \
  CP_WORKSPACE_ROOT="$workspace" \
  CP_ALGORITHMS_DIR="$workspace/Algorithms" \
  zsh "$project_root/cpptools" unsupported >/dev/null 2>&1
_assert_eq "64" "$?" "entrypoint command validation"
CP_QUIET_LOAD=1 CP_UI_STYLE=invalid \
  CP_WORKSPACE_ROOT="$workspace" \
  CP_ALGORITHMS_DIR="$workspace/Algorithms" \
  zsh "$project_root/cpptools" help >/dev/null 2>&1
_assert_eq "70" "$?" "entrypoint initialization failure status"

if (( $+commands[gum] )); then
  CP_UI_STYLE=gum
  help_output="$(COLUMNS=90 cpphelp)"
  _assert_contains "$help_output" "CPP-TOOLS" "Gum help heading"
  _assert_not_contains "$help_output" "╭" "borderless Gum help"
  CP_UI_STYLE=plain
fi

# Shared helpers must preserve command and confirmation status.
typeset spin_output
spin_output="$(_cp_spin "probe" zsh -fc 'print -r -- payload; exit 7')"
_assert_eq "7" "$?" "spinner command status"
_assert_eq "payload" "$spin_output" "spinner command output"

if (( $+commands[gum] )); then
  CP_UI_STYLE=gum
  spin_output="$(_cp_spin \
    "Gum probe" zsh -fc 'print -r -- gum-payload; exit 8' \
    2>/dev/null)"
  _assert_eq "8" "$?" "Gum spinner command status"
  _assert_eq "gum-payload" "$spin_output" "Gum spinner output capture"
  CP_UI_STYLE=plain
fi

_cp_confirm "continue" yes </dev/null
_assert_eq "0" "$?" "non-interactive affirmative default"
_cp_confirm "continue" no </dev/null
_assert_eq "1" "$?" "non-interactive negative default"

# Banner colors are resolved at call time, including after a style change.
CP_UI_STYLE=ansi
typeset banner_output="$(_cp_rule "probe" cyan)"
_assert_contains "$banner_output" $'\e[36m' "dynamic ANSI banner color"
NO_COLOR=1
banner_output="$(_cp_rule "probe" cyan)"
_assert_not_contains "$banner_output" $'\e' "dynamic plain banner color"
unset NO_COLOR
CP_UI_STYLE=plain

# Workspace checks must use physical path boundaries, including symlinks.
cd "$workspace" || exit 1
_check_workspace >/dev/null 2>&1
_assert_eq "0" "$?" "workspace root acceptance"

cd "$outside" || exit 1
_check_workspace >/dev/null 2>&1
_assert_eq "1" "$?" "workspace sibling rejection"

ln -s "$outside" "$workspace/outside-link"
cd "$workspace/outside-link" || exit 1
_check_workspace >/dev/null 2>&1
_assert_eq "1" "$?" "workspace symlink escape rejection"

cd "$workspace" || exit 1
cppcontest ../forbidden >/dev/null 2>&1
_assert_eq "64" "$?" "contest parent traversal rejection"
[[ ! -e "$test_tmp/forbidden" ]]
_assert_eq "0" "$?" "contest traversal leaves no directory"

cppcontest outside-link/new-contest >/dev/null 2>&1
_assert_eq "1" "$?" "contest symlink traversal rejection"
[[ ! -e "$outside/new-contest" ]]
_assert_eq "0" "$?" "symlink traversal leaves no directory"

# Relative symlink creation and template rendering remain portable and atomic.
mkdir -p "$CP_ALGORITHMS_DIR/templates/cpp"
print -r -- '// __FILE_NAME__ :: __PROBLEM_BRIEF__' \
  > "$CP_ALGORITHMS_DIR/templates/cpp/base.cpp"
touch CMakeLists.txt
_cp_link_relative_or_absolute \
  "$CP_ALGORITHMS_DIR/templates" "$workspace/template-link"
_assert_eq "0" "$?" "relative symlink creation"
[[ -L "$workspace/template-link" && -d "$workspace/template-link" ]]
_assert_eq "0" "$?" "relative symlink target resolution"

cppnew 'demo&case' base --no-config >/dev/null 2>&1
_assert_eq "0" "$?" "atomic problem template rendering"
typeset generated_source="$(<demo\&case.cpp)"
_assert_contains "$generated_source" 'demo&case.cpp' \
  "template filename substitution"
_assert_not_contains "$generated_source" '__FILE_NAME__' \
  "template placeholder removal"

cppnew unsupported unknown --no-config >/dev/null 2>&1
_assert_eq "1" "$?" "unknown template rejection"
[[ ! -e unsupported.cpp ]]
_assert_eq "0" "$?" "unknown template leaves no source"
cppnew one base extra >/dev/null 2>&1
_assert_eq "64" "$?" "problem creation argument validation"

(
  cppnew() { [[ "$1" != problem_B ]]; }
  cppconf() { return 0; }
  cppbatch 2 base >/dev/null 2>&1
)
_assert_eq "1" "$?" "batch partial failure propagation"
cppbatch 2 base extra >/dev/null 2>&1
_assert_eq "64" "$?" "batch argument validation"

# Active build metadata must not select absolute or parent-relative paths.
mkdir -p .statistics "$outside/cache"
touch "$outside/cache/CMakeCache.txt"
print -r -- "$outside/cache" > .statistics/active_build_dir
_cp_get_active_build_dir >/dev/null 2>&1
_assert_eq "1" "$?" "absolute active build rejection"

print -r -- "../workspace-escape/cache" > .statistics/active_build_dir
_cp_get_active_build_dir >/dev/null 2>&1
_assert_eq "1" "$?" "parent-relative active build rejection"

mkdir -p build/gcc/debug
touch build/gcc/debug/CMakeCache.txt CMakeLists.txt
print -r -- "build/gcc/debug" > .statistics/active_build_dir
_assert_eq "build/gcc/debug" "$(_cp_get_active_build_dir)" \
  "valid active build selection"

# Invalid cleanup arguments must not mutate the project.
touch build/gcc/debug/keep
cppclean --invalid >/dev/null 2>&1
_assert_eq "64" "$?" "clean argument validation"
[[ -e build/gcc/debug/keep ]]
_assert_eq "0" "$?" "invalid clean preserves artifacts"

cppclean --yes >/dev/null 2>&1
_assert_eq "0" "$?" "non-interactive clean"
[[ ! -e build ]]
_assert_eq "0" "$?" "clean removes build artifacts"

# Runtime workflows must no longer mask program failures.
(
  _check_initialized() { return 0; }
  cppbuild() { return 0; }
  _run_with_timeout() { return 7; }
  cppgo demo >/dev/null 2>&1
)
_assert_eq "7" "$?" "cppgo runtime status propagation"

(
  _check_initialized() { return 0; }
  cppbuild() { return 0; }
  _run_with_timeout() { return 1; }
  cppstress demo 2 >/dev/null 2>&1
)
_assert_eq "1" "$?" "cppstress failure status propagation"

cppstress demo 2 extra >/dev/null 2>&1
_assert_eq "64" "$?" "cppstress argument validation"

# Archive failures must be reported instead of printing a false success.
(
  cd "$workspace" || exit 1
  touch CMakeLists.txt
  tar() { return 1; }
  cpparchive >/dev/null 2>&1
)
_assert_eq "1" "$?" "archive failure propagation"

# Submission parsers reject unsupported options before doing any work.
mkdir -p build/gcc/debug
touch build/gcc/debug/CMakeCache.txt
print -r -- "build/gcc/debug" > .statistics/active_build_dir
cppsubmit --unknown >/dev/null 2>&1
_assert_eq "64" "$?" "submission option validation"
cpptestsubmit --unknown >/dev/null 2>&1
_assert_eq "64" "$?" "submission-test option validation"
cppcheck unexpected >/dev/null 2>&1
_assert_eq "64" "$?" "health-check argument validation"
cppdiag unexpected >/dev/null 2>&1
_assert_eq "64" "$?" "diagnostic argument validation"

# Submission generation assembles a complete file before replacing its target.
mkdir -p "$CP_ALGORITHMS_DIR/scripts"
print -r -- \
  'import pathlib, sys; print(pathlib.Path(sys.argv[1]).read_text())' \
  > "$CP_ALGORITHMS_DIR/scripts/flattener.py"
print -r -- 'int main() { return 0; }' > demo.cpp
(
  _verify_submission_compilation() { return 0; }
  _offer_clipboard_copy() { return 0; }
  cppsubmit demo >/dev/null 2>&1
)
_assert_eq "0" "$?" "atomic submission generation"
typeset generated_submission="$(<submissions/demo_sub.cpp)"
_assert_contains "$generated_submission" 'int main()' \
  "generated submission content"

# A submission runtime failure must make the complete test command fail.
mkdir -p submissions input_cases
touch submissions/demo_sub.cpp input_cases/demo.in
(
  _cp_find_gxx() { print -r -- /usr/bin/true; }
  _run_with_timeout() { return 9; }
  cpptestsubmit --no-generate demo demo.in >/dev/null 2>&1
)
_assert_eq "1" "$?" "submission runtime status propagation"

(( ${+functions[_cppdiag_header]} == 0 ))
_assert_eq "0" "$?" "diagnostic helper namespace isolation"

# Syntax validation covers every maintained Zsh source.
typeset -a syntax_files=(
  "$project_root/competitive.sh"
  "$project_root/cpptools"
  "$project_root"/modules/*.zsh(N)
  "$project_root"/tests/*.zsh(N)
)
zsh -n "${syntax_files[@]}"
_assert_eq "0" "$?" "Zsh syntax validation"

print -r -- "PASS: $assertions cpp-tools assertions"

# ============================================================================ #
# End of tests/run.zsh
