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

# Run inside a wrapper to silence verbose/xtrace output during reloads.
_lazy_scripts_loader() {
  emulate -L zsh
  setopt noxtrace noverbose

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
  local _lazy_cache_version=4
  local _lazy_cache_header="# lazy-scripts-version: ${_lazy_cache_version}"

  # Builds the lazy scripts cache file.
  _lazy_scripts_build_cache() {
    local out_file="$1"
    shift
    local -a scripts=("$@")
    local tmp_file="${out_file}.tmp.$$"
    local -A seen

    # Cleanup trap for temp file.
    trap "rm -f ${(q)tmp_file} 2>/dev/null" EXIT INT TERM

    local script name
    for script in "${scripts[@]}"; do
      local -a names
      # Parse function and alias names (supports names with dashes).
      names=("${(@f)$(awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*alias[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*=/ {
          line=$0
          sub(/^[[:space:]]*alias[[:space:]]+/, "", line)
          name=line
          sub(/=.*/, "", name)
          print name
          next
        }
        /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*\(\)[[:space:]]*\{/ {
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
        # Validate name contains only safe characters.
        [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || continue
        seen[$name]="$script"
      done
    done

    {
      print -r -- "$_lazy_cache_header"
      print -r -- "# Auto-generated. Do not edit."
      print -r -- "typeset -gA _LAZY_SCRIPTS_SOURCED=()"
      print -r -- "_lazy_source_script() {"
      print -r -- '  local script="$1"'
      print -r -- '  [[ -n "${_LAZY_SCRIPTS_SOURCED[$script]-}" ]] && return 0'
      print -r -- '  _LAZY_SCRIPTS_SOURCED[$script]=1'
      print -r -- '  if [[ -r "$script" ]]; then'
      print -r -- '    setopt localoptions noxtrace noverbose'
      print -r -- '    source "$script"'
      print -r -- '    return $?'
      print -r -- '  fi'
      print -r -- '  return 1'
      print -r -- '}'
      print -r -- "_lazy_stub_call() {"
      print -r -- '  local name="$1"'
      print -r -- '  local script="$2"'
      print -r -- '  shift 2'
      print -r -- '  unfunction "$name" 2>/dev/null'
      print -r -- '  _lazy_source_script "$script" || return 1'
      print -r -- '  if typeset -f "$name" >/dev/null 2>&1; then'
      print -r -- '    "$name" "$@"'
      print -r -- '    return $?'
      print -r -- '  fi'
      print -r -- '  if alias "$name" >/dev/null 2>&1; then'
      # Expand alias: use ${=...} to split on whitespace for multi-word aliases.
      print -r -- '    local _alias_cmd="${aliases[$name]}"'
      print -r -- '    ${=_alias_cmd} "$@"'
      print -r -- '    return $?'
      print -r -- '  fi'
      # Warn and fail if function/alias not found after sourcing.
      print -r -- '  print -u2 "lazy-scripts: warning: $name not found after sourcing script"'
      print -r -- '  return 127'
      print -r -- '}'

      local key
      for key in ${(k)seen}; do
        local script_path="${seen[$key]}"
        # Quote key in function declaration for safety.
        print -r -- "function ${(q)key}() { _lazy_stub_call ${(q)key} ${(q)script_path} \"\$@\"; }"
      done
    } >| "$tmp_file" || { rm -f "$tmp_file" 2>/dev/null; trap - EXIT INT TERM; return 1; }

    chmod 600 "$tmp_file" 2>/dev/null || :

    mv -f "$tmp_file" "$out_file" || { rm -f "$tmp_file" 2>/dev/null; trap - EXIT INT TERM; return 1; }
    trap - EXIT INT TERM
  }

  # Determine if cache needs regeneration.
  local _lazy_regen=0
  if [[ ! -f "$_lazy_cache_file" ]]; then
    _lazy_regen=1
  else
    if typeset -f _zsh_is_secure_file >/dev/null 2>&1; then
      _zsh_is_secure_file "$_lazy_cache_file" || _lazy_regen=1
    elif [[ ! -O "$_lazy_cache_file" || -L "$_lazy_cache_file" ]]; then
      _lazy_regen=1
    fi

    if ! command grep -q -F "$_lazy_cache_header" "$_lazy_cache_file" 2>/dev/null; then
      _lazy_regen=1
    fi
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
    if ! mkdir -p "$_lazy_cache_dir" 2>/dev/null; then
      print -u2 "lazy-scripts: warning: cannot create cache directory: $_lazy_cache_dir"
      return 1
    fi
    _lazy_scripts_build_cache "$_lazy_cache_file" "${_lazy_scripts[@]}"
  fi

  if [[ -r "$_lazy_cache_file" ]]; then
    local _lazy_cache_safe=false
    if typeset -f _zsh_is_secure_file >/dev/null 2>&1; then
      _zsh_is_secure_file "$_lazy_cache_file" && _lazy_cache_safe=true
    elif [[ -O "$_lazy_cache_file" && ! -L "$_lazy_cache_file" ]]; then
      _lazy_cache_safe=true
    fi

    if $_lazy_cache_safe; then
      source "$_lazy_cache_file"
    else
      print -u2 "lazy-scripts: warning: skipping insecure cache file: $_lazy_cache_file"
    fi
  fi

  unfunction _lazy_scripts_build_cache 2>/dev/null
  unset _lazy_regen _lazy_scripts_dir _lazy_scripts _lazy_cache_dir _lazy_cache_file _lazy_cache_version _lazy_cache_header
}

_lazy_scripts_loader
unfunction _lazy_scripts_loader 2>/dev/null

# ============================================================================ #
# # End of 95-lazy-scripts.zsh
