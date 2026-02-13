#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++ VS CODE EXTENSION CLEANER +++++++++++++++++++++++++ #
# ============================================================================ #
# Safe cleanup of duplicate VS Code extension versions on macOS and Linux.
#
# This script scans a VS Code extensions directory, groups multiple installed
# versions of the same extension, and plans/removes redundant copies.
#
# Key features:
#  - Version-aware duplicate detection (not mtime-only).
#  - Safe mode: protects versions referenced by VS Code manifests/profiles.
#  - Dry-run by default.
#  - Shared logging/confirm helpers.
#
# Supported strategies:
#  - newest : Keep newest version, remove older duplicates.
#  - oldest : Remove only the oldest duplicate per extension.
#  - all    : Alias of "newest" (kept for backward compatibility).
#
# CLI usage:
#   vscode_extension_cleaner.sh <extensions_dir> [strategy] [dry_run] [debug] [respect_references]
#
# Examples:
#   vscode_extension_cleaner.sh "$HOME/.vscode/extensions"
#   vscode_extension_cleaner.sh "$HOME/.vscode/extensions" newest false
#   vscode_extension_cleaner.sh "$HOME/.vscode/extensions" oldest true true false
#
# Author: XtremeXSPC
# License: MIT
# ============================================================================ #

# ++++++++++++++++++++++++++++++ CONFIGURATION +++++++++++++++++++++++++++++++ #

_VSCODE_EXT_CLEAN_DEFAULT_DIR="${HOME}/.vscode/extensions"
_VSCODE_EXT_CLEAN_DEFAULT_STRATEGY="newest"
_VSCODE_EXT_CLEAN_DEFAULT_DRY_RUN="true"
_VSCODE_EXT_CLEAN_DEFAULT_DEBUG="false"
_VSCODE_EXT_CLEAN_DEFAULT_RESPECT_REFERENCES="true"

# ++++++++++++++++++++++++++ SHARED HELPERS LOADER +++++++++++++++++++++++++++ #

_vscode_ext_clean_helpers_dir="${ZSH_CONFIG_DIR:-$HOME/.config/zsh}/scripts"
if [[ -r "${_vscode_ext_clean_helpers_dir}/_shared_helpers.sh" ]]; then
  # shellcheck disable=SC1091
  source "${_vscode_ext_clean_helpers_dir}/_shared_helpers.sh"
else
  printf "[ERROR] Shared helpers not found: %s/_shared_helpers.sh\n" "$_vscode_ext_clean_helpers_dir" >&2
  return 1 2>/dev/null || exit 1
fi
unset _vscode_ext_clean_helpers_dir

# +++++++++++++++++++++++++++++ HELPER UTILITIES +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _vscode_ext_clean_usage
# -----------------------------------------------------------------------------
# Prints command usage and examples.
# -----------------------------------------------------------------------------
_vscode_ext_clean_usage() {
  cat <<'EOF'
Usage:
  vscode_extension_cleaner.sh <extensions_dir> [strategy] [dry_run] [debug] [respect_references]

Arguments:
  extensions_dir       Path to VS Code extensions directory (required).
  strategy             newest | oldest | all (default: newest; all = newest alias).
  dry_run              true | false (default: true).
  debug                true | false (default: false).
  respect_references   true | false (default: true).

Examples:
  vscode_extension_cleaner.sh "$HOME/.vscode/extensions"
  vscode_extension_cleaner.sh "$HOME/.vscode/extensions" newest false
  vscode_extension_cleaner.sh "$HOME/.vscode/extensions" oldest true true false
EOF
}

# -----------------------------------------------------------------------------
# _vscode_ext_clean_get_mtime
# -----------------------------------------------------------------------------
# Returns modification time (epoch seconds) for a path.
#
# Usage:
#   mtime=$(_vscode_ext_clean_get_mtime <path>)
#
# Returns:
#   0 - mtime printed to stdout.
#   1 - Could not read mtime.
# -----------------------------------------------------------------------------
_vscode_ext_clean_get_mtime() {
  local target_path="$1"
  local mtime

  if mtime=$(stat -f %m "$target_path" 2>/dev/null); then
    printf "%s\n" "$mtime"
    return 0
  fi
  if mtime=$(stat -c %Y "$target_path" 2>/dev/null); then
    printf "%s\n" "$mtime"
    return 0
  fi

  return 1
}

# -----------------------------------------------------------------------------
# _vscode_ext_clean_epoch_to_date
# -----------------------------------------------------------------------------
# Formats an epoch timestamp into a human-readable date.
#
# Usage:
#   formatted=$(_vscode_ext_clean_epoch_to_date <epoch>)
# -----------------------------------------------------------------------------
_vscode_ext_clean_epoch_to_date() {
  local epoch="$1"
  local out

  if out=$(date -r "$epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null); then
    printf "%s\n" "$out"
    return 0
  fi
  if out=$(date -d "@$epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null); then
    printf "%s\n" "$out"
    return 0
  fi

  printf "N/A\n"
}

# -----------------------------------------------------------------------------
# _vscode_ext_clean_parse_name
# -----------------------------------------------------------------------------
# Parses extension directory name into:
#   - _vscode_ext_clean_core_name
#   - _vscode_ext_clean_version
#
# Expected formats:
#   publisher.extension-1.2.3
#   publisher.extension-1.2.3-darwin-arm64
# If no suffix starts with a digit, the whole name is treated as core.
#
# Usage:
#   _vscode_ext_clean_parse_name <folder_name>
# -----------------------------------------------------------------------------
_vscode_ext_clean_parse_name() {
  setopt localoptions noksharrays

  local folder_name="$1"
  _vscode_ext_clean_core_name="$folder_name"
  _vscode_ext_clean_version=""

  if [[ "$folder_name" =~ ^(.*)-([0-9][0-9A-Za-z._+-]*)$ ]]; then
    _vscode_ext_clean_core_name="${match[1]}"
    _vscode_ext_clean_version="${match[2]}"
  fi
}

# -----------------------------------------------------------------------------
# _vscode_ext_clean_version_cmp
# -----------------------------------------------------------------------------
# Compares two version strings.
#
# Usage:
#   cmp=$(_vscode_ext_clean_version_cmp <left> <right>)
#
# Output:
#   1   left > right
#   0   left == right
#  -1   left < right
#
# Notes:
#   - Numeric tokens are compared numerically.
#   - Text tokens are compared lexicographically (case-insensitive).
#   - Missing tokens are treated as 0.
# -----------------------------------------------------------------------------
_vscode_ext_clean_version_cmp() {
  setopt localoptions ksharrays

  local left="$1" right="$2"
  local i max left_token right_token left_lower right_lower
  local normalized_left normalized_right
  local -a left_parts=() right_parts=()

  if [[ -z "$left" && -z "$right" ]]; then
    printf "%s\n" "0"
    return 0
  fi
  if [[ -z "$left" ]]; then
    printf "%s\n" "-1"
    return 0
  fi
  if [[ -z "$right" ]]; then
    printf "%s\n" "1"
    return 0
  fi

  normalized_left="${left//[._+-]/ }"
  normalized_right="${right//[._+-]/ }"
  left_parts=(${=normalized_left})
  right_parts=(${=normalized_right})

  max=${#left_parts[@]}
  if (( ${#right_parts[@]} > max )); then
    max=${#right_parts[@]}
  fi

  for ((i = 0; i < max; i++)); do
    left_token="${left_parts[i]:-0}"
    right_token="${right_parts[i]:-0}"

    if [[ "$left_token" =~ ^[0-9]+$ && "$right_token" =~ ^[0-9]+$ ]]; then
      if (( 10#$left_token > 10#$right_token )); then
        printf "%s\n" "1"
        return 0
      fi
      if (( 10#$left_token < 10#$right_token )); then
        printf "%s\n" "-1"
        return 0
      fi
      continue
    fi

    if [[ "$left_token" =~ ^[0-9]+$ && ! "$right_token" =~ ^[0-9]+$ ]]; then
      printf "%s\n" "1"
      return 0
    fi
    if [[ ! "$left_token" =~ ^[0-9]+$ && "$right_token" =~ ^[0-9]+$ ]]; then
      printf "%s\n" "-1"
      return 0
    fi

    left_lower=$(printf "%s" "$left_token" | tr '[:upper:]' '[:lower:]')
    right_lower=$(printf "%s" "$right_token" | tr '[:upper:]' '[:lower:]')
    if [[ "$left_lower" > "$right_lower" ]]; then
      printf "%s\n" "1"
      return 0
    fi
    if [[ "$left_lower" < "$right_lower" ]]; then
      printf "%s\n" "-1"
      return 0
    fi
  done

  printf "%s\n" "0"
}

# -----------------------------------------------------------------------------
# _vscode_ext_clean_collect_reference_names
# -----------------------------------------------------------------------------
# Collects referenced extension folder names from VS Code manifests:
#   - extensions/extensions.json
#   - User profile extensions.json files (Stable + Insiders)
#
# Usage:
#   _vscode_ext_clean_collect_reference_names <extensions_dir> <output_file>
#
# Returns:
#   0 - Collection completed.
# -----------------------------------------------------------------------------
_vscode_ext_clean_collect_reference_names() {
  local extensions_dir="$1"
  local output_file="$2"
  local manifest
  local manifest_files=()
  local profile_root

  : > "$output_file"

  if [[ -f "${extensions_dir}/extensions.json" ]]; then
    manifest_files+=("${extensions_dir}/extensions.json")
  fi
  if [[ -f "${HOME}/.vscode/extensions/extensions.json" ]]; then
    manifest_files+=("${HOME}/.vscode/extensions/extensions.json")
  fi
  if [[ -f "${HOME}/.vscode-insiders/extensions/extensions.json" ]]; then
    manifest_files+=("${HOME}/.vscode-insiders/extensions/extensions.json")
  fi

  for profile_root in \
    "${HOME}/Library/Application Support/Code/User/profiles" \
    "${HOME}/Library/Application Support/Code - Insiders/User/profiles" \
    "${HOME}/.config/Code/User/profiles" \
    "${HOME}/.config/Code - Insiders/User/profiles"; do
    if [[ -d "$profile_root" ]]; then
      while IFS= read -r manifest; do
        manifest_files+=("$manifest")
      done < <(find "$profile_root" -mindepth 2 -maxdepth 2 -type f -name "extensions.json" 2>/dev/null)
    fi
  done

  for manifest in "${manifest_files[@]}"; do
    grep -oE '"relativeLocation":"[^"]+"' "$manifest" 2>/dev/null \
      | sed -E 's/^"relativeLocation":"([^"]+)"$/\1/' >> "$output_file"

    grep -oE '"path":"[^"]+/extensions/[^"]+"' "$manifest" 2>/dev/null \
      | sed -E 's#^"path":"[^"]+/extensions/([^"]+)"$#\1#' >> "$output_file"
  done

  if [[ -s "$output_file" ]]; then
    local tmp_sorted="${output_file}.sorted"
    sed '/^[[:space:]]*$/d' "$output_file" | LC_ALL=C sort -u > "$tmp_sorted"
    mv "$tmp_sorted" "$output_file"
  fi

  return 0
}

# -----------------------------------------------------------------------------
# _vscode_ext_clean_is_referenced
# -----------------------------------------------------------------------------
# Checks whether an extension directory name is referenced by manifests.
#
# Usage:
#   _vscode_ext_clean_is_referenced <folder_name> <reference_file>
#
# Returns:
#   0 - Referenced.
#   1 - Not referenced.
# -----------------------------------------------------------------------------
_vscode_ext_clean_is_referenced() {
  local folder_name="$1"
  local reference_file="$2"

  [[ -s "$reference_file" ]] || return 1
  grep -Fqx "$folder_name" "$reference_file"
}

# -----------------------------------------------------------------------------
# _vscode_ext_clean_validate_strategy
# -----------------------------------------------------------------------------
# Validates and normalizes strategy argument.
#
# Usage:
#   normalized=$(_vscode_ext_clean_validate_strategy <strategy>)
#
# Returns:
#   0 - Strategy is valid.
#   1 - Invalid strategy.
# -----------------------------------------------------------------------------
_vscode_ext_clean_validate_strategy() {
  local strategy="$1"
  case "$strategy" in
    newest|oldest)
      printf "%s\n" "$strategy"
      return 0
      ;;
    all)
      printf "newest\n"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# -----------------------------------------------------------------------------
# _vscode_ext_clean_run
# -----------------------------------------------------------------------------
# Main worker for extension cleanup.
#
# Usage:
#   _vscode_ext_clean_run <dir> [strategy] [dry_run] [debug] [respect_refs]
# -----------------------------------------------------------------------------
_vscode_ext_clean_run() {
  setopt localoptions localtraps ksharrays

  local folder_path="$1"
  local requested_strategy="${2:-$_VSCODE_EXT_CLEAN_DEFAULT_STRATEGY}"
  local dry_run="${3:-$_VSCODE_EXT_CLEAN_DEFAULT_DRY_RUN}"
  local debug="${4:-$_VSCODE_EXT_CLEAN_DEFAULT_DEBUG}"
  local respect_refs="${5:-$_VSCODE_EXT_CLEAN_DEFAULT_RESPECT_REFERENCES}"
  local strategy

  _shared_init_colors

  if [[ -z "$folder_path" ]]; then
    _shared_log error "Missing required argument: <extensions_dir>."
    _vscode_ext_clean_usage
    return 1
  fi
  if [[ ! -d "$folder_path" ]]; then
    _shared_log error "Invalid directory: $folder_path"
    return 1
  fi

  strategy=$(_vscode_ext_clean_validate_strategy "$requested_strategy") || {
    _shared_log error "Invalid strategy: $requested_strategy (use newest|oldest|all)."
    return 1
  }
  if [[ "$requested_strategy" == "all" ]]; then
    _shared_log info "Strategy 'all' is treated as alias for 'newest'."
  fi

  if ! _shared_is_bool "$dry_run"; then
    _shared_log error "Invalid dry_run value: $dry_run (use true|false)."
    return 1
  fi
  if ! _shared_is_bool "$debug"; then
    _shared_log error "Invalid debug value: $debug (use true|false)."
    return 1
  fi
  if ! _shared_is_bool "$respect_refs"; then
    _shared_log error "Invalid respect_references value: $respect_refs (use true|false)."
    return 1
  fi

  _shared_log info "Scanning VS Code extensions in: $folder_path"
  _shared_log info "Strategy: $strategy"
  if [[ "$dry_run" == "true" ]]; then
    _shared_log info "Running in DRY-RUN mode (no deletions)."
  else
    _shared_log warn "Running in DELETE mode (permanent removal)."
    _shared_confirm "Proceed with deletion?" || {
      _shared_log info "Aborted by user."
      return 0
    }
  fi

  local temp_dir
  temp_dir=$(mktemp -d 2>/dev/null) || {
    _shared_log error "Failed to create temporary working directory."
    return 1
  }
  trap 'rm -rf "$temp_dir"' EXIT

  local all_dirs_file="${temp_dir}/all_dirs.txt"
  local records_file="${temp_dir}/records.txt"
  local cores_file="${temp_dir}/cores.txt"
  local to_delete_file="${temp_dir}/to_delete.txt"
  local referenced_names_file="${temp_dir}/referenced_names.txt"

  find "$folder_path" -mindepth 1 -maxdepth 1 -type d > "$all_dirs_file"
  if [[ ! -s "$all_dirs_file" ]]; then
    _shared_log info "No extension directories found in: $folder_path"
    return 0
  fi

  : > "$records_file"
  : > "$to_delete_file"
  : > "$referenced_names_file"

  local ext_path ext_name ext_core ext_version ext_mtime
  while IFS= read -r ext_path; do
    ext_name=$(basename "$ext_path")
    _vscode_ext_clean_parse_name "$ext_name"
    ext_core="$_vscode_ext_clean_core_name"
    ext_version="$_vscode_ext_clean_version"
    ext_mtime=$(_vscode_ext_clean_get_mtime "$ext_path" 2>/dev/null || printf "0")
    printf "%s|%s|%s|%s|%s\n" "$ext_path" "$ext_name" "$ext_core" "$ext_version" "$ext_mtime" >> "$records_file"
  done < "$all_dirs_file"

  if [[ "$respect_refs" == "true" ]]; then
    _vscode_ext_clean_collect_reference_names "$folder_path" "$referenced_names_file"
    if [[ -s "$referenced_names_file" ]]; then
      _shared_log info "Reference protection enabled."
      _shared_log info "Found $(wc -l < "$referenced_names_file" | tr -d ' ') referenced extension entries."
    else
      _shared_log warn "Reference protection enabled, but no references were found."
    fi
  else
    _shared_log warn "Reference protection disabled."
  fi

  cut -d'|' -f3 "$records_file" | LC_ALL=C sort -u > "$cores_file"

  local core
  local duplicate_groups=0
  local planned_deletions=0
  local protected_skips=0

  while IFS= read -r core; do
    local group_paths=()
    local group_names=()
    local group_versions=()
    local group_mtimes=()
    local group_count=0

    while IFS='|' read -r ext_path ext_name ext_core ext_version ext_mtime; do
      [[ "$ext_core" == "$core" ]] || continue
      group_paths[group_count]="$ext_path"
      group_names[group_count]="$ext_name"
      group_versions[group_count]="$ext_version"
      group_mtimes[group_count]="$ext_mtime"
      ((group_count++))
    done < "$records_file"

    if (( group_count <= 1 )); then
      continue
    fi

    ((duplicate_groups++))
    printf "\n%sExtension '%s' has %d installed versions:%s\n" "$C_BOLD" "$core" "$group_count" "$C_RESET"

    local idx modified_date
    for ((idx = 0; idx < group_count; idx++)); do
      modified_date=$(_vscode_ext_clean_epoch_to_date "${group_mtimes[idx]}")
      printf "  - %s (version: %s, modified: %s)\n" \
        "${group_paths[idx]}" "${group_versions[idx]:-unknown}" "$modified_date"
    done

    local newest_idx=0
    local cmp
    for ((idx = 1; idx < group_count; idx++)); do
      cmp=$(_vscode_ext_clean_version_cmp "${group_versions[idx]}" "${group_versions[newest_idx]}")
      if (( cmp > 0 )); then
        newest_idx=$idx
        continue
      fi
      if (( cmp == 0 )) && (( group_mtimes[idx] > group_mtimes[newest_idx] )); then
        newest_idx=$idx
      fi
    done

    local oldest_unreferenced_idx=-1
    for ((idx = 0; idx < group_count; idx++)); do
      if [[ "$respect_refs" == "true" ]] && _vscode_ext_clean_is_referenced "${group_names[idx]}" "$referenced_names_file"; then
        continue
      fi
      if (( oldest_unreferenced_idx < 0 )); then
        oldest_unreferenced_idx=$idx
        continue
      fi
      cmp=$(_vscode_ext_clean_version_cmp "${group_versions[idx]}" "${group_versions[oldest_unreferenced_idx]}")
      if (( cmp < 0 )); then
        oldest_unreferenced_idx=$idx
        continue
      fi
      if (( cmp == 0 )) && (( group_mtimes[idx] < group_mtimes[oldest_unreferenced_idx] )); then
        oldest_unreferenced_idx=$idx
      fi
    done

    case "$strategy" in
      newest)
        for ((idx = 0; idx < group_count; idx++)); do
          if (( idx == newest_idx )); then
            continue
          fi

          if [[ "$respect_refs" == "true" ]] && _vscode_ext_clean_is_referenced "${group_names[idx]}" "$referenced_names_file"; then
            _shared_log warn "Skipping referenced version: ${group_paths[idx]}"
            ((protected_skips++))
            continue
          fi

          printf "%s\n" "${group_paths[idx]}" >> "$to_delete_file"
          ((planned_deletions++))
        done
        ;;
      oldest)
        if (( oldest_unreferenced_idx < 0 )); then
          _shared_log warn "No unreferenced candidate found for oldest strategy."
          continue
        fi
        printf "%s\n" "${group_paths[oldest_unreferenced_idx]}" >> "$to_delete_file"
        ((planned_deletions++))
        ;;
    esac
  done < "$cores_file"

  echo
  _shared_log info "Duplicate groups found: $duplicate_groups"
  _shared_log info "Planned deletions: $planned_deletions"
  if (( protected_skips > 0 )); then
    _shared_log info "Skipped due to references: $protected_skips"
  fi

  if [[ ! -s "$to_delete_file" ]]; then
    _shared_log ok "No extension folders selected for deletion."
    return 0
  fi

  local final_delete_file="${temp_dir}/to_delete_unique.txt"
  LC_ALL=C sort -u "$to_delete_file" > "$final_delete_file"
  local delete_count
  delete_count=$(wc -l < "$final_delete_file" | tr -d ' ')

  printf "\n%sFolders selected for deletion:%s\n" "$C_BOLD" "$C_RESET"
  sed 's/^/  - /' "$final_delete_file"

  if [[ "$dry_run" == "true" ]]; then
    echo
    _shared_log ok "Dry run complete. $delete_count folder(s) would be deleted."
    return 0
  fi

  local deleted_count=0 failed_count=0
  while IFS= read -r ext_path; do
    if [[ -z "$ext_path" ]]; then
      continue
    fi
    case "$ext_path" in
      "$folder_path"/*) ;;
      *)
        _shared_log error "Refusing to delete outside target directory: $ext_path"
        ((failed_count++))
        continue
        ;;
    esac

    if [[ -d "$ext_path" ]]; then
      if rm -rf "$ext_path"; then
        _shared_log ok "Deleted: $ext_path"
        ((deleted_count++))
      else
        _shared_log error "Failed to delete: $ext_path"
        ((failed_count++))
      fi
    fi
  done < "$final_delete_file"

  echo
  _shared_log info "Deletion summary: $deleted_count deleted, $failed_count failed."
  if (( failed_count > 0 )); then
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# vscode_clean_extensions
# -----------------------------------------------------------------------------
# Backward-compatible public function.
#
# Usage:
#   vscode_clean_extensions <dir> [strategy] [dry_run] [debug] [respect_refs]
# -----------------------------------------------------------------------------
vscode_clean_extensions() {
  _vscode_ext_clean_run "$@"
}

# -----------------------------------------------------------------------------
# vscode_clean_extension
# -----------------------------------------------------------------------------
# Singular alias for convenience and typo-resistance.
# -----------------------------------------------------------------------------
vscode_clean_extension() {
  vscode_clean_extensions "$@"
}

# -----------------------------------------------------------------------------
# _vscode_ext_clean_main
# -----------------------------------------------------------------------------
# Script entrypoint for direct execution.
# -----------------------------------------------------------------------------
_vscode_ext_clean_main() {
  if [[ $# -lt 1 ]]; then
    _vscode_ext_clean_usage
    return 1
  fi
  _vscode_ext_clean_run "$@"
}

if [[ "${ZSH_EVAL_CONTEXT:-}" == toplevel ]]; then
  _vscode_ext_clean_main "$@"
fi
