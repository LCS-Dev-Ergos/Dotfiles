#!/bin/bash
# =========================================================================== #
# ------ Enhanced CMake & Shell Utilities for Competitive Programming ------- #
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
# =========================================================================== #

# ------------------------------ CONFIGURATION ------------------------------ #

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

# Path to your global directory containing reusable headers like debug.h.
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

# ------------------------- PROJECT SETUP & CONFIG -------------------------- #

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

    # Create .contest_metadata if it doesn't exist (for tracking).
    if [ ! -f ".contest_metadata" ]; then
        echo "# Contest Metadata" > .contest_metadata
        echo "CREATED=$(date +"%Y-%m-%d %H:%M:%S")" >> .contest_metadata
        echo "CONTEST_NAME=$(basename "$(pwd)")" >> .contest_metadata
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

    # Create .clangd configuration if it doesn't exist.
    if [ ! -f ".clangd" ]; then
        echo "Creating .clangd configuration from template..."
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS template.
            cp "$SCRIPT_DIR/templates/.clangd.tpl" ./.clangd
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            # Linux template.
            cp "$SCRIPT_DIR/templates/.clangd-linux.tpl" ./.clangd
        else
            # Fallback to macOS template for other platforms.
            cp "$SCRIPT_DIR/templates/.clangd.tpl" ./.clangd
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
.vscode/
.idea/
.cache/
CMakeLists.txt
gcc-toolchain.cmake
clang-toolchain.cmake
compile_commands.json
.clangd
.contest_metadata
.problem_times
*.out
*.exe
*.dSYM/
*.DS_Store
EOF
    fi
    
    # Create directories if they don't exist.
    mkdir -p algorithms
    mkdir -p input_cases
    mkdir -p output_cases
    mkdir -p expected_output

    # Link to the global debug.h if configured and not already linked.
    local master_debug_header="$CP_ALGORITHMS_DIR/debug.h"
    if [ ! -e "algorithms/debug.h" ]; then
        if [ -n "$CP_ALGORITHMS_DIR" ] && [ -f "$master_debug_header" ]; then
            ln -s "$master_debug_header" "algorithms/debug.h"
            echo "Created symlink to global debug.h."
        else
            touch "algorithms/debug.h"
            echo "${YELLOW}Warning: Global debug.h not found. Created a local placeholder.${RESET}"
        fi
    fi
    
    # Copy or link PCH.h for Clang sanitizer builds.
    local master_pch_header="$CP_ALGORITHMS_DIR/PCH.h"
    if [ ! -e "algorithms/PCH.h" ]; then
        if [ -n "$CP_ALGORITHMS_DIR" ] && [ -f "$master_pch_header" ]; then
            ln -s "$master_pch_header" "algorithms/PCH.h"
            echo "Created symlink to global PCH.h (for Clang sanitizer builds)."
        elif [ -f "$SCRIPT_DIR/templates/cpp/PCH.h" ]; then
            cp "$SCRIPT_DIR/templates/cpp/PCH.h" "algorithms/PCH.h"
            echo "Copied PCH.h template for Clang sanitizer builds."
        else
            echo "${YELLOW}Warning: PCH.h not found. Clang sanitizer builds may not work properly.${RESET}"
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
    local template_type=${2:-"default"}
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
        *) # Default template
            template_file="$SCRIPT_DIR/templates/cpp/default.cpp"
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
    touch "output_cases/${problem_name}.out"
    echo "Created empty input file: input_cases/${problem_name}.in"
    echo "Created empty output file: output_cases/${problem_name}.out"

    # Track problem creation time with human-readable format
    echo "${problem_name}:START:$(date +%s):$(date '+%Y-%m-%d %H:%M:%S')" >> .problem_times

    echo "New problem '$problem_name' created. Re-running CMake configuration..."
    cppconf # Re-run configuration to add the new file to the build system.
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

# Configures the CMake project.
# Enhanced to support Clang for Sanitize builds on macOS.
function cppconf() {
    local build_type=${1:-Debug}
    local compiler_override=${2:-""}
    
    # Determine which toolchain to use.
    local toolchain_file="gcc-toolchain.cmake"
    local toolchain_name="GCC"
    
    # Special handling for Sanitize builds.
    if [ "$build_type" = "Sanitize" ]; then
        if [[ "$OSTYPE" == "darwin"* ]] || [ "$compiler_override" = "clang" ]; then
            # On macOS or when explicitly requested, use Clang for sanitizers.
            toolchain_file="clang-toolchain.cmake"
            toolchain_name="Clang (for sanitizers)"
            
            # Create clang-toolchain.cmake if it doesn't exist.
            if [ ! -f "$toolchain_file" ]; then
                echo "Creating clang-toolchain.cmake for sanitizer build..."
                if [ -f "$SCRIPT_DIR/templates/clang-toolchain.cmake.tpl" ]; then
                    cp "$SCRIPT_DIR/templates/clang-toolchain.cmake.tpl" ./"$toolchain_file"
                else
                    echo "${RED}Error: clang-toolchain.cmake template not found!${RESET}" >&2
                    echo "${YELLOW}Falling back to GCC toolchain...${RESET}"
                    toolchain_file="gcc-toolchain.cmake"
                    toolchain_name="GCC"
                fi
            fi
        elif [ "$compiler_override" = "gcc" ]; then
            # Explicitly use GCC even for sanitizers.
            echo "${YELLOW}Warning: GCC sanitizers may not work properly on macOS${RESET}"
        fi
    fi

    # Check if the toolchain file exists, if not, create it.
    if [ ! -f "$toolchain_file" ]; then
        if [ "$toolchain_file" = "gcc-toolchain.cmake" ]; then
            echo "${YELLOW}GCC toolchain file not found. Running cppinit to fix...${RESET}"
            cppinit
        else
            echo "${RED}Toolchain file $toolchain_file not found!${RESET}" >&2
            return 1
        fi
    fi

    # Log the configuration step.
    echo "${BLUE}/===---------------------------------------------------------------------------===/${RESET}"
    echo "${BLUE}Configuring project with build type: ${YELLOW}${build_type}${BLUE} (using ${toolchain_name} toolchain)${RESET}"
    
    # Run CMake with the appropriate toolchain file.
    if cmake -S . -B build -DCMAKE_BUILD_TYPE=${build_type} -DCMAKE_TOOLCHAIN_FILE=${toolchain_file}; then
        echo "${GREEN}CMake configuration successful.${RESET}"
        # Create the symlink for clangd.
        cmake --build build --target symlink_clangd 2>/dev/null || true
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

# ------------------------------- BUILD & RUN ------------------------------- #

# Builds a specific target.
function cppbuild() {
    _check_initialized || return 1
    local target_name=${1:-$(_get_default_target)}
    echo "${CYAN}Building target: ${BOLD}$target_name${RESET}..."
    # Use -j to build in parallel.
    cmake --build build --target "$target_name" -j
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
        echo "${BLUE}${BOLD}/===------ RUNNING: $target_name ------===/${RESET}"
        
        # Track execution time in nanoseconds for better precision.
        local start_time=$(date +%s%N)
        
        if [ -f "$input_path" ]; then
            echo "(input from ${YELLOW}$input_path${RESET})"
            "$exec_path" < "$input_path"
        else
            if [ -n "$2" ]; then # Warn if a specific file was requested but not found.
                 echo "${YELLOW}Warning: Input file '$input_path' not found.${RESET}" >&2
            fi
            "$exec_path"
        fi
        
        local end_time=$(date +%s%N)
        local elapsed_ms=$(( (end_time - start_time) / 1000000 ))
        
        echo "${BLUE}${BOLD}/===----------- FINISHED -----------===/${RESET}"
        echo "${MAGENTA}Execution time: ${elapsed_ms}ms${RESET}"
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
        echo "${BLUE}${BOLD}/===------ INTERACTIVE MODE: $target_name ------===/${RESET}"
        echo "${YELLOW}Enter input (Ctrl+D when done):${RESET}"
        "$exec_path"
        echo "${BLUE}${BOLD}/===----------- FINISHED -----------===/${RESET}"
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

    if ! cppbuild "$target_name"; then
        echo "${RED}Build failed!${RESET}" >&2
        return 1
    fi
    
    # Check for test cases.
    if ! ls "$input_dir/${target_name}".*.in &>/dev/null; then
        echo "${YELLOW}No test cases found in '$input_dir/' for pattern '${target_name}.*.in'${RESET}"
        return 0
    fi

    local passed=0
    local failed=0
    local total=0

    for test_in in "$input_dir/${target_name}".*.in; do
        local test_case_base
        test_case_base=$(basename "$test_in" .in)
        local test_out="$input_dir/${test_case_base}.out"
        local temp_out
        temp_out=$(mktemp)

        ((total++))
        echo -n "Testing $(basename "$test_in")... "
        
        # Measure execution time.
        local start_time=$(date +%s%N)
        "$exec_path" < "$test_in" > "$temp_out"
        local end_time=$(date +%s%N)
        local elapsed_ms=$(( (end_time - start_time) / 1000000 ))

        if [ ! -f "$test_out" ]; then
            echo "${BOLD}${YELLOW}WARNING: Output file '$(basename "$test_out")' not found.${RESET}"
            rm "$temp_out"
            continue
        fi

        # Use diff with -w (ignore all whitespace) and -B (ignore blank lines).
        if diff -wB "$temp_out" "$test_out" >/dev/null; then
            echo "${BOLD}${GREEN}PASSED${RESET} (${elapsed_ms}ms)"
            ((passed++))
        else
            echo "${BOLD}${RED}FAILED${RESET} (${elapsed_ms}ms)"
            ((failed++))
            echo "${BOLD}${YELLOW}/===---------- YOUR OUTPUT ---------===/${RESET}"
            cat "$temp_out"
            echo "${BOLD}${YELLOW}/===----------- EXPECTED -----------===/${RESET}"
            cat "$test_out"
            echo "${BOLD}${YELLOW}/===--------------------------------===/${RESET}"
        fi
        rm "$temp_out"
    done

    # Summary.
    echo ""
    echo "${BOLD}${BLUE}/===---------- TEST SUMMARY ----------===/${RESET}"
    echo "${GREEN}Passed: $passed/$total${RESET}"
    if [ $failed -gt 0 ]; then
        echo "${RED}Failed: $failed/$total${RESET}"
    fi
    echo "${BOLD}${BLUE}/===----------------------------------===/${RESET}"
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

# -------------------------------- UTILITIES -------------------------------- #

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
        rm -f CMakeLists.txt gcc-toolchain.cmake .clangd
        rm -f .contest_metadata .problem_times
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
    if [ ! -f ".problem_times" ]; then
        echo "${YELLOW}No timing data available for this contest.${RESET}"
        return 0
    fi
    
    echo "${BOLD}${BLUE}/===---------- PROBLEM STATISTICS ----------===/${RESET}"
    
    local current_time=$(date +%s)
    while IFS=: read -r problem action timestamp; do
        if [ "$action" = "START" ]; then
            local elapsed=$((current_time - timestamp))
            echo "${CYAN}$problem${RESET}: Started $(_format_duration $elapsed) ago"
        fi
    done < .problem_times
    
    echo "${BOLD}${BLUE}/===----------------------------------------===/${RESET}"
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
        echo "${BOLD}${BLUE}/===----------- $1 -----------===/${RESET}"
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

# ------------------------------- HELP & USAGE ------------------------------ #

# Displays the help message.
function cpphelp() {
    cat << EOF
${BOLD}Enhanced CMake Utilities for Competitive Programming:${RESET}

${BOLD}${CYAN}[ SETUP & CONFIGURATION ]${RESET}
  ${GREEN}cppinit${RESET}                  - Initializes or verifies a project directory (workspace-protected).
  ${GREEN}cppnew${RESET} ${YELLOW}[name] [template]${RESET} - Creates a new .cpp file from a template ('default', 'pbds').
  ${GREEN}cppbatch${RESET} ${YELLOW}[count] [tpl]${RESET}   - Creates multiple problems at once (A, B, C, ...).
  ${GREEN}cppconf${RESET} ${YELLOW}[type]${RESET}           - (Re)configures the project (Debug, Release, Sanitize).
  ${GREEN}cppcontest${RESET} ${YELLOW}[dir_name]${RESET}    - Creates a new contest directory and initializes it.

${BOLD}${CYAN}[ BUILD, RUN, TEST ]${RESET}
  ${GREEN}cppbuild${RESET} ${YELLOW}[name]${RESET}          - Builds a target (defaults to most recent).
  ${GREEN}cpprun${RESET} ${YELLOW}[name]${RESET}            - Runs a target's executable.
  ${GREEN}cppgo${RESET} ${YELLOW}[name] [input]${RESET}     - Builds and runs. Uses '<name>.in' by default.
  ${GREEN}cppi${RESET} ${YELLOW}[name]${RESET}              - Interactive mode: builds and runs with manual input.
  ${GREEN}cppjudge${RESET} ${YELLOW}[name]${RESET}          - Tests against all sample cases with timing info.
  ${GREEN}cppstress${RESET} ${YELLOW}[name] [n]${RESET}     - Stress tests a solution for n iterations (default: 100).

${BOLD}${CYAN}[ UTILITIES ]${RESET}
  ${GREEN}cppwatch${RESET} ${YELLOW}[name]${RESET}          - Auto-rebuilds a target on file change.
  ${GREEN}cppclean${RESET}                 - Removes build artifacts.
  ${GREEN}cppdeepclean${RESET}             - Removes all generated files (interactive).
  ${GREEN}cppstats${RESET}                 - Shows timing statistics for problems.
  ${GREEN}cpparchive${RESET}               - Creates a compressed archive of the contest.
  ${GREEN}cppdiag${RESET}                  - Displays detailed diagnostic info about the toolchain.
  ${GREEN}cpphelp${RESET}                  - Shows this help message.

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

# =========================================================================== #
# End of script