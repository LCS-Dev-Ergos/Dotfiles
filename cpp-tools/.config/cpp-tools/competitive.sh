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
#
# =========================================================================== #

# ------------------------------ CONFIGURATION ------------------------------ #

# Path to your global directory containing reusable headers like debug.h.
# The script will create a symlink to this file in new projects.
# Example: CP_ALGORITHMS_DIR="$HOME/Documents/CP/Algorithms"
CP_ALGORITHMS_DIR="/Volumes/LCS.Data/CP-Problems/CodeForces/Algorithms"

# Detect the script directory for reliable access to templates.
# This works for both bash and zsh when the script is sourced.
if [ -n "$BASH_SOURCE" ]; then
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
elif [ -n "$ZSH_VERSION" ]; then
    SCRIPT_DIR="$( cd "$( dirname "${(%):-%x}" )" &> /dev/null && pwd )"
else
    echo "Unsupported shell for script directory detection." >&2
    # Fallback to current directory, though this may be unreliable
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
        echo "Error: Project is not initialized. Please run 'cppinit' first." >&2
        return 1
    fi
    return 0
}


# ------------------------- PROJECT SETUP & CONFIG -------------------------- #

# Initializes or verifies a competitive programming directory.
# This function is now idempotent.
function cppinit() {
    echo "Initializing Competitive Programming environment..."

    # Check for script directory, essential for finding templates.
    if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR/templates" ]; then
        echo "Error: SCRIPT_DIR is not set or templates directory is missing." >&2
        return 1
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

    # Create .clangd configuration if it doesn't exist.
    if [ ! -f ".clangd" ]; then
        echo "Creating .clangd configuration from template..."
        cp "$SCRIPT_DIR/templates/.clangd.tpl" ./.clangd
    fi
    
    # Create .gitignore if it doesn't exist.
    if [ ! -f ".gitignore" ]; then
        echo "Creating .gitignore..."
        echo -e "build/\nbin/\nlib/\ncompile_commands.json\n*.DS_Store\ngcc-toolchain.cmake" > .gitignore
    fi
    
    # Create directories if they don't exist.
    mkdir -p algorithms
    mkdir -p input_cases

    # Link to the global debug.h if configured and not already linked.
    local master_debug_header="$CP_ALGORITHMS_DIR/debug.h"
    if [ ! -e "algorithms/debug.h" ]; then
        if [ -n "$CP_ALGORITHMS_DIR" ] && [ -f "$master_debug_header" ]; then
            ln -s "$master_debug_header" "algorithms/debug.h"
            echo "Created symlink to global debug.h."
        else
            touch "algorithms/debug.h"
            echo "Warning: Global debug.h not found. Created a local placeholder."
        fi
    fi

    # Create a basic configuration. This will create the build directory.
    cppconf

    echo "✅ Project initialized successfully!"
    echo "Run 'cppnew <problem_name>' to create your first solution file."
}

# Creates a new problem file from a template and re-runs CMake.
function cppnew() {
    # Ensure the project is initialized before creating a new file.
    if [ ! -f "CMakeLists.txt" ]; then
        echo "Project not initialized. Run 'cppinit' before creating a new problem." >&2
        return 1
    fi

    local problem_name=${1:-"main"}
    local template_type=${2:-"default"}
    local file_name="${problem_name}.cpp"
    local template_file

    if [ -f "${problem_name}.cpp" ] || [ -f "${problem_name}.cc" ] || [ -f "${problem_name}.cxx" ]; then
        echo "Error: File for problem '$problem_name' already exists." >&2
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
        echo "Error: Template file '$template_file' not found." >&2
        return 1
    fi
    
    echo "Creating '$file_name' from template '$template_type'..."
    # Replace placeholder and create the file.
    sed "s/__FILE_NAME__/$file_name/g" "$template_file" > "$file_name"
    
    # Also create a corresponding empty input file.
    touch "input_cases/${problem_name}.in"
    echo "Created empty input file: input_cases/${problem_name}.in"

    echo "New problem '$problem_name' created. Re-running CMake configuration..."
    cppconf # Re-run configuration to add the new file to the build system.
}

# Configures the CMake project.
# This is now simplified to use the toolchain file, which is the robust way.
function cppconf() {
    local build_type=${1:-Debug}

    # Check if the toolchain file exists, if not, create it.
    if [ ! -f "gcc-toolchain.cmake" ]; then
        echo "Toolchain file not found. Running cppinit to fix..."
        cppinit
    fi

    echo "Configuring project with build type: ${build_type} (using GCC toolchain)"
    
    # Run CMake, forcing the GCC toolchain. This correctly sets up the compiler
    # and include paths for both building and for clangd.
    if cmake -S . -B build -DCMAKE_BUILD_TYPE=${build_type} -DCMAKE_TOOLCHAIN_FILE=gcc-toolchain.cmake; then
        echo "CMake configuration successful."
        # Create the symlink for clangd.
        cmake --build build --target symlink_clangd
    else
        echo "CMake configuration failed!" >&2
        return 1
    fi
}

# Creates and sets up a new directory for a contest.
function cppcontest() {
    if [ -z "$1" ]; then
        echo "Usage: cppcontest <ContestDirectoryName>" >&2
        echo "Example: cppcontest Codeforces/Round_1037_Div_3" >&2
        return 1
    fi

    local contest_dir="$1"
    
    # Create the directory if it doesn't exist.
    if [ ! -d "$contest_dir" ]; then
        echo "Creating new contest directory: '$contest_dir'"
        mkdir -p "$contest_dir"
    fi
    
    cd "$contest_dir" || return
    
    # Initialize the project here if it's not already set up.
    if [ ! -f "CMakeLists.txt" ]; then
        echo "Initializing new CMake project in '$(pwd)'..."
        cppinit
    else
        echo "Project already initialized. Verifying configuration..."
        cppinit # Run to ensure all components are present.
    fi

    echo "✅ Ready to work in $(pwd). Use 'cppnew <problem_name>' to start."
}

# ------------------------------- BUILD & RUN ------------------------------- #

# Builds a specific target.
function cppbuild() {
    _check_initialized || return 1
    local target_name=${1:-$(_get_default_target)}
    echo "Building target: $target_name..."
    # Use -j to build in parallel.
    cmake --build build --target "$target_name" -j
}

# Runs a specific executable.
function cpprun() {
    _check_initialized || return 1
    local target_name=${1:-$(_get_default_target)}
    local exec_path="./bin/$target_name"
    
    if [ ! -f "$exec_path" ]; then
        echo "Executable '$exec_path' not found. Building first..."
        if ! cppbuild "$target_name"; then
            echo "Build failed!" >&2
            return 1
        fi
    fi

    echo "Running '$exec_path'..."
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

    echo "Building target '$target_name'..."
    if cppbuild "$target_name"; then
        echo "/===----- RUNNING: $target_name -----===/"
        if [ -f "$input_path" ]; then
            echo "(input from $input_path)"
            "$exec_path" < "$input_path"
        else
            if [ -n "$2" ]; then # Warn if a specific file was requested but not found.
                 echo "Warning: Input file '$input_path' not found." >&2
            fi
            "$exec_path"
        fi
        echo "/===----------- FINISHED -----------===/"
    else
        echo "Build failed!" >&2
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
        echo "Build failed!" >&2
        return 1
    fi
    
    # Check for test cases.
    if ! ls "$input_dir/${target_name}".*.in &>/dev/null; then
        echo "No test cases found in '$input_dir/' for pattern '${target_name}.*.in'"
        return 0
    fi

    for test_in in "$input_dir/${target_name}".*.in; do
        local test_case_base
        test_case_base=$(basename "$test_in" .in)
        local test_out="$input_dir/${test_case_base}.out"
        local temp_out
        temp_out=$(mktemp)

        echo -n "Testing $(basename "$test_in")... "
        "$exec_path" < "$test_in" > "$temp_out"

        if [ ! -f "$test_out" ]; then
            echo "⚠️  WARNING: Output file '$(basename "$test_out")' not found."
            rm "$temp_out"
            continue
        fi

        # Use diff with -w (ignore all whitespace) and -B (ignore blank lines).
        if diff -wB "$temp_out" "$test_out" >/dev/null; then
            echo "✅ PASSED"
        else
            echo "❌ FAILED"
            echo "/===--------- YOUR OUTPUT ----------===/"
            cat "$temp_out"
            echo "/===----------- EXPECTED -----------===/"
            cat "$test_out"
            echo "/===--------------------------------===/"
        fi
        rm "$temp_out"
    done
}

# -------------------------------- UTILITIES -------------------------------- #

# Cleans the project by removing the build directory.
function cppclean() {
    echo "Cleaning project..."
    rm -rf build bin lib
    # Also remove the symlink if it exists in the root.
    if [ -L "compile_commands.json" ]; then
        rm "compile_commands.json"
    fi
    echo "Project cleaned."
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
        echo "Error: Source file for target '$target_name' not found." >&2
        return 1
    fi

    if ! command -v fswatch &> /dev/null; then
        echo "Error: 'fswatch' is not installed. Please run 'brew install fswatch'." >&2
        return 1
    fi

    echo "Watching '$source_file' to rebuild target '$target_name'. Press Ctrl+C to stop."
    # Initial build.
    cppbuild "$target_name"

    fswatch -o "$source_file" | while read -r; do cppbuild "$target_name"; done
}

# Displays the help message.
function cpphelp() {
    cat << EOF
Enhanced CMake Utilities for Competitive Programming:

[ SETUP ]
  cppinit                  - Initializes or verifies a project directory (idempotent).
  cppnew [name] [template] - Creates a new .cpp file from a template ('default', 'pbds').
  cppconf [type]           - (Re)configures the project (Debug, Release, Sanitize).
  cppcontest [dir_name]    - Creates a new contest directory and initializes it.

[ BUILD, RUN, TEST ]
  cppbuild [name]          - Builds a target (defaults to most recent).
  cpprun [name]            - Runs a target's executable.
  cppgo [name] [input]     - Builds and runs. Uses '<name>.in' by default.
  cppjudge [name]          - Tests against all sample cases (e.g., name.1.in -> name.1.out).

[ UTILITIES ]
  cppwatch [name]          - Auto-rebuilds a target on file change.
  cppclean                 - Removes build artifacts.
  cpphelp                  - Shows this help message.

* Most commands default to the most recently modified C++ source file.
EOF
}

# echo "✅ Competitive Programming utilities loaded. Type 'cpphelp' for commands."
