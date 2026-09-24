#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
#   █████╗ ██╗   ██╗████████╗ ██████╗      ██████╗ ██████╗ ███╗   ███╗██████╗
#  ██╔══██╗██║   ██║╚══██╔══╝██╔═══██╗    ██╔════╝██╔═══██╗████╗ ████║██╔══██╗
#  ███████║██║   ██║   ██║   ██║   ██║    ██║     ██║   ██║██╔████╔██║██████╔╝
#  ██╔══██║██║   ██║   ██║   ██║   ██║    ██║     ██║   ██║██║╚██╔╝██║██╔═══╝
#  ██║  ██║╚██████╔╝   ██║   ╚██████╔╝    ╚██████╗╚██████╔╝██║ ╚═╝ ██║██║
#  ╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝      ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝
# ============================================================================ #
# ++++++++++++++++++++++++++++ COMPLETION SYSTEMS ++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Shell completion initialization for various tools.
# Completions enhance command-line productivity with tab-completion support.
#
# Tools:
#   - Bun (JavaScript runtime)
#   - Docker (custom completion directory)
#   - ngrok
#   - Angular CLI
#
# Note: This module must load LATE to ensure all PATH modifications are complete.
# ============================================================================ #

typeset -f _zsh_cache_is_fresh >/dev/null 2>&1 ||
  source "${${(%):-%N}:A:h:h}/runtime-helpers.zsh"

# -----------------------------------------------------------------------------
# _cache_completion
# @internal
# @description Loads the completion script a command prints about itself
# through _zsh_cached_init, so the cache follows the installed executable
# (an upgrade regenerates it) instead of expiring on a timer.
# @arg $1 string Command name (e.g. "ngrok", "ng").
# @arg $@ string Arguments that make the command print its zsh completion.
# @exitcode 1 If the command is missing or prints nothing usable.
# @example
#   _cache_completion ng completion script
# -----------------------------------------------------------------------------
_cache_completion() {
  local cmd="$1"
  shift
  (( $+commands[$cmd] )) || return 1
  _zsh_cached_init "completion-$cmd" "${commands[$cmd]}" "$@"
}

# -----------------------------------------------------------------------------
# _zsh_custom_completion
# @internal
# @description Completes a custom command from pre-generated `_arguments`
# specifications; performs no filesystem scans or external commands.
# @noargs
# -----------------------------------------------------------------------------
_zsh_custom_completion() {
  # Completion functions must preserve the option state prepared by compinit.
  # In particular, resetting to native emulation re-enables NOMATCH and makes
  # fzf-tab evaluate internal tags such as `*:globbed-files` as shell globs.
  setopt localoptions
  local command_name="${service:-${words[1]:-}}"
  local packed="${_ZSH_CUSTOM_COMPLETION_SPECS[$command_name]-}"
  [[ -n "$packed" ]] || return 1

  local -a specs=("${(@ps:\x1f:)packed}")
  _arguments -s -S "${specs[@]}"
}

# -----------------------------------------------------------------------------
# _zsh_register_custom_completions
# @internal
# @description Registers generated completion data without replacing a more
# specific completion already provided by Zsh or a third-party tool.
# @noargs
# -----------------------------------------------------------------------------
_zsh_register_custom_completions() {
  emulate -L zsh
  local -a previous=("${_ZSH_CUSTOM_COMPLETION_REGISTERED[@]}")
  local command_name existing

  for command_name in "${previous[@]}"; do
    if (( ${_ZSH_CUSTOM_COMPLETION_COMMANDS[(Ie)$command_name]} == 0 )) &&
        [[ "${_comps[$command_name]-}" == _zsh_custom_completion ]]; then
      unset "_comps[$command_name]"
    fi
  done

  typeset -ga _ZSH_CUSTOM_COMPLETION_REGISTERED=()
  for command_name in "${_ZSH_CUSTOM_COMPLETION_COMMANDS[@]}"; do
    existing="${_comps[$command_name]-}"
    if [[ -z "$existing" || "$existing" == _default ||
          "$existing" == _zsh_custom_completion ]]; then
      compdef _zsh_custom_completion "$command_name"
      _ZSH_CUSTOM_COMPLETION_REGISTERED+=("$command_name")
    fi
  done
}

# -----------------------------------------------------------------------------
# _zsh_load_custom_completions
# @internal
# @description Rebuilds the secure shdoc completion cache when source metadata
# changes, then loads and registers it after compinit.
# @noargs
# -----------------------------------------------------------------------------
_zsh_load_custom_completions() {
  emulate -L zsh
  setopt localoptions no_aliases pipefail extendedglob
  [[ "${ZSH_CUSTOM_COMPLETIONS:-1}" == "1" ]] || return 0

  local default_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"
  local config_dir="${ZSH_CUSTOM_COMPLETION_CONFIG_DIR:-\
${ZSH_CONFIG_DIR:-$default_config_dir}}"
  local generator="$config_dir/scripts/generate-zsh-completions.zsh"
  local indexer="$config_dir/scripts/zfuncs-index.awk"
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/completions"
  local cache_file="$cache_dir/_custom-functions-v1"
  local -a source_files signature_files signature_parts
  local file cached_header="" generated payload
  local expected_header
  local -i rebuild=0
  local -A stat_info

  [[ -r "$generator" && -r "$indexer" ]] || return 1
  source_files=(
    "$config_dir"/functions/*.zsh(N.)
    "$config_dir"/lib/*.zsh(N.)
    "$config_dir"/scripts/**/*.sh(N.)
    "$config_dir"/scripts/**/*.zsh(N.)
  )
  (( ${#source_files[@]} )) || return 1
  signature_files=("${source_files[@]}" "$generator" "$indexer")

  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  for file in "${signature_files[@]}"; do
    stat_info=()
    zstat -L -H stat_info -- "$file" 2>/dev/null || return 1
    signature_parts+=("${file:A}:${stat_info[mtime]}:${stat_info[size]}")
  done
  expected_header="# zsh-custom-completions-v1 ${(j:|:)signature_parts}"

  if _zsh_is_secure_file "$cache_file"; then
    IFS= read -r cached_header < "$cache_file" 2>/dev/null ||
      cached_header=""
    [[ "$cached_header" == "$expected_header" ]] || rebuild=1
  else
    rebuild=1
  fi

  if (( rebuild )); then
    generated="$(command zsh "$generator" "$config_dir")" || generated=""
    if [[ -n "$generated" ]]; then
      payload="${expected_header}"$'\n'"${generated}"$'\n'
      if print -rn -- "$payload" | command zsh -dfn &&
          print -rn -- "$payload" | _zsh_cache_put "$cache_file"; then
        cached_header="$expected_header"
      else
        print -u2 "Custom completion cache generation failed validation."
      fi
    fi

    if [[ "$cached_header" != "$expected_header" ]] &&
        ! _zsh_is_secure_file "$cache_file"; then
      return 1
    fi
  fi

  _zsh_is_secure_file "$cache_file" || return 1
  source "$cache_file" || return 1
  (( ${#_ZSH_CUSTOM_COMPLETION_COMMANDS[@]} )) || return 1
  _zsh_register_custom_completions
}

# -----------------------------------------------------------------------------
# _late_completions
# @internal
# @description Loads generated shdoc completions, sources bun's completion
# script, and caches ngrok/ng completions, all after startup; unregisters
# itself once done.
# @noargs
# -----------------------------------------------------------------------------
_late_completions() {
  _zsh_load_custom_completions ||
    print -u2 "Custom shdoc completions could not be loaded."
  if [[ -s "$HOME/.bun/_bun" ]]; then
    source "$HOME/.bun/_bun"
  fi
  # ngrok picks the script flavor from $SHELL; pin it so a shell started
  # from bash (or an IDE) does not cache the bash script.
  SHELL="${commands[zsh]:-zsh}" _cache_completion ngrok completion
  _cache_completion ng completion script
  unfunction _late_completions 2>/dev/null
}

# ------ Completion directories ------ #
# 20-zinit.zsh and HyDE's shell.zsh add these before their compinit, so this
# is a no-op for them; it is the safety net for the OMZ fallback. ZDOTDIR
# points at $HOME, so the repository completions resolve through the config
# directory.
typeset -i _completion_fpath_changed=0
_zsh_fpath_prepend \
  "${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}/completions" \
  "$HOME/.docker/completions" && _completion_fpath_changed=1

autoload -Uz compinit
typeset -a compinit_opts
compinit_opts=(-d "$ZSH_COMPDUMP")
if [[ "$ZSH_DISABLE_COMPFIX" == true ]]; then
  compinit_opts=(-u $compinit_opts)
fi

# Avoid double compinit (20-zinit.zsh usually already ran it).
if (( ! ${+_comps} )); then
  # Use -C only if the dump file exists, otherwise do a full init.
  if [[ -f "$ZSH_COMPDUMP" ]]; then
    compinit -C "${compinit_opts[@]}"
  else
    compinit "${compinit_opts[@]}"
  fi
elif (( _completion_fpath_changed )); then
  # fpath changed after compinit: rebuild completion map to include new dirs.
  compinit "${compinit_opts[@]}"
fi
unset compinit_opts _completion_fpath_changed

# Fabric patterns live behind one namespaced command. Register its specialized
# completer before generic shdoc completions are loaded, so pattern names are
# offered without creating hundreds of global wrapper functions.
if (( $+functions[_fabric_pattern_completion] )); then
  compdef _fabric_pattern_completion fabric-pattern
fi

# Generate command-specific metadata only after compinit defines compdef. The
# default deferred path keeps signature checks and awk outside prompt startup.
if [[ "${ZSH_FAST_START:-}" == "1" ]]; then
  :
elif [[ "${ZSH_DEFER_COMPLETIONS:-1}" == "1" ]] &&
    typeset -f _zsh_defer >/dev/null 2>&1; then
  _zsh_defer _late_completions
else
  _late_completions
fi

# ============================================================================ #
# End of lib/85-completions.zsh
