#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ FILE & ARCHIVE FUNCTIONS +++++++++++++++++++++++++ #
# ============================================================================ #
#
# File and archive management utilities.
# Provides tools for creating, extracting, and analyzing files.
#
# Functions:
#   - extract     Universal archive extraction.
#   - mktar       Create .tar archive.
#   - mkgz        Create .tar.gz archive.
#   - mktbz       Create .tar.bz2 archive.
#   - mkzip       Create .zip archive.
#   - findlarge   Find files larger than specified size.
#   - tre         Directory tree respecting .gitignore.
#   - count       Count files and directories.
#   - dirsize     Directory size analysis.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# extract
# -----------------------------------------------------------------------------
# Universal extraction function supporting multiple archive formats.
# Automatically detects archive type by extension and uses appropriate tool.
#
# Supported: .tar.bz2, .tbz2, .tar.gz, .tgz, .tar.xz, .txz, .tar,
#            .bz2, .rar, .gz, .zip, .Z, .7z, .xz
#
# Usage:
#   extract <archive>
# -----------------------------------------------------------------------------
function extract() {
  if [[ $# -eq 0 ]]; then
    echo "${C_YELLOW}Usage: extract <archive>${C_RESET}" >&2
    return 1
  fi

  if [[ ! -f "$1" ]]; then
    echo "${C_RED}Error: File '$1' not found.${C_RESET}" >&2
    return 1
  fi

  case "$1" in
    *.tar.bz2 | *.tbz2) tar xjf "$1" ;;
    *.tar.gz | *.tgz) tar xzf "$1" ;;
    *.tar.xz | *.txz) tar xJf "$1" ;;
    *.tar) tar xf "$1" ;;
    *.bz2) bunzip2 "$1" ;;
    *.rar) unrar x "$1" ;;
    *.gz) gunzip "$1" ;;
    *.zip) unzip "$1" ;;
    *.Z) uncompress "$1" ;;
    *.7z) 7z x "$1" ;;
    *.xz) unxz "$1" ;;
    *)
      echo "${C_RED}Error: Unsupported archive format for '$1'${C_RESET}" >&2
      return 1
      ;;
  esac

  if [[ $? -eq 0 ]]; then
    echo "${C_GREEN}Successfully extracted '$1'${C_RESET}"
  else
    echo "${C_RED}Error: Extraction failed for '$1'${C_RESET}" >&2
    return 1
  fi
}

# -----------------------------------------------------------------------------
# mktar, mkgz, mktbz, mkzip
# -----------------------------------------------------------------------------
# Quick helpers to create compressed archives from directories.
#
# Usage:
#   mktar <directory>  - Create .tar archive
#   mkgz <directory>   - Create .tar.gz archive
#   mktbz <directory>  - Create .tar.bz2 archive
#   mkzip <directory>  - Create .zip archive
# -----------------------------------------------------------------------------
mktar() {
  [[ -z "$1" ]] && { echo "${C_YELLOW}Usage: mktar <directory>${C_RESET}"; return 1; }
  tar -cvf "${1%%/}.tar" "${1%%/}/"
}

mkgz() {
  [[ -z "$1" ]] && { echo "${C_YELLOW}Usage: mkgz <directory>${C_RESET}"; return 1; }
  tar -czvf "${1%%/}.tar.gz" "${1%%/}/"
}

mktbz() {
  [[ -z "$1" ]] && { echo "${C_YELLOW}Usage: mktbz <directory>${C_RESET}"; return 1; }
  tar -cjvf "${1%%/}.tar.bz2" "${1%%/}/"
}

mkzip() {
  [[ -z "$1" ]] && { echo "${C_YELLOW}Usage: mkzip <directory>${C_RESET}"; return 1; }
  zip -r "${1%%/}.zip" "${1%%/}/"
}

# -----------------------------------------------------------------------------
# findlarge
# -----------------------------------------------------------------------------
# Find and list files larger than specified size (sorted by size).
#
# Usage:
#   findlarge [size_in_MB] [directory]
# -----------------------------------------------------------------------------
function findlarge() {
  local size="${1:-100}"
  local dir="${2:-.}"

  if ! [[ "$size" =~ ^[0-9]+$ ]]; then
    echo "${C_RED}Error: Size must be a positive number in MB.${C_RESET}" >&2
    return 1
  fi

  echo "${C_CYAN}Finding files larger than ${size}MB in ${dir}...${C_RESET}"
  find "$dir" -type f -size +${size}M -exec du -h {} + 2>/dev/null | sort -rh
}

# -----------------------------------------------------------------------------
# tre
# -----------------------------------------------------------------------------
# Display directory tree respecting .gitignore rules.
# Uses eza if available, falls back to tree.
#
# Usage:
#   tre [directory]
# -----------------------------------------------------------------------------
function tre() {
  if command -v eza >/dev/null 2>&1; then
    eza --tree --git-ignore --color=always "${1:-.}"
  elif command -v tree >/dev/null 2>&1; then
    tree -C --gitignore "${1:-.}"
  else
    echo "${C_RED}Error: Neither 'eza' nor 'tree' is installed.${C_RESET}" >&2
    return 1
  fi
}

# -----------------------------------------------------------------------------
# count
# -----------------------------------------------------------------------------
# Count files and directories with detailed breakdown.
#
# Usage:
#   count [directory] [options]
#
# Options:
#   -r, --recursive  Count recursively (max depth: 5)
#   -a, --all        Show all item types including symlinks
#   -h, --help       Show help message
# -----------------------------------------------------------------------------
function count() {
  local target="."
  local recursive=0
  local show_all=0
  local max_depth=1


  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r | --recursive) recursive=1; max_depth=5; shift ;;
      -a | --all) show_all=1; shift ;;
      -h | --help)
        echo "${C_CYAN}Usage: count [directory] [options]${C_RESET}"
        echo ""
        echo "Options:"
        echo "  -r, --recursive  Count recursively (max depth: 5)"
        echo "  -a, --all        Show all item types including symlinks"
        echo "  -h, --help       Show this help message"
        echo ""
        echo "Examples:"
        echo "  count              Count items in current directory"
        echo "  count /tmp         Count items in /tmp"
        echo "  count -r           Count recursively"
        echo "  count -a /var/log  Count all types in /var/log"
        return 0 ;;
      -*)
        echo "${C_RED}Error: Unknown option '$1'${C_RESET}" >&2
        echo "Use 'count --help' for usage information." >&2
        return 1 ;;
      *) target="$1"; shift ;;
    esac
  done

  # Validate target exists before proceeding.
  if [[ ! -e "$target" ]]; then
    echo "${C_RED}Error: '$target' does not exist${C_RESET}" >&2
    return 1
  fi

  if [[ ! -d "$target" ]]; then
    echo "${C_RED}Error: '$target' is not a directory${C_RESET}" >&2
    return 1
  fi

  if [[ ! -r "$target" ]]; then
    echo "${C_RED}Error: No read permission for '$target'${C_RESET}" >&2
    return 1
  fi

  # Convert target to absolute canonical path.
  # The -P flag resolves all symbolic links in the path to their real locations.
  local canonical_path
  canonical_path="$(cd -P "$target" 2>/dev/null && pwd)" || {
    echo "${C_RED}Error: Cannot access '$target'${C_RESET}" >&2
    return 1
  }

  # Require explicit '/' argument when scanning root to prevent accidents.
  if [[ "$target" == "." && "$canonical_path" == "/" ]]; then
    echo "${C_RED}Error: Refusing to scan root directory. Specify '/' explicitly if intended.${C_RESET}" >&2
    return 1
  fi

  # Initialize counters for different item types.
  local files=0 dirs=0 hidden=0 symlinks=0 total=0

  # Retrieve file type information for all items in a single find traversal.
  # BSD find (macOS) doesn't support -printf, so we use a portable approach.
  local item
  while IFS= read -r item; do
    if [[ -L "$item" ]]; then
      ((symlinks++))
    elif [[ -f "$item" ]]; then
      ((files++))
    elif [[ -d "$item" ]]; then
      ((dirs++))
    fi
  done < <(find "$canonical_path" -mindepth 1 -maxdepth "$max_depth" 2>/dev/null)

  # Count hidden items (names starting with dot).
  hidden=$(find "$canonical_path" -mindepth 1 -maxdepth "$max_depth" \
    -name '.*' 2>/dev/null | wc -l | tr -d ' ')

  # Calculate total.
  total=$((files + dirs + symlinks))

  # Display results with formatted output.
  echo ""
  echo "${C_CYAN}═══════════════════════════════════════════════════${C_RESET}"
  if [[ $recursive -eq 1 ]]; then
    echo "${C_CYAN}Directory Count (Recursive, max depth: $max_depth)${C_RESET}"
  else
    echo "${C_CYAN}Directory Count (Non-recursive)${C_RESET}"
  fi
  echo "${C_CYAN}═══════════════════════════════════════════════════${C_RESET}"
  echo ""
  printf "${C_YELLOW}%-15s${C_RESET} %s\n" "Location:" "$canonical_path"
  echo ""
  printf "${C_GREEN}%-15s${C_RESET} %'6d\n" "Files:" "$files"
  printf "${C_GREEN}%-15s${C_RESET} %'6d\n" "Directories:" "$dirs"

  # Always show symlinks if there are any, or if --all flag is used.
  if [[ $show_all -eq 1 ]] || [[ $symlinks -gt 0 ]]; then
    printf "${C_MAGENTA}%-15s${C_RESET} %'6d\n" "Symlinks:" "$symlinks"
  fi

  printf "${C_BLUE}%-15s${C_RESET} %'6d\n" "Hidden:" "$hidden"

  echo "${C_CYAN}───────────────────────────────────────────────────${C_RESET}"
  printf "${C_YELLOW}%-15s${C_RESET} %'6d\n" "Total:" "$total"
  echo "${C_CYAN}═══════════════════════════════════════════════════${C_RESET}"
  echo ""
}
# -----------------------------------------------------------------------------
# dirsize
# -----------------------------------------------------------------------------
# Calculate and display directory sizes in descending order with pagination.
# Uses Nushell for table rendering if available, falls back to column formatting.
# Only scans immediate subdirectories (depth=1) for performance and safety.
#
# Usage:
#   dirsize [directory] [options]
#
# Arguments:
#   directory - Target directory to analyze (default: current directory).
#
# Options:
#   -n, --limit NUM     Results per page (default: 25).
#   -a, --all           Include files, not just directories.
#   -h, --help          Show help message.
# -----------------------------------------------------------------------------
function dirsize() {
  local python_script="$ZSH_CONFIG_DIR/scripts/python/dirsize.py"

  if [[ ! -f "$python_script" ]]; then
    echo "${C_RED}Error: Python script not found at '$python_script'${C_RESET}" >&2
    return 1
  fi

  python3 "$python_script" "$@"
}

# Create alias for dirsize.
alias ds='dirsize'

# ============================================================================ #
