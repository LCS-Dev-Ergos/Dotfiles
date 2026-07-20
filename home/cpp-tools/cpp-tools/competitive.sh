#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ------- Enhanced CMake & Shell Utilities for Competitive Programming ------- #
#
# Zsh functions for a fast, robust, and IDE-friendly CMake workflow.
#
# Key features:
# - Supports isolated GCC and Clang build profiles.
# - Integrates seamlessly with clangd via `compile_commands.json`.
# - Automatically detects and builds all problems in a contest directory.
# - Provides a suite of `cpp*` commands for a fast and intuitive workflow.
# - Workspace protection to prevent accidental initialization outside
#   CP-Problems directory.
#
# ============================================================================ #

# Detect the script directory for reliable access to modules.
# This works for both bash and zsh when the script is sourced.
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
elif [ -n "$ZSH_VERSION" ]; then
  # In zsh, use ${(%):-%x} to get the script path when sourced.
  SCRIPT_DIR="$( cd "$( dirname "${(%):-%x}" )" &> /dev/null && pwd )"
else
  echo "${C_RED}Unsupported shell for script directory detection.${C_RESET}" >&2
  # Fallback to current directory, though this may be unreliable.
  SCRIPT_DIR="."
fi

# Avoid inheriting global CMake launcher variables that can force unusable
# wrappers (e.g. ccache in restricted environments). Set
# CP_TOOLS_KEEP_COMPILER_LAUNCHERS=1 to preserve inherited values.
if [[ "${CP_TOOLS_KEEP_COMPILER_LAUNCHERS:-0}" != "1" ]]; then
  unset CMAKE_C_COMPILER_LAUNCHER
  unset CMAKE_CXX_COMPILER_LAUNCHER
fi

# Source all modules in dependency order and stop on the first failure.
typeset _cp_module
for _cp_module in \
  00-configuration.zsh \
  05-ui.zsh \
  10-project-setup.zsh \
  20-build-run.zsh \
  30-submission.zsh \
  40-compiler.zsh \
  50-utilities.zsh \
  60-aliases.zsh \
  70-help.zsh
do
  if [[ ! -r "$SCRIPT_DIR/modules/$_cp_module" ]]; then
    print -u2 -r -- "cpp-tools: missing module: $_cp_module"
    unset _cp_module
    return 1 2>/dev/null || exit 1
  fi
  if ! source "$SCRIPT_DIR/modules/$_cp_module"; then
    print -u2 -r -- "cpp-tools: failed to load module: $_cp_module"
    unset _cp_module
    return 1 2>/dev/null || exit 1
  fi
done
unset _cp_module

# ============================================================================ #
# End of competitive.sh
