#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++ VS CODE EXTENSION CLEANER +++++++++++++++++++++++++ #
# ============================================================================ #
# Thin shell wrapper around the Python cleanup backend.
#
# The Python backend is the source of truth for duplicate-extension cleanup.
# This shell layer keeps the historical command surface used by dotfiles and
# other shell modules.
#
# Author: XtremeXSPC
# License: MIT
# ============================================================================ #

_VSCODE_EXT_CLEAN_DEFAULT_DIR="${HOME}/.vscode/extensions"
_VSCODE_EXT_CLEAN_DEFAULT_STRATEGY="newest"
_VSCODE_EXT_CLEAN_DEFAULT_DRY_RUN="true"
_VSCODE_EXT_CLEAN_DEFAULT_DEBUG="false"
_VSCODE_EXT_CLEAN_DEFAULT_RESPECT_REFERENCES="true"
_VSCODE_EXT_CLEAN_DEFAULT_AUTO_CONFIRM="false"
_VSCODE_EXT_CLEAN_DEFAULT_PRUNE_STALE_REFERENCES="false"

_vscode_ext_clean_common="${${(%):-%N}:A:h}/_common.zsh"
if [[ -r "$_vscode_ext_clean_common" ]]; then
  # shellcheck disable=SC1090
  source "$_vscode_ext_clean_common"
else
  printf "[ERROR] vscode common module not found: %s\n" "$_vscode_ext_clean_common" >&2
  return 1 2>/dev/null || exit 1
fi
unset _vscode_ext_clean_common

# -----------------------------------------------------------------------------
# _vscode_ext_clean_usage
# @internal
# @description Prints command usage and examples.
# @noargs
# -----------------------------------------------------------------------------
_vscode_ext_clean_usage() {
  printf "%s\n" \
    "Usage:" \
    "  vscode-extension-cleaner.zsh <extensions_dir> [strategy] [dry_run] [debug] [respect_references] [auto_confirm] [prune_stale_references]" \
    "" \
    "Arguments:" \
    "  extensions_dir       Path to VS Code extensions directory (required)." \
    "  strategy             newest | oldest | all (default: newest; all = newest alias)." \
    "  dry_run              true | false (default: true)." \
    "  debug                true | false (default: false)." \
    "  respect_references   true | false (default: true)." \
    "  auto_confirm         true | false (default: false)." \
    "  prune_stale_refs     true | false (default: false)." \
    "" \
    "Notes:" \
    "  - Cleanup is quarantine-based, not destructive deletion." \
    "  - By default, every manifest-named folder is protected." \
    "  - Enable prune_stale_refs only when you explicitly want aggressive duplicate cleanup." \
    "  - The Python backend is required for cleanup operations." \
    "" \
    "Examples:" \
    "  vscode-extension-cleaner.zsh \"\$HOME/.vscode/extensions\"" \
    "  vscode-extension-cleaner.zsh \"\$HOME/.vscode/extensions\" newest false" \
    "  vscode-extension-cleaner.zsh \"\$HOME/.vscode/extensions\" oldest true true false true false"
}

# -----------------------------------------------------------------------------
# _vscode_ext_clean_validate_strategy
# @internal
# @description Validates and normalizes the cleanup strategy; "all" aliases
# to "newest".
# @arg $1 string Requested strategy: newest, oldest, or all.
# @exitcode 1 If the strategy is none of the above.
# @stdout The normalized strategy, on success.
# -----------------------------------------------------------------------------
_vscode_ext_clean_validate_strategy() {
  local requested_strategy="$1"
  case "$requested_strategy" in
    newest|oldest) printf "%s\n" "$requested_strategy" ;;
    all) printf "%s\n" "newest" ;;
    *) return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# _vscode_ext_clean_run_python
# @internal
# @description Validates the historical positional shell arguments and
# invokes the Python cleanup backend.
# @arg $1 path Extensions directory.
# @arg $2 string Optional strategy: newest, oldest, or all.
# @arg $3 boolean Optional dry-run flag; defaults to true.
# @arg $4 boolean Optional debug flag; defaults to false.
# @arg $5 boolean Optional reference protection; defaults to true.
# @arg $6 boolean Optional auto-confirm flag; defaults to false.
# @arg $7 boolean Optional stale-reference pruning; defaults to false.
# @exitcode 1 If an argument is invalid or the Python backend is unavailable.
# -----------------------------------------------------------------------------
_vscode_ext_clean_run_python() {
  local folder_path="$1"
  local requested_strategy="${2:-$_VSCODE_EXT_CLEAN_DEFAULT_STRATEGY}"
  local dry_run="${3:-$_VSCODE_EXT_CLEAN_DEFAULT_DRY_RUN}"
  local debug="${4:-$_VSCODE_EXT_CLEAN_DEFAULT_DEBUG}"
  local respect_refs="${5:-$_VSCODE_EXT_CLEAN_DEFAULT_RESPECT_REFERENCES}"
  local auto_confirm="${6:-$_VSCODE_EXT_CLEAN_DEFAULT_AUTO_CONFIRM}"
  local prune_stale_refs="${7:-$_VSCODE_EXT_CLEAN_DEFAULT_PRUNE_STALE_REFERENCES}"
  local strategy

  strategy=$(_vscode_ext_clean_validate_strategy "$requested_strategy") || {
    _shared_log error "Invalid strategy: $requested_strategy (use newest|oldest|all)."
    return 1
  }

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
  if ! _shared_is_bool "$auto_confirm"; then
    _shared_log error "Invalid auto_confirm value: $auto_confirm (use true|false)."
    return 1
  fi
  if ! _shared_is_bool "$prune_stale_refs"; then
    _shared_log error "Invalid prune_stale_references value: $prune_stale_refs (use true|false)."
    return 1
  fi

  if ! _vscode_python_backend_available; then
    _shared_log error "Cleaner: Python backend unavailable."
    return 1
  fi

  local -a cmd=(
    env
    "VSCODE_SYNC_FORCE_COLOR=${VSCODE_SYNC_FORCE_COLOR:-1}"
    python3
    "${_VSCODE_MODULE_ROOT}/python/cli.py"
    clean
    "$folder_path"
    --home "$HOME"
    --strategy "$strategy"
  )

  [[ "$respect_refs" == "true" ]] || cmd+=(--no-respect-references)
  [[ "$prune_stale_refs" == "true" ]] && cmd+=(--prune-stale-references)
  [[ "$dry_run" == "true" ]] || cmd+=(--apply)
  [[ "$auto_confirm" == "true" ]] && cmd+=(--yes)
  [[ "$debug" == "true" ]] && _shared_log info "Cleaner: using Python backend."

  "${cmd[@]}"
}

# -----------------------------------------------------------------------------
# _vscode_ext_clean_run
# @internal
# @description Backward-compatible entrypoint used by the sync update
# wrapper; validates the required directory argument before delegating.
# @arg $1 path Extensions directory.
# @arg $@ string Remaining arguments forwarded to _vscode_ext_clean_run_python.
# @exitcode 1 If the extensions directory argument is missing, or the
# delegated cleanup fails.
# -----------------------------------------------------------------------------
_vscode_ext_clean_run() {
  local folder_path="$1"

  if [[ -z "$folder_path" ]]; then
    _shared_log error "Missing required argument: <extensions_dir>."
    _vscode_ext_clean_usage
    return 1
  fi

  _vscode_ext_clean_run_python "$@"
}

# -----------------------------------------------------------------------------
# vscode_clean_extensions
# -----------------------------------------------------------------------------
# @description Cleans duplicate VS Code extensions through the Python backend.
# Cleanup is quarantine-based by default; dry-run defaults to true.
# @arg $1 path Extensions directory.
# @arg $2 string Optional strategy: newest, oldest, or all.
# @arg $3 boolean Optional dry-run flag; defaults to true.
# @arg $4 boolean Optional debug flag; defaults to false.
# @arg $5 boolean Optional reference protection; defaults to true.
# @arg $6 boolean Optional auto-confirm flag; defaults to false.
# @arg $7 boolean Optional stale-reference pruning; defaults to false.
# @exitcode 1 If an argument, dependency, or cleanup operation is invalid.
# -----------------------------------------------------------------------------
vscode_clean_extensions() {
  _vscode_ext_clean_run "$@"
}

# -----------------------------------------------------------------------------
# vscode_clean_extension
# -----------------------------------------------------------------------------
# @description Alias for vscode_clean_extensions.
# @arg $@ string Arguments forwarded to vscode_clean_extensions.
# @exitcode 1 If the delegated cleanup fails.
# -----------------------------------------------------------------------------
vscode_clean_extension() {
  vscode_clean_extensions "$@"
}

# ============================================================================ #
# End of vscode/extension-cleaner.zsh
