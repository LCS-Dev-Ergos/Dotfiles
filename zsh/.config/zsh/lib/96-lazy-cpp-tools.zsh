#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++ LAZY CPP-TOOLS LOADER +++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Lazily loads functions and aliases from ~/.config/cpp-tools/competitive.sh
# on first use, avoiding heavy startup cost.
#
# Controlled by:
#   ZSH_LAZY_CPP_TOOLS=1   (default: enabled)
#
# Delegates to the shared engine in 94-lazy-loader-core.zsh.
#
# ============================================================================ #
# Early exit conditions.
[[ $- == *i* ]] || return 0
[[ "${ZSH_FAST_START:-}" == "1" ]] && return 0
[[ "${ZSH_LAZY_CPP_TOOLS:-1}" == "1" ]] || return 0

typeset -f _lazy_loader_core >/dev/null 2>&1 || return 0

() {
  local main_script="$HOME/.config/cpp-tools/competitive.sh"
  [[ -r "$main_script" ]] || return 0

  local -a scan_files=("$main_script")
  local mod_dir="${main_script:h}/modules"
  [[ -d "$mod_dir" ]] && scan_files+=("$mod_dir"/*.zsh(N))

  _lazy_loader_core "cpp-tools" 6 "$main_script" "${scan_files[@]}"
}

# Last consumer of the core engine -- clean it up.
unfunction _lazy_loader_core 2>/dev/null

# ============================================================================ #
# # End of 96-lazy-cpp-tools.zsh
