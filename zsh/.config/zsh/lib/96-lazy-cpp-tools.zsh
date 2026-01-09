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
# ============================================================================ #
# Early exit conditions.
[[ $- == *i* ]] || return 0
[[ "${ZSH_FAST_START:-}" == "1" ]] && return 0
[[ "${ZSH_LAZY_CPP_TOOLS:-1}" == "1" ]] || return 0

# Load and prepare lazy cpp-tools.
local _lazy_cpp_script="$HOME/.config/cpp-tools/competitive.sh"
[[ -r "$_lazy_cpp_script" ]] || return 0

# Cache file paths.
local _lazy_cpp_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
local _lazy_cpp_cache_file="$_lazy_cpp_cache_dir/lazy-cpp-tools.zsh"

# Builds the lazy cpp-tools cache file.
_lazy_cpp_build_cache() {
  local script="$1"
  local out_file="$2"
  local tmp_file="${out_file}.tmp.$$"
  local -A seen

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

  local name
  for name in "${names[@]}"; do
    [[ -z "$name" ]] && continue
    seen[$name]="$script"
  done

  {
    print -r -- "# Auto-generated. Do not edit."
    print -r -- "typeset -gA _LAZY_CPP_SOURCED"
    print -r -- "_lazy_cpp_source_script() {"
    print -r -- '  local script="$1"'
    print -r -- '  [[ -n "${_LAZY_CPP_SOURCED[$script]-}" ]] && return 0'
    print -r -- '  _LAZY_CPP_SOURCED[$script]=1'
    print -r -- '  if [[ -r "$script" ]]; then'
    print -r -- '    () { setopt localoptions noxtrace noverbose; source "$script"; }'
    print -r -- '    return $?'
    print -r -- '  fi'
    print -r -- '  return 1'
    print -r -- '}'
    print -r -- "_lazy_cpp_stub_call() {"
    print -r -- '  local name="$1"'
    print -r -- '  local script="$2"'
    print -r -- '  shift 2'
    print -r -- '  unfunction "$name" 2>/dev/null'
    print -r -- '  _lazy_cpp_source_script "$script" || true'
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
      print -r -- "function $key() { _lazy_cpp_stub_call ${(q)key} ${(q)script_path} \"\\$@\"; }"
    done
  } >| "$tmp_file" && mv -f "$tmp_file" "$out_file"
}

# Determine if cache needs regeneration.
local _lazy_cpp_regen=0
if [[ ! -f "$_lazy_cpp_cache_file" ]]; then
  _lazy_cpp_regen=1
else
  if zmodload -F zsh/stat b:zstat 2>/dev/null; then
    local -a _lazy_cpp_stat
    zstat -A _lazy_cpp_stat +mtime -- "$_lazy_cpp_cache_file" 2>/dev/null || _lazy_cpp_regen=1
    local _lazy_cpp_cache_mtime="${_lazy_cpp_stat[1]:-0}"
    if (( ! _lazy_cpp_regen )); then
      zstat -A _lazy_cpp_stat +mtime -- "$_lazy_cpp_script" 2>/dev/null || _lazy_cpp_regen=1
      if (( _lazy_cpp_stat[1] > _lazy_cpp_cache_mtime )); then
        _lazy_cpp_regen=1
      fi
    fi
  else
    _lazy_cpp_regen=1
  fi
fi

if (( _lazy_cpp_regen )); then
  mkdir -p "$_lazy_cpp_cache_dir" 2>/dev/null
  _lazy_cpp_build_cache "$_lazy_cpp_script" "$_lazy_cpp_cache_file"
fi

[[ -r "$_lazy_cpp_cache_file" ]] && source "$_lazy_cpp_cache_file"

unfunction _lazy_cpp_build_cache 2>/dev/null
unset _lazy_cpp_regen _lazy_cpp_script _lazy_cpp_cache_dir _lazy_cpp_cache_file

# ============================================================================ #
