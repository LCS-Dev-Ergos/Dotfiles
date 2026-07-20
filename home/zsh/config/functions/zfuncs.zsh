#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ CUSTOM FUNCTION CATALOG ++++++++++++++++++++++++++ #
# ============================================================================ #
#
# On-demand index of public functions defined by this Zsh environment.
# Documentation next to each function remains the source of truth; this file
# only discovers, caches, and renders it (see scripts/zfuncs-index.awk).
#
# Functions:
#   - zfuncs   List, look up, refresh, or validate the function catalog.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# _zfuncs_resolve_status
# @internal
# @description Stores a cataloged function's loaded, lazy, or missing state in
# REPLY without creating a command-substitution subshell.
# @arg $1 string Function name to inspect.
# @arg $2 path Source file associated with the function.
# -----------------------------------------------------------------------------
_zfuncs_resolve_status() {
  emulate -L zsh
  local function_name="$1"
  local function_source="$2"
  if typeset -f "$function_name" >/dev/null 2>&1; then
    local body="${functions[$function_name]-}"
    if [[ "$body" == *'_lazy_loader_dispatch'* ||
          "$body" == *'_lazy_dispatch'* ||
          "$body" == *'_lazy_load_and_run'* ]]; then
      REPLY="lazy"
    else
      REPLY="loaded"
    fi
  elif [[ -r "$function_source" ]]; then
    REPLY="lazy"
  else
    REPLY="missing"
  fi
}

# -----------------------------------------------------------------------------
# _zfuncs_catalog_status
# @internal
# @description Prints whether a cataloged function is loaded, lazy, or missing.
# @arg $1 string Function name to inspect.
# @arg $2 path Source file associated with the function.
# @stdout The resolved function state.
# -----------------------------------------------------------------------------
_zfuncs_catalog_status() {
  _zfuncs_resolve_status "$@"
  print -r -- "$REPLY"
}

# -----------------------------------------------------------------------------
# zfuncs
# @description Lists documented functions or shows one function's documentation.
# The local catalog is rebuilt automatically when sources change.
# @arg $@ string Optional subcommand and arguments; run with --help for syntax.
# @exitcode 0 If the requested catalog operation succeeds.
# @exitcode 1 If catalog generation, lookup, or validation fails.
# @exitcode 2 If command-line arguments are invalid.
# -----------------------------------------------------------------------------
function zfuncs() {
  emulate -L zsh
  setopt localoptions no_aliases pipefail extendedglob

  local action="list"
  local target=""

  case "${1:-}" in
    "") ;;
    info)
      [[ $# -eq 2 ]] || {
        print -u2 "Usage: zfuncs info <name>"
        return 2
      }
      action="info"
      target="$2"
      ;;
    --check)
      [[ $# -eq 1 ]] || {
        print -u2 "Usage: zfuncs --check"
        return 2
      }
      action="check"
      ;;
    --refresh)
      [[ $# -eq 1 ]] || {
        print -u2 "Usage: zfuncs --refresh"
        return 2
      }
      action="refresh"
      ;;
    -h|--help)
      [[ $# -eq 1 ]] || {
        print -u2 "Usage: zfuncs --help"
        return 2
      }
      action="help"
      ;;
    -* )
      print -u2 "zfuncs: unknown option: $1"
      print -u2 "Usage: zfuncs [info NAME|--check|--refresh|--help]"
      return 2
      ;;
    *)
      [[ $# -eq 1 ]] || {
        print -u2 "Usage: zfuncs info <name>"
        return 2
      }
      action="info"
      target="$1"
      ;;
  esac

  if [[ "$action" == info && "$target" != [A-Za-z][A-Za-z0-9_-]# ]]; then
    print -u2 "zfuncs: invalid function name: $target"
    return 2
  fi

  if [[ "$action" == help ]]; then
    print -r -- "Usage: zfuncs [info NAME|NAME|--check|--refresh|--help]"
    print -r -- ""
    print -r -- "  (no args)   List public custom functions by category."
    print -r -- "  info NAME   Show semantics, usage, status, and source."
    print -r -- "  --check     Validate documentation and registrations."
    print -r -- "  --refresh   Rebuild the local catalog, then list it."
    print -r -- ""
    print -r -- "Environment:"
    print -r -- "  ZFUNCS_STYLE  Output style: auto, gum, ansi, or plain."
    print -r -- \
      "  ZFUNCS_MAX_WIDTH  Maximum listing width: 80-240 (default: 160)."
    print -r -- "  NO_COLOR      Disable styled output when set."
    return 0
  fi

  local config_dir="${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}"
  local indexer="$config_dir/scripts/zfuncs-index.awk"
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
  local cache_file="$cache_dir/zfuncs/catalog-v1"
  local separator=$'\x1f'
  local -a source_files signature_files signature_parts

  [[ -r "$indexer" ]] || {
    print -u2 "zfuncs: indexer not found: $indexer"
    return 1
  }

  source_files=(
    "$config_dir"/functions/*.zsh(N.)
    "$config_dir"/lib/*.zsh(N.)
    "$config_dir"/scripts/**/*.sh(N.)
    "$config_dir"/scripts/**/*.zsh(N.)
  )
  signature_files=("${source_files[@]}" "$indexer")

  (( ${#source_files[@]} )) || {
    print -u2 "zfuncs: no source files found below $config_dir"
    return 1
  }

  zmodload -i zsh/stat zsh/parameter 2>/dev/null || {
    print -u2 "zfuncs: the zsh/stat and zsh/parameter modules are required"
    return 1
  }

  local file
  local -A stat_info
  for file in "${signature_files[@]}"; do
    stat_info=()
    if ! zstat -L -H stat_info -- "$file" 2>/dev/null; then
      print -u2 "zfuncs: cannot inspect source: $file"
      return 1
    fi
    signature_parts+=("${file:A}:${stat_info[mtime]}:${stat_info[size]}")
  done

  local signature="${(j:|:)signature_parts}"
  local expected_header="# zfuncs-cache-v1 ${signature}"
  local cached_header=""
  local rebuild=0

  if [[ "$action" == refresh ]]; then
    rebuild=1
  elif typeset -f _zsh_is_secure_file >/dev/null 2>&1 &&
      _zsh_is_secure_file "$cache_file"; then
    IFS= read -r cached_header < "$cache_file" 2>/dev/null || cached_header=""
    [[ "$cached_header" == "$expected_header" ]] || rebuild=1
  else
    rebuild=1
  fi

  if (( rebuild )); then
    if ! typeset -f _zsh_cache_put >/dev/null 2>&1; then
      local runtime_helpers="$config_dir/runtime-helpers.zsh"
      [[ -r "$runtime_helpers" ]] && source "$runtime_helpers"
    fi
    typeset -f _zsh_cache_put >/dev/null 2>&1 || {
      print -u2 "zfuncs: secure cache writer is unavailable"
      return 1
    }

    {
      print -r -- "$expected_header"
      LC_ALL=C command awk \
        -v sep="$separator" \
        -f "$indexer" \
        "${source_files[@]}"
    } | _zsh_cache_put "$cache_file" || {
      print -u2 "zfuncs: failed to rebuild the local catalog"
      return 1
    }
  fi

  local -a names registered_names
  local -A categories summaries usages details sources source_lines qualities
  local -A duplicates
  local name category summary usage detail source source_line quality
  local first_line=1

  while IFS="$separator" read -r \
      name category summary usage detail source source_line quality; do
    if (( first_line )); then
      first_line=0
      [[ "$name" == "$expected_header" ]] || {
        print -u2 "zfuncs: invalid cache header"
        return 1
      }
      continue
    fi

    [[ "$name" == [A-Za-z][A-Za-z0-9_-]# ]] || continue
    if [[ -n "${sources[$name]-}" && "${sources[$name]}" != "$source" ]]; then
      duplicates[$name]="${sources[$name]}, $source"
      local old_score=0 new_score=0
      [[ "${qualities[$name]}" == legacy ]] && old_score=1
      [[ "${qualities[$name]}" == standard ]] && old_score=2
      [[ "$quality" == legacy ]] && new_score=1
      [[ "$quality" == standard ]] && new_score=2
      (( new_score > old_score )) || continue
    elif [[ -z "${sources[$name]-}" ]]; then
      names+=("$name")
    fi

    categories[$name]="$category"
    summaries[$name]="$summary"
    usages[$name]="$usage"
    details[$name]="$detail"
    sources[$name]="$source"
    source_lines[$name]="$source_line"
    qualities[$name]="$quality"
  done < "$cache_file"

  (( ${#names[@]} )) || {
    print -u2 "zfuncs: the catalog is empty"
    return 1
  }

  for name in "${names[@]}"; do
    [[ "${qualities[$name]}" == standard ]] && registered_names+=("$name")
  done

  local requested_style="${ZFUNCS_STYLE:-${ZSH_UI_STYLE:-auto}}"
  local visual_style="plain"
  if [[ "$action" != check ]]; then
    local ui_helpers="$config_dir/scripts/_shared-helpers.zsh"
    [[ -r "$ui_helpers" ]] || {
      print -u2 "zfuncs: shared UI helpers not found: $ui_helpers"
      return 1
    }
    source "$ui_helpers" || {
      print -u2 "zfuncs: failed to load shared UI helpers"
      return 1
    }
    local ZSH_UI_STYLE="$requested_style"
    _zsh_ui_resolve_mode || {
      print -u2 "zfuncs: invalid output style: $requested_style"
      return 2
    }
    visual_style="$REPLY"
  fi

  if [[ "$action" == info ]]; then
    [[ -n "${sources[$target]-}" && "${qualities[$target]-}" == standard ]] || {
      print -u2 "zfuncs: no registered public function named '$target'"
      [[ -n "${sources[$target]-}" ]] &&
        print -u2 \
          "zfuncs: '$target' has incomplete metadata; run 'zfuncs --check'"
      return 1
    }

    local display_source="${sources[$target]#$config_dir/}"
    local display_summary="${summaries[$target]:-(documentation missing)}"
    _zfuncs_resolve_status "$target" "${sources[$target]}"
    local display_status="$REPLY"

    if [[ "$visual_style" == gum ]]; then
      local -a info_lines=(
        "Usage     ${usages[$target]:-(not documented)}"
        "Category  ${categories[$target]}"
        "Status    $display_status"
        "Source    ${display_source}:${source_lines[$target]}"
      )
      [[ -z "${details[$target]-}" ]] ||
        info_lines+=("Details   ${details[$target]}")
      [[ -z "${duplicates[$target]-}" ]] ||
        info_lines+=("Conflict  ${duplicates[$target]}")

      _zsh_ui_card "$target — $display_summary" "" "${info_lines[@]}"
      return $?
    fi

    if [[ "$visual_style" == ansi ]]; then
      _zsh_ui_set_palette "$visual_style"
      local -a styled_info_lines=(
        "${_ZSH_UI_INFO}Usage${_ZSH_UI_RESET}     "\
"${usages[$target]:-(not documented)}"
        "${_ZSH_UI_INFO}Category${_ZSH_UI_RESET}  ${categories[$target]}"
        "${_ZSH_UI_INFO}Status${_ZSH_UI_RESET}    $display_status"
        "${_ZSH_UI_INFO}Source${_ZSH_UI_RESET}    "\
"${_ZSH_UI_MUTED}${display_source}:${source_lines[$target]}"\
"${_ZSH_UI_RESET}"
      )
      [[ -z "${details[$target]-}" ]] ||
        styled_info_lines+=(
          "${_ZSH_UI_INFO}Details${_ZSH_UI_RESET}   ${details[$target]}")
      [[ -z "${duplicates[$target]-}" ]] ||
        styled_info_lines+=(
          "${_ZSH_UI_INFO}Conflict${_ZSH_UI_RESET}  ${duplicates[$target]}")
      _zsh_ui_card "$target — $display_summary" "" \
        "${styled_info_lines[@]}"
      return $?
    fi

    print -r -- "$target — $display_summary"
    print -r -- ""
    print -r -- "Usage:    ${usages[$target]:-(not documented)}"
    print -r -- "Category: ${categories[$target]}"
    print -r -- "Status:   $display_status"
    print -r -- "Source:   ${display_source}:${source_lines[$target]}"
    [[ -z "${details[$target]-}" ]] ||
      print -r -- "Details:  ${details[$target]}"
    [[ -z "${duplicates[$target]-}" ]] ||
      print -r -- "Conflict: ${duplicates[$target]}"
    return 0
  fi

  if [[ "$action" == check ]]; then
    local -i errors=0 warnings=0
    local -a sorted_names=("${(on)names[@]}")
    for name in "${sorted_names[@]}"; do
      if [[ -n "${duplicates[$name]-}" ]]; then
        print -u2 \
          "error: $name is registered by multiple sources: ${duplicates[$name]}"
        (( errors++ ))
      fi
      if [[ "${qualities[$name]}" == missing ]]; then
        print -u2 \
          "error: $name has no matching documentation block "\
"(${sources[$name]}:${source_lines[$name]})"
        (( errors++ ))
        continue
      fi
      if [[ "${qualities[$name]}" == invalid ]]; then
        print -u2 \
          "error: $name combines @noargs with @arg or @option "\
"(${sources[$name]}:${source_lines[$name]})"
        (( errors++ ))
        continue
      fi
      if [[ -z "${usages[$name]-}" ]]; then
        print -u2 \
          "warning: $name has no @noargs, @arg, or @option metadata "\
"(${sources[$name]}:${source_lines[$name]})"
        (( warnings++ ))
      fi
      if [[ "${qualities[$name]}" == legacy ]]; then
        print -u2 \
          "warning: $name uses legacy or incomplete shdoc metadata "\
"(${sources[$name]}:${source_lines[$name]})"
        (( warnings++ ))
      fi
    done
    print -r -- \
      "Checked ${#names[@]} public functions: "\
"$errors error(s), $warnings warning(s)."
    (( errors == 0 && warnings == 0 ))
    return $?
  fi

  local -A category_seen
  local -a category_names sorted_names
  (( ${#registered_names[@]} )) || {
    print -u2 "zfuncs: no functions have complete registration metadata"
    return 1
  }
  for name in "${registered_names[@]}"; do
    category_seen[${categories[$name]}]=1
  done
  category_names=("${(onk)category_seen[@]}")
  sorted_names=("${(on)registered_names[@]}")

  local title="CUSTOM FUNCTIONS"
  local subtitle="${#registered_names} documented commands"
  subtitle+=" · ${#category_names} categories · zfuncs NAME for details"
  local current_category function_status display_summary
  local styled_status category_title display_name status_text
  local -i terminal_width=${COLUMNS:-160}
  local -i maximum_width=160
  local -i name_width=12
  local -i max_name_width summary_width

  if [[ -n "${ZFUNCS_MAX_WIDTH:-}" &&
        "${ZFUNCS_MAX_WIDTH}" != <-> ]]; then
    print -u2 "zfuncs: ZFUNCS_MAX_WIDTH must be an integer from 80 to 240"
    return 2
  fi
  if [[ "${ZFUNCS_MAX_WIDTH:-}" == <-> ]]; then
    maximum_width=$ZFUNCS_MAX_WIDTH
    (( maximum_width < 80 )) && maximum_width=80
    (( maximum_width > 240 )) && maximum_width=240
  fi
  (( terminal_width < 60 )) && terminal_width=60
  (( terminal_width > maximum_width )) && terminal_width=maximum_width

  for name in "${registered_names[@]}"; do
    (( ${#name} > name_width )) && name_width=${#name}
  done
  max_name_width=$(( terminal_width - 35 ))
  (( max_name_width > 40 )) && max_name_width=40
  (( max_name_width < 12 )) && max_name_width=12
  (( name_width > max_name_width )) && name_width=max_name_width
  summary_width=$(( terminal_width - name_width - 15 ))
  (( summary_width < 10 )) && summary_width=10

  local reset="" name_color="" muted="" rule_character="-"
  if [[ "$visual_style" != plain ]]; then
    _zsh_ui_heading "$title" "$subtitle" || return $?
    _zsh_ui_set_palette "$visual_style"
    reset="$_ZSH_UI_RESET"
    name_color="$_ZSH_UI_INFO"
    muted=$'\e[38;5;252m'
    rule_character="─"
  else
    print -r -- "$title"
    print -r -- "$subtitle"
  fi
  _zsh_ui_rule "$rule_character" "$terminal_width"
  print -r -- ""

  local category_rule
  local -i category_rule_width
  for current_category in "${category_names[@]}"; do
    category_title="${(U)current_category}"
    category_rule_width=$(( ${#category_title} + 4 ))
    (( category_rule_width < 24 )) && category_rule_width=24
    (( category_rule_width > 48 )) && category_rule_width=48
    (( category_rule_width > terminal_width - 2 )) &&
      category_rule_width=$(( terminal_width - 2 ))
    category_rule="${(pl:$category_rule_width::$rule_character:)}"
    if [[ "$visual_style" != plain ]]; then
      _zsh_ui_section "$category_title" || return $?
      print -r -- "${muted}  ${category_rule}${reset}"
    else
      print -r -- "$category_title"
      print -r -- "  ${category_rule}"
    fi

    for name in "${sorted_names[@]}"; do
      [[ "${categories[$name]}" == "$current_category" ]] || continue
      display_name="$name"
      if (( ${#display_name} > name_width )); then
        display_name="${display_name[1,$(( name_width - 1 ))]}…"
      fi
      _zfuncs_resolve_status "$name" "${sources[$name]}"
      function_status="$REPLY"
      display_summary="${summaries[$name]:-(documentation missing)}"
      if (( ${#display_summary} > summary_width )); then
        display_summary="${display_summary[1,$(( summary_width - 1 ))]}…"
      fi

      if [[ "$visual_style" != plain ]]; then
        case "$function_status" in
          loaded) styled_status="${_ZSH_UI_OK}● loaded ${reset}" ;;
          lazy) styled_status="${_ZSH_UI_WARN}◌ lazy   ${reset}" ;;
          *) styled_status="${_ZSH_UI_ERROR}× missing${reset}" ;;
        esac
        printf '  %s%-*s%s  %s  %s%s%s\n' \
          "$name_color" "$name_width" "$display_name" "$reset" \
          "$styled_status" "$muted" "$display_summary" "$reset"
      else
        status_text="[$function_status]"
        printf '  %-*s  %-9s  %s\n' \
          "$name_width" "$display_name" "$status_text" "$display_summary"
      fi
    done
    print -r -- ""
  done
}

# ============================================================================ #
# End of zfuncs.zsh
