#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++++++ RELOAD TEST ++++++++++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies functions/core.zsh's reload: sourcing it removes a framework/plugin
# reload alias in favor of the canonical function, unexpected arguments return
# exit status 2, and a fast-start .zshrc sourced in isolation exits 0.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail

typeset test_root="${0:A:h:h}"

alias reload='source ~/.zshrc'
source "$test_root/functions/core.zsh"

(( ${+aliases[reload]} == 0 )) || {
  print -u2 "FAIL: canonical reload did not remove the plugin alias"
  return 1
}
typeset -f reload >/dev/null 2>&1 || {
  print -u2 "FAIL: canonical reload function is unavailable"
  return 1
}

typeset -i reload_rc=0
reload unexpected >/dev/null 2>&1 || reload_rc=$?
(( reload_rc == 2 )) || {
  print -u2 "FAIL: reload accepted unexpected arguments"
  return 1
}

typeset source_status
source_status="$(
    ZSH_FAST_START=1 \
    ZSH_CONFIG_DIR="$test_root" \
    DOTFILES_ZSH_ROOT="${test_root:h}" \
    zsh -dfi -c \
    'source "$DOTFILES_ZSH_ROOT/zshrc"; print -r -- "$?"' \
    </dev/null
)" || {
  print -u2 "FAIL: fast-start reload smoke test could not run"
  return 1
}
[[ "${source_status##*$'\n'}" == 0 ]] || {
  print -u2 "FAIL: sourcing .zshrc returned a failure status"
  return 1
}

print -r -- "PASS: clean reload function and successful .zshrc status"

# ============================================================================ #
# End of tests/test-reload.zsh
