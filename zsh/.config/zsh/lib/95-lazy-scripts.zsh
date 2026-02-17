#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++ LAZY SCRIPT LOADER ++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Lazily loads functions and aliases from ~/.config/zsh/scripts/*.sh on first
# use instead of sourcing all scripts at startup.
#
# Delegates to the shared engine in 94-lazy-loader-core.zsh.
#
# ============================================================================ #
# Early exit conditions.
[[ $- == *i* ]] || return 0
[[ "${ZSH_FAST_START:-}" == "1" ]] && return 0
[[ "${ZSH_LAZY_SCRIPTS:-1}" == "1" ]] || return 0

typeset -f _lazy_loader_core >/dev/null 2>&1 || return 0

() {
  local scripts_dir="$ZSH_CONFIG_DIR/scripts"
  [[ -d "$scripts_dir" ]] || return 0

  local -a scripts=("$scripts_dir"/*.sh(N))
  (( ${#scripts} )) || return 0

  _lazy_loader_core "scripts" 5 "auto" "${scripts[@]}"
}

# ============================================================================ #
# # End of 95-lazy-scripts.zsh
