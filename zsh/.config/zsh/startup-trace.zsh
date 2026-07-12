#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++ ZSH STARTUP TRACE +++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Opt-in startup milestones from the first environment file to input-ready.
# Loaded only when ZSH_STARTUP_TRACE=1; .zshrc calls _zsh_startup_trace_mark
# at fixed points and _zsh_startup_trace_arm to install the finishing hooks.
# All functions here are internal to the trace itself.
#
# Environment:
#   ZSH_STARTUP_TRACE         Set to 1 to enable tracing.
#   ZSH_STARTUP_TRACE_ORIGIN  Optional epoch override for the trace start.
#   ZSH_STARTUP_TRACE_FILE    Write TSV here instead of a stderr table.
#   ZSH_STARTUP_TRACE_FINISH  "zle" (default) or "precmd" completion point.
#   ZSH_STARTUP_TRACE_EXIT    Set to 1 to exit the shell once the trace ends.
#
# ============================================================================ #

[[ "${ZSH_STARTUP_TRACE:-0}" == "1" ]] || return 0
(( ${_ZSH_STARTUP_TRACE_ACTIVE:-0} )) && return 0

zmodload -i zsh/datetime 2>/dev/null || {
  print -u2 "startup trace: zsh/datetime is unavailable"
  return 1
}

typeset startup_trace_origin="${ZSH_STARTUP_TRACE_ORIGIN:-}"
if [[ ! "$startup_trace_origin" =~ '^[0-9]+([.][0-9]+)?$' ]]; then
  startup_trace_origin="$EPOCHREALTIME"
fi

typeset -gi _ZSH_STARTUP_TRACE_ACTIVE=1
typeset -gi _ZSH_STARTUP_TRACE_FINISHED=0
typeset -ga _ZSH_STARTUP_TRACE_LABELS=("trace:start")
typeset -ga _ZSH_STARTUP_TRACE_TIMES=("$startup_trace_origin")
typeset -g _ZSH_STARTUP_TRACE_START="$startup_trace_origin"
unset startup_trace_origin

# -----------------------------------------------------------------------------
# _zsh_startup_trace_mark
# @internal
# @description Records one named startup milestone using EPOCHREALTIME.
# @arg $1 string Milestone name.
# -----------------------------------------------------------------------------
_zsh_startup_trace_mark() {
  (( _ZSH_STARTUP_TRACE_ACTIVE && ! _ZSH_STARTUP_TRACE_FINISHED )) ||
    return 0
  local label="${1:-unnamed}"
  label="${label//$'\t'/ }"
  label="${label//$'\n'/ }"
  _ZSH_STARTUP_TRACE_LABELS+=("$label")
  _ZSH_STARTUP_TRACE_TIMES+=("$EPOCHREALTIME")
}

# -----------------------------------------------------------------------------
# _zsh_startup_trace_write
# @internal
# @description Writes the current startup trace as TSV or a stderr table.
# @noargs
# -----------------------------------------------------------------------------
_zsh_startup_trace_write() {
  local target="${ZSH_STARTUP_TRACE_FILE:-}"
  local previous="$_ZSH_STARTUP_TRACE_START"
  local timestamp total delta label
  local -i index
  local output="# zsh-startup-trace-v1"$'\n'
  output+="elapsed_ms"$'\t'"delta_ms"$'\t'"milestone"$'\n'

  for (( index = 1; index <= ${#_ZSH_STARTUP_TRACE_LABELS[@]}; index++ )); do
    timestamp="${_ZSH_STARTUP_TRACE_TIMES[index]}"
    label="${_ZSH_STARTUP_TRACE_LABELS[index]}"
    total=$(( (timestamp - _ZSH_STARTUP_TRACE_START) * 1000.0 ))
    delta=$(( (timestamp - previous) * 1000.0 ))
    printf -v total '%.3f' "$total"
    printf -v delta '%.3f' "$delta"
    output+="${total}"$'\t'"${delta}"$'\t'"${label}"$'\n'
    previous="$timestamp"
  done

  if [[ -n "$target" ]]; then
    local target_dir="${target:A:h}"
    local temp_file=""
    command mkdir -p -- "$target_dir" || return 1
    temp_file="$(mktemp "$target_dir/.startup-trace.XXXXXX")" || return 1
    command chmod 600 "$temp_file" 2>/dev/null || {
      command rm -f -- "$temp_file"
      return 1
    }
    print -rn -- "$output" >| "$temp_file" || {
      command rm -f -- "$temp_file"
      return 1
    }
    command mv -f -- "$temp_file" "$target"
    return $?
  fi

  print -u2 -r -- "Zsh startup trace"
  printf >&2 '%10s  %10s  %s\n' "TOTAL(ms)" "DELTA(ms)" "MILESTONE"
  previous="$_ZSH_STARTUP_TRACE_START"
  for (( index = 1; index <= ${#_ZSH_STARTUP_TRACE_LABELS[@]}; index++ )); do
    timestamp="${_ZSH_STARTUP_TRACE_TIMES[index]}"
    label="${_ZSH_STARTUP_TRACE_LABELS[index]}"
    total=$(( (timestamp - _ZSH_STARTUP_TRACE_START) * 1000.0 ))
    delta=$(( (timestamp - previous) * 1000.0 ))
    printf -v total '%.3f' "$total"
    printf -v delta '%.3f' "$delta"
    printf >&2 '%10s  %10s  %s\n' "$total" "$delta" "$label"
    previous="$timestamp"
  done
}

# -----------------------------------------------------------------------------
# _zsh_startup_trace_finish
# @internal
# @description Finalizes the trace when ZLE accepts its first input line.
# @noargs
# -----------------------------------------------------------------------------
_zsh_startup_trace_finish() {
  (( _ZSH_STARTUP_TRACE_FINISHED )) && return 0
  _zsh_startup_trace_mark "input-ready"
  _ZSH_STARTUP_TRACE_FINISHED=1

  autoload -Uz add-zsh-hook add-zle-hook-widget
  add-zsh-hook -d precmd _zsh_startup_trace_precmd 2>/dev/null
  add-zsh-hook -d zshexit _zsh_startup_trace_abort 2>/dev/null
  add-zle-hook-widget -d line-init _zsh_startup_trace_finish 2>/dev/null
  _zsh_startup_trace_write

  if [[ "${ZSH_STARTUP_TRACE_EXIT:-0}" == "1" ]]; then
    zle -I 2>/dev/null || true
    exit 0
  fi
}

# -----------------------------------------------------------------------------
# _zsh_startup_trace_precmd
# @internal
# @description Records the first precmd boundary and provides a non-ZLE mode.
# @noargs
# -----------------------------------------------------------------------------
_zsh_startup_trace_precmd() {
  _zsh_startup_trace_mark "precmd"
  if [[ "${ZSH_STARTUP_TRACE_FINISH:-zle}" == "precmd" ]]; then
    _zsh_startup_trace_finish
  fi
}

# -----------------------------------------------------------------------------
# _zsh_startup_trace_abort
# @internal
# @description Writes a partial trace if the shell exits before input-ready.
# @noargs
# -----------------------------------------------------------------------------
_zsh_startup_trace_abort() {
  (( _ZSH_STARTUP_TRACE_FINISHED )) && return 0
  _zsh_startup_trace_mark "shell-exit"
  _ZSH_STARTUP_TRACE_FINISHED=1
  _zsh_startup_trace_write
}

# -----------------------------------------------------------------------------
# _zsh_startup_trace_arm
# @internal
# @description Arms one-shot precmd, ZLE line-init, and early-exit hooks.
# @noargs
# -----------------------------------------------------------------------------
_zsh_startup_trace_arm() {
  [[ $- == *i* ]] || return 0
  _zsh_startup_trace_mark ".zshrc:loaded"

  autoload -Uz add-zsh-hook add-zle-hook-widget
  add-zsh-hook -d precmd _zsh_startup_trace_precmd 2>/dev/null
  add-zsh-hook precmd _zsh_startup_trace_precmd
  precmd_functions=(
    _zsh_startup_trace_precmd
    ${precmd_functions:#_zsh_startup_trace_precmd}
  )
  add-zsh-hook -d zshexit _zsh_startup_trace_abort 2>/dev/null
  add-zsh-hook zshexit _zsh_startup_trace_abort

  if [[ "${ZSH_STARTUP_TRACE_FINISH:-zle}" != "precmd" ]]; then
    add-zle-hook-widget -d line-init _zsh_startup_trace_finish 2>/dev/null
    if ! add-zle-hook-widget line-init _zsh_startup_trace_finish; then
      ZSH_STARTUP_TRACE_FINISH="precmd"
    fi
  fi
}

# ============================================================================ #
# End of startup-trace.zsh
