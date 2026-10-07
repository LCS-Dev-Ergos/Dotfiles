#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++ C AND C++ TOOLCHAIN INTEGRATION ++++++++++++++++++++++ #
# ============================================================================ #

# Conservative C/C++ defaults: keep them tool-friendly and non-invasive.
# Avoid global optimization flags here; project build files should own those.

# Baseline CC/CXX come from home/dev/toolchains/llvm through Home Manager's
# session variables, so every managed shell receives immutable compiler paths.
# On Darwin, the priority-5 drivers also cover tools that ignore CC/CXX and
# invoke a generic compiler name directly. `use_llvm`/`use_gnu` can still
# override the active toolchain per shell.

if command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ccache"
  export CCACHE_COMPRESS=1
  export CCACHE_COMPRESSLEVEL="${CCACHE_COMPRESSLEVEL:-5}"
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-10G}"

  # The default mtime+size compiler check cannot tell Nix toolchain versions
  # apart: store files share epoch mtimes and the driver scripts keep a stable
  # size across bumps, so stale hits could survive an upgrade. The drivers
  # embed their store paths, so hashing their content is a reliable signature.
  export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"

  # CMake launcher variables (used by CMake projects when available).
  export CMAKE_C_COMPILER_LAUNCHER="ccache"
  export CMAKE_CXX_COMPILER_LAUNCHER="ccache"
fi

# Enable compile_commands.json generation for LSP/tooling in CMake projects.
: "${CMAKE_EXPORT_COMPILE_COMMANDS:=1}"
export CMAKE_EXPORT_COMPILE_COMMANDS

# An unavailable optional integration is a successful no-op.
:
