#!/bin/bash
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
PERFETTO_UI_DIR="$HOME/Dev/Tools/perfetto"

# Check if terminal supports colors.
if test -t 1; then
    N_COLORS=$(tput colors)
    if test -n "$N_COLORS" && test $N_COLORS -ge 8; then
        BOLD="$(tput bold)"
        BLUE="$(tput setaf 4)"
        CYAN="$(tput setaf 6)"
        GREEN="$(tput setaf 2)"
        RED="$(tput setaf 1)"
        YELLOW="$(tput setaf 3)"
        MAGENTA="$(tput setaf 5)"
        RESET="$(tput sgr0)"
    fi
fi

# Detect the script directory for reliable access to templates.
# This works for both bash and zsh when the script is sourced.
if [ -n "$BASH_SOURCE" ]; then
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
elif [ -n "$ZSH_VERSION" ]; then
    SCRIPT_DIR="$( cd "$( dirname "${(%):-%x}" )" &> /dev/null && pwd )"
else
    echo "${RED}Unsupported shell for script directory detection.${RESET}" >&2
    # Fallback to current directory, though this may be unreliable.
    SCRIPT_DIR="."
fi

# Utility to get the last modified cpp file as the default target.
_get_default_target() {
    # Find the most recently modified .cpp, .cc, or .cxx file.
    local default_target
    default_target=$(ls -t *.cpp *.cc *.cxx 2>/dev/null | head -n 1 | sed -E 's/\.(cpp|cc|cxx)$//')
    # If no file is found, default to "main".
    echo "${default_target:-main}"
}

# Utility to check if the project is initialized.
_check_initialized() {
    if [ ! -f "CMakeLists.txt" ] || [ ! -d "build" ]; then
        echo "${RED}Error: Project is not initialized. Please run 'cppinit' first.${RESET}" >&2
        return 1
    fi
    return 0
}

# Utility to check if we're in the allowed workspace.
_check_workspace() {
    local current_dir="$(pwd)"
    if [[ "$current_dir" != "$CP_WORKSPACE_ROOT"* ]]; then
        echo "${RED}Error: This command can only be run within the competitive programming workspace.${RESET}" >&2
        echo "${YELLOW}Expected workspace root: ${CP_WORKSPACE_ROOT}${RESET}" >&2
        echo "${YELLOW}Current directory: ${current_dir}${RESET}" >&2
        return 1
    fi
    return 0
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

# -------------------------- PROJECT SETUP & CONFIG -------------------------- #

# Initializes or verifies a competitive programming directory.
# This function is now idempotent and workspace-protected.
function cppinit() {
    # Check workspace restriction.
    if ! _check_workspace; then
        echo "${RED}Initialization aborted. Navigate to your CP workspace first.${RESET}" >&2
        return 1
    fi

    echo "${CYAN}Initializing Competitive Programming environment...${RESET}"

    # Check for script directory, essential for finding templates.
    if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR/templates" ]; then
        echo "${RED}Error: SCRIPT_DIR is not set or templates directory is missing.${RESET}" >&2
        return 1
    fi

    # Create .statistics and .ide-configs directories if they don't exist.
    mkdir -p .ide-configs
    mkdir -p .statistics

    # Create .contest_metadata in .statistics directory f it doesn't exist (for tracking).
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
            echo "${YELLOW}Warning: Global debug.h not found. Created a local placeholder.${RESET}"
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
            echo "${YELLOW}Warning: Global templates directory not found. Created a local placeholder.${RESET}"
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
            echo "${YELLOW}Warning: Global modules directory not found. Created a local placeholder.${RESET}"
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
            echo "${YELLOW}Warning: PCH.h not found. Clang builds may not work properly.${RESET}"
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
            echo "${YELLOW}Warning: PCH_Wrapper.h not found. Some builds may not work properly.${RESET}"
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

    echo "${BOLD}${GREEN}Project initialized successfully!${RESET}"
    echo "Run '${CYAN}cppnew <problem_name>${RESET}' to create your first solution file."
}

# Creates a new problem file from a template and re-runs CMake.
function cppnew() {
    # Ensure the project is initialized before creating a new file.
    if [ ! -f "CMakeLists.txt" ]; then
        echo "${RED}Project not initialized. Run 'cppinit' before creating a new problem.${RESET}" >&2
        return 1
    fi

    local problem_name=${1:-"main"}
    local template_type=${2:-"base"}
    local file_name="${problem_name}.cpp"
    local template_file

    if [ -f "${problem_name}.cpp" ] || [ -f "${problem_name}.cc" ] || [ -f "${problem_name}.cxx" ]; then
        echo "${RED}Error: File for problem '$problem_name' already exists.${RESET}" >&2
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
        echo "${RED}Error: Template file '$template_file' not found.${RESET}" >&2
        return 1
    fi
    
    echo "${CYAN}Creating '$file_name' from template '$template_type'...${RESET}"
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
        echo "${RED}Usage: cppdelete <problem_name>${RESET}" >&2
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
        echo "${RED}Error: No source file found for problem '$problem_name'${RESET}" >&2
        return 1
    fi

    # List all files that will be deleted.
    echo "${YELLOW}The following files will be deleted:${RESET}"
    echo "  - Source file: ${CYAN}$source_file${RESET}"
    
    # Check for input/output files.
    local files_to_delete=("$source_file")
    
    if [ -f "input_cases/${problem_name}.in" ]; then
        echo "  - Input file: ${CYAN}input_cases/${problem_name}.in${RESET}"
        files_to_delete+=("input_cases/${problem_name}.in")
    fi
    
    # Check for multiple input files (numbered pattern).
    while IFS= read -r -d '' input_file; do
        echo "  - Input file: ${CYAN}$input_file${RESET}"
        files_to_delete+=("$input_file")
    done < <(find input_cases -name "${problem_name}.*.in" -print0 2>/dev/null)
    
    if [ -f "output_cases/${problem_name}.exp" ]; then
        echo "  - Output file: ${CYAN}output_cases/${problem_name}.exp${RESET}"
        files_to_delete+=("output_cases/${problem_name}.exp")
    fi
    
    # Check for multiple output files (numbered pattern).
    while IFS= read -r -d '' output_file; do
        echo "  - Output file: ${CYAN}$output_file${RESET}"
        files_to_delete+=("$output_file")
    done < <(find output_cases -name "${problem_name}.*.exp" -print0 2>/dev/null)
    
    # Check for submission file.
    if [ -f "$SUBMISSIONS_DIR/${problem_name}_sub.cpp" ]; then
        echo "  - Submission file: ${CYAN}$SUBMISSIONS_DIR/${problem_name}_sub.cpp${RESET}"
        files_to_delete+=("$SUBMISSIONS_DIR/${problem_name}_sub.cpp")
    fi
    
    # Check for executable in bin directory.
    if [ -f "bin/${problem_name}" ]; then
        echo "  - Executable: ${CYAN}bin/${problem_name}${RESET}"
        files_to_delete+=("bin/${problem_name}")
    fi
    
    # Confirmation prompt.
    echo ""
    echo -n "${YELLOW}Are you sure you want to delete these files? (y/N): ${RESET}"
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
            echo "${GREEN}Deleted: $file${RESET}"
            ((deleted_count++))
        fi
    done
    
    # Remove problem timing data from statistics.
    if [ -f ".statistics/problem_times" ]; then
        grep -v "^${problem_name}:" .statistics/problem_times > .statistics/problem_times.tmp 2>/dev/null || true
        mv .statistics/problem_times.tmp .statistics/problem_times 2>/dev/null || true
    fi
    
    echo ""
    echo "${GREEN}Successfully deleted problem '$problem_name' ($deleted_count files removed)${RESET}"
    
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
    
    echo "${CYAN}Creating $count problems with template '$template'...${RESET}"
    
    for i in $(seq 65 $((64 + count))); do
        local problem_name="problem_$(printf "\\$(printf '%03o' $i)")"
        if [ ! -f "${problem_name}.cpp" ]; then
            cppnew "$problem_name" "$template"
        else
            echo "${YELLOW}Skipping $problem_name - already exists${RESET}"
        fi
    done
    
    echo "${GREEN}Batch creation complete!${RESET}"
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
                    echo "${YELLOW}Warning: Unknown value for 'timing': '$value'. Ignoring.${RESET}"
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
                    echo "${YELLOW}Warning: Unknown value for 'pch': '$value'. Ignoring.${RESET}"
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
                echo "${YELLOW}Warning: Unknown argument '$arg'. Ignoring.${RESET}"
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
            echo "${RED}Error: Unknown compiler choice '$compiler_choice'${RESET}" >&2
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
            echo "${RED}Error: Template for $toolchain_file not found!${RESET}" >&2
            if [ "$toolchain_file" = "gcc-toolchain.cmake" ]; then
                echo "${YELLOW}Running cppinit to fix missing GCC toolchain...${RESET}"
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
    echo "${BLUE}╔═══---------------------------------------------------------------------------═══╗${RESET}"
    echo "  ${BLUE}Configuring project:${RESET}"
    echo "    ${CYAN}Build Type:${RESET} ${YELLOW}${build_type}${RESET}"
    echo "    ${CYAN}Compiler:${RESET} ${YELLOW}${toolchain_name}${RESET}"
    echo "    ${CYAN}Timing Report:${RESET} ${YELLOW}${timing_cmake_arg##*=}${RESET}"
    echo "    ${CYAN}PCH Support:${RESET} ${YELLOW}${pch_cmake_arg##*=}${RESET}"
    if [[ "${cmake_flags[*]}" == *"LTO"* ]]; then
        echo "    ${CYAN}LTO:${RESET} ${YELLOW}Enabled${RESET}"
    fi
    if [ -n "$force_pch_rebuild_arg" ]; then
        echo "    ${CYAN}PCH Rebuild:${RESET} ${YELLOW}Forced${RESET}"
    fi
    echo "${BLUE}╚═══---------------------------------------------------------------------------═══╝${RESET}"
    
    # Run CMake with the selected toolchain - use array expansion.
    if cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=${build_type} \
        -DCMAKE_TOOLCHAIN_FILE=${toolchain_file} \
        -DCMAKE_CXX_FLAGS="-std=c++23" \
        "${cmake_flags[@]}"; then
        echo "${GREEN}CMake configuration successful.${RESET}"
        
        # If PCH rebuild was requested, clean PCH first.
        if [ -n "$force_pch_rebuild_arg" ]; then
            echo "${CYAN}Cleaning PCH cache...${RESET}"
            if cmake --build build --target pch_clean 2>/dev/null; then
                echo "${GREEN}PCH cache cleaned.${RESET}"
            else
                echo "${YELLOW}PCH clean target not available (normal for first run).${RESET}"
            fi
        fi
        
        # Create the symlink for clangd.
        cmake --build build --target symlink_clangd 2>/dev/null || true
        
        # Save configuration for quick reference.
        echo "$build_type:$compiler_choice:${pch_cmake_arg##*=}" > .statistics/last_config
    else
        echo "${RED}CMake configuration failed!${RESET}" >&2
        return 1
    fi
}

# Creates and sets up a new directory for a contest.
function cppcontest() {
    if [ -z "$1" ]; then
        echo "${RED}Usage: cppcontest <ContestDirectoryName>${RESET}" >&2
        echo "Example: cppcontest Codeforces/Round_1037_Div_3" >&2
        return 1
    fi

    # Ensure we're in the workspace before creating a contest.
    if ! _check_workspace; then
        echo "${RED}Contest creation aborted. Navigate to your CP workspace first.${RESET}" >&2
        return 1
    fi

    local contest_dir="$1"
    
    # Create the directory if it doesn't exist.
    if [ ! -d "$contest_dir" ]; then
        echo "${CYAN}Creating new contest directory: '$contest_dir'${RESET}"
        mkdir -p "$contest_dir"
    fi
    
    cd "$contest_dir" || return
    
    # Initialize the project here if it's not already set up.
    if [ ! -f "CMakeLists.txt" ]; then
        echo "Initializing new CMake project in '${BOLD}$(pwd)${RESET}'..."
        cppinit
    else
        echo "Project already initialized. Verifying configuration..."
        cppinit # Run to ensure all components are present.
    fi

    echo "${GREEN}Ready to work in ${BOLD}$(pwd)${RESET}. Use '${CYAN}cppnew <problem_name>${RESET}' to start."
}

# ------------------------------- BUILD & RUN -------------------------------- #

# Builds a specific target with intelligent, conditional, and formatted output.
function cppbuild() {
    _check_initialized || return 1
    local target_name=${1:-$(_get_default_target)}
    echo "${CYAN}Building target: ${BOLD}$target_name${RESET}..."

    # Record start time for total build duration.
    local start_time=$(date +%s%N)

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
    local end_time=$(date +%s%N)
    local elapsed_ns=$(( end_time - start_time ))
    local elapsed_ms=$(( elapsed_ns / 1000000 ))
    local decimal_part=$(( (elapsed_ns % 1000000) / 10000 ))

    # Handle build failures with full error output.
    if [ $build_status -ne 0 ]; then
        echo ""
        echo "${BOLD}${RED}╔═══--------- BUILD FAILED ---------═══╗${RESET}"
        echo "$build_output"
        printf "${RED}Build failed after %d.%02dms${RESET}\n" $elapsed_ms $decimal_part
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
            echo "${BOLD}${CYAN}╔═══--------------------- Compilation Time Statistics ----------------------═══╗${RESET}"
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
            echo -e " ${CYAN}Note: To analyze the detailed trace with Perfetto UI, run:${RESET}"
            echo -e "   ${BOLD}${GREEN}cpptrace $target_name${RESET}"
            fi

            echo ""
            echo "${BOLD}${CYAN}╚═══--------------- Compilation Finished, Proceeding to Link ---------------═══╝${RESET}"
            echo ""
        fi

        # 4. Print the linking line and anything after it.
        echo "$build_output" | sed -n '/Linking CXX executable/,$p'
        else
        # Target up-to-date - show only the summary line.
        echo "$build_output" | tail -n 1
        fi

    # Display total build time.
    printf "${MAGENTA}Total build time: %d.%02dms${RESET}\n" $elapsed_ms $decimal_part

    return 0
}

# Runs a specific executable.
function cpprun() {
    _check_initialized || return 1
    local target_name=${1:-$(_get_default_target)}
    local exec_path="./bin/$target_name"
    
    if [ ! -f "$exec_path" ]; then
        echo "${YELLOW}Executable '$exec_path' not found. Building first...${RESET}"
        if ! cppbuild "$target_name"; then
            echo "${RED}Build failed!${RESET}" >&2
            return 1
        fi
    fi

    echo "${BLUE}Running '$exec_path'...${RESET}"
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

    echo "${CYAN}Building target '${BOLD}$target_name${CYAN}'...${RESET}"
    if cppbuild "$target_name"; then
        echo ""
        echo "${BLUE}════-------------------------------------════${RESET}"
        echo "${BLUE}${BOLD}RUNNING: $target_name${RESET}"
        
        # Track execution time in nanoseconds for better precision.
        local start_time=$(date +%s%N)
        
        if [ -f "$input_path" ]; then
            echo "(input from ${YELLOW}$input_path${RESET})"
            timeout 5s "$exec_path" < "$input_path"
            local exit_code=$?
        else
            if [ -n "$2" ]; then # Warn if a specific file was requested but not found.
                 echo "${YELLOW}Warning: Input file '$input_path' not found.${RESET}" >&2
            fi
            timeout 5s "$exec_path"
            local exit_code=$?
        fi
        
        local end_time=$(date +%s%N)
        local elapsed_ns=$(( end_time - start_time ))
        local elapsed_ms=$(( elapsed_ns / 1000000 ))
        local decimal_part=$(( (elapsed_ns % 1000000) / 10000 ))
        
        # Check if the program was terminated due to timeout
        if [ $exit_code -eq 124 ]; then
            echo "${YELLOW}⚠ Program terminated after 5-second timeout${RESET}"
        elif [ $exit_code -ne 0 ] && [ $exit_code -ne 124 ]; then
            echo "${RED}Program exited with code $exit_code${RESET}"
        fi
        
        echo "${BLUE}════------------- FINISHED --------------════${RESET}"
        printf "${MAGENTA}Execution time: %d.%02dms${RESET}\n" $elapsed_ms $decimal_part
        echo ""
    else
        echo "${RED}Build failed!${RESET}" >&2
        return 1
    fi
}

# Force a rebuild and run, useful for re-triggering compilation analysis.
function cppforcego() {
    local target=$(_get_default_target)
    local exec_name=$(echo "${1:-$target}" | sed -E 's/\.(cpp|cc|cxx)$//')
    
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
    
    echo "${CYAN}Building target '${BOLD}$target_name${CYAN}'...${RESET}"
    if cppbuild "$target_name"; then
        echo ""
        echo "${BLUE}════-------------------------------------════${RESET}"
        echo "${BLUE}${BOLD}INTERACTIVE MODE: $target_name${RESET}"
        echo "${YELLOW}Enter input (Ctrl+D when done):${RESET}"
        "$exec_path"
        echo "${BLUE}════------------- FINISHED --------------════${RESET}"
    else
        echo "${RED}Build failed!${RESET}" >&2
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
        echo "${RED}Build failed!${RESET}" >&2
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
        echo "${YELLOW}No test cases found for '$target_name' (looked for '${target_name}.*.in' and '${target_name}.in')${RESET}"
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
        local start_time=$(date +%s%N)
        "$exec_path" < "$test_in" > "$temp_out"
        local end_time=$(date +%s%N)
        local elapsed_ms=$(( (end_time - start_time) / 1000000 ))

        # Check if expected output file exists.
        if [ ! -f "$output_case" ]; then
            echo "${BOLD}${YELLOW}WARNING: Expected output file '$(basename "$output_case")' not found.${RESET}"
            rm "$temp_out"
            continue
        fi

        # Use diff with -w (ignore all whitespace) and -B (ignore blank lines).
        if diff -wB "$temp_out" "$output_case" >/dev/null; then
            echo "${BOLD}${GREEN}PASSED${RESET} (${elapsed_ms}ms)"
            ((passed++))
        else
            echo "${BOLD}${RED}FAILED${RESET} (${elapsed_ms}ms)"
            ((failed++))
            echo "${BOLD}${YELLOW}════------------ YOUR OUTPUT ------------════${RESET}"
            cat "$temp_out"
            echo "${BOLD}${YELLOW}╠═══------------- EXPECTED --------------═══╣${RESET}"
            cat "$output_case"
            echo "${BOLD}${YELLOW}════-------------------------------------════${RESET}"
        fi
        rm "$temp_out"
    done

    # Summary.
    echo ""
    echo "${BOLD}${BLUE}════----------- TEST SUMMARY ------------════${RESET}"
    echo "${GREEN}Passed: $passed/$total${RESET}"
    if [ $failed -gt 0 ]; then
        echo "${RED}Failed: $failed/$total${RESET}"
    fi
    echo "${BOLD}${BLUE}════-------------------------------------════${RESET}"
}

# Quick stress testing function.
function cppstress() {
    _check_initialized || return 1
    local target_name=${1:-$(_get_default_target)}
    local iterations=${2:-100}
    local exec_path="./bin/$target_name"
    
    if ! cppbuild "$target_name"; then
        echo "${RED}Build failed!${RESET}" >&2
        return 1
    fi
    
    echo "${CYAN}Stress testing '$target_name' for $iterations iterations...${RESET}"
    
    local failed=0
    for i in $(seq 1 $iterations); do
        printf "\rIteration %d/%d... " $i $iterations
        
        # Run with empty input and check for crashes.
        if ! timeout 2 "$exec_path" < /dev/null > /dev/null 2>&1; then
            ((failed++))
            echo "${RED}Failed at iteration $i${RESET}"
        fi
    done
    
    echo ""
    if [ $failed -eq 0 ]; then
        echo "${GREEN}All $iterations iterations completed successfully!${RESET}"
    else
        echo "${RED}$failed iterations failed out of $iterations${RESET}"
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
        echo -e "${RED}Error: Not in a valid CP workspace directory${RESET}" >&2
        echo -e "${YELLOW}Current directory: $PWD${RESET}" >&2
        echo -e "${YELLOW}Expected workspace: $CP_WORKSPACE_ROOT${RESET}" >&2
        return 1
    fi
    
    # Check that the solution file exists.
    if [ ! -f "$solution_file" ]; then
        echo -e "${RED}Error: Solution file '$solution_file' not found${RESET}" >&2
        return 1
    fi
    
    # Check if the new flattener system is available.
    if [ ! -f "$flattener_script" ]; then
        echo -e "${YELLOW}Warning: New flattener not found at '$flattener_script'${RESET}"
        return $?
    fi
    
    # Create submissions directory if needed.
    mkdir -p "$submission_dir"
    
    echo -e "${CYAN}Generating submission for '${BOLD}$target_name${RESET}${CYAN}' using modular template system...${RESET}"
    
    # Generate submission header with metadata.
    local header_file="/tmp/${target_name}_header.txt"
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
    echo -e "${BLUE}Running template flattener...${RESET}"
    
    # Set PYTHONPATH to include the scripts directory for module imports.
    export PYTHONPATH="$SCRIPTS_DIR:$PYTHONPATH"
    
    if python3 "$flattener_script" "$solution_file" > "$submission_file.tmp" 2>/tmp/flattener_error.log; then
        # Combine header with flattened content.
        cat "$header_file" "$submission_file.tmp" > "$submission_file"
        rm -f "$submission_file.tmp" "$header_file"
        
        # Calculate and display statistics.
        local file_size=$(wc -c < "$submission_file")
        local line_count=$(wc -l < "$submission_file")
        local template_lines=$(grep -c "^//" "$submission_file" 2>/dev/null || echo 0)
        local code_lines=$((line_count - template_lines))
        
        echo -e "${GREEN}✓ Submission generated successfully${RESET}"
        printf "${YELLOW}  %-6s %s${RESET}\n" "File:" "${BOLD}$submission_file${RESET}"
        printf "${YELLOW}  %-6s %s${RESET}\n" "Size:" "$(numfmt --to=iec-i --suffix=B $file_size 2>/dev/null || echo "$file_size bytes")"
        printf "${YELLOW}  %-6s %s${RESET}\n" "Lines:" "$line_count total ($code_lines code, $template_lines comments)"
        
        # Verify compilation with the generated file.
        if _verify_submission_compilation "$submission_file"; then
            echo -e "${GREEN}✓ Compilation verification passed${RESET}"
        else
            echo -e "${RED}⚠ Warning: Compilation verification failed${RESET}"
            echo -e "${YELLOW}  Review the generated file for potential issues${RESET}"
        fi
        
        # Offer clipboard integration.
        _offer_clipboard_copy "$submission_file"
        
        return 0
    else
        echo -e "${RED}Error: Flattener failed to process the file${RESET}" >&2
        if [ -f /tmp/flattener_error.log ]; then
            echo -e "${RED}Error details:${RESET}"
            cat /tmp/flattener_error.log >&2
        fi
        rm -f "$header_file" "$submission_file.tmp" /tmp/flattener_error.log
        return 1
    fi
}


# Verify that the generated submission compiles correctly.
function _verify_submission_compilation() {
    local submission_file="$1"
    local test_binary="/tmp/test_submission_$(basename "$submission_file" .cpp)"
    
    # Attempt syntax-only compilation with competition flags.
    if g++-15 -std=c++23 -O2 -DNDEBUG -fsyntax-only "$submission_file" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Offer to copy submission to clipboard with multi-platform support.
function _offer_clipboard_copy() {
    local file="$1"
    
    # Detect available clipboard command.
    local clipboard_cmd=""
    local clipboard_name=""
    
    if command -v pbcopy &> /dev/null; then
        clipboard_cmd="pbcopy"
        clipboard_name="macOS clipboard"
    elif command -v xclip &> /dev/null; then
        clipboard_cmd="xclip -selection clipboard"
        clipboard_name="X11 clipboard"
    elif command -v wl-copy &> /dev/null; then
        clipboard_cmd="wl-copy"
        clipboard_name="Wayland clipboard"
    else
        return 0
    fi
    
    echo ""
    printf "Copy to $clipboard_name? [y/N]: "
    read -r REPLY < /dev/tty
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if cat "$file" | eval $clipboard_cmd; then
            echo -e "${GREEN}✓ Copied to $clipboard_name${RESET}"
        else
            echo -e "${RED}Failed to copy to clipboard${RESET}"
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
    echo -e "${CYAN}Testing submission file...${RESET}"
    
    # Ensure bin directory exists.
    mkdir -p "$(dirname "$test_binary")"
    
    # Compile with timing information.
    echo -e "${BLUE}Compiling submission...${RESET}"
    local start_time=$(date +%s%N 2>/dev/null || date +%s)
    
    if g++-15 -std=c++23 -O2 -DNDEBUG -march=native \
           -I"$CP_ALGORITHMS_DIR" \
           "$submission_file" -o "$test_binary" 2>/tmp/compile_error.log; then
        
        local end_time=$(date +%s%N 2>/dev/null || date +%s)
        if [[ "$start_time" == *"N" ]]; then
            local compile_time=$(( (end_time - start_time) / 1000000 ))
            echo -e "${GREEN}✓ Submission compiled successfully in ${compile_time}ms${RESET}"
        else
            echo -e "${GREEN}✓ Submission compiled successfully${RESET}"
        fi
        
        # Test execution with input.
        if [ -f "$input_path" ]; then
            echo -e "${BLUE}Testing with input from $input_path:${RESET}"
            echo -e "${CYAN}╔═══------------------------------------------═══╗${RESET}"
            
            # Run with timeout and capture output.
            timeout 2s "$test_binary" < "$input_path" 2>&1 | head -n 50
            local exit_code=${PIPESTATUS[0]}
            
            echo -e "${CYAN}╚═══------------------------------------------═══╝${RESET}"
            
            if [ $exit_code -eq 124 ]; then
                echo -e "${YELLOW}⚠ Execution timeout (2s limit exceeded)${RESET}"
            elif [ $exit_code -ne 0 ]; then
                echo -e "${RED}⚠ Program exited with code $exit_code${RESET}"
            else
                echo -e "${GREEN}✓ Execution completed successfully${RESET}"
            fi
        else
            echo -e "${YELLOW}No input file found at '$input_path'${RESET}"
            echo -e "${YELLOW}Running without input (5s timeout)...${RESET}"
            timeout 5s "$test_binary"
        fi
        
        # Cleanup binary.
        rm -f "$test_binary"
    else
        echo -e "${RED}✗ Submission compilation failed${RESET}" >&2
        echo -e "${RED}Compilation errors:${RESET}"
        cat /tmp/compile_error.log >&2
        rm -f /tmp/compile_error.log
        return 1
    fi
}

# Complete workflow with enhanced progress tracking.
function cppfull() {
    _check_initialized || return 1
    local target_name=${1:-$(_get_default_target)}
    local input_name=${2:-"${target_name}.in"}
    
    echo -e "${BLUE}╔═══------------------------------------------═══╗${RESET}"
    echo -e "${BLUE}${BOLD} FULL WORKFLOW: $(printf "%-20s" "$target_name")${RESET}"
    echo -e "${BLUE}╚═══------------------------------------------═══╝${RESET}"
    
    # Step 1: Development version test.
    echo ""
    echo -e "${CYAN}[1/3] Testing development version...${RESET}"
    if ! cppgo "$target_name" "$input_name"; then
        echo -e "${RED}✗ Development version failed${RESET}" >&2
        return 1
    fi
    echo -e "${GREEN}✓ Development test passed${RESET}"
    
    # Step 2: Generate submission.
    echo ""
    echo -e "${CYAN}[2/3] Generating submission...${RESET}"
    if ! cppsubmit "$target_name"; then
        echo -e "${RED}✗ Submission generation failed${RESET}" >&2
        return 1
    fi
    
    # Step 3: Test submission.
    echo ""
    echo -e "${CYAN}[3/3] Testing submission...${RESET}"
    if ! cpptestsubmit "$target_name" "$input_name"; then
        echo -e "${RED}✗ Submission test failed${RESET}" >&2
        return 1
    fi
    
    # Summary with file information.
    local submission_file="$SUBMISSIONS_DIR/${target_name}_sub.cpp"
    local file_size=$(wc -c < "$submission_file" 2>/dev/null || echo "0")
    
    echo ""
    echo -e "${GREEN}${BOLD}╔═══------------------------------------------═══╗${RESET}"
    echo -e "${GREEN}${BOLD}  ✓ Full workflow completed successfully${RESET}"
    echo -e "${GREEN}${BOLD}╚═══------------------------------------------═══╝${RESET}"
    echo -e "${YELLOW}📁 Submission: $submission_file${RESET}"
    echo -e "${YELLOW}📊 Size: $(numfmt --to=iec-i --suffix=B $file_size 2>/dev/null || echo "$file_size bytes")${RESET}"
    echo -e "${YELLOW}📋 Ready for contest submission${RESET}"
    
    # Final clipboard offer.
    _offer_clipboard_copy "$submission_file"
}

# Comprehensive system health check.
function cppcheck() {
    echo -e "${CYAN}${BOLD}Checking template system health...${RESET}"
    echo -e "${CYAN}╔═══------------------------------------------═══╗${RESET}"
    
    local all_good=true
    local warnings=0
    
    # Check workspace configuration
    echo -e "${BLUE}Workspace Configuration:${RESET}"
    if [ -n "$CP_WORKSPACE_ROOT" ] && [ -d "$CP_WORKSPACE_ROOT" ]; then
        echo -e "${GREEN}  ✓ Workspace root: $CP_WORKSPACE_ROOT${RESET}"
    else
        echo -e "${RED}  ✗ Workspace root not configured or missing${RESET}"
        all_good=false
    fi
    
    if [ -n "$CP_ALGORITHMS_DIR" ] && [ -d "$CP_ALGORITHMS_DIR" ]; then
        echo -e "${GREEN}  ✓ Algorithms directory: $CP_ALGORITHMS_DIR${RESET}"
    else
        echo -e "${RED}  ✗ Algorithms directory not configured or missing${RESET}"
        all_good=false
    fi
    
    # Check template system components.
    echo -e "\n${BLUE}Template System Components:${RESET}"
    
    # Check for new modular system.
    if [ -f "$SCRIPTS_DIR/flattener.py" ]; then
        echo -e "${GREEN}  ✓ Flattener script found${RESET}"
        if python3 -c "import sys; sys.exit(0)" 2>/dev/null; then
            echo -e "${GREEN}  ✓ Python 3 available${RESET}"
        else
            echo -e "${RED}  ✗ Python 3 not available${RESET}"
            all_good=false
        fi
    else
        echo -e "${YELLOW}  ⚠ Flattener script not found (using legacy system)${RESET}"
        warnings=$((warnings + 1))
    fi
    
    # Check templates directory.
    if [ -d "$TEMPLATES_DIR" ]; then
        local template_count=$(ls -1 "$TEMPLATES_DIR"/*.hpp 2>/dev/null | wc -l)
        echo -e "${GREEN}  ✓ Templates directory: $template_count files${RESET}"
    else
        echo -e "${YELLOW}  ⚠ Templates directory not found (optional)${RESET}"
        warnings=$((warnings + 1))
    fi
    
    # Check modules directory.
    if [ -d "$MODULES_DIR" ]; then
        local module_count=$(ls -1 "$MODULES_DIR"/*.hpp 2>/dev/null | wc -l)
        echo -e "${GREEN}  ✓ Modules directory: $module_count files${RESET}"
    else
        echo -e "${YELLOW}  ⚠ Modules directory not found (optional)${RESET}"
        warnings=$((warnings + 1))
    fi
    
    # Check legacy system fallback.
    local legacy_build="$CP_ALGORITHMS_DIR/build_template.sh"
    if [ -f "$legacy_build" ]; then
        echo -e "${GREEN}  ✓ Legacy build script available (fallback)${RESET}"
    else
        echo -e "${YELLOW}  ⚠ Legacy build script not found${RESET}"
        warnings=$((warnings + 1))
    fi
    
    # Check compiler and tools.
    echo -e "\n${BLUE}Development Tools:${RESET}"
    
    if command -v g++ &> /dev/null; then
        local gcc_version=$(g++ --version | head -n1)
        echo -e "${GREEN}  ✓ Compiler: $gcc_version${RESET}"
        
        # Check C++ standard support.
        if echo | g++ -std=c++23 -x c++ - -fsyntax-only &>/dev/null; then
            echo -e "${GREEN}  ✓ C++23 support available${RESET}"
        elif echo | g++ -std=c++20 -x c++ - -fsyntax-only &>/dev/null; then
            echo -e "${YELLOW}  ⚠ C++20 available (C++23 not supported)${RESET}"
            warnings=$((warnings + 1))
        else
            echo -e "${RED}  ✗ Modern C++ standards not supported${RESET}"
            all_good=false
        fi
    else
        echo -e "${RED}  ✗ g++ compiler not found${RESET}"
        all_good=false
    fi
    
    if command -v python3 &> /dev/null; then
        local python_version=$(python3 --version 2>&1)
        echo -e "${GREEN}  ✓ Python: $python_version${RESET}"
    else
        echo -e "${YELLOW}  ⚠ Python 3 not found (required for new features)${RESET}"
        warnings=$((warnings + 1))
    fi
    
    # Summary.
    echo -e "\n${CYAN}╚═══------------------------------------------═══╝${RESET}"
    if $all_good; then
        if [ $warnings -eq 0 ]; then
            echo -e "${GREEN}${BOLD}✓ All systems fully operational${RESET}"
        else
            echo -e "${GREEN}${BOLD}✓ Core systems operational${RESET}"
            echo -e "${YELLOW}  $warnings warning(s) for optional features${RESET}"
        fi
        return 0
    else
        echo -e "${RED}${BOLD}✗ Critical issues detected${RESET}"
        echo -e "${YELLOW}  Please resolve the issues marked with ✗${RESET}"
        return 1
    fi
}

# ---------------------------- COMPILER UTILITIES ---------------------------- #

# Quick compiler switch function for GCC.
function cppgcc() {
    local build_type=${1:-Debug}
    echo "${CYAN}Switching to GCC toolchain (${build_type})...${RESET}"
    echo "${YELLOW}Cleaning build environment first...${RESET}"
    cppclean
    cppconf "$build_type" gcc
}

# Quick compiler switch function for Clang.
function cppclang() {
    local build_type=${1:-Debug}
    echo "${CYAN}Switching to Clang toolchain (${build_type})...${RESET}"
    echo "${YELLOW}Cleaning build environment first...${RESET}"
    cppclean
    cppconf "$build_type" clang
}

# Quick profiling build.
function cppprof() {
    echo "${CYAN}Configuring profiling build with Clang...${RESET}"
    echo "${YELLOW}Cleaning build environment first...${RESET}"
    cppclean
    CP_TIMING=1 cppconf Release clang
}

# Show current configuration.
function cppinfo() {
    if [ -f ".statistics/last_config" ]; then
        local config=$(cat .statistics/last_config)
        local build_type=${config%:*}
        local compiler=${config#*:}
        echo "${CYAN}Current configuration:${RESET}"
        echo "  Build Type: ${YELLOW}$build_type${RESET}"
        echo "  Compiler: ${YELLOW}$compiler${RESET}"
    else
        echo "${YELLOW}No configuration found. Run 'cppconf' first.${RESET}"
    fi
    
    if [ -f "build/CMakeCache.txt" ]; then
        local actual_compiler=$(grep "CMAKE_CXX_COMPILER:FILEPATH=" build/CMakeCache.txt | cut -d'=' -f2)
        echo "  Actual Path: ${GREEN}$actual_compiler${RESET}"
        
        # Check for LTO support.
        if grep -q "INTERPROCEDURAL_OPTIMIZATION.*TRUE" build/CMakeCache.txt 2>/dev/null; then
            echo "  ${GREEN}LTO: Enabled${RESET}"
        fi
    fi
}

# -------------------------------- UTILITIES --------------------------------- #

# Cleans the project by removing the build directory.
function cppclean() {
    echo "${CYAN}Cleaning project...${RESET}"
    rm -rf build bin lib
    # Also remove the symlink if it exists in the root.
    if [ -L "compile_commands.json" ]; then
        rm "compile_commands.json"
    fi
    echo "Project cleaned."
}

# Deep clean - removes everything except source files and input cases.
function cppdeepclean() {
    echo "${YELLOW}This will remove all generated files except source code and test cases.${RESET}"
    echo -n "Are you sure? (y/N): "
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        cppclean
        rm -f CMakeLists.txt gcc-toolchain.cmake clang-toolchain.cmake .clangd
        rm -f .contest_metadata .problem_times
        rm -rf .cache
        echo "${GREEN}Deep clean complete.${RESET}"
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
        echo "${RED}Error: Source file for target '$target_name' not found.${RESET}" >&2
        return 1
    fi

    if ! command -v fswatch &> /dev/null; then
        echo "${RED}Error: 'fswatch' is not installed. Please run 'brew install fswatch'.${RESET}" >&2
        return 1
    fi

    echo "${CYAN}Watching '$source_file' to rebuild target '$target_name'. Press Ctrl+C to stop.${RESET}"
    # Initial build.
    cppbuild "$target_name"

    fswatch -o "$source_file" | while read -r; do cppbuild "$target_name"; done
}

# Show time statistics for problems in the current contest.
function cppstats() {
    if [ ! -f ".statistics/problem_times" ]; then
        echo "${YELLOW}No timing data available for this contest.${RESET}"
        return 0
    fi
    
    echo "${BOLD}${BLUE}╔═══----------- PROBLEM STATISTICS -----------═══╗${RESET}"
    echo ""

    local current_time=$(date +%s)
    while IFS=: read -r problem action timestamp; do
        if [ "$action" = "START" ]; then
            local elapsed=$((current_time - timestamp))
            echo "${CYAN}$problem${RESET}: Started $(_format_duration $elapsed) ago"
        fi
    done < .statistics/problem_times
    
    echo ""
    echo "${BOLD}${BLUE}╚═══------------------------------------------═══╝${RESET}"
}

# Archive the current contest with all solutions.
function cpparchive() {
    local contest_name=$(basename "$(pwd)")
    local archive_name="${contest_name}_$(date +%Y%m%d_%H%M%S).tar.gz"
    
    echo "${CYAN}Archiving contest to '$archive_name'...${RESET}"
    
    # Create archive excluding build artifacts.
    tar -czf "../$archive_name" \
        --exclude="build" \
        --exclude="bin" \
        --exclude="lib" \
        --exclude="*.dSYM" \
        --exclude=".git" \
        .
    
    echo "${GREEN}Contest archived to '../$archive_name'${RESET}"
}

# Displays detailed diagnostic information about the toolchain and environment.
function cppdiag() {
    # Helper function to print formatted headers.
    _print_header() {
        echo ""
        echo "${BOLD}${BLUE}╔═══---------------- $1 ----------------═══╗${RESET}"
    }

    echo "${BOLD}Running Competitive Programming Environment Diagnostics...${RESET}"

    _print_header "SYSTEM & SHELL"
    # Display OS and shell information.
    uname -a
    echo "Shell: $SHELL"
    [ -n "$BASH_VERSION" ] && echo "Bash Version: $BASH_VERSION"
    [ -n "$ZSH_VERSION" ] && echo "Zsh Version: $ZSH_VERSION"
    echo "Script Directory: $SCRIPT_DIR"

    _print_header "WORKSPACE CONFIGURATION"
    echo "CP Workspace Root: ${CYAN}$CP_WORKSPACE_ROOT${RESET}"
    echo "Algorithms Directory: ${CYAN}$CP_ALGORITHMS_DIR${RESET}"
    
    # Check if we're in the workspace.
    local current_dir="$(pwd)"
    if [[ "$current_dir" == "$CP_WORKSPACE_ROOT"* ]]; then
        echo "Current Location: ${GREEN}Inside workspace${RESET}"
    else
        echo "Current Location: ${YELLOW}Outside workspace${RESET}"
    fi

    _print_header "CORE TOOLS"
    
    # Check for g++
    local GXX_PATH
    GXX_PATH=$(command -v g++-15 || command -v g++-14 || command -v g++-13 || command -v g++)
    if [ -n "$GXX_PATH" ]; then
        echo "${GREEN}g++:${RESET}"
        echo "   ${CYAN}Path:${RESET} $GXX_PATH"
        echo "   ${CYAN}Version:${RESET} $($GXX_PATH --version | head -n 1)"
    else
        echo "${RED}g++: Not found!${RESET}"
    fi

    # Check for clang++
    local CLANGXX_PATH
    CLANGXX_PATH=$(command -v clang++)
    if [ -n "$CLANGXX_PATH" ]; then
        echo "${GREEN}clang++:${RESET}"
        echo "   ${CYAN}Path:${RESET} $CLANGXX_PATH"
        echo "   ${CYAN}Version:${RESET} $($CLANGXX_PATH --version | head -n 1)"
        
        # Check if it's Apple Clang or LLVM Clang.
        if $CLANGXX_PATH --version | grep -q "Apple"; then
            echo "   ${CYAN}Type:${RESET} Apple Clang (Xcode)"
        else
            echo "   ${CYAN}Type:${RESET} LLVM Clang"
        fi
    else
        echo "${YELLOW}clang++: Not found (optional, needed for sanitizers on macOS)${RESET}"
    fi

    # Check for cmake.
    local CMAKE_PATH
    CMAKE_PATH=$(command -v cmake)
    if [ -n "$CMAKE_PATH" ]; then
        echo "${GREEN}cmake:${RESET}"
        echo "   ${CYAN}Path:${RESET} $CMAKE_PATH"
        echo "   ${CYAN}Version:${RESET} $($CMAKE_PATH --version | head -n 1)"
    else
        echo "${RED}cmake: Not found!${RESET}"
    fi

    # Check for clangd.
    local CLANGD_PATH
    CLANGD_PATH=$(command -v clangd)
    if [ -n "$CLANGD_PATH" ]; then
        echo "${GREEN}clangd:${RESET}"
        echo "   ${CYAN}Path:${RESET} $CLANGD_PATH"
        echo "   ${CYAN}Version:${RESET} $($CLANGD_PATH --version | head -n 1)"
    else
        echo "${RED}clangd: Not found!${RESET}"
    fi

    # Check for fswatch (optional).
    local FSWATCH_PATH
    FSWATCH_PATH=$(command -v fswatch)
    if [ -n "$FSWATCH_PATH" ]; then
        echo "${GREEN}fswatch:${RESET}"
        echo "   ${CYAN}Path:${RESET} $FSWATCH_PATH"
    else
        echo "${YELLOW}fswatch: Not found (optional, needed for cppwatch)${RESET}"
    fi

    _print_header "PROJECT CONFIGURATION (in $(pwd))"
    if [ -f "CMakeLists.txt" ]; then
        echo "${GREEN}Found CMakeLists.txt${RESET}"
        
        # Check CMake Cache for the configured compiler.
        if [ -f "build/CMakeCache.txt" ]; then
            local cached_compiler
            cached_compiler=$(grep "CMAKE_CXX_COMPILER:FILEPATH=" build/CMakeCache.txt | cut -d'=' -f2)
            echo "   ${CYAN}CMake Cached CXX Compiler:${RESET} $cached_compiler"
        else
            echo "   ${YELLOW}Info: No CMake cache found. Run 'cppconf' to generate it.${RESET}"
        fi

        # Display .clangd configuration if it exists.
        if [ -f ".clangd" ]; then
            echo "${GREEN}Found .clangd config${RESET}"
        else
            echo "   ${YELLOW}Info: No .clangd config file found in this project.${RESET}"
        fi

        # Check for metadata files.
        if [ -f ".contest_metadata" ]; then
            echo "${GREEN}Found contest metadata${RESET}"
            grep "CONTEST_NAME" .contest_metadata | sed 's/^/   /'
            grep "CREATED" .contest_metadata | sed 's/^/   /'
        fi

        # Count problems.
        local cpp_count=$(ls -1 *.cpp 2>/dev/null | wc -l)
        echo "   ${CYAN}C++ files:${RESET} $cpp_count"

    else
        echo "${RED}Not inside a project directory (CMakeLists.txt not found).${RESET}"
    fi

    _print_header "COMPILER FEATURES CHECK"
    
    # Test with GCC if available.
    if [ -n "$GXX_PATH" ]; then
        echo "${CYAN}Testing GCC features:${RESET}"
        local test_file="/tmp/cp_gcc_test_$.cpp"
        cat > "$test_file" << 'EOF'
#include <bits/stdc++.h>
#include <ext/pb_ds/assoc_container.hpp>
using namespace std;
using namespace __gnu_pbds;
int main() { cout << "OK" << endl; return 0; }
EOF
        
        if $GXX_PATH -std=c++23 "$test_file" -o /tmp/cp_gcc_test_$ 2>/dev/null; then
            echo "  ${GREEN}bits/stdc++.h: Available${RESET}"
            echo "  ${GREEN}PBDS: Available${RESET}"
            echo "  ${GREEN}C++23: Supported${RESET}"
            rm -f /tmp/cp_gcc_test_$
        else
            echo "  ${RED}Some GCC features may not be available. Check your installation.${RESET}"
        fi
        rm -f "$test_file"
    fi
    
    # Test with Clang if available.
    if [ -n "$CLANGXX_PATH" ]; then
        echo ""
        echo "${CYAN}Testing Clang features:${RESET}"
        
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
                echo "  ${GREEN}PCH.h: Compatible${RESET}"
                echo "  ${GREEN}C++23: Supported${RESET}"
                rm -f /tmp/cp_clang_test_$
            else
                echo "  ${YELLOW}PCH.h compilation failed (check algorithms/PCH.h)${RESET}"
            fi
        else
            echo "  ${YELLOW}PCH.h: Not found in algorithms/ directory${RESET}"
        fi
        
        # Test sanitizer support.
        echo "#include <iostream>\nint main(){return 0;}" > "$test_pch"
        if $CLANGXX_PATH -fsanitize=address "$test_pch" -o /tmp/cp_clang_san_$ 2>/dev/null; then
            echo "  ${GREEN}AddressSanitizer: Available${RESET}"
            rm -f /tmp/cp_clang_san_$
        else
            echo "  ${RED}AddressSanitizer: Not available${RESET}"
        fi
        
        if $CLANGXX_PATH -fsanitize=undefined "$test_pch" -o /tmp/cp_clang_san_$ 2>/dev/null; then
            echo "  ${GREEN}UBSanitizer: Available${RESET}"
            rm -f /tmp/cp_clang_san_$
        else
            echo "  ${RED}UBSanitizer: Not available${RESET}"
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
function cppgo_() {
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
            echo "${RED}Error: No file found for problem '${problem_id}' (tried ${target_name}.* and ${target_name}[1-9].*).${RESET}" >&2
            return 1
        fi
    fi
    
    cppgo "$target_name" "$input_file"
}

# Create aliases for common problem letters and numbered variants
for letter in {A..H}; do
    alias "cppgo_${letter}"="cppgo_ ${letter}"
    # Create numbered variants (e.g., cppgo_A1, cppgo_A2, etc.)
    for num in {1..9}; do
        alias "cppgo_${letter}${num}"="cppgo_ ${letter}${num}"
    done
done

# ------------------------------- HELP & USAGE ------------------------------- #

# Displays the help message.
function cpphelp() {
    cat << EOF
${BOLD}Enhanced CMake Utilities for Competitive Programming:${RESET}

${BOLD}${CYAN}[ SETUP & CONFIGURATION ]${RESET}
  ${GREEN}cppinit${RESET}                       - Initializes or verifies a project directory (workspace-protected).
  ${GREEN}cppnew${RESET} ${YELLOW}[name] [template]${RESET}      - Creates a new .cpp file from a template ('default', 'pbds', 'advanced', 'base').
  ${GREEN}cppdelete${RESET} ${YELLOW}[name]${RESET}              - Deletes a problem file and associated data (interactive).
  ${GREEN}cppbatch${RESET} ${YELLOW}[count] [tpl]${RESET}        - Creates multiple problems at once (A, B, C, ...).
  ${GREEN}cppconf${RESET} ${YELLOW}[type] [compiler] ${RESET}    - (Re)configures the project (Debug/Release/Sanitize, gcc/clang/auto, timing reports).
          ${YELLOW}[timing=on/off]${RESET}
  ${GREEN}cppcontest${RESET} ${YELLOW}[dir_name]${RESET}         - Creates a new contest directory and initializes it.

${BOLD}${CYAN}[ BUILD, RUN, TEST ]${RESET}
  ${GREEN}cppbuild${RESET} ${YELLOW}[name]${RESET}          - Builds a target (defaults to most recent).
  ${GREEN}cpprun${RESET} ${YELLOW}[name]${RESET}            - Runs a target's executable.
  ${GREEN}cppgo${RESET} ${YELLOW}[name] [input]${RESET}     - Builds and runs. Uses '<name>.in' by default.
  ${GREEN}cppforcego${RESET} ${YELLOW}[name]${RESET}        - Force rebuild and run (updates timestamp).
  ${GREEN}cppi${RESET} ${YELLOW}[name]${RESET}              - Interactive mode: builds and runs with manual input.
  ${GREEN}cppjudge${RESET} ${YELLOW}[name]${RESET}          - Tests against all sample cases with timing info.
  ${GREEN}cppstress${RESET} ${YELLOW}[name] [n]${RESET}     - Stress tests a solution for n iterations (default: 100).

${BOLD}${CYAN}[ COMPILER SELECTION ]${RESET}
  ${GREEN}cppgcc${RESET} ${YELLOW}[type]${RESET}            - Configure with GCC compiler (defaults to Debug).
  ${GREEN}cppclang${RESET} ${YELLOW}[type]${RESET}          - Configure with Clang compiler (defaults to Debug).
  ${GREEN}cppprof${RESET}                  - Configure profiling build with Clang and timing enabled.
  ${GREEN}cppinfo${RESET}                  - Shows current compiler and build configuration.

${BOLD}${CYAN}[ UTILITIES ]${RESET}
  ${GREEN}cppwatch${RESET} ${YELLOW}[name]${RESET}          - Auto-rebuilds a target on file change (requires fswatch).
  ${GREEN}cppclean${RESET}                 - Removes build artifacts.
  ${GREEN}cppdeepclean${RESET}             - Removes all generated files (interactive).
  ${GREEN}cppstats${RESET}                 - Shows timing statistics for problems.
  ${GREEN}cpparchive${RESET}               - Creates a compressed archive of the contest.
  ${GREEN}cppdiag${RESET}                  - Displays detailed diagnostic info about the toolchain.
  ${GREEN}cpphelp${RESET}                  - Shows this help message.

${BOLD}${CYAN}[ SUBMISSION PREPARATION ]${RESET}
  ${GREEN}cppsubmit${RESET} ${YELLOW}[name]${RESET}             - Generates a single-file submission (flattener-based).
  ${GREEN}cpptestsubmit${RESET} ${YELLOW}[name] [input]${RESET} - Tests the generated submission file.
  ${GREEN}cppfull${RESET} ${YELLOW}[name] [input]${RESET}       - Full workflow: test dev version, generate submission, test submission.
  ${GREEN}cppcheck${RESET}                     - Checks the health of the template system and environment.

${BOLD}${CYAN}[ QUICK ACCESS ALIASES ]${RESET}
  ${GREEN}cppgo_A${RESET}, ${GREEN}cppgo_B${RESET}, etc.       - Quick run for problem_A, problem_B, etc.
  ${GREEN}cppgo_A1${RESET}, ${GREEN}cppgo_A2${RESET}, etc.     - Quick run for numbered variants (problem_A1, problem_A2, etc.).
  
  Short aliases: 
    ${GREEN}cppc${RESET}=cppconf, ${GREEN}cppb${RESET}=cppbuild, ${GREEN}cppr${RESET}=cpprun, ${GREEN}cppg${RESET}=cppgo, and more.

${BOLD}${MAGENTA}[ WORKSPACE INFO ]${RESET}
  Workspace Root: ${CYAN}${CP_WORKSPACE_ROOT}${RESET}
  Algorithms Dir: ${CYAN}${CP_ALGORITHMS_DIR}${RESET}

* Most commands default to the most recently modified C++ source file.
* Workspace protection prevents accidental initialization outside CP directory.
EOF
}

# Display load message only if not in quiet mode.
export CP_QUIET_LOAD=${1:-0}
if [ -z "$CP_QUIET_LOAD" ]; then
    echo "${GREEN}Competitive Programming utilities loaded. Type 'cpphelp' for commands.${RESET}"
fi

# ============================================================================ #
# End of script