#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# VS Code extension cleaner wrapper.
# Loads the dedicated VS Code cleaner module and preserves CLI behavior.
# ============================================================================ #

_vscode_ext_wrapper_path="${${(%):-%N}:A}"
_vscode_ext_wrapper_dir="${_vscode_ext_wrapper_path:h}"
_vscode_ext_module="${_vscode_ext_wrapper_dir}/vscode/extension_cleaner.sh"

if [[ -r "$_vscode_ext_module" ]]; then
  # shellcheck disable=SC1090
  source "$_vscode_ext_module"
else
  printf "[ERROR] VS Code extension cleaner module not found: %s\n" "$_vscode_ext_module" >&2
  return 1 2>/dev/null || exit 1
fi

unset _vscode_ext_wrapper_path
unset _vscode_ext_wrapper_dir
unset _vscode_ext_module

if [[ "${ZSH_EVAL_CONTEXT:-}" == toplevel ]]; then
  _vscode_ext_clean_main "$@"
fi

# ============================================================================ #
# End of script.
