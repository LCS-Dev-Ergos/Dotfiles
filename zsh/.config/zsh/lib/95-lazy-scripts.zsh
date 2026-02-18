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

  # Generic scripts (auto-mapped by definition file).
  _lazy_loader_core "scripts" 6 "auto" "${scripts[@]}"

  # VS Code sync commands live in modular subfiles; map their stubs to the
  # legacy wrapper so module bootstrap runs before command execution.
  local vscode_sync_wrapper="$scripts_dir/vscode_sync.sh"
  local vscode_sync_commands="$scripts_dir/vscode/sync/commands.sh"
  if [[ -r "$vscode_sync_wrapper" && -r "$vscode_sync_commands" ]]; then
    _lazy_loader_core "vscode-sync" 1 "$vscode_sync_wrapper" "$vscode_sync_commands"
  fi

  # VS Code extension-cleaner functions also live in a modular subfile; map
  # lazy stubs to the wrapper to preserve existing entrypoint behavior.
  local vscode_cleaner_wrapper="$scripts_dir/vscode_extension_cleaner.sh"
  local vscode_cleaner_module="$scripts_dir/vscode/extension_cleaner.sh"
  if [[ -r "$vscode_cleaner_wrapper" && -r "$vscode_cleaner_module" ]]; then
    _lazy_loader_core "vscode-ext-cleaner" 1 "$vscode_cleaner_wrapper" "$vscode_cleaner_module"
  fi
}

# ============================================================================ #
# # End of 95-lazy-scripts.zsh
