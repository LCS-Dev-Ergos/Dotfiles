# ============================================================================ #
# +++++++++++++++++++++++++ CPP-TOOLS CONFIGURATION ++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Core configuration and shared utilities for cpp-tools.
# Sets workspace paths, colors, script location, and helper functions.
#
# Functions:
#   - _get_default_target  Resolve default C++ target name.
#   - _check_initialized   Ensure project has CMake setup.
#   - _check_workspace     Validate working directory is in workspace.
#   - _format_duration     Format elapsed time values.
#   - _get_timeout_cmd     Select available timeout command.
#   - _run_with_timeout    Execute command with timeout fallback.
#
# ============================================================================ #

# Load datetime module for high-precision timing
zmodload zsh/datetime 2>/dev/null || true

# ------------------------------ CONFIGURATION ------------------------------- #

# Define the allowed workspace root directories for competitive programming.
if [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS path.
  CP_WORKSPACE_ROOT="/Volumes/LCS.Data/CP-Problems"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
  # Linux path.
  CP_WORKSPACE_ROOT="/LCS.Data/CP-Problems"
else
  # Fallback - user must set this.
  CP_WORKSPACE_ROOT="${CP_WORKSPACE_ROOT:-$HOME/CP-Problems}"
fi

# Path to global directory containing reusable headers like debug.h.
# The script will create a symlink to this file in new projects.
if [[ "$OSTYPE" == "darwin"* ]]; then
  # Default path for macOS.
  CP_ALGORITHMS_DIR="/Volumes/LCS.Data/CP-Problems/CodeForces/Algorithms"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
  # Default path for Linux.
  CP_ALGORITHMS_DIR="/LCS.Data/CP-Problems/CodeForces/Algorithms"
  # Alternative path if the primary one doesn't exist.
  if [ ! -d "$CP_ALGORITHMS_DIR" ]; then
    CP_ALGORITHMS_DIR="/home/$(whoami)/LCS.Data/CP-Problems/CodeForces/Algorithms"
  fi
else
  # Fallback for other platforms.
  CP_ALGORITHMS_DIR="${CP_ALGORITHMS_DIR:-$HOME/CP/Algorithms}"
fi

# Derived paths for the modular template system.
TEMPLATES_DIR="$CP_ALGORITHMS_DIR/templates"
SCRIPTS_DIR="$CP_ALGORITHMS_DIR/scripts"
MODULES_DIR="$CP_ALGORITHMS_DIR/modules"
SUBMISSIONS_DIR="submissions"

# Path to Perfetto UI directory for trace analysis.
# PERFETTO_UI_DIR="$HOME/Dev/Tools/perfetto"

# Check if terminal supports colors.
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null) -ge 8 ]]; then
  C_RESET=$'\e[0m'
  C_BOLD=$'\e[1m'
  C_RED=$'\e[31m'
  C_GREEN=$'\e[32m'
  C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'
  C_MAGENTA=$'\e[35m'
  C_CYAN=$'\e[36m'
else
  C_RESET=""
  C_BOLD=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_MAGENTA=""
  C_CYAN=""
fi

# Detect the script directory for reliable access to templates.
# This works for both bash and zsh when the script is sourced.
if [ -z "$SCRIPT_DIR" ]; then
  if [ -n "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
  elif [ -n "$ZSH_VERSION" ]; then
    # In zsh, use ${(%):-%x} to get the script path when sourced.
    # shellcheck disable=SC2295
    SCRIPT_DIR="$( cd "$( dirname "${(%):-%x}" )" &> /dev/null && pwd )"
  else
    echo "${C_RED}Unsupported shell for script directory detection.${C_RESET}" >&2
    # Fallback to current directory, though this may be unreliable.
    SCRIPT_DIR="."
  fi
fi

# -----------------------------------------------------------------------------
# _get_default_target
# -----------------------------------------------------------------------------
# Resolve the most recently modified C++ file as target name.
# Falls back to "main" when no source files are present.
# -----------------------------------------------------------------------------
_get_default_target() {
  # Find the most recently modified .cpp, .cc, or .cxx file using Zsh glob qualifiers.
  # (.): regular files
  # om: order by modification time (newest first)
  # [1]: take the first one
  local -a files=( *.(cpp|cc|cxx)(.om[1]) )

  if (( ${#files} )); then
    # Remove extension
    echo "${files[1]:r}"
  else
    echo "main"
  fi
}

# -----------------------------------------------------------------------------
# _check_initialized
# -----------------------------------------------------------------------------
# Verify CMakeLists.txt and build directory exist for a project.
# -----------------------------------------------------------------------------
_check_initialized() {
  if [ ! -f "CMakeLists.txt" ] || [ ! -d "build" ]; then
    echo "${C_RED}Error: Project is not initialized. Please run 'cppinit' first.${C_RESET}" >&2
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# _check_workspace
# -----------------------------------------------------------------------------
# Ensure current directory is within the configured workspace root.
# -----------------------------------------------------------------------------
_check_workspace() {
  local current_dir workspace_dir
  workspace_dir="$CP_WORKSPACE_ROOT"

  if [ -z "$workspace_dir" ] || [ ! -d "$workspace_dir" ]; then
    echo "${C_RED}Error: Workspace root is not configured or missing.${C_RESET}" >&2
    echo "${C_YELLOW}Current directory: $(pwd)${C_RESET}" >&2
    return 1
  fi

  if command -v realpath >/dev/null 2>&1; then
    workspace_dir=$(realpath "$workspace_dir")
    current_dir=$(realpath "$(pwd)")
  else
    workspace_dir=$(cd "$workspace_dir" 2>/dev/null && pwd -P)
    current_dir=$(pwd -P)
  fi

  if [ -z "$workspace_dir" ] || [ -z "$current_dir" ]; then
    echo "${C_RED}Error: Unable to resolve workspace paths.${C_RESET}" >&2
    return 1
  fi

  case "${current_dir}/" in
    "${workspace_dir}/"*) return 0 ;;
    *)
      echo "${C_RED}Error: This command can only be run within the competitive programming workspace.${C_RESET}" >&2
      echo "${C_YELLOW}Expected workspace root: ${workspace_dir}${C_RESET}" >&2
      echo "${C_YELLOW}Current directory: ${current_dir}${C_RESET}" >&2
      return 1
      ;;
  esac
}

# -----------------------------------------------------------------------------
# _format_duration
# -----------------------------------------------------------------------------
# Format elapsed time in seconds into a human-readable string.
#
# Usage:
#   _format_duration <seconds>
# -----------------------------------------------------------------------------
_format_duration() {
  local seconds=$1
  local hours=$((seconds / 3600))
  local minutes=$(((seconds % 3600) / 60))
  local secs=$((seconds % 60))

  if [ $hours -gt 0 ]; then
    printf "%dh %dm %ds" $hours $minutes $secs
  elif [ $minutes -gt 0 ]; then
    printf "%dm %ds" $minutes $secs
  else
    printf "%ds" $secs
  fi
}

# -----------------------------------------------------------------------------
# _get_timeout_cmd
# -----------------------------------------------------------------------------
# Choose the available timeout binary (timeout or gtimeout).
# -----------------------------------------------------------------------------
_get_timeout_cmd() {
  if command -v timeout >/dev/null 2>&1; then
    echo "timeout"
    return 0
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    echo "gtimeout"
    return 0
  fi
  return 1
}

# -----------------------------------------------------------------------------
# _run_with_timeout
# -----------------------------------------------------------------------------
# Run a command with a timeout when possible, with Python fallback.
#
# Usage:
#   _run_with_timeout <duration> <command> [args...]
# -----------------------------------------------------------------------------
_run_with_timeout() {
  local duration="$1"
  shift

  local timeout_bin
  timeout_bin=$(_get_timeout_cmd) || true

  if [ -n "$timeout_bin" ]; then
    "$timeout_bin" "$duration" "$@"
    return $?
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$duration" "$@" <<'PY'
import subprocess, sys

raw_duration = sys.argv[1]
cmd = sys.argv[2:]

try:
    timeout = float(raw_duration[:-1]) if raw_duration.endswith("s") else float(raw_duration)
except Exception:
    timeout = None

try:
    result = subprocess.run(cmd, timeout=timeout, check=False)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
PY
    return $?
  fi

  if [ -z "${_CP_WARNED_TIMEOUT:-}" ]; then
    echo "${C_YELLOW}Warning: No timeout utility available; running without a time limit.${C_RESET}" >&2
    _CP_WARNED_TIMEOUT=1
  fi

  "$@"
}

# ============================================================================ #
# End of 00-configuration.zsh
