#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++ LAZY SCRIPT LOADER ++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Lazily loads functions and aliases from ~/.config/zsh/scripts/*.sh on first
# use instead of sourcing all scripts at startup.
#
# How it works:
#   - Scans scripts for function + alias names.
#   - Generates a cached stub file in $XDG_CACHE_HOME/zsh/lazy-scripts.zsh.
#   - Each stub sources the owning script on first invocation.
#
# This keeps startup fast while preserving existing behavior when a function
# is actually used.
#
# ============================================================================ #
# Early exit conditions.
[[ $- == *i* ]] || return 0
[[ "${ZSH_FAST_START:-}" == "1" ]] && return 0
[[ "${ZSH_LAZY_SCRIPTS:-1}" == "1" ]] || return 0

# Load and prepare lazy scripts.
local _lazy_scripts_dir="$ZSH_CONFIG_DIR/scripts"
[[ -d "$_lazy_scripts_dir" ]] || return 0

# Gather all script files.
local -a _lazy_scripts
_lazy_scripts=("$_lazy_scripts_dir"/*.sh(N))
(( ${#_lazy_scripts} )) || return 0

# Cache file paths.
local _lazy_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
local _lazy_cache_file="$_lazy_cache_dir/lazy-scripts.zsh"

# Builds the lazy scripts cache file.
_lazy_scripts_build_cache() {
  local out_file="$1"
  shift
  local -a scripts=("$@")
  local tmp_file="${out_file}.tmp.$$"
  local -A seen

  local script name
  for script in "${scripts[@]}"; do
    local -a names
    names=("${(@f)$(awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*alias[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=/ {
        line=$0
        sub(/^[[:space:]]*alias[[:space:]]+/, "", line)
        name=line
        sub(/=.*/, "", name)
        print name
        next
      }
      /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/ {
        line=$0
        sub(/^[[:space:]]*/, "", line)
        if (line ~ /^function[[:space:]]+/) sub(/^function[[:space:]]+/, "", line)
        name=line
        sub(/[[:space:]]*\(\).*/, "", name)
        print name
      }
    ' "$script")}")

    for name in "${names[@]}"; do
      [[ -z "$name" ]] && continue
      seen[$name]="$script"
    done
  done

  {
    print -r -- "# Auto-generated. Do not edit."
    print -r -- "typeset -gA _LAZY_SCRIPTS_SOURCED"
    print -r -- "_lazy_source_script() {"
    print -r -- '  local script="$1"'
    print -r -- '  [[ -n "${_LAZY_SCRIPTS_SOURCED[$script]-}" ]] && return 0'
    print -r -- '  _LAZY_SCRIPTS_SOURCED[$script]=1'
    print -r -- '  if [[ -r "$script" ]]; then'
    print -r -- '    () { setopt localoptions noxtrace noverbose; source "$script"; }'
    print -r -- '    return $?'
    print -r -- '  fi'
    print -r -- '  return 1'
    print -r -- '}'
    print -r -- "_lazy_stub_call() {"
    print -r -- '  local name="$1"'
    print -r -- '  local script="$2"'
    print -r -- '  shift 2'
    print -r -- '  unfunction "$name" 2>/dev/null'
    print -r -- '  _lazy_source_script "$script" || true'
    print -r -- '  if typeset -f "$name" >/dev/null 2>&1; then'
    print -r -- '    "$name" "$@"'
    print -r -- '    return $?'
    print -r -- '  fi'
    print -r -- '  if alias "$name" >/dev/null 2>&1; then'
    print -r -- '    eval "${aliases[$name]}" "$@"'
    print -r -- '    return $?'
    print -r -- '  fi'
    print -r -- '  command "$name" "$@"'
    print -r -- '}'

    local key
    for key in ${(k)seen}; do
      local script_path="${seen[$key]}"
      print -r -- "function $key() { _lazy_stub_call ${(q)key} ${(q)script_path} \"\\$@\"; }"
    done
  } >| "$tmp_file" && mv -f "$tmp_file" "$out_file"
}

# Determine if cache needs regeneration.
local _lazy_regen=0
if [[ ! -f "$_lazy_cache_file" ]]; then
  _lazy_regen=1
else
  if zmodload -F zsh/stat b:zstat 2>/dev/null; then
    local -a _lazy_stat
    zstat -A _lazy_stat +mtime -- "$_lazy_cache_file" 2>/dev/null || _lazy_regen=1
    local _lazy_cache_mtime="${_lazy_stat[1]:-0}"
    if (( ! _lazy_regen )); then
      local _lazy_script
      for _lazy_script in "${_lazy_scripts[@]}"; do
        zstat -A _lazy_stat +mtime -- "$_lazy_script" 2>/dev/null || { _lazy_regen=1; break; }
        if (( _lazy_stat[1] > _lazy_cache_mtime )); then
          _lazy_regen=1
          break
        fi
      done
    fi
  else
    _lazy_regen=1
  fi
fi

if (( _lazy_regen )); then
  mkdir -p "$_lazy_cache_dir" 2>/dev/null
  _lazy_scripts_build_cache "$_lazy_cache_file" "${_lazy_scripts[@]}"
fi

[[ -r "$_lazy_cache_file" ]] && source "$_lazy_cache_file"

unfunction _lazy_scripts_build_cache 2>/dev/null
unset _lazy_regen _lazy_scripts_dir _lazy_scripts _lazy_cache_dir _lazy_cache_file

# ============================================================================ #
