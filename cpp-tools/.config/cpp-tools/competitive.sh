#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ------- Enhanced CMake & Shell Utilities for Competitive Programming ------- #
#
# A collection of shell functions to streamline the C++ competitive programming
# workflow. It uses a CMake-based build system designed to be fast, robust,
# and IDE-friendly, especially on macOS.
#
# Key features:
# - Forces Homebrew GCC for full C++20 support, <bits/stdc++.h>, and PBDS.
# - Integrates seamlessly with clangd via `compile_commands.json`.
# - Automatically detects and builds all problems in a contest directory.
# - Provides a suite of `cpp*` commands for a fast and intuitive workflow.
# - Workspace protection to prevent accidental initialization outside
#   CP-Problems directory.
#
# ============================================================================ #

# Detect the script directory for reliable access to modules.
# This works for both bash and zsh when the script is sourced.
if [ -n "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
elif [ -n "$ZSH_VERSION" ]; then
  # In zsh, use ${(%):-%x} to get the script path when sourced.
  SCRIPT_DIR="$( cd "$( dirname "${(%):-%x}" )" &> /dev/null && pwd )"
else
  echo "${C_RED}Unsupported shell for script directory detection.${C_RESET}" >&2
  # Fallback to current directory, though this may be unreliable.
  SCRIPT_DIR="."
fi

# Source all module files.
source "$SCRIPT_DIR/modules/00-configuration.zsh"
source "$SCRIPT_DIR/modules/10-project-setup.zsh"
source "$SCRIPT_DIR/modules/20-build-run.zsh"
source "$SCRIPT_DIR/modules/30-submission.zsh"
source "$SCRIPT_DIR/modules/40-compiler.zsh"
source "$SCRIPT_DIR/modules/50-utilities.zsh"
source "$SCRIPT_DIR/modules/60-aliases.zsh"
source "$SCRIPT_DIR/modules/70-help.zsh"

# ============================================================================ #
# End of competitive.sh
