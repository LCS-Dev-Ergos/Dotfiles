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
  local skip_config=0

  if [ "${3:-}" = "--no-config" ] || [ "${CPPNEW_SKIP_CONFIG:-0}" = "1" ]; then
    skip_config=1
  fi

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

  # Ensure generated-data directories exist.
  mkdir -p input_cases output_cases .statistics

  # Create corresponding empty input/output files.
  touch "input_cases/${problem_name}.in"
  touch "output_cases/${problem_name}.exp"
  echo "Created empty input file: input_cases/${problem_name}.in"
  echo "Created empty output file: output_cases/${problem_name}.exp"

  # Track problem creation time with human-readable format.
  echo "${problem_name}:START:$(date +%s):$(date '+%Y-%m-%d %H:%M:%S')" >> .statistics/problem_times

  if [ "$skip_config" -eq 1 ]; then
    echo "New problem '$problem_name' created. Skipping CMake configuration (batch mode)."
  else
    echo "New problem '$problem_name' created. Re-running CMake configuration..."
    cppconf # Re-run configuration to add the new file to the build system.
  fi
}

# -----------------------------------------------------------------------------
# cppdelete
# -----------------------------------------------------------------------------
# Delete one or more problems and associated files interactively.
#
# Usage:
#   cppdelete [--yes|-y] [--no-config] <problem_name> [problem_name...]
#   cppdelete problem_A,problem_B,problem_C
# -----------------------------------------------------------------------------
function cppdelete() {
  setopt localoptions typesetsilent

  local auto_confirm=0
  local skip_config=0
  local arg token normalized
  local -a requested_problems=()
  local -a valid_problems=()
  local -a missing_problems=()
  local -a files_to_delete=()
  typeset -A seen_problems
  typeset -A seen_files

  for arg in "$@"; do
    case "$arg" in
      -y|--yes)
        auto_confirm=1
        continue
        ;;
      --no-config)
        skip_config=1
        continue
        ;;
    esac

    normalized="${arg//,/ }"
    for token in ${(z)normalized}; do
      token="${token%.cpp}"
      token="${token%.cc}"
      token="${token%.cxx}"
      token="${token#,}"
      token="${token%,}"
      [ -z "$token" ] && continue

      if (( ! ${+seen_problems[$token]} )); then
        seen_problems[$token]=1
        requested_problems+=("$token")
      fi
    done
  done

  if (( ${#requested_problems} == 0 )); then
    echo "${C_RED}Usage: cppdelete [--yes|-y] [--no-config] <problem_name> [problem_name...]${C_RESET}" >&2
    echo "Examples:" >&2
    echo "  cppdelete problem_A problem_B problem_C" >&2
    echo "  cppdelete problem_A,problem_B,problem_C" >&2
    return 1
  fi

  echo "${C_YELLOW}The following files will be deleted:${C_RESET}"

  local problem_name source_file ext file input_file output_file
  for problem_name in "${requested_problems[@]}"; do
    source_file=""
    for ext in cpp cc cxx; do
      if [ -f "${problem_name}.${ext}" ]; then
        source_file="${problem_name}.${ext}"
        break
      fi
    done

    if [ -z "$source_file" ]; then
      missing_problems+=("$problem_name")
      continue
    fi

    valid_problems+=("$problem_name")
    echo "${C_CYAN}[${problem_name}]${C_RESET}"

    if (( ! ${+seen_files[$source_file]} )); then
      files_to_delete+=("$source_file")
      seen_files[$source_file]=1
      echo "  - Source file: ${C_CYAN}$source_file${C_RESET}"
    fi

    file="input_cases/${problem_name}.in"
    if [ -f "$file" ] && (( ! ${+seen_files[$file]} )); then
      files_to_delete+=("$file")
      seen_files[$file]=1
      echo "  - Input file: ${C_CYAN}$file${C_RESET}"
    fi

    local -a input_files=( input_cases/"${problem_name}".*.in(N) )
    for input_file in "${input_files[@]}"; do
      if (( ! ${+seen_files[$input_file]} )); then
        files_to_delete+=("$input_file")
        seen_files[$input_file]=1
        echo "  - Input file: ${C_CYAN}$input_file${C_RESET}"
      fi
    done

    file="output_cases/${problem_name}.exp"
    if [ -f "$file" ] && (( ! ${+seen_files[$file]} )); then
      files_to_delete+=("$file")
      seen_files[$file]=1
      echo "  - Output file: ${C_CYAN}$file${C_RESET}"
    fi

    local -a output_files=( output_cases/"${problem_name}".*.exp(N) )
    for output_file in "${output_files[@]}"; do
      if (( ! ${+seen_files[$output_file]} )); then
        files_to_delete+=("$output_file")
        seen_files[$output_file]=1
        echo "  - Output file: ${C_CYAN}$output_file${C_RESET}"
      fi
    done

    file="$SUBMISSIONS_DIR/${problem_name}_sub.cpp"
    if [ -f "$file" ] && (( ! ${+seen_files[$file]} )); then
      files_to_delete+=("$file")
      seen_files[$file]=1
      echo "  - Submission file: ${C_CYAN}$file${C_RESET}"
    fi

    file="bin/${problem_name}"
    if [ -f "$file" ] && (( ! ${+seen_files[$file]} )); then
      files_to_delete+=("$file")
      seen_files[$file]=1
      echo "  - Executable: ${C_CYAN}$file${C_RESET}"
    fi
  done

  if (( ${#missing_problems} > 0 )); then
    echo "${C_YELLOW}Warning: Source file not found for: ${missing_problems[*]}${C_RESET}"
  fi

  if (( ${#valid_problems} == 0 )) || (( ${#files_to_delete} == 0 )); then
    echo "${C_RED}Error: No matching problem files found to delete.${C_RESET}" >&2
    return 1
  fi

  if [ "$auto_confirm" -eq 0 ]; then
    local response
    echo ""
    printf "${C_YELLOW}Are you sure you want to delete these files? (y/N): ${C_RESET}"
    read -r response || response=""

    if [[ ! "$response" =~ ^[Yy]$ ]]; then
      echo "Deletion cancelled."
      return 0
    fi
  fi

  local deleted_count=0
  for file in "${files_to_delete[@]}"; do
    if [ -e "$file" ]; then
      rm -f -- "$file"
      echo "${C_GREEN}Deleted: $file${C_RESET}"
      ((deleted_count++))
    fi
  done

  if [ -f ".statistics/problem_times" ] && (( ${#valid_problems} > 0 )); then
    local stats_tmp=".statistics/problem_times.tmp.$$"
    : > "$stats_tmp"

    local line keep p
    while IFS= read -r line; do
      keep=1
      for p in "${valid_problems[@]}"; do
        if [[ "$line" == "${p}:"* ]]; then
          keep=0
          break
        fi
      done
      if [ "$keep" -eq 1 ]; then
        echo "$line" >> "$stats_tmp"
      fi
    done < ".statistics/problem_times"

    mv "$stats_tmp" ".statistics/problem_times"
  fi

  echo ""
  echo "${C_GREEN}Successfully deleted problem(s): ${valid_problems[*]} ($deleted_count files removed)${C_RESET}"

  if [ "$skip_config" -eq 0 ] && [ -f "CMakeLists.txt" ]; then
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
  setopt localoptions typesetsilent

  local count=${1:-5}
  local template=${2:-"base"}
  local created_count=0
  local -a letters=(A B C D E F G H I J K L M N O P Q R S T U V W X Y Z)

  if [[ ! "$count" =~ '^[0-9]+$' ]] || [ "$count" -le 0 ]; then
    echo "${C_RED}Error: count must be a positive integer (got '$count').${C_RESET}" >&2
    return 1
  fi

  if [ "$count" -gt "${#letters[@]}" ]; then
    echo "${C_YELLOW}Warning: Requested $count problems, but only ${#letters[@]} letters are supported (A-Z).${C_RESET}"
    count=${#letters[@]}
  fi

  echo "${C_CYAN}Creating $count problems with template '$template'...${C_RESET}"

  local idx
  for (( idx = 1; idx <= count; idx++ )); do
    local problem_name
    local letter
    letter="${letters[idx]}"
    problem_name="problem_${letter}"
    if [ ! -f "${problem_name}.cpp" ]; then
      if CPPNEW_SKIP_CONFIG=1 cppnew "$problem_name" "$template"; then
        ((created_count++))
      fi
    else
      echo "${C_YELLOW}Skipping $problem_name - already exists${C_RESET}"
    fi
  done

  if [ "$created_count" -gt 0 ]; then
    echo "Re-running CMake configuration once for $created_count new problem(s)..."
    cppconf
  else
    echo "No new problems were created. Skipping CMake reconfiguration."
  fi

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

  # If the requested compiler family differs from the one cached in build/,
  # recreate the build directory so CMake actually applies the new toolchain.
  local rebuild_build_dir=0
  local rebuild_reason=""
  if [ -f "build/CMakeCache.txt" ]; then
    local cached_compiler
    local cached_toolchain
    local cached_toolchain_base

    cached_compiler=$(grep -E '^CMAKE_CXX_COMPILER:(FILEPATH|PATH|STRING)=' build/CMakeCache.txt | head -n1 | cut -d'=' -f2-)
    cached_toolchain=$(grep -E '^CMAKE_TOOLCHAIN_FILE:' build/CMakeCache.txt | head -n1 | cut -d'=' -f2-)
    cached_toolchain_base=${cached_toolchain##*/}

    case "$toolchain_file" in
      gcc-toolchain.cmake)
        if [[ "$cached_compiler" == *clang* ]]; then
          rebuild_build_dir=1
          rebuild_reason="cached compiler is Clang"
        fi
        ;;
      clang-toolchain.cmake)
        if [[ "$cached_compiler" == *g++* || "$cached_compiler" == *gcc* ]]; then
          rebuild_build_dir=1
          rebuild_reason="cached compiler is GCC"
        fi
        ;;
    esac

    if [ "$rebuild_build_dir" -eq 0 ] && [ -n "$cached_toolchain_base" ] && [ "$cached_toolchain_base" != "$toolchain_file" ]; then
      rebuild_build_dir=1
      rebuild_reason="cached toolchain is '$cached_toolchain_base'"
    fi
  fi

  if [ "$rebuild_build_dir" -eq 1 ]; then
    echo "${C_YELLOW}Toolchain switch detected (${rebuild_reason}). Recreating build directory...${C_RESET}"
    rm -rf -- build
  fi

  # CMAKE_TOOLCHAIN_FILE is meaningful only during first configure of a build dir.
  # Passing it on subsequent reconfigure triggers noisy warnings in CMake.
  local cmake_toolchain_arg=()
  if [ ! -f "build/CMakeCache.txt" ]; then
    cmake_toolchain_arg=("-DCMAKE_TOOLCHAIN_FILE=${toolchain_file}")
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
    "${cmake_toolchain_arg[@]}" \
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
