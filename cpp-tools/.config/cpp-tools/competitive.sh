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
if [[ -t 1 ]] && command -v tput >/dev/null && [[ $(tput colors) -ge 8 ]]; then
    C_RESET="\e[0m"
    C_BOLD="\e[1m"
    C_RED="\e[31m"
    C_GREEN="\e[32m"
    C_YELLOW="\e[33m"
    BLUE="\e[34m"
    C_BLUE="$BLUE"
    C_MAGENTA="\e[35m"
    C_CYAN="\e[36m"
else
    C_RESET=""
    C_BOLD=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    BLUE=""
    C_BLUE=""
    C_MAGENTA=""
    C_CYAN=""
fi

# Detect the script directory for reliable access to templates.
# This works for both bash and zsh when the script is sourced.
if [ -n "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
elif [ -n "$ZSH_VERSION" ]; then
    # In zsh, use ${(%):-%x} to get the script path when sourced
    SCRIPT_DIR="$( cd "$( dirname "${(%):-%x}" )" &> /dev/null && pwd )"
else
    echo "${C_RED}Unsupported shell for script directory detection.${C_RESET}" >&2
    # Fallback to current directory, though this may be unreliable.
    SCRIPT_DIR="."
fi

# Utility to get the last modified cpp file as the default target.
_get_default_target() {
    # Find the most recently modified .cpp, .cc, or .cxx file.
    local default_target
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS version using stat
        default_target=$(find . -maxdepth 1 -type f \
            \( -name "*.cpp" -o -name "*.cc" -o -name "*.cxx" \) \
            -exec stat -f '%m %N' {} \; 2>/dev/null \
            | sort -rn \
            | head -n 1 \
            | sed -E 's/^[0-9]+ \.\/(.+)\.(cpp|cc|cxx)$/\1/')
    else
        # Linux version with -printf
        default_target=$(find . -maxdepth 1 -type f \
            \( -name "*.cpp" -o -name "*.cc" -o -name "*.cxx" \) \
            -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn \
            | head -n 1 \
            | sed -E 's/^[0-9.]+ \.\/(.+)\.(cpp|cc|cxx)$/\1/')
    fi
    # If no file is found, default to "main".
    echo "${default_target:-main}"
}

# Utility to check if the project is initialized.
_check_initialized() {
    if [ ! -f "CMakeLists.txt" ] || [ ! -d "build" ]; then
        echo "${C_RED}Error: Project is not initialized. Please run 'cppinit' first.${C_RESET}" >&2
        return 1
    fi
    return 0
}

# Utility to check if we're in the allowed workspace.
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

# Utility to format elapsed time nicely.
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

# Portable timeout runner: prefers coreutils timeout/gtimeout, falls back to Python,
# and finally runs without a limit (with a one-time warning).
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

# -------------------------- PROJECT SETUP & CONFIG -------------------------- #

# Initializes or verifies a competitive programming directory.
# This function is now idempotent and workspace-protected.
function cppinit() {
    # Check workspace restriction.
    if ! _check_workspace; then
        echo "${C_RED}Initialization aborted. Navigate to your CP workspace first.${C_RESET}" >&2
        return 1
    fi

    echo "${C_CYAN}Initializing Competitive Programming environment...${C_RESET}"

    # Check for script directory, essential for finding templates.
    if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR/templates" ]; then
        echo "${C_RED}Error: SCRIPT_DIR is not set or templates directory is missing.${C_RESET}" >&2
        return 1
    fi

    # Create .statistics and .ide-configs directories if they don't exist.
    mkdir -p .ide-configs
    mkdir -p .statistics

    # Create .contest_metadata in .statistics directory if it doesn't exist (for tracking).
    if [ ! -f ".statistics/contest_metadata" ]; then
        echo "# Contest Metadata" > .statistics/contest_metadata
        echo "CREATED=$(date +"%Y-%m-%d %H:%M:%S")" >> .statistics/contest_metadata
        echo "CONTEST_NAME=$(basename "$(pwd)")" >> .statistics/contest_metadata
    fi

    # Create CMakeLists.txt if it doesn't exist.
    if [ ! -f "CMakeLists.txt" ]; then
        echo "Creating CMakeLists.txt from template..."
        cp "$SCRIPT_DIR/templates/CMakeLists.txt.tpl" ./CMakeLists.txt
    fi

    # Create gcc-toolchain.cmake if it doesn't exist.
    if [ ! -f "gcc-toolchain.cmake" ]; then
        echo "Creating gcc-toolchain.cmake to enforce GCC usage..."
        cp "$SCRIPT_DIR/templates/gcc-toolchain.cmake.tpl" ./gcc-toolchain.cmake
    fi

    # Create clang-toolchain.cmake if template exists (for potential sanitizer builds).
    if [ ! -f "clang-toolchain.cmake" ] && [ -f "$SCRIPT_DIR/templates/clang-toolchain.cmake.tpl" ]; then
        echo "Creating clang-toolchain.cmake for potential sanitizer usage..."
        cp "$SCRIPT_DIR/templates/clang-toolchain.cmake.tpl" ./clang-toolchain.cmake
    fi

    # Create .clangd configuration in .ide-configs directory if it doesn't exist.
    if [ ! -f ".ide-configs/clangd" ]; then
        echo "Creating .clangd configuration from template..."
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS template.
            cp "$SCRIPT_DIR/templates/.clangd.tpl" ./.ide-configs/clangd
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            # Linux template.
            cp "$SCRIPT_DIR/templates/.clangd-linux.tpl" ./.ide-configs/clangd
        else
            # Fallback to macOS template for other platforms.
            cp "$SCRIPT_DIR/templates/.clangd.tpl" ./.ide-configs/clangd
        fi
    fi

    # Create .gitignore if it doesn't exist.
    if [ ! -f ".gitignore" ]; then
        echo "Creating .gitignore..."
        cat > .gitignore << 'EOF'
build/
bin/
lib/
algorithms/
not_passed/
!.vscode/
.idea/
.cache/*
.ide-configs/
.statistics/
compile_commands.json
.clangd
.clang-format
.clang-tidy
*.out
*.exe
*.dSYM/
*.DS_Store
EOF
    fi

    # Create symlink to .ide-configs/clangd for IDE compatibility.
    if [ ! -L ".clangd" ]; then
        ln -sf .ide-configs/clangd .clangd
        echo "Created .clangd symlink for IDE compatibility"
    fi

    # Create directories if they don't exist.
    mkdir -p algorithms
    mkdir -p input_cases
    mkdir -p output_cases
    mkdir -p expected_output
    mkdir -p submissions

    # Link to the global debug.h if configured and not already linked.
    local master_debug_header="$CP_ALGORITHMS_DIR/libs/debug.h"
    if [ ! -e "algorithms/debug.h" ]; then
        if [ -n "$CP_ALGORITHMS_DIR" ] && [ -f "$master_debug_header" ]; then
            ln -s "$master_debug_header" "algorithms/debug.h"
            echo "Created symlink to global debug.h."
        else
            touch "algorithms/debug.h"
            echo "${C_YELLOW}Warning: Global debug.h not found. Created a local placeholder.${C_RESET}"
        fi
    fi

    # Link to the global templates directory if configured and not already linked.
    local master_templates_dir="$CP_ALGORITHMS_DIR/templates"
    if [ ! -e "algorithms/templates" ]; then
        if [ -n "$CP_ALGORITHMS_DIR" ] && [ -d "$master_templates_dir" ]; then
            ln -s "$master_templates_dir" "algorithms/templates"
            echo "Created symlink to global templates directory."
        else
            mkdir -p "algorithms/templates"
            echo "${C_YELLOW}Warning: Global templates directory not found. Created a local placeholder.${C_RESET}"
        fi
    fi

    # Link to the global modules directory if configured and not already linked.
    local master_modules_dir="$CP_ALGORITHMS_DIR/modules"
    if [ ! -e "algorithms/modules" ]; then
        if [ -n "$CP_ALGORITHMS_DIR" ] && [ -d "$master_modules_dir" ]; then
            ln -s "$master_modules_dir" "algorithms/modules"
            echo "Created symlink to global modules directory."
        else
            mkdir -p "algorithms/modules"
            echo "${C_YELLOW}Warning: Global modules directory not found. Created a local placeholder.${C_RESET}"
        fi
    fi

    # Copy or link PCH.h and PCH_Wrapper.h for Clang builds.
    local master_pch_header="$CP_ALGORITHMS_DIR/libs/PCH.h"
    local master_pch_wrapper="$CP_ALGORITHMS_DIR/libs/PCH_Wrapper.h"

    if [ ! -e "algorithms/PCH.h" ]; then
        if [ -n "$CP_ALGORITHMS_DIR" ] && [ -f "$master_pch_header" ]; then
            ln -s "$master_pch_header" "algorithms/PCH.h"
            echo "Created symlink to global PCH.h (for Clang builds)."
        elif [ -f "$SCRIPT_DIR/templates/cpp/PCH.h" ]; then
            cp "$SCRIPT_DIR/templates/cpp/PCH.h" "algorithms/PCH.h"
            echo "Copied PCH.h template for Clang builds."
        else
            echo "${C_YELLOW}Warning: PCH.h not found. Clang builds may not work properly.${C_RESET}"
        fi
    fi

    if [ ! -e "algorithms/PCH_Wrapper.h" ]; then
        if [ -n "$CP_ALGORITHMS_DIR" ] && [ -f "$master_pch_wrapper" ]; then
            ln -s "$master_pch_wrapper" "algorithms/PCH_Wrapper.h"
            echo "Created symlink to global PCH_Wrapper.h."
        elif [ -f "$SCRIPT_DIR/templates/cpp/PCH_Wrapper.h" ]; then
            cp "$SCRIPT_DIR/templates/cpp/PCH_Wrapper.h" "algorithms/PCH_Wrapper.h"
            echo "Copied PCH_Wrapper.h template."
        else
            echo "${C_YELLOW}Warning: PCH_Wrapper.h not found. Some builds may not work properly.${C_RESET}"
        fi
    fi

    # Set up VS Code configurations if templates are available.
    local vscode_tpl_dir="$SCRIPT_DIR/templates/vscode"
    local vscode_dest_dir=".vscode"

    if [ -d "$vscode_tpl_dir" ]; then
        if [ ! -d "$vscode_dest_dir" ]; then
            echo "Setting up VS Code configurations..."
            mkdir -p "$vscode_dest_dir"

            # Loop through all available templates and copy them.
            for template in "$vscode_tpl_dir"/*.json; do
                if [ -f "$template" ]; then
                    cp "$template" "$vscode_dest_dir/"
                    echo "  -> Copied template: $(basename "$template")"
                fi
            done
        else
            echo "VS Code directory already exists. Skipping VS Code setup."
        fi
    fi

    # Create a basic configuration. This will create the build directory.
    cppconf

    echo "${C_BOLD}${C_GREEN}Project initialized successfully!${C_RESET}"
    echo "Run '${C_CYAN}cppnew <problem_name>${C_RESET}' to create your first solution file."
}

# Creates a new problem file from a template and re-runs CMake.
function cppnew() {
    # Ensure the project is initialized before creating a new file.
    if [ ! -f "CMakeLists.txt" ]; then
        echo "${C_RED}Project not initialized. Run 'cppinit' before creating a new problem.${C_RESET}" >&2
        return 1
    fi

    local problem_name=${1:-"main"}
    local template_type=${2:-"base"}
    local file_name="${problem_name}.cpp"
    local template_file

    if [ -f "${problem_name}.cpp" ] || [ -f "${problem_name}.cc" ] || [ -f "${problem_name}.cxx" ]; then
        echo "${C_RED}Error: File for problem '$problem_name' already exists.${C_RESET}" >&2
        return 1
    fi

    # Determine the template file based on the type.
    case $template_type in
        "pbds")
            template_file="$SCRIPT_DIR/templates/cpp/pbds.cpp"
            ;;
        "default")
            template_file="$SCRIPT_DIR/templates/cpp/default.cpp"
            ;;
        "advanced")
            template_file="$SCRIPT_DIR/templates/cpp/advanced.cpp"
            ;;
        *) # Base template.
            template_file="$SCRIPT_DIR/templates/cpp/base.cpp"
            ;;
    esac

    if [ ! -f "$template_file" ]; then
        echo "${C_RED}Error: Template file '$template_file' not found.${C_RESET}" >&2
        return 1
    fi

    echo "${C_CYAN}Creating '$file_name' from template '$template_type'...${C_RESET}"
    # Replace placeholder and create the file.
    sed "s/__FILE_NAME__/$file_name/g" "$template_file" > "$file_name"

    # Create corresponding empty input/output files.
    touch "input_cases/${problem_name}.in"
    touch "output_cases/${problem_name}.exp"
    echo "Created empty input file: input_cases/${problem_name}.in"
    echo "Created empty output file: output_cases/${problem_name}.exp"

    # Track problem creation time with human-readable format.
    echo "${problem_name}:START:$(date +%s):$(date '+%Y-%m-%d %H:%M:%S')" >> .statistics/problem_times

    echo "New problem '$problem_name' created. Re-running CMake configuration..."
    cppconf # Re-run configuration to add the new file to the build system.
}

# Deletes a problem and all its associated files.
function cppdelete() {
    local problem_name=${1}

    if [ -z "$problem_name" ]; then
        echo "${C_RED}Usage: cppdelete <problem_name>${C_RESET}" >&2
        return 1
    fi

    # Check if any source file exists for this problem.
    local source_file=""
    for ext in cpp cc cxx; do
        if [ -f "${problem_name}.${ext}" ]; then
            source_file="${problem_name}.${ext}"
            break
        fi
    done

    if [ -z "$source_file" ]; then
        echo "${C_RED}Error: No source file found for problem '$problem_name'${C_RESET}" >&2
        return 1
    fi

    # List all files that will be deleted.
    echo "${C_YELLOW}The following files will be deleted:${C_RESET}"
    echo "  - Source file: ${C_CYAN}$source_file${C_RESET}"

    # Check for input/output files.
    local files_to_delete=("$source_file")

    if [ -f "input_cases/${problem_name}.in" ]; then
        echo "  - Input file: ${C_CYAN}input_cases/${problem_name}.in${C_RESET}"
        files_to_delete+=("input_cases/${problem_name}.in")
    fi

    # Check for multiple input files (numbered pattern).
    while IFS= read -r -d '' input_file; do
        echo "  - Input file: ${C_CYAN}$input_file${C_RESET}"
        files_to_delete+=("$input_file")
    done < <(find input_cases -name "${problem_name}.*.in" -print0 2>/dev/null)

    if [ -f "output_cases/${problem_name}.exp" ]; then
        echo "  - Output file: ${C_CYAN}output_cases/${problem_name}.exp${C_RESET}"
        files_to_delete+=("output_cases/${problem_name}.exp")
    fi

    # Check for multiple output files (numbered pattern).
    while IFS= read -r -d '' output_file; do
        echo "  - Output file: ${C_CYAN}$output_file${C_RESET}"
        files_to_delete+=("$output_file")
    done < <(find output_cases -name "${problem_name}.*.exp" -print0 2>/dev/null)

    # Check for submission file.
    if [ -f "$SUBMISSIONS_DIR/${problem_name}_sub.cpp" ]; then
        echo "  - Submission file: ${C_CYAN}$SUBMISSIONS_DIR/${problem_name}_sub.cpp${C_RESET}"
        files_to_delete+=("$SUBMISSIONS_DIR/${problem_name}_sub.cpp")
    fi

    # Check for executable in bin directory.
    if [ -f "bin/${problem_name}" ]; then
        echo "  - Executable: ${C_CYAN}bin/${problem_name}${C_RESET}"
        files_to_delete+=("bin/${problem_name}")
    fi

    # Confirmation prompt.
    echo ""
    echo -n "${C_YELLOW}Are you sure you want to delete these files? (y/N): ${C_RESET}"
    read -r response

    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Deletion cancelled."
        return 0
    fi

    # Delete the files.
    local deleted_count=0
    for file in "${files_to_delete[@]}"; do
        if [ -f "$file" ]; then
            rm "$file"
            echo "${C_GREEN}Deleted: $file${C_RESET}"
            ((deleted_count++))
        fi
    done

    # Remove problem timing data from statistics.
    if [ -f ".statistics/problem_times" ]; then
        grep -v "^${problem_name}:" .statistics/problem_times > .statistics/problem_times.tmp 2>/dev/null || true
        mv .statistics/problem_times.tmp .statistics/problem_times 2>/dev/null || true
    fi

    echo ""
    echo "${C_GREEN}Successfully deleted problem '$problem_name' ($deleted_count files removed)${C_RESET}"

    # Re-run CMake configuration to update the build system.
    if [ -f "CMakeLists.txt" ]; then
        echo "Re-running CMake configuration to update build system..."
        cppconf
    fi
}

# Batch creation of multiple problems at once.
function cppbatch() {
    local count=${1:-5}
    local template=${2:-"default"}

    echo "${C_CYAN}Creating $count problems with template '$template'...${C_RESET}"

    for i in $(seq 65 $((64 + count))); do
        local problem_name
        local letter
        letter=$(printf '%b' "$(printf '\\%03o' "$i")")
        problem_name="problem_${letter}"
        if [ ! -f "${problem_name}.cpp" ]; then
            cppnew "$problem_name" "$template"
        else
            echo "${C_YELLOW}Skipping $problem_name - already exists${C_RESET}"
        fi
    done

    echo "${C_GREEN}Batch creation complete!${C_RESET}"
}

function cppconf() {
    local build_type=${1:-Debug}
    local compiler_choice=${2:-auto}
    local timing_cmake_arg="-DCP_ENABLE_TIMING=OFF" # Timing is OFF by default.
    local pch_cmake_arg="-DCP_ENABLE_PCH=AUTO" # PCH auto-selection by default.
    local force_pch_rebuild_arg=""

    # Parse all arguments.
    for arg in "$@"; do
        case $arg in
            # Case-insensitive matching for build types.
            [Dd]ebug|[Rr]elease|[Ss]anitize)
                build_type=$(echo "$arg" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
                ;;

            # Compiler override arguments.
            gcc|g++|clang|clang++|auto)
                compiler_choice=$(echo "$arg" | tr '[:upper:]' '[:lower:]')
                ;;

            # Check for timing argument.
            timing=*)
                local value=${arg#*=}
                if [[ "$value" == "on" || "$value" == "true" ]]; then
                    timing_cmake_arg="-DCP_ENABLE_TIMING=ON"
                elif [[ "$value" == "off" || "$value" == "false" ]]; then
                    timing_cmake_arg="-DCP_ENABLE_TIMING=OFF"
                else
                    echo "${C_YELLOW}Warning: Unknown value for 'timing': '$value'. Ignoring.${C_RESET}"
                fi
                ;;

            # Check for PCH argument.
            pch=*)
                local value=${arg#*=}
                if [[ "$value" == "on" || "$value" == "true" ]]; then
                    pch_cmake_arg="-DCP_ENABLE_PCH=ON"
                elif [[ "$value" == "off" || "$value" == "false" ]]; then
                    pch_cmake_arg="-DCP_ENABLE_PCH=OFF"
                elif [[ "$value" == "auto" ]]; then
                    pch_cmake_arg="-DCP_ENABLE_PCH=AUTO"
                else
                    echo "${C_YELLOW}Warning: Unknown value for 'pch': '$value'. Ignoring.${C_RESET}"
                fi
                ;;

            # Check for PCH rebuild argument.
            pch-rebuild=*)
                local value=${arg#*=}
                if [[ "$value" == "on" || "$value" == "true" ]]; then
                    force_pch_rebuild_arg="-DCP_FORCE_PCH_REBUILD=ON"
                fi
                ;;

            # Shorthand for PCH rebuild.
            pch-rebuild|rebuild-pch)
                force_pch_rebuild_arg="-DCP_FORCE_PCH_REBUILD=ON"
                ;;

            # Handle unknown arguments.
            *)
                echo "${C_YELLOW}Warning: Unknown argument '$arg'. Ignoring.${C_RESET}"
                ;;
        esac
    done

    # Normalize compiler choice to lowercase.
    compiler_choice=$(echo "$compiler_choice" | tr '[:upper:]' '[:lower:]')

    # Determine which toolchain to use.
    local toolchain_file=""
    local toolchain_name=""

    # Compiler selection logic.
    case "$compiler_choice" in
        gcc|g++)
            toolchain_file="gcc-toolchain.cmake"
            toolchain_name="GCC (forced)"
            ;;
        clang|clang++)
            toolchain_file="clang-toolchain.cmake"
            toolchain_name="Clang/LLVM (forced)"
            ;;
        auto|"")
            # Auto-selection based on build type and platform.
            if [ "$build_type" = "Sanitize" ]; then
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    # On macOS, prefer Clang for sanitizers.
                    toolchain_file="clang-toolchain.cmake"
                    toolchain_name="Clang/LLVM (auto-selected for sanitizers)"
                else
                    # On Linux, try GCC first.
                    toolchain_file="gcc-toolchain.cmake"
                    toolchain_name="GCC (auto-selected)"
                fi
            else
                # Default to GCC for Debug/Release.
                toolchain_file="gcc-toolchain.cmake"
                toolchain_name="GCC (default)"
            fi
            ;;
        *)
            echo "${C_RED}Error: Unknown compiler choice '$compiler_choice'${C_RESET}" >&2
            echo "Valid options: gcc, clang, auto" >&2
            return 1
            ;;
    esac

    # Create toolchain file if it doesn't exist.
    if [ ! -f "$toolchain_file" ]; then
        local template_file="$SCRIPT_DIR/templates/${toolchain_file}.tpl"
        if [ -f "$template_file" ]; then
            echo "Creating $toolchain_file from template..."
            cp "$template_file" ./"$toolchain_file"
        else
            echo "${C_RED}Error: Template for $toolchain_file not found!${C_RESET}" >&2
            if [ "$toolchain_file" = "gcc-toolchain.cmake" ]; then
                echo "${C_YELLOW}Running cppinit to fix missing GCC toolchain...${C_RESET}"
                cppinit
            else
                return 1
            fi
        fi
    fi

    # Auto-configure PCH based on build type if set to AUTO.
    if [[ "$pch_cmake_arg" == *"AUTO"* ]]; then
        if [ "$build_type" = "Debug" ]; then
            pch_cmake_arg="-DCP_ENABLE_PCH=ON"
        else
            pch_cmake_arg="-DCP_ENABLE_PCH=OFF"
        fi
    fi

    # Use array for CMake flags to avoid space issues.
    local cmake_flags=()

    # Enable timing if requested via environment variable or argument.
    if [ -n "$CP_TIMING" ]; then
        timing_cmake_arg="-DCP_ENABLE_TIMING=ON"
    fi
    cmake_flags+=("$timing_cmake_arg")
    cmake_flags+=("$pch_cmake_arg")

    # Add PCH rebuild flag if specified.
    if [ -n "$force_pch_rebuild_arg" ]; then
        cmake_flags+=("$force_pch_rebuild_arg")
    fi

    # Enable LTO for Release builds with Clang.
    if [ "$build_type" = "Release" ] && [[ "$toolchain_file" == *"clang"* ]]; then
        cmake_flags+=("-DCP_ENABLE_LTO=ON")
    fi

    # Log the configuration step.
    echo "${C_BLUE}╔═══---------------------------------------------------------------------------═══╗${C_RESET}"
    echo "  ${C_BLUE}Configuring project:${C_RESET}"
    echo "    ${C_CYAN}Build Type:${C_RESET} ${C_YELLOW}${build_type}${C_RESET}"
    echo "    ${C_CYAN}Compiler:${C_RESET} ${C_YELLOW}${toolchain_name}${C_RESET}"
    echo "    ${C_CYAN}Timing Report:${C_RESET} ${C_YELLOW}${timing_cmake_arg##*=}${C_RESET}"
    echo "    ${C_CYAN}PCH Support:${C_RESET} ${C_YELLOW}${pch_cmake_arg##*=}${C_RESET}"
    if [[ "${cmake_flags[*]}" == *"LTO"* ]]; then
        echo "    ${C_CYAN}LTO:${C_RESET} ${C_YELLOW}Enabled${C_RESET}"
    fi
    if [ -n "$force_pch_rebuild_arg" ]; then
        echo "    ${C_CYAN}PCH Rebuild:${C_RESET} ${C_YELLOW}Forced${C_RESET}"
    fi
    echo "${C_BLUE}╚═══---------------------------------------------------------------------------═══╝${C_RESET}"

    # Run CMake with the selected toolchain - use array expansion.
    if cmake -S . -B build \
        -DCMAKE_BUILD_TYPE="${build_type}" \
        -DCMAKE_TOOLCHAIN_FILE="${toolchain_file}" \
        -DCMAKE_CXX_FLAGS="-std=c++23" \
        "${cmake_flags[@]}"; then
        echo "${C_GREEN}CMake configuration successful.${C_RESET}"

        # If PCH rebuild was requested, clean PCH first.
        if [ -n "$force_pch_rebuild_arg" ]; then
            echo "${C_CYAN}Cleaning PCH cache...${C_RESET}"
            if cmake --build build --target pch_clean 2>/dev/null; then
                echo "${C_GREEN}PCH cache cleaned.${C_RESET}"
            else
                echo "${C_YELLOW}PCH clean target not available (normal for first run).${C_RESET}"
            fi
        fi

        # Create the symlink for clangd.
        cmake --build build --target symlink_clangd 2>/dev/null || true

        # Save configuration for quick reference.
        echo "$build_type:$compiler_choice:${pch_cmake_arg##*=}" > .statistics/last_config
    else
        echo "${C_RED}CMake configuration failed!${C_RESET}" >&2
        return 1
    fi
}

# Creates and sets up a new directory for a contest.
function cppcontest() {
    if [ -z "$1" ]; then
        echo "${C_RED}Usage: cppcontest <ContestDirectoryName>${C_RESET}" >&2
        echo "Example: cppcontest Codeforces/Round_1037_Div_3" >&2
        return 1
    fi

    # Ensure we're in the workspace before creating a contest.
    if ! _check_workspace; then
        echo "${C_RED}Contest creation aborted. Navigate to your CP workspace first.${C_RESET}" >&2
        return 1
    fi

    local contest_dir="$1"

    # Create the directory if it doesn't exist.
    if [ ! -d "$contest_dir" ]; then
        echo "${C_CYAN}Creating new contest directory: '$contest_dir'${C_RESET}"
        mkdir -p "$contest_dir"
    fi

    cd "$contest_dir" || return

    # Initialize the project here if it's not already set up.
    if [ ! -f "CMakeLists.txt" ]; then
        echo "Initializing new CMake project in '${C_BOLD}$(pwd)${C_RESET}'..."
        cppinit
    else
        echo "Project already initialized. Verifying configuration..."
        cppinit # Run to ensure all components are present.
    fi

    echo "${C_GREEN}Ready to work in ${C_BOLD}$(pwd)${C_RESET}. Use '${C_CYAN}cppnew <problem_name>${C_RESET}' to start."
}

# ------------------------------- BUILD & RUN -------------------------------- #

# Builds a specific target with intelligent, conditional, and formatted output.
function cppbuild() {
    _check_initialized || return 1
    local target_name=${1:-$(_get_default_target)}
    echo "${C_CYAN}Building target: ${C_BOLD}$target_name${C_RESET}..."

    # Record start time for total build duration.
    local start_time
    local use_ns=true
    start_time=$(date +%s%N 2>/dev/null || true)
    if [[ ! "$start_time" =~ ^[0-9]+$ ]]; then
        use_ns=false
        start_time=$(date +%s)
    fi

    # Check if timing is enabled in CMake cache.
    local timing_enabled=false
    if [ -f "build/CMakeCache.txt" ]; then
        if grep -q "CP_ENABLE_TIMING:BOOL=ON" build/CMakeCache.txt 2>/dev/null; then
            timing_enabled=true
        fi
    fi

    # Capture both stdout and stderr to analyze build output.
    local build_output
    build_output=$(cmake --build build --target "$target_name" -j 2>&1)
    local build_status=$?

    # Calculate total build time.
    local end_time
    if $use_ns; then
        end_time=$(date +%s%N 2>/dev/null || date +%s)
    else
        end_time=$(date +%s)
    fi

    local elapsed_str
    local have_ms=false
    local elapsed_ms=0
    local decimal_part=0
    local elapsed_s=0
    if $use_ns && [[ "$end_time" =~ ^[0-9]+$ ]]; then
        have_ms=true
        local elapsed_ns=$(( end_time - start_time ))
        elapsed_ms=$(( elapsed_ns / 1000000 ))
        decimal_part=$(( (elapsed_ns % 1000000) / 10000 ))
        elapsed_str=$(printf "%d.%02dms" "$elapsed_ms" "$decimal_part")
    else
        elapsed_s=$(( end_time - start_time ))
        elapsed_str="${elapsed_s}s"
    fi

    # Handle build failures with full error output.
    if [ $build_status -ne 0 ]; then
        echo ""
        echo "${C_BOLD}${C_RED}╔═══--------- BUILD FAILED ---------═══╗${C_RESET}"
        echo "$build_output"
        printf "${C_RED}Build failed after %s${C_RESET}\n" "$elapsed_str"
        return 1
    fi

    # Show detailed output only if actual compilation occurred.
    if [[ "$build_output" == *"Building CXX object"* ]]; then
        # Real compilation happened - format the output for better readability.

        # 1. Print everything up to the compilation line.
        echo "$build_output" | sed -n '/Building CXX object/q;p'

        # 2. Print the compilation line itself.
        echo "$build_output" | grep "Building CXX object"

        # 3. Print timing statistics only if timing is enabled.
        if [ "$timing_enabled" = true ]; then
            echo ""
            echo "${C_BOLD}${C_CYAN}╔═══--------------------- Compilation Time Statistics ----------------------═══╗${C_RESET}"
            echo ""

            # Universal timing report finder for both GCC and Clang.
            local timing_report
            timing_report=$(echo "$build_output" | sed -n '/Time variable/,/TOTAL/p; /Pass execution timing report/,$p')

            if [ -n "$timing_report" ]; then
                # Extract only the relevant parts, stopping before the linking phase.
                echo "$timing_report" | sed '/Linking CXX executable/q'
            else
                echo " Compilation finished. (Timing report not found in output)."
            fi

            # Check if this is a Clang build and add trace analysis note.
            if [ -f "build/CMakeCache.txt" ] && grep -q "clang" build/CMakeCache.txt; then
            echo ""
            echo -e " Clang compilation finished."
            echo -e " ${C_CYAN}Note: To analyze the detailed trace with Perfetto UI, run:${C_RESET}"
            echo -e "   ${C_BOLD}${C_GREEN}cpptrace $target_name${C_RESET}"
            fi

            echo ""
            echo "${C_BOLD}${C_CYAN}╚═══--------------- Compilation Finished, Proceeding to Link ---------------═══╝${C_RESET}"
            echo ""
        fi

        # 4. Print the linking line and anything after it.
        echo "$build_output" | sed -n '/Linking CXX executable/,$p'
    else
        # Target up-to-date - show only the summary line.
        echo "$build_output" | tail -n 1
        fi

    # Display total build time.
    printf "${C_MAGENTA}Total build time: %s${C_RESET}\n" "$elapsed_str"

    return 0
}

# Runs a specific executable.
function cpprun() {
    _check_initialized || return 1
    local target_name=${1:-$(_get_default_target)}
    local exec_path="./bin/$target_name"

    if [ ! -f "$exec_path" ]; then
        echo "${C_YELLOW}Executable '$exec_path' not found. Building first...${C_RESET}"
        if ! cppbuild "$target_name"; then
            echo "${C_RED}Build failed!${C_RESET}" >&2
            return 1
        fi
    fi

    echo "${C_BLUE}Running '$exec_path'...${C_RESET}"
    "$exec_path"
}

# All-in-one: build and run with optional input file redirection.
function cppgo() {
    _check_initialized || return 1
    local target_name=${1:-$(_get_default_target)}
    local exec_path="./bin/$target_name"

    # Default to the problem's own input file if a second argument isn't given.
    local input_file=${2:-"${target_name}.in"}
    local input_path="input_cases/$input_file"

    echo "${C_CYAN}Building target '${C_BOLD}$target_name${C_CYAN}'...${C_RESET}"
    if cppbuild "$target_name"; then
        echo ""
        echo "${C_BLUE}════-------------------------------------════${C_RESET}"
        echo "${C_BLUE}${C_BOLD}RUNNING: $target_name${C_RESET}"

        # Track execution time in nanoseconds for better precision.
        local start_time
        local use_ns=true
        start_time=$(date +%s%N 2>/dev/null || true)
        if [[ ! "$start_time" =~ ^[0-9]+$ ]]; then
            use_ns=false
            start_time=$(date +%s)
        fi

        local exit_code=0
        if [ -f "$input_path" ]; then
            echo "(input from ${C_YELLOW}$input_path${C_RESET})"
            _run_with_timeout 5s "$exec_path" < "$input_path"
            exit_code=$?
        else
            if [ -n "$2" ]; then # Warn if a specific file was requested but not found.
                 echo "${C_YELLOW}Warning: Input file '$input_path' not found.${C_RESET}" >&2
            fi
            _run_with_timeout 5s "$exec_path"
            exit_code=$?
        fi

        local end_time
        if $use_ns; then
            end_time=$(date +%s%N 2>/dev/null || date +%s)
        else
            end_time=$(date +%s)
        fi

        # Check if the program was terminated due to timeout
        if [ $exit_code -eq 124 ]; then
            echo "${C_YELLOW}⚠ Program terminated after 5-second timeout${C_RESET}"
        elif [ $exit_code -ne 0 ] && [ $exit_code -ne 124 ]; then
            echo "${C_RED}Program exited with code $exit_code${C_RESET}"
        fi

        echo "${C_BLUE}════------------- FINISHED --------------════${C_RESET}"
        if $use_ns && [[ "$end_time" =~ ^[0-9]+$ ]]; then
            local elapsed_ns=$(( end_time - start_time ))
            local elapsed_ms=$(( elapsed_ns / 1000000 ))
            local decimal_part=$(( (elapsed_ns % 1000000) / 10000 ))
            printf "${C_MAGENTA}Execution time: %d.%02dms${C_RESET}\n" $elapsed_ms $decimal_part
        else
            local elapsed_s=$(( end_time - start_time ))
            printf "${C_MAGENTA}Execution time: %ds${C_RESET}\n" $elapsed_s
        fi
        echo ""
    else
        echo "${C_RED}Build failed!${C_RESET}" >&2
        return 1
    fi
}

# Force a rebuild and run, useful for re-triggering compilation analysis.
function cppforcego() {
    local target
    target=$(_get_default_target)
    local exec_name
    exec_name=$(echo "${1:-$target}" | sed -E 's/\.(cpp|cc|cxx)$//')

    # Find the source file corresponding to the target.
    local source_file
    for ext in cpp cc cxx; do
        if [ -f "${exec_name}.${ext}" ]; then
            source_file="${exec_name}.${ext}"
            break
        fi
    done

    if [ -z "$source_file" ]; then
        echo "Error: Source file for target '$exec_name' not found."
        return 1
    fi

    echo "Forcing rebuild for '$source_file' by updating its timestamp..."
    # 'touch' updates the file's modification time, making the build system
    # think it's new and needs to be recompiled.
    touch "$source_file"

    # Now, run the regular cppgo command.
    cppgo "$@"
}

# Interactive input mode - builds and runs with manual input.
function cppi() {
    _check_initialized || return 1
    local target_name=${1:-$(_get_default_target)}
    local exec_path="./bin/$target_name"

    echo "${C_CYAN}Building target '${C_BOLD}$target_name${C_CYAN}'...${C_RESET}"
    if cppbuild "$target_name"; then
        echo ""
        echo "${C_BLUE}════-------------------------------------════${C_RESET}"
        echo "${C_BLUE}${C_BOLD}INTERACTIVE MODE: $target_name${C_RESET}"
        echo "${C_YELLOW}Enter input (Ctrl+D when done):${C_RESET}"
        "$exec_path"
        echo "${C_BLUE}════------------- FINISHED --------------════${C_RESET}"
    else
        echo "${C_RED}Build failed!${C_RESET}" >&2
        return 1
    fi
}

# Judges a solution against all corresponding sample cases.
function cppjudge() {
    _check_initialized || return 1
    local target_name=${1:-$(_get_default_target)}
    local exec_path="./bin/$target_name"
    local input_dir="input_cases"
    local output_dir="output_cases"

    if ! cppbuild "$target_name"; then
        echo "${C_RED}Build failed!${C_RESET}" >&2
        return 1
    fi

    # Check for test cases - first try the specific pattern, then fall back to simple .in file.
    local test_files=()

    # Use find to avoid "no matches found" error in zsh.
    while IFS= read -r -d '' file; do
        test_files+=("$file")
    done < <(find "$input_dir" -name "${target_name}.*.in" -print0 2>/dev/null)

    # If no numbered test cases found, check for single test case.
    if [ ${#test_files[@]} -eq 0 ] && [ -f "$input_dir/${target_name}.in" ]; then
        test_files+=("$input_dir/${target_name}.in")
    fi

    if [ ${#test_files[@]} -eq 0 ]; then
        echo "${C_YELLOW}No test cases found for '$target_name' (looked for '${target_name}.*.in' and '${target_name}.in')${C_RESET}"
        return 0
    fi

    local passed=0
    local failed=0
    local total=0

    for test_in in "${test_files[@]}"; do
        local test_case_base
        test_case_base=$(basename "$test_in" .in)
        local output_case="$output_dir/${test_case_base}.exp"
        local temp_out
        temp_out=$(mktemp)

        ((total++))
        echo -n "Testing $(basename "$test_in")... "

        # Measure execution time.
        local start_time
        local use_ns=true
        start_time=$(date +%s%N 2>/dev/null || true)
        if [[ ! "$start_time" =~ ^[0-9]+$ ]]; then
            use_ns=false
            start_time=$(date +%s)
        fi
        "$exec_path" < "$test_in" > "$temp_out"
        local end_time
        if $use_ns; then
            end_time=$(date +%s%N 2>/dev/null || date +%s)
        else
            end_time=$(date +%s)
        fi

        local elapsed_ms
        if $use_ns && [[ "$end_time" =~ ^[0-9]+$ ]]; then
            elapsed_ms=$(( (end_time - start_time) / 1000000 ))
        else
            elapsed_ms=$(( (end_time - start_time) * 1000 ))
        fi

        # Check if expected output file exists.
        if [ ! -f "$output_case" ]; then
            echo "${C_BOLD}${C_YELLOW}WARNING: Expected output file '$(basename "$output_case")' not found.${C_RESET}"
            rm "$temp_out"
            continue
        fi

        # Use diff with -w (ignore all whitespace) and -B (ignore blank lines).
        if diff -wB "$temp_out" "$output_case" >/dev/null; then
            echo "${C_BOLD}${C_GREEN}PASSED${C_RESET} (${elapsed_ms}ms)"
            ((passed++))
        else
            echo "${C_BOLD}${C_RED}FAILED${C_RESET} (${elapsed_ms}ms)"
            ((failed++))
            echo "${C_BOLD}${C_YELLOW}════------------ YOUR OUTPUT ------------════${C_RESET}"
            cat "$temp_out"
            echo "${C_BOLD}${C_YELLOW}╠═══------------- EXPECTED --------------═══╣${C_RESET}"
            cat "$output_case"
            echo "${C_BOLD}${C_YELLOW}════-------------------------------------════${C_RESET}"
        fi
        rm "$temp_out"
    done

    # Summary.
    echo ""
    echo "${C_BOLD}${C_BLUE}════----------- TEST SUMMARY ------------════${C_RESET}"
    echo "${C_GREEN}Passed: $passed/$total${C_RESET}"
    if [ $failed -gt 0 ]; then
        echo "${C_RED}Failed: $failed/$total${C_RESET}"
    fi
    echo "${C_BOLD}${C_BLUE}════-------------------------------------════${C_RESET}"
}

# Quick stress testing function.
function cppstress() {
    _check_initialized || return 1
    local target_name=${1:-$(_get_default_target)}
    local iterations=${2:-100}
    local exec_path="./bin/$target_name"

    if ! cppbuild "$target_name"; then
        echo "${C_RED}Build failed!${C_RESET}" >&2
        return 1
    fi

    echo "${C_CYAN}Stress testing '$target_name' for $iterations iterations...${C_RESET}"

    local failed=0
    for i in $(seq 1 "$iterations"); do
        printf "\rIteration %d/%d... " "$i" "$iterations"

        # Run with empty input and check for crashes.
        if ! _run_with_timeout 2 "$exec_path" < /dev/null > /dev/null 2>&1; then
            ((failed++))
            echo "${C_RED}Failed at iteration $i${C_RESET}"
        fi
    done

    echo ""
    if [ $failed -eq 0 ]; then
        echo "${C_GREEN}All $iterations iterations completed successfully!${C_RESET}"
    else
        echo "${C_RED}$failed iterations failed out of $iterations${C_RESET}"
    fi
}

# ---------------------------- SUBMISSION HELPERS ---------------------------- #

# Enhanced submission generation using the new modular flattener system.
function cppsubmit() {
    _check_initialized || return 1
    local target_name=${1:-$(_get_default_target)}
    local solution_file="${target_name}.cpp"
    local submission_dir="$SUBMISSIONS_DIR"
    local submission_file="$submission_dir/${target_name}_sub.cpp"
    local flattener_script="$SCRIPTS_DIR/flattener.py"

    # Validate that we are in a valid workspace.
    if [[ ! "$PWD" == "$CP_WORKSPACE_ROOT"* ]]; then
        echo -e "${C_RED}Error: Not in a valid CP workspace directory${C_RESET}" >&2
        echo -e "${C_YELLOW}Current directory: $PWD${C_RESET}" >&2
        echo -e "${C_YELLOW}Expected workspace: $CP_WORKSPACE_ROOT${C_RESET}" >&2
        return 1
    fi

    # Check that the solution file exists.
    if [ ! -f "$solution_file" ]; then
        echo -e "${C_RED}Error: Solution file '$solution_file' not found${C_RESET}" >&2
        return 1
    fi

    # Check if the new flattener system is available.
    if [ ! -f "$flattener_script" ]; then
        echo -e "${C_YELLOW}Warning: New flattener not found at '$flattener_script'${C_RESET}"
        return 1
    fi

    # Create submissions directory if needed.
    mkdir -p "$submission_dir"

    echo -e "${C_CYAN}Generating submission for '${C_BOLD}$target_name${C_RESET}${C_CYAN}' using modular template system...${C_RESET}"

    # Generate submission header with metadata.
    local header_file
    header_file=$(mktemp "/tmp/${target_name}_header.XXXXXX") || {
        echo -e "${C_RED}Error: Unable to create temporary header file${C_RESET}" >&2
        return 1
    }
    cat > "$header_file" << EOF
//===----------------------------------------------------------------------===//
/**
 * @file: ${target_name}_sub.cpp
 * @generated: $(date '+%Y-%m-%d %H:%M:%S')
 * @source: $solution_file
 * @author: Costantino Lombardi
 *
 * @brief: Codeforces Round #XXX (Div. X) - Problem Y
 */
//===----------------------------------------------------------------------===//
/* Included library and Compiler Optimizations */
EOF

    # Run the Python flattener with proper path context.
    echo -e "${C_BLUE}Running template flattener...${C_RESET}"

    # Set PYTHONPATH to include the scripts directory for module imports.
    export PYTHONPATH="$SCRIPTS_DIR:$PYTHONPATH"

    local flattened_tmp
    flattened_tmp=$(mktemp "/tmp/${target_name}_flattened.XXXXXX") || {
        echo -e "${C_RED}Error: Unable to create temporary flattened file${C_RESET}" >&2
        rm -f -- "$header_file"
        return 1
    }

    local flattener_err
    flattener_err=$(mktemp "/tmp/flattener_error.XXXXXX") || {
        echo -e "${C_RED}Error: Unable to create temporary error log${C_RESET}" >&2
        rm -f -- "$header_file" "$flattened_tmp"
        return 1
    }

    if python3 "$flattener_script" "$solution_file" > "$flattened_tmp" 2>"$flattener_err"; then
        # Combine header with flattened content.
        cat "$header_file" "$flattened_tmp" > "$submission_file"
        rm -f -- "$flattened_tmp" "$header_file" "$flattener_err"

        # Calculate and display statistics.
        local file_size
        file_size=$(wc -c < "$submission_file")
        local line_count
        line_count=$(wc -l < "$submission_file")
        local template_lines
        template_lines=$(grep -c "^//" "$submission_file" 2>/dev/null || echo 0)
        local code_lines=$((line_count - template_lines))

        echo -e "${C_GREEN}✓ Submission generated successfully${C_RESET}"
        printf "${C_YELLOW}  %-6s %s${C_RESET}\n" "File:" "${C_BOLD}$submission_file${C_RESET}"
        printf "${C_YELLOW}  %-6s %s${C_RESET}\n" "Size:" "$(numfmt --to=iec-i --suffix=B "$file_size" 2>/dev/null || echo "$file_size bytes")"
        printf "${C_YELLOW}  %-6s %s${C_RESET}\n" "Lines:" "$line_count total ($code_lines code, $template_lines comments)"

        # Verify compilation with the generated file.
        if _verify_submission_compilation "$submission_file"; then
            echo -e "${C_GREEN}✓ Compilation verification passed${C_RESET}"
        else
            echo -e "${C_RED}⚠ Warning: Compilation verification failed${C_RESET}"
            echo -e "${C_YELLOW}  Review the generated file for potential issues${C_RESET}"
        fi

        # Offer clipboard integration.
        _offer_clipboard_copy "$submission_file"

        return 0
    else
        echo -e "${C_RED}Error: Flattener failed to process the file${C_RESET}" >&2
        if [ -f "$flattener_err" ]; then
            echo -e "${C_RED}Error details:${C_RESET}"
            cat "$flattener_err" >&2
        fi
        rm -f -- "$header_file" "$flattened_tmp" "$flattener_err"
        return 1
    fi
}


# Verify that the generated submission compiles correctly.
function _verify_submission_compilation() {
    local submission_file="$1"

    # Find available g++ compiler
    local gxx_compiler
    gxx_compiler=$(command -v g++-15 || command -v g++-14 || command -v g++-13 || command -v g++)

    if [ -z "$gxx_compiler" ]; then
        echo "${C_YELLOW}Warning: No g++ compiler found for verification${C_RESET}" >&2
        return 1
    fi

    # Attempt syntax-only compilation with competition flags.
    if "$gxx_compiler" -std=c++23 -O2 -DNDEBUG -fsyntax-only "$submission_file" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Offer to copy submission to clipboard with multi-platform support.
function _offer_clipboard_copy() {
    local file="$1"

    # Detect available clipboard command.
    local clipboard_cmd=()
    local clipboard_name=""

    if command -v pbcopy &> /dev/null; then
        clipboard_cmd=(pbcopy)
        clipboard_name="macOS clipboard"
    elif command -v xclip &> /dev/null; then
        clipboard_cmd=(xclip -selection clipboard)
        clipboard_name="X11 clipboard"
    elif command -v wl-copy &> /dev/null; then
        clipboard_cmd=(wl-copy)
        clipboard_name="Wayland clipboard"
    else
        return 0
    fi

    echo ""
    printf "Copy to %s? [y/N]: " "$clipboard_name"
    read -r REPLY < /dev/tty
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if "${clipboard_cmd[@]}" < "$file"; then
            echo -e "${C_GREEN}✓ Copied to $clipboard_name${C_RESET}"
        else
            echo -e "${C_RED}Failed to copy to clipboard${C_RESET}"
        fi
    fi
}

# Enhanced test submission with better error handling and timing.
function cpptestsubmit() {
    _check_initialized || return 1
    local target_name=${1:-$(_get_default_target)}

    # Generate submission first.
    if ! cppsubmit "$target_name"; then
        return 1
    fi

    local submission_file="$SUBMISSIONS_DIR/${target_name}_sub.cpp"
    local test_binary="./bin/${target_name}_submission"
    local input_file=${2:-"${target_name}.in"}
    local input_path="input_cases/$input_file"

    echo ""
    echo -e "${C_CYAN}Testing submission file...${C_RESET}"

    # Ensure bin directory exists.
    mkdir -p "$(dirname "$test_binary")"

    # Find available g++ compiler
    local gxx_compiler
    gxx_compiler=$(command -v g++-15 || command -v g++-14 || command -v g++-13 || command -v g++)

    if [ -z "$gxx_compiler" ]; then
        echo "${C_RED}Error: No g++ compiler found${C_RESET}" >&2
        return 1
    fi

    # Compile with timing information.
    echo -e "${C_BLUE}Compiling submission...${C_RESET}"
    local start_time
    local use_ns=true
    start_time=$(date +%s%N 2>/dev/null || true)
    if [[ ! "$start_time" =~ ^[0-9]+$ ]]; then
        use_ns=false
        start_time=$(date +%s)
    fi

    local compile_err_log
    compile_err_log=$(mktemp "/tmp/cp_compile_error.XXXXXX") || {
        echo "${C_RED}Error: Unable to create temporary log file${C_RESET}" >&2
        return 1
    }

    if "$gxx_compiler" -std=c++23 -O2 -DNDEBUG -march=native \
           -I"$CP_ALGORITHMS_DIR" \
           "$submission_file" -o "$test_binary" 2>"$compile_err_log"; then

        local end_time
        if $use_ns; then
            end_time=$(date +%s%N 2>/dev/null || date +%s)
        else
            end_time=$(date +%s)
        fi

        if $use_ns && [[ "$end_time" =~ ^[0-9]+$ ]]; then
            local compile_time=$(( (end_time - start_time) / 1000000 ))
            echo -e "${C_GREEN}✓ Submission compiled successfully in ${compile_time}ms${C_RESET}"
        else
            local compile_time=$(( end_time - start_time ))
            echo -e "${C_GREEN}✓ Submission compiled successfully in ${compile_time}s${C_RESET}"
        fi

        # Test execution with input.
        if [ -f "$input_path" ]; then
            echo -e "${C_BLUE}Testing with input from $input_path:${C_RESET}"
            echo -e "${C_CYAN}╔═══------------------------------------------═══╗${C_RESET}"

            # Run with timeout and capture output.
            local run_output
            run_output=$(_run_with_timeout 2s "$test_binary" < "$input_path" 2>&1)
            local exit_code=$?
            echo "$run_output" | head -n 50

            echo -e "${C_CYAN}╚═══------------------------------------------═══╝${C_RESET}"

            if [ "$exit_code" -eq 124 ]; then
                echo -e "${C_YELLOW}⚠ Execution timeout (2s limit exceeded)${C_RESET}"
            elif [ "$exit_code" -ne 0 ]; then
                echo -e "${C_RED}⚠ Program exited with code $exit_code${C_RESET}"
            else
                echo -e "${C_GREEN}✓ Execution completed successfully${C_RESET}"
            fi
        else
            echo -e "${C_YELLOW}No input file found at '$input_path'${C_RESET}"
            echo -e "${C_YELLOW}Running without input (5s timeout)...${C_RESET}"
            _run_with_timeout 5s "$test_binary"
        fi

        # Cleanup binary.
        rm -f -- "$test_binary"
    else
        echo -e "${C_RED}✗ Submission compilation failed${C_RESET}" >&2
        echo -e "${C_RED}Compilation errors:${C_RESET}"
        cat "$compile_err_log" >&2
        rm -f -- "$compile_err_log"
        return 1
    fi
    rm -f -- "$compile_err_log"
}

# Complete workflow with enhanced progress tracking.
function cppfull() {
    _check_initialized || return 1
    local target_name=${1:-$(_get_default_target)}
    local input_name=${2:-"${target_name}.in"}

    echo -e "${C_BLUE}╔═══------------------------------------------═══╗${C_RESET}"
    echo -e "${C_BLUE}${C_BOLD} FULL WORKFLOW: $(printf "%-20s" "$target_name")${C_RESET}"
    echo -e "${C_BLUE}╚═══------------------------------------------═══╝${C_RESET}"

    # Step 1: Development version test.
    echo ""
    echo -e "${C_CYAN}[1/3] Testing development version...${C_RESET}"
    if ! cppgo "$target_name" "$input_name"; then
        echo -e "${C_RED}✗ Development version failed${C_RESET}" >&2
        return 1
    fi
    echo -e "${C_GREEN}✓ Development test passed${C_RESET}"

    # Step 2: Generate submission.
    echo ""
    echo -e "${C_CYAN}[2/3] Generating submission...${C_RESET}"
    if ! cppsubmit "$target_name"; then
        echo -e "${C_RED}✗ Submission generation failed${C_RESET}" >&2
        return 1
    fi

    # Step 3: Test submission.
    echo ""
    echo -e "${C_CYAN}[3/3] Testing submission...${C_RESET}"
    if ! cpptestsubmit "$target_name" "$input_name"; then
        echo -e "${C_RED}✗ Submission test failed${C_RESET}" >&2
        return 1
    fi

    # Summary with file information.
    local submission_file="$SUBMISSIONS_DIR/${target_name}_sub.cpp"
    local file_size
    file_size=$(wc -c < "$submission_file" 2>/dev/null || echo "0")

    echo ""
    echo -e "${C_GREEN}${C_BOLD}╔═══------------------------------------------═══╗${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}  ✓ Full workflow completed successfully${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}╚═══------------------------------------------═══╝${C_RESET}"
    echo -e "${C_YELLOW}📁 Submission: $submission_file${C_RESET}"
    echo -e "${C_YELLOW}📊 Size: $(numfmt --to=iec-i --suffix=B "$file_size" 2>/dev/null || echo "$file_size bytes")${C_RESET}"
    echo -e "${C_YELLOW}📋 Ready for contest submission${C_RESET}"

    # Final clipboard offer.
    _offer_clipboard_copy "$submission_file"
}

# Comprehensive system health check.
function cppcheck() {
    echo -e "${C_CYAN}${C_BOLD}Checking template system health...${C_RESET}"
    echo -e "${C_CYAN}╔═══------------------------------------------═══╗${C_RESET}"

    local all_good=true
    local warnings=0

    # Check workspace configuration
    echo -e "${C_BLUE}Workspace Configuration:${C_RESET}"
    if [ -n "$CP_WORKSPACE_ROOT" ] && [ -d "$CP_WORKSPACE_ROOT" ]; then
        echo -e "${C_GREEN}  ✓ Workspace root: $CP_WORKSPACE_ROOT${C_RESET}"
    else
        echo -e "${C_RED}  ✗ Workspace root not configured or missing${C_RESET}"
        all_good=false
    fi

    if [ -n "$CP_ALGORITHMS_DIR" ] && [ -d "$CP_ALGORITHMS_DIR" ]; then
        echo -e "${C_GREEN}  ✓ Algorithms directory: $CP_ALGORITHMS_DIR${C_RESET}"
    else
        echo -e "${C_RED}  ✗ Algorithms directory not configured or missing${C_RESET}"
        all_good=false
    fi

    # Check template system components.
    echo -e "\n${C_BLUE}Template System Components:${C_RESET}"

    # Check for new modular system.
    if [ -f "$SCRIPTS_DIR/flattener.py" ]; then
        echo -e "${C_GREEN}  ✓ Flattener script found${C_RESET}"
        if python3 -c "import sys; sys.exit(0)" 2>/dev/null; then
            echo -e "${C_GREEN}  ✓ Python 3 available${C_RESET}"
        else
            echo -e "${C_RED}  ✗ Python 3 not available${C_RESET}"
            all_good=false
        fi
    else
        echo -e "${C_YELLOW}  ⚠ Flattener script not found (using legacy system)${C_RESET}"
        warnings=$((warnings + 1))
    fi

    # Check templates directory.
    if [ -d "$TEMPLATES_DIR" ]; then
        local template_count
        template_count=$(find "$TEMPLATES_DIR" -maxdepth 1 -name "*.hpp" 2>/dev/null | wc -l)
        echo -e "${C_GREEN}  ✓ Templates directory: $template_count files${C_RESET}"
    else
        echo -e "${C_YELLOW}  ⚠ Templates directory not found (optional)${C_RESET}"
        warnings=$((warnings + 1))
    fi

    # Check modules directory.
    if [ -d "$MODULES_DIR" ]; then
        local module_count
        module_count=$(find "$MODULES_DIR" -maxdepth 1 -name "*.hpp" 2>/dev/null | wc -l)
        echo -e "${C_GREEN}  ✓ Modules directory: $module_count files${C_RESET}"
    else
        echo -e "${C_YELLOW}  ⚠ Modules directory not found (optional)${C_RESET}"
        warnings=$((warnings + 1))
    fi

    # Check legacy system fallback.
    local legacy_build="$CP_ALGORITHMS_DIR/build_template.sh"
    if [ -f "$legacy_build" ]; then
        echo -e "${C_GREEN}  ✓ Legacy build script available (fallback)${C_RESET}"
    else
        echo -e "${C_YELLOW}  ⚠ Legacy build script not found${C_RESET}"
        warnings=$((warnings + 1))
    fi

    # Check compiler and tools.
    echo -e "\n${C_BLUE}Development Tools:${C_RESET}"

    if command -v g++ &> /dev/null; then
        local gcc_version
        gcc_version=$(g++ --version | head -n1)
        echo -e "${C_GREEN}  ✓ Compiler: $gcc_version${C_RESET}"

        # Check C++ standard support.
        if echo | g++ -std=c++23 -x c++ - -fsyntax-only &>/dev/null; then
            echo -e "${C_GREEN}  ✓ C++23 support available${C_RESET}"
        elif echo | g++ -std=c++20 -x c++ - -fsyntax-only &>/dev/null; then
            echo -e "${C_YELLOW}  ⚠ C++20 available (C++23 not supported)${C_RESET}"
            warnings=$((warnings + 1))
        else
            echo -e "${C_RED}  ✗ Modern C++ standards not supported${C_RESET}"
            all_good=false
        fi
    else
        echo -e "${C_RED}  ✗ g++ compiler not found${C_RESET}"
        all_good=false
    fi

    if command -v python3 &> /dev/null; then
        local python_version
        python_version=$(python3 --version 2>&1)
        echo -e "${C_GREEN}  ✓ Python: $python_version${C_RESET}"
    else
        echo -e "${C_YELLOW}  ⚠ Python 3 not found (required for new features)${C_RESET}"
        warnings=$((warnings + 1))
    fi

    # Summary.
    echo -e "\n${C_CYAN}╚═══------------------------------------------═══╝${C_RESET}"
    if $all_good; then
        if [ $warnings -eq 0 ]; then
            echo -e "${C_GREEN}${C_BOLD}✓ All systems fully operational${C_RESET}"
        else
            echo -e "${C_GREEN}${C_BOLD}✓ Core systems operational${C_RESET}"
            echo -e "${C_YELLOW}  $warnings warning(s) for optional features${C_RESET}"
        fi
        return 0
    else
        echo -e "${C_RED}${C_BOLD}✗ Critical issues detected${C_RESET}"
        echo -e "${C_YELLOW}  Please resolve the issues marked with ✗${C_RESET}"
        return 1
    fi
}

# ---------------------------- COMPILER UTILITIES ---------------------------- #

# Quick compiler switch function for GCC.
function cppgcc() {
    local build_type=${1:-Debug}
    echo "${C_CYAN}Switching to GCC toolchain (${build_type})...${C_RESET}"
    echo "${C_YELLOW}Cleaning build environment first...${C_RESET}"
    cppclean
    cppconf "$build_type" gcc
}

# Quick compiler switch function for Clang.
function cppclang() {
    local build_type=${1:-Debug}
    echo "${C_CYAN}Switching to Clang toolchain (${build_type})...${C_RESET}"
    echo "${C_YELLOW}Cleaning build environment first...${C_RESET}"
    cppclean
    cppconf "$build_type" clang
}

# Quick profiling build.
function cppprof() {
    echo "${C_CYAN}Configuring profiling build with Clang...${C_RESET}"
    echo "${C_YELLOW}Cleaning build environment first...${C_RESET}"
    cppclean
    CP_TIMING=1 cppconf Release clang
}

# Show current configuration.
function cppinfo() {
    if [ -f ".statistics/last_config" ]; then
        local config
        config=$(cat .statistics/last_config)
        local build_type=${config%:*}
        local compiler=${config#*:}
        echo "${C_CYAN}Current configuration:${C_RESET}"
        echo "  Build Type: ${C_YELLOW}$build_type${C_RESET}"
        echo "  Compiler: ${C_YELLOW}$compiler${C_RESET}"
    else
        echo "${C_YELLOW}No configuration found. Run 'cppconf' first.${C_RESET}"
    fi

    if [ -f "build/CMakeCache.txt" ]; then
        local actual_compiler
        actual_compiler=$(grep "CMAKE_CXX_COMPILER:FILEPATH=" build/CMakeCache.txt | cut -d'=' -f2)
        echo "  Actual Path: ${C_GREEN}$actual_compiler${C_RESET}"

        # Check for LTO support.
        if grep -q "INTERPROCEDURAL_OPTIMIZATION.*TRUE" build/CMakeCache.txt 2>/dev/null; then
            echo "  ${C_GREEN}LTO: Enabled${C_RESET}"
        fi
    fi
}

# -------------------------------- UTILITIES --------------------------------- #

# Cleans the project by removing the build directory.
function cppclean() {
    _check_workspace || return 1
    if [ ! -f "CMakeLists.txt" ]; then
        echo "${C_RED}Error: No CMakeLists.txt found in $(pwd). Aborting clean to avoid accidental deletion.${C_RESET}" >&2
        return 1
    fi
    echo "${C_CYAN}Cleaning project...${C_RESET}"
    rm -rf -- build bin lib
    # Also remove the symlink if it exists in the root.
    if [ -L "compile_commands.json" ]; then
        rm -- "compile_commands.json"
    fi
    echo "Project cleaned."
}

# Deep clean - removes everything except source files and input cases.
function cppdeepclean() {
    _check_workspace || return 1
    if [ ! -f "CMakeLists.txt" ]; then
        echo "${C_RED}Error: No CMakeLists.txt found in $(pwd). Aborting deep clean to avoid accidental deletion.${C_RESET}" >&2
        return 1
    fi
    echo "${C_YELLOW}This will remove all generated files except source code and test cases.${C_RESET}"
    echo -n "Are you sure? (y/N): "
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        cppclean
        rm -f -- CMakeLists.txt gcc-toolchain.cmake clang-toolchain.cmake .clangd
        rm -f -- .contest_metadata .problem_times
        rm -rf -- .cache
        echo "${C_GREEN}Deep clean complete.${C_RESET}"
    else
        echo "Deep clean cancelled."
    fi
}

# Watches a source file for changes and automatically rebuilds it.
function cppwatch() {
    _check_initialized || return 1
    local target_name=${1:-$(_get_default_target)}
    local source_file

    # Find the actual source file extension.
    if [ -f "${target_name}.cpp" ]; then source_file="${target_name}.cpp";
    elif [ -f "${target_name}.cc" ]; then source_file="${target_name}.cc";
    elif [ -f "${target_name}.cxx" ]; then source_file="${target_name}.cxx";
    else
        echo "${C_RED}Error: Source file for target '$target_name' not found.${C_RESET}" >&2
        return 1
    fi

    if ! command -v fswatch &> /dev/null; then
        echo "${C_RED}Error: 'fswatch' is not installed. Please run 'brew install fswatch'.${C_RESET}" >&2
        return 1
    fi

    echo "${C_CYAN}Watching '$source_file' to rebuild target '$target_name'. Press Ctrl+C to stop.${C_RESET}"
    # Initial build.
    cppbuild "$target_name"

    fswatch -o "$source_file" | while read -r; do cppbuild "$target_name"; done
}

# Show time statistics for problems in the current contest.
function cppstats() {
    if [ ! -f ".statistics/problem_times" ]; then
        echo "${C_YELLOW}No timing data available for this contest.${C_RESET}"
        return 0
    fi

    echo "${C_BOLD}${C_BLUE}╔═══----------- PROBLEM STATISTICS -----------═══╗${C_RESET}"
    echo ""

    local current_time
    current_time=$(date +%s)
    while IFS=: read -r problem action timestamp; do
        if [ "$action" = "START" ]; then
            local elapsed=$((current_time - timestamp))
            echo "${C_CYAN}$problem${C_RESET}: Started $(_format_duration $elapsed) ago"
        fi
    done < .statistics/problem_times

    echo ""
    echo "${C_BOLD}${C_BLUE}╚═══------------------------------------------═══╝${C_RESET}"
}

# Archive the current contest with all solutions.
function cpparchive() {
    local contest_name
    contest_name=$(basename "$(pwd)")
    local archive_name
    archive_name="${contest_name}_$(date +%Y%m%d_%H%M%S).tar.gz"

    echo "${C_CYAN}Archiving contest to '$archive_name'...${C_RESET}"

    # Create archive excluding build artifacts.
    tar -czf "../$archive_name" \
        --exclude="build" \
        --exclude="bin" \
        --exclude="lib" \
        --exclude="*.dSYM" \
        --exclude=".git" \
        .

    echo "${C_GREEN}Contest archived to '../$archive_name'${C_RESET}"
}

# Displays detailed diagnostic information about the toolchain and environment.
function cppdiag() {
    # Helper function to print formatted headers.
    _print_header() {
        echo ""
        echo "${C_BOLD}${C_BLUE}╔═══---------------- $1 ----------------═══╗${C_RESET}"
    }

    echo "${C_BOLD}Running Competitive Programming Environment Diagnostics...${C_RESET}"

    _print_header "SYSTEM & SHELL"
    # Display OS and shell information.
    uname -a
    echo "Shell: $SHELL"
    [ -n "$BASH_VERSION" ] && echo "Bash Version: $BASH_VERSION"
    [ -n "$ZSH_VERSION" ] && echo "Zsh Version: $ZSH_VERSION"
    echo "Script Directory: $SCRIPT_DIR"

    _print_header "WORKSPACE CONFIGURATION"
    echo "CP Workspace Root: ${C_CYAN}$CP_WORKSPACE_ROOT${C_RESET}"
    echo "Algorithms Directory: ${C_CYAN}$CP_ALGORITHMS_DIR${C_RESET}"

    # Check if we're in the workspace.
    local current_dir
    current_dir="$(pwd)"
    if [[ "$current_dir" == "$CP_WORKSPACE_ROOT"* ]]; then
        echo "Current Location: ${C_GREEN}Inside workspace${C_RESET}"
    else
        echo "Current Location: ${C_YELLOW}Outside workspace${C_RESET}"
    fi

    _print_header "CORE TOOLS"

    # Check for g++
    local GXX_PATH
    GXX_PATH=$(command -v g++-15 || command -v g++-14 || command -v g++-13 || command -v g++)
    if [ -n "$GXX_PATH" ]; then
        echo "${C_GREEN}g++:${C_RESET}"
        echo "   ${C_CYAN}Path:${C_RESET} $GXX_PATH"
        echo "   ${C_CYAN}Version:${C_RESET} $($GXX_PATH --version | head -n 1)"
    else
        echo "${C_RED}g++: Not found!${C_RESET}"
    fi

    # Check for clang++
    local CLANGXX_PATH
    CLANGXX_PATH=$(command -v clang++)
    if [ -n "$CLANGXX_PATH" ]; then
        echo "${C_GREEN}clang++:${C_RESET}"
        echo "   ${C_CYAN}Path:${C_RESET} $CLANGXX_PATH"
        echo "   ${C_CYAN}Version:${C_RESET} $($CLANGXX_PATH --version | head -n 1)"

        # Check if it's Apple Clang or LLVM Clang.
        if $CLANGXX_PATH --version | grep -q "Apple"; then
            echo "   ${C_CYAN}Type:${C_RESET} Apple Clang (Xcode)"
        else
            echo "   ${C_CYAN}Type:${C_RESET} LLVM Clang"
        fi
    else
        echo "${C_YELLOW}clang++: Not found (optional, needed for sanitizers on macOS)${C_RESET}"
    fi

    # Check for cmake.
    local CMAKE_PATH
    CMAKE_PATH=$(command -v cmake)
    if [ -n "$CMAKE_PATH" ]; then
        echo "${C_GREEN}cmake:${C_RESET}"
        echo "   ${C_CYAN}Path:${C_RESET} $CMAKE_PATH"
        echo "   ${C_CYAN}Version:${C_RESET} $($CMAKE_PATH --version | head -n 1)"
    else
        echo "${C_RED}cmake: Not found!${C_RESET}"
    fi

    # Check for clangd.
    local CLANGD_PATH
    CLANGD_PATH=$(command -v clangd)
    if [ -n "$CLANGD_PATH" ]; then
        echo "${C_GREEN}clangd:${C_RESET}"
        echo "   ${C_CYAN}Path:${C_RESET} $CLANGD_PATH"
        echo "   ${C_CYAN}Version:${C_RESET} $($CLANGD_PATH --version | head -n 1)"
    else
        echo "${C_RED}clangd: Not found!${C_RESET}"
    fi

    # Check for fswatch (optional).
    local FSWATCH_PATH
    FSWATCH_PATH=$(command -v fswatch)
    if [ -n "$FSWATCH_PATH" ]; then
        echo "${C_GREEN}fswatch:${C_RESET}"
        echo "   ${C_CYAN}Path:${C_RESET} $FSWATCH_PATH"
    else
        echo "${C_YELLOW}fswatch: Not found (optional, needed for cppwatch)${C_RESET}"
    fi

    _print_header "PROJECT CONFIGURATION (in $(pwd))"
    if [ -f "CMakeLists.txt" ]; then
        echo "${C_GREEN}Found CMakeLists.txt${C_RESET}"

        # Check CMake Cache for the configured compiler.
        if [ -f "build/CMakeCache.txt" ]; then
            local cached_compiler
            cached_compiler=$(grep "CMAKE_CXX_COMPILER:FILEPATH=" build/CMakeCache.txt | cut -d'=' -f2)
            echo "   ${C_CYAN}CMake Cached CXX Compiler:${C_RESET} $cached_compiler"
        else
            echo "   ${C_YELLOW}Info: No CMake cache found. Run 'cppconf' to generate it.${C_RESET}"
        fi

        # Display .clangd configuration if it exists.
        if [ -f ".clangd" ]; then
            echo "${C_GREEN}Found .clangd config${C_RESET}"
        else
            echo "   ${C_YELLOW}Info: No .clangd config file found in this project.${C_RESET}"
        fi

        # Check for metadata files.
        if [ -f ".contest_metadata" ]; then
            echo "${C_GREEN}Found contest metadata${C_RESET}"
            grep "CONTEST_NAME" .contest_metadata | sed 's/^/   /'
            grep "CREATED" .contest_metadata | sed 's/^/   /'
        fi

        # Count problems.
        local cpp_count
        cpp_count=$(find . -maxdepth 1 -name "*.cpp" -type f 2>/dev/null | wc -l)
        echo "   ${C_CYAN}C++ files:${C_RESET} $cpp_count"

    else
        echo "${C_RED}Not inside a project directory (CMakeLists.txt not found).${C_RESET}"
    fi

    _print_header "COMPILER FEATURES CHECK"

    # Test with GCC if available.
    if [ -n "$GXX_PATH" ]; then
        echo "${C_CYAN}Testing GCC features:${C_RESET}"
        local test_file="/tmp/cp_gcc_test_$.cpp"
        cat > "$test_file" << 'EOF'
#include <bits/stdc++.h>
#include <ext/pb_ds/assoc_container.hpp>
using namespace std;
using namespace __gnu_pbds;
int main() { cout << "OK" << endl; return 0; }
EOF

        if $GXX_PATH -std=c++23 "$test_file" -o /tmp/cp_gcc_test_$ 2>/dev/null; then
            echo "  ${C_GREEN}bits/stdc++.h: Available${C_RESET}"
            echo "  ${C_GREEN}PBDS: Available${C_RESET}"
            echo "  ${C_GREEN}C++23: Supported${C_RESET}"
            rm -f /tmp/cp_gcc_test_$
        else
            echo "  ${C_RED}Some GCC features may not be available. Check your installation.${C_RESET}"
        fi
        rm -f "$test_file"
    fi

    # Test with Clang if available.
    if [ -n "$CLANGXX_PATH" ]; then
        echo ""
        echo "${C_CYAN}Testing Clang features:${C_RESET}"

        # Test PCH.h compatibility.
        local test_pch="/tmp/cp_clang_test_$.cpp"
        cat > "$test_pch" << 'EOF'
#define USE_CLANG_SANITIZE
#include "PCH.h"
using namespace std;
int main() { cout << "OK" << endl; return 0; }
EOF

        # Check if PCH.h exists in algorithms directory.
        if [ -f "algorithms/PCH.h" ]; then
            if $CLANGXX_PATH -std=c++23 -I./algorithms "$test_pch" -o /tmp/cp_clang_test_$ 2>/dev/null; then
                echo "  ${C_GREEN}PCH.h: Compatible${C_RESET}"
                echo "  ${C_GREEN}C++23: Supported${C_RESET}"
                rm -f /tmp/cp_clang_test_$
            else
                echo "  ${C_YELLOW}PCH.h compilation failed (check algorithms/PCH.h)${C_RESET}"
            fi
        else
            echo "  ${C_YELLOW}PCH.h: Not found in algorithms/ directory${C_RESET}"
        fi

        # Test sanitizer support.
        printf "#include <iostream>\nint main(){return 0;}" > "$test_pch"
        if $CLANGXX_PATH -fsanitize=address "$test_pch" -o /tmp/cp_clang_san_$ 2>/dev/null; then
            echo "  ${C_GREEN}AddressSanitizer: Available${C_RESET}"
            rm -f /tmp/cp_clang_san_$
        else
            echo "  ${C_RED}AddressSanitizer: Not available${C_RESET}"
        fi

        if $CLANGXX_PATH -fsanitize=undefined "$test_pch" -o /tmp/cp_clang_san_$ 2>/dev/null; then
            echo "  ${C_GREEN}UBSanitizer: Available${C_RESET}"
            rm -f /tmp/cp_clang_san_$
        else
            echo "  ${C_RED}UBSanitizer: Not available${C_RESET}"
        fi

        rm -f "$test_pch"
    fi

    echo ""
}

# --------------------------- SOME USEFUL ALIASES ---------------------------- #
# Shorter aliases for convenience.
alias cppc='cppconf'
alias cppb='cppbuild'
alias cppr='cpprun'
alias cppg='cppgo'
alias cppi='cppi'
alias cppj='cppjudge'
alias cpps='cppstats'
alias cppcl='cppclean'
alias cppdc='cppdeepclean'
alias cppw='cppwatch'
alias cppn='cppnew'
alias cppdel='cppdelete'
alias cppf='cppforcego'
alias cppct='cppcontest'
alias cppar='cpparchive'
alias cppst='cppstress'
alias cppd='cppdiag'
alias cppin='cppinit'
alias cpph='cpphelp'

# Short alias for problem run with input redirection.
# Dynamic problem runner function that handles both problem_X and problem_X[0..9] patterns.
function _cppgo_problem() {
    local problem_id="$1"
    local target_name="problem_${problem_id}"
    local input_file="${target_name}.in"

    # Check if the target file exists, if not try with numeric suffix.
    if [ ! -f "${target_name}.cpp" ] && [ ! -f "${target_name}.cc" ] && [ ! -f "${target_name}.cxx" ]; then
        # Try with numeric suffix (problem_A1, problem_A2, etc.).
        local found_file=""
        for ext in cpp cc cxx; do
            for num in {1..9}; do
                if [ -f "${target_name}${num}.${ext}" ]; then
                    target_name="${target_name}${num}"
                    input_file="${target_name}.in"
                    found_file="${target_name}.${ext}"
                    break 2
                fi
            done
        done

        if [ -z "$found_file" ]; then
            echo "${C_RED}Error: No file found for problem '${problem_id}' (tried ${target_name}.* and ${target_name}[1-9].*).${C_RESET}" >&2
            return 1
        fi
    fi

    cppgo "$target_name" "$input_file"
}

# Create aliases for common problem letters
for letter in {A..H}; do
    alias cppgo_${letter}="_cppgo_problem ${letter}"
done

# Create numbered variant aliases (e.g., cppgo_A1, cppgo_A2, etc.)
for letter in {A..H}; do
    for num in {1..9}; do
        alias cppgo_${letter}${num}="cppgo problem_${letter}${num} problem_${letter}${num}.in"
    done
done

# ------------------------------- HELP & USAGE ------------------------------- #

# Displays the help message.
function cpphelp() {
    cat << EOF
${C_BOLD}Enhanced CMake Utilities for Competitive Programming:${C_RESET}

${C_BOLD}${C_CYAN}[ SETUP & CONFIGURATION ]${C_RESET}
  ${C_GREEN}cppinit${C_RESET}                       - Initializes or verifies a project directory (workspace-protected).
  ${C_GREEN}cppnew${C_RESET} ${C_YELLOW}[name] [template]${C_RESET}      - Creates a new .cpp file from a template ('default', 'pbds', 'advanced', 'base').
  ${C_GREEN}cppdelete${C_RESET} ${C_YELLOW}[name]${C_RESET}              - Deletes a problem file and associated data (interactive).
  ${C_GREEN}cppbatch${C_RESET} ${C_YELLOW}[count] [tpl]${C_RESET}        - Creates multiple problems at once (A, B, C, ...).
  ${C_GREEN}cppconf${C_RESET} ${C_YELLOW}[type] [compiler] ${C_RESET}    - (Re)configures the project (Debug/Release/Sanitize, gcc/clang/auto, timing reports).
          ${C_YELLOW}[timing=on/off]${C_RESET}
  ${C_GREEN}cppcontest${C_RESET} ${C_YELLOW}[dir_name]${C_RESET}         - Creates a new contest directory and initializes it.

${C_BOLD}${C_CYAN}[ BUILD, RUN, TEST ]${C_RESET}
  ${C_GREEN}cppbuild${C_RESET} ${C_YELLOW}[name]${C_RESET}          - Builds a target (defaults to most recent).
  ${C_GREEN}cpprun${C_RESET} ${C_YELLOW}[name]${C_RESET}            - Runs a target's executable.
  ${C_GREEN}cppgo${C_RESET} ${C_YELLOW}[name] [input]${C_RESET}     - Builds and runs. Uses '<name>.in' by default.
  ${C_GREEN}cppforcego${C_RESET} ${C_YELLOW}[name]${C_RESET}        - Force rebuild and run (updates timestamp).
  ${C_GREEN}cppi${C_RESET} ${C_YELLOW}[name]${C_RESET}              - Interactive mode: builds and runs with manual input.
  ${C_GREEN}cppjudge${C_RESET} ${C_YELLOW}[name]${C_RESET}          - Tests against all sample cases with timing info.
  ${C_GREEN}cppstress${C_RESET} ${C_YELLOW}[name] [n]${C_RESET}     - Stress tests a solution for n iterations (default: 100).

${C_BOLD}${C_CYAN}[ COMPILER SELECTION ]${C_RESET}
  ${C_GREEN}cppgcc${C_RESET} ${C_YELLOW}[type]${C_RESET}            - Configure with GCC compiler (defaults to Debug).
  ${C_GREEN}cppclang${C_RESET} ${C_YELLOW}[type]${C_RESET}          - Configure with Clang compiler (defaults to Debug).
  ${C_GREEN}cppprof${C_RESET}                  - Configure profiling build with Clang and timing enabled.
  ${C_GREEN}cppinfo${C_RESET}                  - Shows current compiler and build configuration.

${C_BOLD}${C_CYAN}[ UTILITIES ]${C_RESET}
  ${C_GREEN}cppwatch${C_RESET} ${C_YELLOW}[name]${C_RESET}          - Auto-rebuilds a target on file change (requires fswatch).
  ${C_GREEN}cppclean${C_RESET}                 - Removes build artifacts.
  ${C_GREEN}cppdeepclean${C_RESET}             - Removes all generated files (interactive).
  ${C_GREEN}cppstats${C_RESET}                 - Shows timing statistics for problems.
  ${C_GREEN}cpparchive${C_RESET}               - Creates a compressed archive of the contest.
  ${C_GREEN}cppdiag${C_RESET}                  - Displays detailed diagnostic info about the toolchain.
  ${C_GREEN}cpphelp${C_RESET}                  - Shows this help message.

${C_BOLD}${C_CYAN}[ SUBMISSION PREPARATION ]${C_RESET}
  ${C_GREEN}cppsubmit${C_RESET} ${C_YELLOW}[name]${C_RESET}             - Generates a single-file submission (flattener-based).
  ${C_GREEN}cpptestsubmit${C_RESET} ${C_YELLOW}[name] [input]${C_RESET} - Tests the generated submission file.
  ${C_GREEN}cppfull${C_RESET} ${C_YELLOW}[name] [input]${C_RESET}       - Full workflow: test dev version, generate submission, test submission.
  ${C_GREEN}cppcheck${C_RESET}                     - Checks the health of the template system and environment.

${C_BOLD}${C_CYAN}[ QUICK ACCESS ALIASES ]${C_RESET}
  ${C_GREEN}cppgo_A${C_RESET}, ${C_GREEN}cppgo_B${C_RESET}, etc.       - Quick run for problem_A, problem_B, etc.
  ${C_GREEN}cppgo_A1${C_RESET}, ${C_GREEN}cppgo_A2${C_RESET}, etc.     - Quick run for numbered variants (problem_A1, problem_A2, etc.).

  Short aliases:
    ${C_GREEN}cppc${C_RESET}=cppconf, ${C_GREEN}cppb${C_RESET}=cppbuild, ${C_GREEN}cppr${C_RESET}=cpprun, ${C_GREEN}cppg${C_RESET}=cppgo, and more.

${C_BOLD}${C_MAGENTA}[ WORKSPACE INFO ]${C_RESET}
  Workspace Root: ${C_CYAN}${CP_WORKSPACE_ROOT}${C_RESET}
  Algorithms Dir: ${C_CYAN}${CP_ALGORITHMS_DIR}${C_RESET}

* Most commands default to the most recently modified C++ source file.
* Workspace protection prevents accidental initialization outside CP directory.
EOF
}

# Display load message only if not in quiet mode.
export CP_QUIET_LOAD=${1:-0}
if [ -z "$CP_QUIET_LOAD" ]; then
    echo "${C_GREEN}Competitive Programming utilities loaded. Type 'cpphelp' for commands.${C_RESET}"
fi

# ============================================================================ #
# End of script
