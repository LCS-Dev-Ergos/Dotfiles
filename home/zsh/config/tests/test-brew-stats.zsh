#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++++ BREW_STATS TEST ++++++++++++++++++++++++++++++ #
# ============================================================================ #
# Exercises the public brew_stats interface with mocked brew/du/jq commands and
# real fixture directories: argument validation, scope filtering, sorting,
# --top, --quiet, canonical cask-alias handling, symlink-escape and cycle
# safety, cache-path validation, inventory-consistency re-checks, and render
# failures. No installed packages or network access are used.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail extendedglob
umask 077

typeset test_root="${0:A:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir brew-stats)" || return 1

_brew_stats_test_cleanup() {
  [[ -n "${fixture_root:-}" ]] && command rm -rf -- "$fixture_root"
}
trap _brew_stats_test_cleanup EXIT
trap 'exit 130' INT TERM HUP

export ZSH_CONFIG_DIR="$test_root"
export ZSH_UI_STYLE=plain
source "$test_root/runtime-helpers.zsh"
PLATFORM=macOS
ARCH_LINUX=false
source "$test_root/functions/package-management.zsh"
typeset -f brew_stats >/dev/null || {
  print -u2 "FAIL: brew_stats is not defined on macOS"
  return 1
}

# @internal
# @description Finds an exact package row in rendered table output.
_test_line_of() {
  local -a lines=("${(f)1}") fields
  local -i index
  for (( index = 1; index <= ${#lines[@]}; index++ )); do
    fields=("${(z)lines[index]}")
    [[ "${fields[1]-}" == "$2" ]] && {
      print -r -- "$index"
      return 0
    }
  done
  return 1
}

# @internal
# @description Requires a substring in command output.
_test_contains() {
  [[ "$1" == *"$2"* ]] && return 0
  print -u2 "FAIL: $3"
  print -u2 "$1"
  return 1
}

# ----- Filesystem fixture ----------------------------------------------------
typeset cellar="$fixture_root/Cellar"
typeset caskroom="$fixture_root/Caskroom"
typeset cache="$fixture_root/cache"
typeset external="$fixture_root/external"
typeset real_du="${commands[du]}"
command mkdir -p -- \
  "$cellar/pkg-small" "$cellar/pkg-large" \
  "$caskroom/caskA/.metadata" "$cache" "$external/formula-data" \
  "$external/caskA.app/Contents"

# Exact block multiples keep allocated-size expectations deterministic.
command dd if=/dev/zero of="$cellar/pkg-small/f" bs=1024 count=8 2>/dev/null
command dd if=/dev/zero of="$cellar/pkg-large/f" bs=1024 count=200 2>/dev/null
command dd if=/dev/zero of="$caskroom/caskA/f" bs=1024 count=40 2>/dev/null
command dd if=/dev/zero \
  of="$external/formula-data/large" bs=1024 count=1024 2>/dev/null
command dd if=/dev/zero \
  of="$external/caskA.app/Contents/f" bs=1024 count=64 2>/dev/null

# Formula links stay excluded. Cask artifacts are included once despite nested
# links, an application-bundle cycle, and a renamed-cask alias.
command ln -s -- "$external/formula-data" "$cellar/pkg-small/external"
command ln -s -- "$external/caskA.app" "$caskroom/caskA/caskA.app"
command ln -s -- \
  "$external/caskA.app/Contents" "$caskroom/caskA/caskA-contents"
command ln -s -- . "$external/caskA.app/Contents/cycle"
command ln -s -- caskA "$caskroom/cask-old"
print -r -- '{}' >| "$caskroom/caskA/.metadata/config.json"
command chmod 600 "$caskroom/caskA/.metadata/config.json"

# ----- Command adapters ------------------------------------------------------
typeset mock_bin="$fixture_root/bin"
typeset du_log="$fixture_root/du-calls"
typeset churn_file="$fixture_root/inventory-churn"
command mkdir -p -- "$mock_bin"
{
  print -r -- '#!/bin/sh'
  print -r -- 'case "$1" in'
  print -r -- '  --cellar) printf "%s\n" "$MOCK_CELLAR" ;;'
  print -r -- '  --caskroom) printf "%s\n" "$MOCK_CASKROOM" ;;'
  print -r -- \
    '  --cache) [ "${MOCK_CACHE_FAIL:-0}" = 1 ] && exit 9; printf "%s\n" "$MOCK_CACHE" ;;'
  print -r -- '  list)'
  print -r -- '    [ "${MOCK_LIST_FAIL:-}" = "$2" ] && exit 9'
  print -r -- '    [ "$2" = "--formula" ] && ls -1 "$MOCK_CELLAR"'
  print -r -- \
    '    [ "$2" = "--formula" ] && [ -n "${MOCK_EXTRA_FORMULA:-}" ] && printf "%s\n" "$MOCK_EXTRA_FORMULA"'
  print -r -- '    [ "$2" = "--cask" ] && ls -1 "$MOCK_CASKROOM"'
  print -r -- \
    '    [ "$2" = "--cask" ] && [ -n "${MOCK_EXTRA_CASK:-}" ] && printf "%s\n" "$MOCK_EXTRA_CASK"'
  print -r -- \
    '    if [ "${MOCK_CHURN_SCOPE:-}" = "$2" ]; then if [ -e "$MOCK_CHURN_FILE" ]; then printf "%s\n" changed-after-snapshot; else : > "$MOCK_CHURN_FILE"; fi; fi'
  print -r -- '    ;;'
  print -r -- '  *) exit 1 ;;'
  print -r -- 'esac'
} >| "$mock_bin/brew"
command chmod 700 "$mock_bin/brew"

{
  print -r -- '#!/bin/sh'
  print -r -- 'printf "call\n" >> "$MOCK_DU_LOG"'
  print -r -- \
    'case " $* " in *"${MOCK_DU_FAIL_MATCH:-__never__}"*) exit 9 ;; esac'
  print -r -- 'exec "$MOCK_REAL_DU" "$@"'
} >| "$mock_bin/du"
command chmod 700 "$mock_bin/du"

{
  print -r -- '#!/bin/sh'
  print -r -- '[ "${MOCK_JQ_FAIL:-0}" = 1 ] && exit 9'
  print -r -- 'printf "%s\n" "$MOCK_ARTIFACT_ROOT"'
} >| "$mock_bin/jq"
command chmod 700 "$mock_bin/jq"

export MOCK_CELLAR="$cellar"
export MOCK_CASKROOM="$caskroom"
export MOCK_CACHE="$cache"
export MOCK_REAL_DU="$real_du"
export MOCK_DU_LOG="$du_log"
export MOCK_ARTIFACT_ROOT="$external"
export MOCK_CHURN_FILE="$churn_file"
path=("$mock_bin" $path)
rehash

typeset formula_small_line formula_large_line cask_managed_line artifact_line
formula_small_line="$("$real_du" -sk -- "$cellar/pkg-small")"
formula_large_line="$("$real_du" -sk -- "$cellar/pkg-large")"
cask_managed_line="$("$real_du" -sk -- "$caskroom/caskA")"
artifact_line="$("$real_du" -sk -- "$external/caskA.app")"
typeset -i expected_formula_kb=$(( \
  ${formula_small_line%%[[:space:]]*} +
  ${formula_large_line%%[[:space:]]*} ))
typeset -i expected_cask_kb=$(( \
  ${cask_managed_line%%[[:space:]]*} +
  ${artifact_line%%[[:space:]]*} ))
typeset -i expected_total_kb=$(( expected_formula_kb + expected_cask_kb ))
typeset expected_formula_human="${expected_formula_kb}.0 KB"
typeset expected_cask_human="${expected_cask_kb}.0 KB"
typeset expected_total_human="${expected_total_kb}.0 KB"

# @internal
# @description Runs brew_stats with optional temporary NAME=value assignments
# and checks its status, diagnostic, and optionally its lack of partial stdout.
_test_brew_failure() {
  emulate -L zsh
  setopt localoptions extendedglob
  local -i expected_rc=$1 no_stdout=0 rc=0
  local expected="$2"
  shift 2
  if [[ "${1-}" == --no-stdout ]]; then
    no_stdout=1
    shift
  fi

  local assignment key
  while (( $# )) && [[ "$1" == [A-Za-z_][A-Za-z0-9_]#=* ]]; do
    assignment="$1"
    key="${assignment%%=*}"
    local "$assignment"
    export "$key"
    shift
  done
  [[ "${1-}" == -- ]] && shift

  local stdout_file="$fixture_root/assert.stdout"
  local stderr_file="$fixture_root/assert.stderr"
  : >| "$stdout_file"
  : >| "$stderr_file"
  brew_stats "$@" >"$stdout_file" 2>"$stderr_file" || rc=$?
  (( rc == expected_rc )) || {
    print -u2 "FAIL: expected rc=$expected_rc, got rc=$rc for: ${(j: :)@}"
    print -u2 "$(<"$stderr_file")"
    return 1
  }

  local diagnostic="$(<"$stderr_file")"
  [[ "$diagnostic" == *"$expected"* ]] || {
    print -u2 "FAIL: missing diagnostic '$expected' for: ${(j: :)@}"
    print -u2 "$diagnostic"
    return 1
  }
  (( ! no_stdout )) || [[ ! -s "$stdout_file" ]] || {
    print -u2 "FAIL: failed report emitted partial stdout"
    return 1
  }
}

# ----- Arguments and successful reports --------------------------------------
_test_brew_failure 2 'brew_stats:' -- -f -c
_test_brew_failure 2 'brew_stats:' -- --top abc
_test_brew_failure 2 'brew_stats:' -- --top 0
_test_brew_failure 2 'brew_stats:' -- --sort bogus
_test_brew_failure 2 'brew_stats:' -- --nope

typeset default_output="$(brew_stats)"
_test_contains "$default_output" 'pkg-large' \
  "default report omitted pkg-large"
_test_contains "$default_output" '200.0 KB' \
  "default report changed pkg-large's allocated size"
_test_contains "$default_output" "caskA" \
  "default report omitted the canonical cask"
_test_contains "$default_output" "Formulae: 2 ($expected_formula_human)" \
  "formula subtotal followed an external symlink"
_test_contains "$default_output" "Casks:    1 ($expected_cask_human)" \
  "canonical cask alias was counted separately"
_test_contains "$default_output" \
  "Total:    3 packages ($expected_total_human)" "grand total is wrong"
[[ "$default_output" != *cask-old* && "$default_output" != *package_name=* ]] || {
  print -u2 "FAIL: report leaked an alias or local declaration"
  return 1
}

typeset -i idx_large idx_cask idx_small
idx_large=$(_test_line_of "$default_output" pkg-large)
idx_cask=$(_test_line_of "$default_output" caskA)
idx_small=$(_test_line_of "$default_output" pkg-small)
(( idx_large < idx_cask && idx_cask < idx_small )) || {
  print -u2 "FAIL: default size order is wrong"
  return 1
}

typeset formula_only="$(brew_stats --formula -q)"
typeset cask_only="$(brew_stats --cask -q)"
! _test_line_of "$formula_only" caskA >/dev/null || {
  print -u2 "FAIL: --formula listed a cask"
  return 1
}
! _test_line_of "$cask_only" pkg-small >/dev/null &&
  ! _test_line_of "$cask_only" pkg-large >/dev/null || {
    print -u2 "FAIL: --cask listed a formula"
    return 1
  }

typeset by_name="$(brew_stats --formula --sort name -q)"
(( $(_test_line_of "$by_name" pkg-large) <
   $(_test_line_of "$by_name" pkg-small) )) || {
  print -u2 "FAIL: --sort name returned the wrong order"
  return 1
}

typeset top_quiet="$(brew_stats --top 1 -q)"
typeset package
typeset -i top_matches=0
for package in pkg-large pkg-small caskA; do
  _test_line_of "$top_quiet" "$package" >/dev/null && top_matches+=1
done
(( top_matches == 1 )) || {
  print -u2 "FAIL: --top 1 did not return exactly one package"
  return 1
}
typeset top_output="$(brew_stats --top 1)"
_test_contains "$top_output" \
  "Total:    3 packages ($expected_total_human)" \
  "--top narrowed the summary totals"
typeset quiet_output="$(brew_stats -q)"
[[ "$quiet_output" != *'Homebrew disk usage'* ]] || {
  print -u2 "FAIL: --quiet printed the summary card"
  return 1
}

# Formula measurement retains its one-process fast path.
: >| "$du_log"
brew_stats --formula -q >/dev/null
typeset -i formula_du_calls
formula_du_calls="$(command wc -l <"$du_log" | command tr -d ' ')"
(( formula_du_calls == 1 )) || {
  print -u2 "FAIL: formula measurement used $formula_du_calls du calls"
  return 1
}

# ----- Operational failures --------------------------------------------------
_test_brew_failure 1 'could not measure formula' \
  MOCK_DU_FAIL_MATCH=pkg-small -- --formula -q
_test_brew_failure 1 'installed formula inventory' \
  MOCK_LIST_FAIL=--formula -- --formula -q
_test_brew_failure 1 'installed cask inventory' \
  MOCK_LIST_FAIL=--cask -- --cask -q
_test_brew_failure 1 'formula directory is missing' \
  MOCK_EXTRA_FORMULA=missing-package -- --formula -q

typeset outside_formula="$fixture_root/outside-formula"
typeset outside_cask="$fixture_root/outside-cask"
command mkdir -p -- "$outside_formula" "$outside_cask"
command ln -s -- "$outside_formula" "$cellar/escaped-formula"
_test_brew_failure 1 'escapes the Cellar' -- --formula -q
command rm -f -- "$cellar/escaped-formula"
command ln -s -- "$outside_cask" "$caskroom/escaped-cask"
_test_brew_failure 1 'escapes the Caskroom' -- --cask -q
command rm -f -- "$caskroom/escaped-cask"

command ln -s -- "$fixture_root/missing.app" "$caskroom/caskA/broken.app"
_test_brew_failure 1 'could not measure cask' -- --cask -q
command rm -f -- "$caskroom/caskA/broken.app"
typeset untrusted_root="$fixture_root/untrusted"
command mkdir -p -- "$untrusted_root"
command ln -s -- "$untrusted_root" "$caskroom/caskA/untrusted"
_test_brew_failure 1 'could not measure cask' -- --cask -q
command rm -f -- "$caskroom/caskA/untrusted"
_test_brew_failure 1 'could not measure cask' \
  MOCK_JQ_FAIL=1 -- --cask -q
command chmod 666 "$caskroom/caskA/.metadata/config.json"
_test_brew_failure 1 'could not measure cask' -- --cask -q
command chmod 600 "$caskroom/caskA/.metadata/config.json"

command rm -f -- "$churn_file"
_test_brew_failure 1 'inventory changed' \
  MOCK_CHURN_SCOPE=--formula -- --formula -q
command rm -f -- "$churn_file"

unset NO_COLOR
typeset invalid_quiet="$(ZSH_UI_STYLE=invalid brew_stats --formula -q)"
_test_contains "$invalid_quiet" pkg-large \
  "--quiet depended on the informational UI style"
_test_brew_failure 1 'could not render' \
  ZSH_UI_STYLE=invalid -- --formula
typeset original_ui_table="${functions[_zsh_ui_table]}"
_zsh_ui_table() { return 1; }
_test_brew_failure 1 'could not render' -- --formula -q
functions[_zsh_ui_table]="$original_ui_table"

_test_brew_failure 1 'Homebrew cache' --no-stdout \
  MOCK_CACHE_FAIL=1 -- --formula
typeset invalid_cache="$fixture_root/cache-file"
print -r -- "not a directory" >| "$invalid_cache"
_test_brew_failure 1 'cache path is not a directory' \
  "MOCK_CACHE=$invalid_cache" -- --formula
typeset broken_cache="$fixture_root/broken-cache"
command ln -s -- "$fixture_root/missing-cache" "$broken_cache"
_test_brew_failure 1 'broken symlink' \
  "MOCK_CACHE=$broken_cache" -- --formula
_test_brew_failure 1 'invalid Homebrew cache path' \
  MOCK_CACHE=relative-cache -- --formula

typeset unsafe_cache="$fixture_root/"$'cache-\e[2J\nnext'
command mkdir -p -- "$unsafe_cache"
typeset unsafe_cache_output="$(MOCK_CACHE="$unsafe_cache" brew_stats --formula)"
[[ "$unsafe_cache_output" != *$'\e'* &&
   "$unsafe_cache_output" == *'cache-\x1b[2J\nnext'* ]] || {
  print -u2 "FAIL: cache path was not sanitized"
  return 1
}

# Empty inventories are a clean no-op.
typeset empty_cellar="$fixture_root/EmptyCellar"
typeset empty_caskroom="$fixture_root/EmptyCaskroom"
command mkdir -p -- "$empty_cellar" "$empty_caskroom"
MOCK_CELLAR="$empty_cellar" MOCK_CASKROOM="$empty_caskroom" \
  brew_stats -q >/dev/null 2>/dev/null

print -r -- \
  "PASS: brew_stats enforces safe snapshots, exact errors, and batch sizing"

# ============================================================================ #
# End of tests/test-brew-stats.zsh
