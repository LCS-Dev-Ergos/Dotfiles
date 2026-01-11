# ============================================================================ #
# ++++++++++++++++++++++++++++++ PROJECT SETUP +++++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Project initialization, template creation, and configuration helpers.
# Handles workspace safety, contest scaffolding, and CMake setup.
#
# Functions:
#   - cppinit     Initialize or verify a project directory.
#   - cppnew      Create a new problem source and inputs.
#   - cppdelete   Remove a problem and related artifacts.
#   - cppbatch    Create multiple problems in bulk.
#   - cppconf     Configure CMake and compiler settings.
#   - cppcontest  Create and initialize a contest directory.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# cppinit
# -----------------------------------------------------------------------------
# Initialize or verify a competitive programming project directory.
# Creates templates, directories, and IDE configuration.
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# cppnew
# -----------------------------------------------------------------------------
# Create a new problem source file from a template and re-run CMake.
#
# Usage:
#   cppnew [problem_name] [template]
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# cppdelete
# -----------------------------------------------------------------------------
# Delete a problem source and associated files interactively.
#
# Usage:
#   cppdelete <problem_name>
# -----------------------------------------------------------------------------
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
  local -a input_files=( input_cases/"${problem_name}".*.in(N) )
  for input_file in "${input_files[@]}"; do
    echo "  - Input file: ${C_CYAN}$input_file${C_RESET}"
    files_to_delete+=("$input_file")
  done

  if [ -f "output_cases/${problem_name}.exp" ]; then
    echo "  - Output file: ${C_CYAN}output_cases/${problem_name}.exp${C_RESET}"
    files_to_delete+=("output_cases/${problem_name}.exp")
  fi

  # Check for multiple output files (numbered pattern).
  local -a output_files=( output_cases/"${problem_name}".*.exp(N) )
  for output_file in "${output_files[@]}"; do
    echo "  - Output file: ${C_CYAN}$output_file${C_RESET}"
    files_to_delete+=("$output_file")
  done

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
      rm -f -- "$file"
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

# -----------------------------------------------------------------------------
# cppbatch
# -----------------------------------------------------------------------------
# Create multiple problems with sequential letter names.
#
# Usage:
#   cppbatch [count] [template]
# -----------------------------------------------------------------------------
function cppbatch() {
  local count=${1:-5}
  local template=${2:-"default"}

  echo "${C_CYAN}Creating $count problems with template '$template'...${C_RESET}"

  for (( i=65; i < 65 + count; i++ )); do
    local problem_name
    local letter
    # Zsh character conversion: convert ASCII code to character.
    letter=${(#)i}
    problem_name="problem_${letter}"
    if [ ! -f "${problem_name}.cpp" ]; then
      cppnew "$problem_name" "$template"
    else
      echo "${C_YELLOW}Skipping $problem_name - already exists${C_RESET}"
    fi
  done

  echo "${C_GREEN}Batch creation complete!${C_RESET}"
}

# -----------------------------------------------------------------------------
# cppconf
# -----------------------------------------------------------------------------
# Configure CMake build parameters, compiler selection, and flags.
#
# Usage:
#   cppconf [Debug|Release|Sanitize] [gcc|clang|auto] [options]
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# cppcontest
# -----------------------------------------------------------------------------
# Create and initialize a contest directory within the workspace.
#
# Usage:
#   cppcontest <ContestDirectoryName>
# -----------------------------------------------------------------------------
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

# ============================================================================ #
# End of 10-project-setup.zsh
