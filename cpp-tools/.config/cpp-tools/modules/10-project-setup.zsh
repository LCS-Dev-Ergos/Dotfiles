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
# _cp_link_relative_or_absolute
# -----------------------------------------------------------------------------
# Create a symlink preferring relative targets for portability across machines.
# Falls back to absolute target when relative computation is not available.
# -----------------------------------------------------------------------------
_cp_link_relative_or_absolute() {
  local target="$1"
  local link_path="$2"
  local link_target="$target"
  local link_dir
  link_dir=$(dirname -- "$link_path")

  if command -v python3 >/dev/null 2>&1; then
    local maybe_rel=""
    maybe_rel=$(python3 - "$link_dir" "$target" << 'PY' 2>/dev/null
import os
import sys

base_dir = os.path.realpath(sys.argv[1])
target_path = os.path.realpath(sys.argv[2])
print(os.path.relpath(target_path, base_dir))
PY
    ) || true
    if [ -n "$maybe_rel" ]; then
      link_target="$maybe_rel"
    fi
  fi

  ln -s "$link_target" "$link_path"
}

# -----------------------------------------------------------------------------
# _cp_setup_vscode_configs
# -----------------------------------------------------------------------------
# Set up VS Code configuration by linking to centralized shared entries.
# Prefers a single .vscode directory symlink on fresh workspaces; falls back to
# per-entry linking when a local .vscode directory already exists.
# -----------------------------------------------------------------------------
_cp_setup_vscode_configs() {
  local vscode_dest_dir=".vscode"
  local master_vscode_dir="$CP_ALGORITHMS_DIR/.vscode"
  local -a vscode_entries=(
    "settings.json"
    "tasks.json"
    "launch.json"
    "c_cpp_properties.json"
    "scripts"
  )

  if [ -z "$CP_ALGORITHMS_DIR" ] || [ ! -d "$master_vscode_dir" ]; then
    echo "${C_YELLOW}Warning: Central VS Code config directory not found at '$master_vscode_dir'. Skipping VS Code setup.${C_RESET}"
    return 0
  fi

  # Fresh workspace: link the whole .vscode directory for full parity.
  if [ ! -e "$vscode_dest_dir" ] && [ ! -L "$vscode_dest_dir" ]; then
    _cp_link_relative_or_absolute "$master_vscode_dir" "$vscode_dest_dir"
    echo "Created centralized VS Code directory symlink: $vscode_dest_dir -> $master_vscode_dir"
    return 0
  fi

  if [ -L "$vscode_dest_dir" ]; then
    echo "VS Code directory already linked: $vscode_dest_dir"
    return 0
  fi

  if [ ! -d "$vscode_dest_dir" ]; then
    echo "${C_YELLOW}Warning: '$vscode_dest_dir' exists but is not a directory/symlink. Skipping VS Code setup.${C_RESET}"
    return 0
  fi

  # Legacy/local .vscode directory: ensure required files and scripts are linked.
  local entry_name central_entry dest_entry
  for entry_name in "${vscode_entries[@]}"; do
    central_entry="$master_vscode_dir/$entry_name"
    dest_entry="$vscode_dest_dir/$entry_name"

    if [ ! -e "$central_entry" ] && [ ! -L "$central_entry" ]; then
      echo "${C_YELLOW}Warning: Missing central VS Code entry '$central_entry'.${C_RESET}"
      continue
    fi

    if [ -e "$dest_entry" ] || [ -L "$dest_entry" ]; then
      if [ -L "$dest_entry" ]; then
        echo "VS Code config already linked: $dest_entry"
      else
        echo "${C_YELLOW}VS Code config exists and was not replaced: $dest_entry${C_RESET}"
      fi
      continue
    fi

    _cp_link_relative_or_absolute "$central_entry" "$dest_entry"
    echo "Created VS Code config symlink: $dest_entry -> $central_entry"
  done
}

# -----------------------------------------------------------------------------
# _cp_select_clangd_profile
# -----------------------------------------------------------------------------
# Return the central clangd profile path selected for the current OS.
# -----------------------------------------------------------------------------
_cp_select_clangd_profile() {
  local clangd_dir="$CP_ALGORITHMS_DIR/clangd"
  local uname_s
  uname_s=$(uname -s 2>/dev/null || true)

  if [[ "$OSTYPE" == "darwin"* ]] || [ "$uname_s" = "Darwin" ]; then
    echo "$clangd_dir/clangd.macos"
  elif [[ "$OSTYPE" == "linux"* ]] || [ "$uname_s" = "Linux" ]; then
    echo "$clangd_dir/clangd.linux"
  else
    echo "$clangd_dir/clangd.linux"
  fi
}

# -----------------------------------------------------------------------------
# _cp_setup_clangd_config
# -----------------------------------------------------------------------------
# Configure .ide-configs/clangd as a symlink to central OS-specific profile.
# Migrates legacy copied profiles and keeps explicit custom files untouched.
# -----------------------------------------------------------------------------
_cp_setup_clangd_config() {
  local selected_profile
  selected_profile="$(_cp_select_clangd_profile)"

  if [ ! -f "$selected_profile" ]; then
    echo "${C_RED}Error: Missing centralized clangd profile '$selected_profile'.${C_RESET}" >&2
    return 1
  fi

  local clangd_dest=".ide-configs/clangd"
  local linux_profile="$CP_ALGORITHMS_DIR/clangd/clangd.linux"
  local macos_profile="$CP_ALGORITHMS_DIR/clangd/clangd.macos"

  if [ -e "$clangd_dest" ] && [ ! -L "$clangd_dest" ]; then
    if cmp -s "$clangd_dest" "$linux_profile" 2>/dev/null || cmp -s "$clangd_dest" "$macos_profile" 2>/dev/null; then
      rm -f -- "$clangd_dest"
      echo "Migrated legacy local clangd config to centralized symlink."
    else
      echo "${C_YELLOW}Warning: Local clangd config exists and was not replaced: $clangd_dest${C_RESET}"
      return 0
    fi
  fi

  if [ -L "$clangd_dest" ]; then
    rm -f -- "$clangd_dest"
  fi

  _cp_link_relative_or_absolute "$selected_profile" "$clangd_dest"
  echo "Configured .clangd profile from centralized source: $selected_profile"
}

# -----------------------------------------------------------------------------
# _cp_problem_template_file
# -----------------------------------------------------------------------------
# Resolve centralized C++ problem template path for the requested template type.
# -----------------------------------------------------------------------------
_cp_problem_template_file() {
  local template_type="${1:-base}"
  local templates_dir="$CP_ALGORITHMS_DIR/templates/cpp"

  if [ -z "$CP_ALGORITHMS_DIR" ] || [ ! -d "$templates_dir" ]; then
    return 1
  fi

  case "$template_type" in
    "pbds")
      echo "$templates_dir/pbds.cpp"
      ;;
    "default")
      echo "$templates_dir/default.cpp"
      ;;
    "advanced")
      echo "$templates_dir/advanced.cpp"
      ;;
    *)
      echo "$templates_dir/base.cpp"
      ;;
  esac
}

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

  # Centralized setup requires a valid Algorithms root.
  if [ -z "$CP_ALGORITHMS_DIR" ] || [ ! -d "$CP_ALGORITHMS_DIR" ]; then
    echo "${C_RED}Error: CP_ALGORITHMS_DIR is not set or is invalid.${C_RESET}" >&2
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

  # Create thin centralized CMake shim if it doesn't exist.
  if [ ! -f "CMakeLists.txt" ]; then
    echo "Creating minimal centralized CMakeLists.txt shim..."
    cat > "CMakeLists.txt" << 'EOF'
# Thin round-level CMakeLists: delegates all build logic to centralized modules.
cmake_minimum_required(VERSION 3.20)
project(competitive_programming LANGUAGES CXX)

set(CP_ROUND_BOOTSTRAP "${CMAKE_CURRENT_SOURCE_DIR}/algorithms/cmake/CPRoundBootstrap.cmake")
if(NOT EXISTS "${CP_ROUND_BOOTSTRAP}")
  message(FATAL_ERROR
    "Central build bootstrap not found: ${CP_ROUND_BOOTSTRAP}\n"
    "Run cppinit (or recreate algorithms/cmake symlink) to restore shared build modules.")
endif()

include("${CP_ROUND_BOOTSTRAP}")
EOF
  fi

  # Create thin CMakePresets wrapper if it doesn't exist.
  if [ ! -f "CMakePresets.json" ]; then
    cat > "CMakePresets.json" << 'EOF'
{
  "version": 6,
  "include": [
    "algorithms/cmake/CPRoundPresets.json"
  ]
}
EOF
    echo "Created CMakePresets.json for centralized presets."
  fi

  # Toolchain files are now centralized (no round-local copies/symlinks).
  if [ -n "$CP_ALGORITHMS_DIR" ]; then
    if [ ! -f "$CP_ALGORITHMS_DIR/gcc-toolchain.cmake" ]; then
      echo "${C_RED}Error: Missing centralized toolchain: $CP_ALGORITHMS_DIR/gcc-toolchain.cmake${C_RESET}" >&2
      return 1
    fi
    if [ ! -f "$CP_ALGORITHMS_DIR/clang-toolchain.cmake" ]; then
      echo "${C_YELLOW}Warning: Central clang toolchain not found at $CP_ALGORITHMS_DIR/clang-toolchain.cmake${C_RESET}"
    fi
  fi

  # Configure centralized OS-specific clangd profile.
  if ! _cp_setup_clangd_config; then
    return 1
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
      _cp_link_relative_or_absolute "$master_debug_header" "algorithms/debug.h"
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
      _cp_link_relative_or_absolute "$master_templates_dir" "algorithms/templates"
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
      _cp_link_relative_or_absolute "$master_modules_dir" "algorithms/modules"
      echo "Created symlink to global modules directory."
    else
      mkdir -p "algorithms/modules"
      echo "${C_YELLOW}Warning: Global modules directory not found. Created a local placeholder.${C_RESET}"
    fi
  fi

  # Link to shared CMake helper modules if available.
  local master_cmake_dir="$CP_ALGORITHMS_DIR/cmake"
  if [ ! -e "algorithms/cmake" ]; then
    if [ -n "$CP_ALGORITHMS_DIR" ] && [ -d "$master_cmake_dir" ]; then
      _cp_link_relative_or_absolute "$master_cmake_dir" "algorithms/cmake"
      echo "Created symlink to global CMake helper modules."
    else
      mkdir -p "algorithms/cmake"
      echo "${C_YELLOW}Warning: Global CMake helper modules not found. Created a local placeholder.${C_RESET}"
    fi
  fi

  # Copy or link PCH.h and PCH_Wrapper.h for Clang builds.
  local master_pch_header="$CP_ALGORITHMS_DIR/libs/PCH.h"
  local master_pch_wrapper="$CP_ALGORITHMS_DIR/libs/PCH_Wrapper.h"

  if [ ! -e "algorithms/PCH.h" ]; then
    if [ -n "$CP_ALGORITHMS_DIR" ] && [ -f "$master_pch_header" ]; then
      _cp_link_relative_or_absolute "$master_pch_header" "algorithms/PCH.h"
      echo "Created symlink to global PCH.h (for Clang builds)."
    else
      echo "${C_YELLOW}Warning: PCH.h not found. Clang builds may not work properly.${C_RESET}"
    fi
  fi

  if [ ! -e "algorithms/PCH_Wrapper.h" ]; then
    if [ -n "$CP_ALGORITHMS_DIR" ] && [ -f "$master_pch_wrapper" ]; then
      _cp_link_relative_or_absolute "$master_pch_wrapper" "algorithms/PCH_Wrapper.h"
      echo "Created symlink to global PCH_Wrapper.h."
    else
      echo "${C_YELLOW}Warning: PCH_Wrapper.h not found. Some builds may not work properly.${C_RESET}"
    fi
  fi

  # Set up VS Code configuration links from centralized shared files.
  _cp_setup_vscode_configs

  # Create a basic configuration. This will create the build directory.
  if ! cppconf; then
    echo "${C_RED}Project initialization failed during CMake configuration.${C_RESET}" >&2
    echo "${C_YELLOW}Fix the reported issues and run '${C_CYAN}cppconf${C_YELLOW}' again.${C_RESET}" >&2
    return 1
  fi

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
  local problem_brief
  local escaped_file_name
  local escaped_problem_brief
  local skip_config=0

  if [ "${3:-}" = "--no-config" ] || [ "${CPPNEW_SKIP_CONFIG:-0}" = "1" ]; then
    skip_config=1
  fi

  if [ -f "${problem_name}.cpp" ] || [ -f "${problem_name}.cc" ] || [ -f "${problem_name}.cxx" ]; then
    echo "${C_RED}Error: File for problem '$problem_name' already exists.${C_RESET}" >&2
    return 1
  fi

  # Resolve centralized template path based on requested type.
  template_file="$(_cp_problem_template_file "$template_type")" || {
    echo "${C_RED}Error: Centralized template directory not found at '$CP_ALGORITHMS_DIR/templates/cpp'.${C_RESET}" >&2
    return 1
  }

  if [ ! -f "$template_file" ]; then
    echo "${C_RED}Error: Template file '$template_file' not found.${C_RESET}" >&2
    return 1
  fi

  problem_brief=$(_problem_brief "$problem_name")
  escaped_file_name=${file_name//\\/\\\\}
  escaped_file_name=${escaped_file_name//\//\\/}
  escaped_file_name=${escaped_file_name//&/\\&}
  escaped_problem_brief=${problem_brief//\\/\\\\}
  escaped_problem_brief=${escaped_problem_brief//\//\\/}
  escaped_problem_brief=${escaped_problem_brief//&/\\&}

  echo "${C_CYAN}Creating '$file_name' from template '$template_type'...${C_RESET}"
  # Replace placeholders and create the file.
  sed \
    -e "s/__FILE_NAME__/${escaped_file_name}/g" \
    -e "s/__PROBLEM_BRIEF__/${escaped_problem_brief}/g" \
    "$template_file" > "$file_name"

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

  local problem_name source_file file input_file output_file
  for problem_name in "${requested_problems[@]}"; do
    source_file=$(_resolve_target_source "$problem_name")

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
_cppconf_normalize_build_type() {
  local raw="${1:l}"
  case "$raw" in
    debug) echo "Debug" ;;
    release) echo "Release" ;;
    sanitize) echo "Sanitize" ;;
    *) return 1 ;;
  esac
}

_cppconf_parse_on_off() {
  local raw="${1:l}"
  case "$raw" in
    on|true|1|yes) echo "ON" ;;
    off|false|0|no) echo "OFF" ;;
    *) return 1 ;;
  esac
}

_cppconf_parse_on_off_auto() {
  local raw="${1:l}"
  case "$raw" in
    auto) echo "AUTO" ;;
    *) _cppconf_parse_on_off "$raw" ;;
  esac
}

_cppconf_select_toolchain() {
  local build_type="$1"
  local compiler_choice="${2:l}"

  case "$compiler_choice" in
    gcc|g++)
      echo "gcc-toolchain.cmake|GCC (forced)|gcc"
      return 0
      ;;
    clang|clang++)
      echo "clang-toolchain.cmake|Clang/LLVM (forced)|clang"
      return 0
      ;;
    auto|"")
      if [ "$build_type" = "Sanitize" ] && [[ "$OSTYPE" == "darwin"* ]]; then
        echo "clang-toolchain.cmake|Clang/LLVM (auto-selected for sanitizers)|auto"
      elif [ "$build_type" = "Sanitize" ]; then
        echo "gcc-toolchain.cmake|GCC (auto-selected)|auto"
      else
        echo "gcc-toolchain.cmake|GCC (default)|auto"
      fi
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_cppconf_ensure_toolchain_file() {
  local toolchain_file="$1"
  if [ -z "$CP_ALGORITHMS_DIR" ]; then
    echo "${C_RED}Error: CP_ALGORITHMS_DIR is not set. Cannot resolve centralized toolchain.${C_RESET}" >&2
    return 1
  fi

  local resolved="$CP_ALGORITHMS_DIR/$toolchain_file"
  if [ ! -f "$resolved" ]; then
    echo "${C_RED}Error: Missing centralized toolchain '$resolved'.${C_RESET}" >&2
    return 1
  fi

  echo "$resolved"
}

_cppconf_rebuild_reason_for_toolchain() {
  local build_dir="$1"
  local toolchain_file="$2"
  local toolchain_base="${toolchain_file##*/}"
  [ -f "$build_dir/CMakeCache.txt" ] || return 1

  local cached_compiler cached_compiler_id cached_toolchain cached_toolchain_base
  cached_compiler=$(grep -E '^CMAKE_CXX_COMPILER:(FILEPATH|PATH|STRING)=' "$build_dir/CMakeCache.txt" | head -n1 | cut -d'=' -f2-)
  cached_compiler_id=$(grep -E '^CMAKE_CXX_COMPILER_ID:STRING=' "$build_dir/CMakeCache.txt" | head -n1 | cut -d'=' -f2-)
  cached_toolchain=$(grep -E '^CMAKE_TOOLCHAIN_FILE:' "$build_dir/CMakeCache.txt" | head -n1 | cut -d'=' -f2-)
  cached_toolchain_base=${cached_toolchain##*/}

  case "$toolchain_base" in
    gcc-toolchain.cmake)
      if [[ "$cached_compiler_id" == *Clang* ]] || { [ -z "$cached_compiler_id" ] && [[ "$cached_compiler" == *clang* ]]; }; then
        echo "cached compiler is Clang"
        return 0
      fi
      ;;
    clang-toolchain.cmake)
      if [[ "$cached_compiler_id" == "GNU" ]] || { [ -z "$cached_compiler_id" ] && [[ "$cached_compiler" == *g++* || "$cached_compiler" == *gcc* ]]; }; then
        echo "cached compiler is GCC"
        return 0
      fi
      ;;
  esac

  if [ -z "$cached_toolchain_base" ]; then
    echo "cached toolchain is missing"
    return 0
  fi

  if [ -n "$cached_toolchain_base" ] && [ "$cached_toolchain_base" != "$toolchain_base" ]; then
    echo "cached toolchain is '$cached_toolchain_base'"
    return 0
  fi

  return 1
}

_cppconf_rebuild_reason_for_stale_cmake_system_toolchain() {
  local build_dir="$1"
  local toolchain_file="$2"
  local toolchain_base="${toolchain_file##*/}"
  [ -d "$build_dir/CMakeFiles" ] || return 1

  local cmake_system_file
  cmake_system_file=$(find "$build_dir/CMakeFiles" -maxdepth 2 -type f -name CMakeSystem.cmake | head -n1)
  [ -n "$cmake_system_file" ] || return 1

  local system_toolchain
  system_toolchain=$(sed -n 's/^[[:space:]]*include("\([^"]*toolchain\.cmake\)")$/\1/p' "$cmake_system_file" | head -n1)
  [ -n "$system_toolchain" ] || return 1

  local system_toolchain_base="${system_toolchain##*/}"
  if [ "$system_toolchain_base" != "$toolchain_base" ]; then
    echo "CMakeSystem.cmake references '$system_toolchain_base'"
    return 0
  fi

  if [ "$system_toolchain" != "$toolchain_file" ]; then
    if [ ! -f "$system_toolchain" ]; then
      echo "CMakeSystem.cmake references missing '$system_toolchain'"
      return 0
    fi
    if [ -f "$toolchain_file" ]; then
      echo "CMakeSystem.cmake uses non-centralized '$system_toolchain'"
      return 0
    fi
  fi

  return 1
}

function cppconf() {
  local build_type="Debug"
  local compiler_choice="auto"
  local timing_mode="OFF"
  local pch_mode="AUTO"
  local force_pch_rebuild="OFF"

  local i=1 arg value normalized
  while [ $i -le $# ]; do
    arg="${@[i]}"
    case "$arg" in
      --build-type|-b)
        ((i++))
        if [ $i -gt $# ]; then
          echo "${C_RED}Error: Missing value after '$arg'.${C_RESET}" >&2
          return 1
        fi
        value="${@[i]}"
        normalized=$(_cppconf_normalize_build_type "$value") || {
          echo "${C_RED}Error: Invalid build type '$value'. Use Debug, Release, or Sanitize.${C_RESET}" >&2
          return 1
        }
        build_type="$normalized"
        ;;
      --compiler|-c)
        ((i++))
        if [ $i -gt $# ]; then
          echo "${C_RED}Error: Missing value after '$arg'.${C_RESET}" >&2
          return 1
        fi
        compiler_choice="${@[i]}"
        ;;
      --timing)
        ((i++))
        if [ $i -gt $# ]; then
          echo "${C_RED}Error: Missing value after '$arg'.${C_RESET}" >&2
          return 1
        fi
        value=$(_cppconf_parse_on_off "${@[i]}") || {
          echo "${C_RED}Error: Invalid timing value '${@[i]}'. Use on/off.${C_RESET}" >&2
          return 1
        }
        timing_mode="$value"
        ;;
      --pch)
        ((i++))
        if [ $i -gt $# ]; then
          echo "${C_RED}Error: Missing value after '$arg'.${C_RESET}" >&2
          return 1
        fi
        value=$(_cppconf_parse_on_off_auto "${@[i]}") || {
          echo "${C_RED}Error: Invalid pch value '${@[i]}'. Use on/off/auto.${C_RESET}" >&2
          return 1
        }
        pch_mode="$value"
        ;;
      --pch-rebuild|rebuild-pch)
        force_pch_rebuild="ON"
        ;;
      timing=*)
        value=$(_cppconf_parse_on_off "${arg#*=}") || {
          echo "${C_YELLOW}Warning: Unknown timing value '${arg#*=}'. Ignoring.${C_RESET}"
          ((i++))
          continue
        }
        timing_mode="$value"
        ;;
      pch=*)
        value=$(_cppconf_parse_on_off_auto "${arg#*=}") || {
          echo "${C_YELLOW}Warning: Unknown pch value '${arg#*=}'. Ignoring.${C_RESET}"
          ((i++))
          continue
        }
        pch_mode="$value"
        ;;
      pch-rebuild=*)
        value=$(_cppconf_parse_on_off "${arg#*=}") || {
          echo "${C_YELLOW}Warning: Unknown pch-rebuild value '${arg#*=}'. Ignoring.${C_RESET}"
          ((i++))
          continue
        }
        if [ "$value" = "ON" ]; then
          force_pch_rebuild="ON"
        fi
        ;;
      [Dd]ebug|[Rr]elease|[Ss]anitize)
        normalized=$(_cppconf_normalize_build_type "$arg") || true
        [ -n "$normalized" ] && build_type="$normalized"
        ;;
      gcc|g++|clang|clang++|auto)
        compiler_choice="$arg"
        ;;
      *)
        echo "${C_YELLOW}Warning: Unknown argument '$arg'. Ignoring.${C_RESET}"
        ;;
    esac
    ((i++))
  done

  if [ -n "$CP_TIMING" ]; then
    timing_mode="ON"
  fi

  local toolchain_selection toolchain_file toolchain_name
  toolchain_selection=$(_cppconf_select_toolchain "$build_type" "$compiler_choice") || {
    echo "${C_RED}Error: Unknown compiler choice '$compiler_choice'.${C_RESET}" >&2
    echo "Valid options: gcc, clang, auto" >&2
    return 1
  }
  toolchain_file="${toolchain_selection%%|*}"
  toolchain_name="${${toolchain_selection#*|}%%|*}"

  local resolved_toolchain_file
  resolved_toolchain_file=$(_cppconf_ensure_toolchain_file "$toolchain_file") || {
    return 1
  }
  toolchain_file="$resolved_toolchain_file"

  local toolchain_base compiler_key build_type_key build_dir
  toolchain_base="${toolchain_file##*/}"
  case "$toolchain_base" in
    clang-toolchain.cmake) compiler_key="clang" ;;
    *) compiler_key="gcc" ;;
  esac
  build_type_key=$(_cp_build_type_key "$build_type") || {
    echo "${C_RED}Error: Unsupported build type '$build_type'.${C_RESET}" >&2
    return 1
  }
  build_dir=$(_cp_profile_build_dir "$compiler_key" "$build_type_key")

  # Keep clangd profile aligned with current host OS also during plain cppconf.
  mkdir -p .ide-configs
  if ! _cp_setup_clangd_config; then
    echo "${C_RED}Error: Failed to configure centralized clangd profile.${C_RESET}" >&2
    return 1
  fi
  ln -sf .ide-configs/clangd .clangd

  local rebuild_reason
  rebuild_reason=$(_cppconf_rebuild_reason_for_toolchain "$build_dir" "$toolchain_file") || true
  if [ -z "$rebuild_reason" ]; then
    rebuild_reason=$(_cppconf_rebuild_reason_for_stale_cmake_system_toolchain "$build_dir" "$toolchain_file") || true
  fi
  if [ -n "$rebuild_reason" ]; then
    echo "${C_YELLOW}Detected stale cache in '${build_dir}' (${rebuild_reason}). Recreating this profile directory...${C_RESET}"
    rm -rf -- "$build_dir"
  fi

  local -a cmake_toolchain_arg=("-DCMAKE_TOOLCHAIN_FILE=${toolchain_file}")

  if [ "$pch_mode" = "AUTO" ]; then
    if [ "$build_type" = "Debug" ]; then
      if [[ "$toolchain_file" == *"clang"* ]]; then
        pch_mode="OFF"
      else
        pch_mode="ON"
      fi
    else
      pch_mode="OFF"
    fi
  fi

  local -a cmake_flags=(
    "-DCP_ENABLE_TIMING=${timing_mode}"
    "-DCP_ENABLE_PCH=${pch_mode}"
  )
  if [ "$force_pch_rebuild" = "ON" ]; then
    cmake_flags+=("-DCP_FORCE_PCH_REBUILD=ON")
  fi
  if [ "$build_type" = "Release" ] && [[ "$toolchain_file" == *"clang"* ]]; then
    cmake_flags+=("-DCP_ENABLE_LTO=ON")
  fi

  echo "${C_BLUE}╔═══───────────────────────────────────────────────────────────────────────────═══╗${C_RESET}"
  echo "  ${C_BLUE}Configuring project:${C_RESET}"
  echo "    ${C_CYAN}Build Type:${C_RESET} ${C_YELLOW}${build_type}${C_RESET}"
  echo "    ${C_CYAN}Compiler:${C_RESET} ${C_YELLOW}${toolchain_name}${C_RESET}"
  echo "    ${C_CYAN}Build Dir:${C_RESET} ${C_YELLOW}${build_dir}${C_RESET}"
  echo "    ${C_CYAN}Timing Report:${C_RESET} ${C_YELLOW}${timing_mode}${C_RESET}"
  echo "    ${C_CYAN}PCH Support:${C_RESET} ${C_YELLOW}${pch_mode}${C_RESET}"
  if [[ "${cmake_flags[*]}" == *"CP_ENABLE_LTO=ON"* ]]; then
    echo "    ${C_CYAN}LTO:${C_RESET} ${C_YELLOW}Enabled${C_RESET}"
  fi
  if [ "$force_pch_rebuild" = "ON" ]; then
    echo "    ${C_CYAN}PCH Rebuild:${C_RESET} ${C_YELLOW}Forced${C_RESET}"
  fi
  echo "${C_BLUE}╚═══───────────────────────────────────────────────────────────────────────────═══╝${C_RESET}"

  mkdir -p -- "${build_dir:h}"

  if cmake -S . -B "$build_dir" \
    -DCMAKE_BUILD_TYPE="${build_type}" \
    "${cmake_toolchain_arg[@]}" \
    -DCMAKE_CXX_FLAGS="-std=c++23" \
    "${cmake_flags[@]}"; then
    echo "${C_GREEN}CMake configuration successful.${C_RESET}"

    if [ "$force_pch_rebuild" = "ON" ]; then
      echo "${C_CYAN}Cleaning PCH cache...${C_RESET}"
      if cmake --build "$build_dir" --target pch_clean 2>/dev/null; then
        echo "${C_GREEN}PCH cache cleaned.${C_RESET}"
      else
        echo "${C_YELLOW}PCH clean target not available (normal for first run).${C_RESET}"
      fi
    fi

    cmake --build "$build_dir" --target symlink_clangd 2>/dev/null || true

    mkdir -p .statistics
    echo "$build_type:$compiler_key:${pch_mode}:$build_dir" > .statistics/last_config
    _cp_set_active_build_dir "$build_dir"
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
