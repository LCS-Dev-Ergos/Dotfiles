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

# HyDE adds the user completion directory before this module runs. Keep loading
# generated metadata, but do not add that directory to fpath a second time.
if [[ "$HYDE_ENABLED" == "1" ]]; then
  HYDE_SKIP_FPATH_COMPLETIONS=1
fi

# -----------------------------------------------------------------------------
# _cache_completion
# @internal
# @description Sources a cached completion script, regenerating it under
# ${XDG_CACHE_HOME:-$HOME/.cache}/zsh/completions/_<cmd> when missing or
# older than 7 days.
# @arg $1 string Command name (e.g. "ngrok", "ng").
# @arg $@ string Generation command (e.g. ngrok completion).
# @example
#   _cache_completion "ngrok" "ngrok completion"
#   _cache_completion "ng" "ng completion script"
# -----------------------------------------------------------------------------
_cache_completion() {
  local cmd="$1"
  shift
  local -a generate_cmd=("$@")
  local cache_file="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/completions/_$cmd"
  # Check if cache exists, is safe, and is less than 7 days old.
  if _zsh_cache_is_fresh "$cache_file" 604800; then
    source "$cache_file"
    return
  elif [[ -f "$cache_file" ]] && ! _zsh_is_secure_file "$cache_file"; then
    print -u2 "Completion cache skipped (insecure file): $cache_file"
  fi

  # Generate completion.
  local cache_dir="${cache_file:h}"
  local tmp_file=""
  mkdir -p "$cache_dir"

  tmp_file="$(mktemp "${cache_dir}/.${cmd}.XXXXXX" 2>/dev/null)" || return 1
  if "${generate_cmd[@]}" >"$tmp_file" 2>/dev/null; then
    chmod 600 "$tmp_file" 2>/dev/null || :
    mv -f "$tmp_file" "$cache_file"
  else
    rm -f -- "$tmp_file" 2>/dev/null
    return 1
  fi

  _zsh_is_secure_file "$cache_file" && source "$cache_file"
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

  zmodload -i zsh/stat 2>/dev/null || return 1
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
  if command -v ngrok >/dev/null 2>&1; then
    _cache_completion ngrok ngrok completion
  fi
  if command -v ng >/dev/null 2>&1; then
    _cache_completion ng ng completion script
  fi
  unfunction _late_completions 2>/dev/null
}

# ----------- Docker CLI  ------------ #
# Add custom completions directories (unless HyDE already did it).
typeset -i _completion_fpath_changed=0
if [[ "${HYDE_SKIP_FPATH_COMPLETIONS:-0}" != "1" ]]; then
  # ZDOTDIR points at $HOME, not the XDG config tree, so the repository
  # completions must be resolved through the config directory instead.
  local _completions_dir="${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}/completions"
  if [[ -d "$_completions_dir" ]] && (( ${fpath[(Ie)$_completions_dir]} == 0 )); then
    fpath=("$_completions_dir" $fpath)
    _completion_fpath_changed=1
  fi
  unset _completions_dir
fi

# Docker completions (always check, as HyDE doesn't add this).
local _docker_completions_dir="$HOME/.docker/completions"
if [[ -d "$_docker_completions_dir" ]] && (( ${fpath[(Ie)$_docker_completions_dir]} == 0 )); then
  fpath=("$_docker_completions_dir" $fpath)
  _completion_fpath_changed=1
fi
unset _docker_completions_dir

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
