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
# Note: This file shares similar logic with 95-lazy-scripts.zsh.
# They are kept separate due to different use cases:
#   - 95-lazy-scripts.zsh: scans a directory of scripts.
#   - This file: loads a single specific script.
#
# ============================================================================ #
# Early exit conditions.
[[ $- == *i* ]] || return 0
[[ "${ZSH_FAST_START:-}" == "1" ]] && return 0
[[ "${ZSH_LAZY_CPP_TOOLS:-1}" == "1" ]] || return 0

# Run inside a wrapper to silence verbose/xtrace output during reloads.
_lazy_cpp_loader() {
  emulate -L zsh
  setopt noxtrace noverbose

  # Load and prepare lazy cpp-tools.
  local _lazy_cpp_script="$HOME/.config/cpp-tools/competitive.sh"
  [[ -r "$_lazy_cpp_script" ]] || return 0

  # Cache file paths.
  local _lazy_cpp_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
  local _lazy_cpp_cache_file="$_lazy_cpp_cache_dir/lazy-cpp-tools.zsh"
  local _lazy_cpp_cache_version=5
  local _lazy_cpp_cache_header="# lazy-cpp-tools-version: ${_lazy_cpp_cache_version}"

  # Builds the lazy cpp-tools cache file.
  _lazy_cpp_build_cache() {
    local script="$1"
    local out_file="$2"
    local tmp_file="${out_file}.tmp.$$"
    local -A seen

    # Cleanup trap for temp file.
    trap "rm -f ${(q)tmp_file} 2>/dev/null" EXIT INT TERM

    local -a names
    local -a source_files
    local script_dir
    script_dir="${script:h}"
    source_files=("$script")
    if [[ -d "$script_dir/modules" ]]; then
      source_files+=("$script_dir/modules/"*.zsh(N))
    fi

    # Parse function and alias names (supports names with dashes).
    local file
    for file in "${source_files[@]}"; do
      [[ -r "$file" ]] || continue
      names+=("${(@f)$(awk '
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
      ' "$file")}")
    done

    local name
    for name in "${names[@]}"; do
      [[ -z "$name" ]] && continue
      # Validate name contains only safe characters.
      [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || continue
      seen[$name]="$script"
    done

    {
      print -r -- "$_lazy_cpp_cache_header"
      print -r -- "# Auto-generated. Do not edit."
      print -r -- "typeset -gA _LAZY_CPP_SOURCED=()"
      print -r -- "_lazy_cpp_source_script() {"
      print -r -- '  local script="$1"'
      print -r -- '  [[ -n "${_LAZY_CPP_SOURCED[$script]-}" ]] && return 0'
      print -r -- '  _LAZY_CPP_SOURCED[$script]=1'
      print -r -- '  if [[ -r "$script" ]]; then'
      print -r -- '    setopt localoptions noxtrace noverbose'
      print -r -- '    source "$script"'
      print -r -- '    return $?'
      print -r -- '  fi'
      print -r -- '  return 1'
      print -r -- '}'
      print -r -- "_lazy_cpp_stub_call() {"
      print -r -- '  local name="$1"'
      print -r -- '  local script="$2"'
      print -r -- '  shift 2'
      print -r -- '  unfunction "$name" 2>/dev/null'
      print -r -- '  _lazy_cpp_source_script "$script" || return 1'
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
      print -r -- '  print -u2 "lazy-cpp-tools: warning: $name not found after sourcing script"'
      print -r -- '  return 127'
      print -r -- '}'

      local key
      for key in ${(k)seen}; do
        local script_path="${seen[$key]}"
        # Quote key in function declaration for safety.
        print -r -- "function ${(q)key}() { _lazy_cpp_stub_call ${(q)key} ${(q)script_path} \"\$@\"; }"
      done
    } >| "$tmp_file" || { rm -f "$tmp_file" 2>/dev/null; trap - EXIT INT TERM; return 1; }

    chmod 600 "$tmp_file" 2>/dev/null || :

    mv -f "$tmp_file" "$out_file" || { rm -f "$tmp_file" 2>/dev/null; trap - EXIT INT TERM; return 1; }
    trap - EXIT INT TERM
  }

  # Determine if cache needs regeneration.
  local _lazy_cpp_regen=0
  if [[ ! -f "$_lazy_cpp_cache_file" ]]; then
    _lazy_cpp_regen=1
  else
    if typeset -f _zsh_is_secure_file >/dev/null 2>&1; then
      _zsh_is_secure_file "$_lazy_cpp_cache_file" || _lazy_cpp_regen=1
    elif [[ ! -O "$_lazy_cpp_cache_file" || -L "$_lazy_cpp_cache_file" ]]; then
      _lazy_cpp_regen=1
    fi

    if ! command grep -q -F "$_lazy_cpp_cache_header" "$_lazy_cpp_cache_file" 2>/dev/null; then
      _lazy_cpp_regen=1
    fi
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
      # Also check module files for changes.
      if (( ! _lazy_cpp_regen )); then
        local _lazy_cpp_mod_dir="${_lazy_cpp_script:h}/modules"
        if [[ -d "$_lazy_cpp_mod_dir" ]]; then
          local _lazy_cpp_mod
          for _lazy_cpp_mod in "$_lazy_cpp_mod_dir"/*.zsh(N); do
            zstat -A _lazy_cpp_stat +mtime -- "$_lazy_cpp_mod" 2>/dev/null || { _lazy_cpp_regen=1; break; }
            if (( _lazy_cpp_stat[1] > _lazy_cpp_cache_mtime )); then
              _lazy_cpp_regen=1
              break
            fi
          done
        fi
      fi
    else
      _lazy_cpp_regen=1
    fi
  fi

  if (( _lazy_cpp_regen )); then
    if ! mkdir -p "$_lazy_cpp_cache_dir" 2>/dev/null; then
      print -u2 "lazy-cpp-tools: warning: cannot create cache directory: $_lazy_cpp_cache_dir"
      return 1
    fi
    _lazy_cpp_build_cache "$_lazy_cpp_script" "$_lazy_cpp_cache_file"
  fi

  if [[ -r "$_lazy_cpp_cache_file" ]]; then
    local _lazy_cpp_cache_safe=false
    if typeset -f _zsh_is_secure_file >/dev/null 2>&1; then
      _zsh_is_secure_file "$_lazy_cpp_cache_file" && _lazy_cpp_cache_safe=true
    elif [[ -O "$_lazy_cpp_cache_file" && ! -L "$_lazy_cpp_cache_file" ]]; then
      _lazy_cpp_cache_safe=true
    fi

    if $_lazy_cpp_cache_safe; then
      source "$_lazy_cpp_cache_file"
    else
      print -u2 "lazy-cpp-tools: warning: skipping insecure cache file: $_lazy_cpp_cache_file"
    fi
  fi

  unfunction _lazy_cpp_build_cache 2>/dev/null
  unset _lazy_cpp_regen _lazy_cpp_script _lazy_cpp_cache_dir _lazy_cpp_cache_file _lazy_cpp_cache_version _lazy_cpp_cache_header
}

_lazy_cpp_loader
unfunction _lazy_cpp_loader 2>/dev/null

# ============================================================================ #
# # End of 96-lazy-cpp-tools.zsh
