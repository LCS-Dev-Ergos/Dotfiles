# ============================================================================ #
# +++++++++++++++++++++++++ CPP-TOOLS CONFIGURATION ++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Core configuration and shared utilities for cpp-tools.
# Sets workspace paths, colors, script location, and helper functions.
#
# Functions:
#   - _get_default_target     Resolve default C++ target name.
#   - _normalize_target_name  Normalize target identifier (drop extension/path).
#   - _resolve_target_source  Resolve existing source file for a target.
#   - _check_initialized      Ensure project has CMake setup.
#   - _check_workspace        Validate working directory is in workspace.
#   - _problem_label          Normalize problem label for metadata.
#   - _contest_label          Extract contest label from path.
#   - _problem_brief          Build contest/problem brief string.
#   - _format_duration        Format elapsed time values.
#   - _get_timeout_cmd        Select available timeout command.
#   - _run_with_timeout       Execute command with timeout fallback.
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
  # Honor explicit focus first when set and valid.
  if [ -n "${CP_FOCUSED_TARGET:-}" ]; then
    local focused_target focused_source
    focused_target=$(_normalize_target_name "$CP_FOCUSED_TARGET")
    focused_source=$(_resolve_target_source "$focused_target")
    if [ -n "$focused_source" ]; then
      echo "$focused_target"
      return 0
    fi
  fi

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
# _normalize_target_name
# -----------------------------------------------------------------------------
# Normalize a target identifier by stripping directory and source extension.
# -----------------------------------------------------------------------------
_normalize_target_name() {
  local raw="$1"
  raw="${raw:t}"
  raw="${raw%.cpp}"
  raw="${raw%.cc}"
  raw="${raw%.cxx}"
  echo "$raw"
}

# -----------------------------------------------------------------------------
# _resolve_target_source
# -----------------------------------------------------------------------------
# Resolve the first existing source path among .cpp/.cc/.cxx for a target.
#
# Usage:
#   _resolve_target_source <target_or_filename>
# -----------------------------------------------------------------------------
_resolve_target_source() {
  local target_name
  target_name=$(_normalize_target_name "$1")

  [ -z "$target_name" ] && return 1

  local ext candidate
  for ext in cpp cc cxx; do
    candidate="${target_name}.${ext}"
    if [ -f "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
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
# _problem_label
# -----------------------------------------------------------------------------
# Normalize problem identifier from filenames like:
#   A.cpp, A, problem_A.cpp, problem_A
# Falls back to the raw value when pattern is unknown.
# -----------------------------------------------------------------------------
_problem_label() {
  local raw="$1"
  raw="${raw:t}"
  raw="${raw%.cpp}"
  raw="${raw%.cc}"
  raw="${raw%.cxx}"

  if [[ "$raw" =~ '^problem_([A-Za-z][0-9]*)$' ]]; then
    echo "${match[1]:u}"
    return 0
  fi

  if [[ "$raw" =~ '^([A-Za-z][0-9]*)$' ]]; then
    echo "${match[1]:u}"
    return 0
  fi

  if [ -n "$raw" ]; then
    echo "$raw"
  else
    echo "Y"
  fi
}

# -----------------------------------------------------------------------------
# _contest_label
# -----------------------------------------------------------------------------
# Extract contest round/division from current path or provided string.
# Recognizes forms such as:
#   Round_1070_Div_2, round-1070-div2, Round1070Div2
# -----------------------------------------------------------------------------
_contest_label() {
  local context="${1:-$PWD}"
  local normalized="${context//-/_}"
  local round=""
  local division=""

  if [[ "$normalized" =~ '[Rr]ound[^0-9]*([0-9]+)' ]]; then
    round="${match[1]}"
  fi

  if [[ "$normalized" =~ '[Dd]iv[^0-9]*([0-9]+)' ]]; then
    division="${match[1]}"
  fi

  if [ -z "$round" ]; then
    return 1
  fi

  if [ -n "$division" ]; then
    echo "Codeforces Round ${round} (Div. ${division})"
  else
    echo "Codeforces Round ${round}"
  fi
}

# -----------------------------------------------------------------------------
# _problem_brief
# -----------------------------------------------------------------------------
# Build the standard problem brief string used in templates/submissions.
# -----------------------------------------------------------------------------
_problem_brief() {
  local target_name="$1"
  local problem_name contest_name

  problem_name=$(_problem_label "$target_name")
  contest_name=$(_contest_label "$PWD" 2>/dev/null || true)

  if [ -n "$contest_name" ]; then
    echo "${contest_name} - Problem ${problem_name}"
  else
    echo "Codeforces Round XXX (Div. X) - Problem ${problem_name}"
  fi
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
# Run a command with a timeout binary.
#
# Usage:
#   _run_with_timeout <duration> <command> [args...]
# -----------------------------------------------------------------------------
_run_with_timeout() {
  local duration="$1"
  shift

  local timeout_bin
  timeout_bin=$(_get_timeout_cmd) || true

  if [ -z "$timeout_bin" ]; then
    if [ -z "${_CP_WARNED_TIMEOUT:-}" ]; then
      echo "${C_RED}Error: No timeout command found ('timeout' or 'gtimeout').${C_RESET}" >&2
      echo "${C_YELLOW}Install coreutils (macOS): brew install coreutils${C_RESET}" >&2
      _CP_WARNED_TIMEOUT=1
    else
      echo "${C_RED}Error: timeout utility is required but unavailable.${C_RESET}" >&2
    fi
    return 127
  fi

  "$timeout_bin" "$duration" "$@"
}

# ============================================================================ #
# End of 00-configuration.zsh
