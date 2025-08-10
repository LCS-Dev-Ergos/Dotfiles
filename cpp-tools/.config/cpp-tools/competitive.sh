#!/bin/bash
# =========================================================================== #
# ------ Enhanced CMake & Shell Utilities for Competitive Programming ------- #
# =========================================================================== #

# Detect the script directory for reliable access to templates
# Works both when the script is executed directly and when sourced
if [ -n "$BASH_SOURCE" ]; then
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
elif [ -n "$ZSH_VERSION" ]; then
    SCRIPT_DIR="$( cd "$( dirname "${(%):-%x}" )" &> /dev/null && pwd )"
else
    echo "Unsupported shell for script directory detection." >&2
fi

# Utility to get the last modified cpp file as the default target
_get_default_target() {
    # Find the most recently modified .cpp file in the current directory
    local default_target=$(ls -t *.cpp *.cc *.cxx 2>/dev/null | head -n 1 | sed -E 's/\.(cpp|cc|cxx)$//')
    # If none found, default to "main"
    echo "${default_target:-main}"
}

# ------------------------- PROJECT SETUP & CONFIG -------------------------- #

# Initialize a new competitive programming directory
function cppinit() {
    if [ -f "CMakeLists.txt" ]; then
        echo "Project already initialized."
        return 1
    fi

    # Check if the script directory is set
    if [ -z "$SCRIPT_DIR" ]; then
        echo "Error: SCRIPT_DIR is not set. Cannot find templates."
        return 1
    fi

    echo "Initializing Competitive Programming environment..."

    # Create CMakeLists.txt
    echo "Creating CMakeLists.txt from template..."
    cp "$SCRIPT_DIR/templates/CMakeLists.txt.tpl" ./CMakeLists.txt

    # Create gcc-toolchain.cmake
    # echo "Creating gcc-toolchain.cmake from template..."
    # cp "$SCRIPT_DIR/templates/gcc-toolchain.cmake.tpl" ./gcc-toolchain.cmake

    # Create .gitignore
    echo -e "build/\nbin/\nlib/\ncompile_commands.json\n*.DS_Store" > .gitignore
    
    # Create an 'algorithms' directory for shared code like debug.h
    mkdir -p algorithms

    # Create a basic configuration file
    cppconf

    echo "Project initialized successfully!"
    echo "Run 'cppnew <problem_name>' to create your first solution file."
}

# Create a new problem file from a template and re-run CMake
function cppnew() {
    local problem_name=${1:-"main"}
    local template_type=${2:-"default"}
    local file_name="${problem_name}.cpp"
    local template_file

    if [ -f "$file_name" ]; then
        echo "File '$file_name' already exists."
        return 1
    fi

    echo "Creating '$file_name' from template..."
    # Determine the template file based on the type
    local template_content
    case $template_type in
        "pbds")
            template_file="$SCRIPT_DIR/templates/cpp/pbds.cpp"
            ;;
        *) # Default template
            template_file="$SCRIPT_DIR/templates/cpp/default.cpp"
            ;;
    esac
    
    # Replace placeholder and create file
    local template_content=$(cat "$template_file")
    echo "${template_content//__FILE_NAME__/$file_name}" > "$file_name"
    
    # The debug header from template.txt should be placed in 'algorithms/debug.h'
    # For now, let's create a placeholder if it doesn't exist.
    if [ ! -f "algorithms/debug.h" ]; then
        echo "// Placeholder for debug library" > "algorithms/debug.h"
    fi

    echo "New problem '$problem_name' created. Re-running CMake configuration..."
    cppconf # Re-run configuration to add the new file
}

# Configure CMake with the correct toolchain and build type
function cppconf() {
    local build_type=${1:-Debug}

    # Find the path to the GCC compiler
    local GXX_PATH=$(which g++-15 || which g++-14 || which g++-13 || which g++)
    if [ -z "$GXX_PATH" ]; then
        echo "Error: Could not find a g++ executable in your PATH."
        echo "Please install with 'brew install gcc'."
        return 1
    fi

    # Derive the gcc path from g++ path (e.g., from g++-15 to gcc-15)
    local GCC_PATH=$(echo "$GXX_PATH" | sed 's/g++/gcc/')

    echo "Forcing compilers:"
    echo "CXX = $GXX_PATH"
    echo "CC  = $GCC_PATH"

    # Run CMake with the environment variables to force the selection
    if CXX="$GXX_PATH" CC="$GCC_PATH" cmake -G "Unix Makefiles" -S . -B build -DCMAKE_BUILD_TYPE=${build_type}; then
        echo "CMake configuration successful."
        # The symlink for clangd will now be correct because it's based on the GCC configuration
        cmake --build build --target symlink_clangd
    else
        echo "CMake configuration failed!"
        return 1
    fi
}

# Create and set up a new directory for a contest
function cppcontest() {
    if [ -z "$1" ]; then
        echo "Usage: cppcontest <ContestDirectoryName>"
        echo "Example: cppcontest Codeforces/ROUND_1037_DIV_3"
        return 1
    fi

    local contest_dir="$1"
    
    if [ -d "$contest_dir" ]; then
        echo "Directory '$contest_dir' already exists. Navigating into it."
    else
        echo "Creating new contest directory: '$contest_dir'"
        mkdir -p "$contest_dir"
    fi
    
    # Navigate into the contest directory
    cd "$contest_dir"
    
    # Initialize the project here if it's not already set up
    if [ ! -f "CMakeLists.txt" ]; then
        echo "Initializing new CMake project in '$(pwd)'..."
        cppinit
    else
        echo "Project already initialized in this directory."
    fi

    echo "✅ Ready to work in $(pwd). Use 'cppnew <problem_name>' to start."
}

# ------------------------------- BUILD & RUN ------------------------------- #

# Build a specific target (defaults to the last modified .cxx file)
function cppbuild() {
    local target=$(_get_default_target)
    local exec_name=$(echo "${1:-$target}" | sed -E 's/\.(cpp|cc|cxx)$//')
    echo "Building target: $target..."
    cmake --build build --target "${1:-$target}" -j # Use all available cores
}

# Run a specific executable (defaults to the last modified .cpp file)
function cpprun() {
    local target=$(_get_default_target)
    local exec_name=$(echo "${1:-$target}" | sed -E 's/\.(cpp|cc|cxx)$//')
    local exec_path="./bin/$exec_name"
    
    if [ ! -f "$exec_path" ]; then
        echo "Executable '$exec_path' not found. Building first..."
        if ! cppbuild "$exec_name"; then
            echo "Build failed!"
            return 1
        fi
    fi

    echo "Running '$exec_path'..."
    $exec_path
}

# All-in-one: build and run with optional input file redirection
function cppgo() {
    local target=$(_get_default_target)
    local exec_name=$(echo "${1:-$target}" | sed -E 's/\.(cpp|cc|cxx)$//')
    local exec_path="./bin/$exec_name"
    local input_file="input.txt"

    # If second argument is provided, use it as input file
    [ ! -z "$2" ] && input_file=$2

    echo "Building target '$exec_name'..."
    if cmake --build build --target "$exec_name" -j; then
        echo "/===----- RUNNING -----===/"
        if [ -f "$input_file" ]; then
            echo "(input from $input_file)"
            $exec_path < "$input_file"
        else
            $exec_path
        fi
        echo "/===----- FINISHED -----===/"
    else
        echo "Build failed!"
        return 1
    fi
}

# Judge solution against sample cases (e.g., main.1.in -> main.1.out)
function cppjudge() {
    local target=$(_get_default_target)
    local exec_name=$(echo "${1:-$target}" | sed -E 's/\.(cpp|cc|cxx)$//')
    local exec_path="./bin/$exec_name"

    if ! cppbuild "$exec_name"; then
        echo "Build failed!"
        return 1
    fi

    for test_in in ${exec_name}.*.in; do
        if [ -f "$test_in" ]; then
            local test_case=$(basename "$test_in" .in)
            local test_out="${test_case}.out"
            local temp_out=$(mktemp)

            echo -n "Testing $test_case... "
            $exec_path < "$test_in" > "$temp_out"

            if [ ! -f "$test_out" ]; then
                echo "WARNING: Output file '$test_out' not found."
                continue
            fi

            if diff -wB "$temp_out" "$test_out" >/dev/null; then
                echo "✅ PASSED"
            else
                echo "❌ FAILED"
                echo "# --------- YOUR OUTPUT --------- #"
                cat "$temp_out"
                echo "# ---------- EXPECTED ----------- #"
                cat "$test_out"
                echo "# ------------------------------- #"
            fi
            rm "$temp_out"
        fi
    done
}

# -------------------------------- UTILITIES -------------------------------- #

# Clean the project by removing the entire build directory
function cppclean() {
    echo "Cleaning project by removing the 'build' directory..."
    rm -rf build
}

# Watch for changes and auto-rebuild the last modified file
function cppwatch() {
    local target=$(_get_default_target)
    local source_file=$(echo "${1:-$target}" | sed -E 's/\.(cpp|cc|cxx)$//')

    # Check if the source file exists
    if ! command -v fswatch &> /dev/null && ! command -v inotifywait &> /dev/null; then
        echo "Please install 'fswatch' (macOS) or 'inotify-tools' (Linux)."
        return 1
    fi

    echo "Watching '$source_file' to rebuild target '$target'. Press Ctrl+C to stop."
    # Initial build
    cppbuild "$target"

    if command -v fswatch &> /dev/null; then
        fswatch -o "$source_file" | while read -r; do cppbuild "$target"; done
    else
        while inotifywait -e modify,create,delete -q "$source_file"; do cppbuild "$target"; done
    fi
}

# Help function
function cpphelp() {
    cat << EOF
Enhanced CMake Utilities for Competitive Programming:

[ SETUP ]
  cppinit                  - Initializes a new project directory.
  cppnew [name] [template] - Creates a new .cpp file from a template (e.g., 'default', 'pbds') and updates the build system.
  cppconf [type] [use_gcc] - (Re)configures the project (Debug, Release, Sanitize). Defaults to Debug with GCC.
  cppcontest [dir_name]    - Creates a new contest directory and initializes it.

[ BUILD, RUN, TEST ]
  cppbuild [name]          - Builds a target (defaults to most recent).
  cpprun [name]            - Runs a target's executable.
  cppgo [name] [input]     - Builds and runs in one go. Uses 'input.txt' by default.
  cppjudge [name]          - Tests executable against all sample cases (e.g., name.1.in).

[ UTILITIES ]
  cppwatch [name]          - Auto-rebuilds a target when its source file changes.
  cppclean                 - Removes the build directory.
  cpphelp                  - Shows this help message.

* Most commands default to the most recently modified .cpp file.
EOF
}

# echo "✅ Competitive Programming utilities loaded. Type 'cpphelp' for commands."

# =========================================================================== #
