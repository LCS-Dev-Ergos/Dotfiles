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
# @description Extracts supported archives into dedicated directories,
# flattening a single top-level entry when possible.
# @arg $1 path First archive file; additional archives may be supplied.
# @option -r | --remove Delete each source archive after successful extraction.
# @option -h | --help Show usage information.
# @exitcode 1 If an archive is missing, unsupported, or fails to extract.
# -----------------------------------------------------------------------------
function extract() {
  if [[ "$1" == -h || "$1" == --help ]]; then
    echo "Usage: extract [-r|--remove] <archive> [archive ...]"
    return 0
  fi
  setopt localoptions noautopushd nullglob

  if [[ $# -eq 0 ]]; then
    echo "${C_YELLOW}Usage: extract [-r|--remove] <archive> [archive ...]${C_RESET}" >&2
    return 1
  fi

  local remove_archive=0
  if [[ "$1" == "-r" || "$1" == "--remove" ]]; then
    remove_archive=1
    shift
  fi

  if [[ $# -eq 0 ]]; then
    echo "${C_YELLOW}Usage: extract [-r|--remove] <archive> [archive ...]${C_RESET}" >&2
    return 1
  fi

  local archive lower had_errors=0 pwd="$PWD"
  for archive in "$@"; do
    if [[ ! -f "$archive" ]]; then
      echo "${C_RED}Error: File '$archive' not found.${C_RESET}" >&2
      had_errors=1
      continue
    fi

    local full_path="${archive:A}"
    local extract_dir="${archive:t:r}"
    if [[ $extract_dir =~ '\.tar$' ]]; then
      extract_dir="${extract_dir:r}"
    fi
    if [[ -e "$extract_dir" ]]; then
      local rnd="${(L)"${$(( [##36]$RANDOM*$RANDOM ))}":1:5}"
      extract_dir="${extract_dir}-${rnd}"
    fi

    if ! command mkdir -p -- "$extract_dir"; then
      echo "${C_RED}Error: Could not create extraction directory '$extract_dir'.${C_RESET}" >&2
      had_errors=1
      continue
    fi
    if ! builtin cd -q -- "$extract_dir"; then
      echo "${C_RED}Error: Could not enter extraction directory '$extract_dir'.${C_RESET}" >&2
      had_errors=1
      continue
    fi

    echo "extract: extracting to $extract_dir" >&2

    lower="${archive:l}"
    local rc=0

    case "$lower" in
      *.tar.gz | *.tgz)
        if command -v pigz >/dev/null 2>&1; then
          tar -I pigz -xvf "$full_path"
        else
          tar -xzf "$full_path"
        fi
        rc=$?
        ;;
      *.tar.bz2 | *.tbz | *.tbz2)
        if command -v pbzip2 >/dev/null 2>&1; then
          tar -I pbzip2 -xvf "$full_path"
        else
          tar -xjf "$full_path"
        fi
        rc=$?
        ;;
      *.tar.xz | *.txz)
        if command -v pixz >/dev/null 2>&1; then
          tar -I pixz -xvf "$full_path"
        elif tar --xz --help >/dev/null 2>&1; then
          tar --xz -xvf "$full_path"
        else
          xzcat "$full_path" | tar -xvf -
        fi
        rc=$?
        ;;
      *.tar.zma | *.tlz)
        if tar --lzma --help >/dev/null 2>&1; then
          tar --lzma -xvf "$full_path"
        else
          lzcat "$full_path" | tar -xvf -
        fi
        rc=$?
        ;;
      *.tar.zst | *.tzst)
        if tar --zstd --help >/dev/null 2>&1; then
          tar --zstd -xvf "$full_path"
        else
          zstdcat "$full_path" | tar -xvf -
        fi
        rc=$?
        ;;
      *.tar) tar -xf "$full_path"; rc=$? ;;
      *.tar.lz)
        if command -v lzip >/dev/null 2>&1; then
          tar -xf "$full_path"
          rc=$?
        else
          echo "${C_RED}Error: 'lzip' is required for '$archive'.${C_RESET}" >&2
          rc=1
        fi
        ;;
      *.tar.lz4)
        if command -v lz4 >/dev/null 2>&1; then
          lz4 -c -d "$full_path" | tar -xvf -
          rc=$?
        else
          echo "${C_RED}Error: 'lz4' is required for '$archive'.${C_RESET}" >&2
          rc=1
        fi
        ;;
      *.tar.lrz)
        if command -v lrzuntar >/dev/null 2>&1; then
          lrzuntar "$full_path"
          rc=$?
        else
          echo "${C_RED}Error: lrzuntar is required for '$archive'.${C_RESET}" >&2
          rc=1
        fi
        ;;
      *.gz)
        if command -v pigz >/dev/null 2>&1; then
          pigz -cdk "$full_path" > "${archive:t:r}"
        else
          gunzip -ck "$full_path" > "${archive:t:r}"
        fi
        rc=$?
        ;;
      *.bz2)
        if command -v pbzip2 >/dev/null 2>&1; then
          pbzip2 -cdk "$full_path" > "${archive:t:r}"
        else
          bunzip2 -ck "$full_path" > "${archive:t:r}"
        fi
        rc=$?
        ;;
      *.xz) xz -cdk "$full_path" > "${archive:t:r}"; rc=$? ;;
      *.lzma) unlzma -c "$full_path" > "${archive:t:r}"; rc=$? ;;
      *.lz4)
        if command -v lz4 >/dev/null 2>&1; then
          lz4 -d "$full_path" "${archive:t:r}" >/dev/null
          rc=$?
        else
          echo "${C_RED}Error: 'lz4' is required for '$archive'.${C_RESET}" >&2
          rc=1
        fi
        ;;
      *.lrz)
        if command -v lrunzip >/dev/null 2>&1; then
          lrunzip "$full_path"
          rc=$?
        else
          echo "${C_RED}Error: lrunzip is required for '$archive'.${C_RESET}" >&2
          rc=1
        fi
        ;;
      *.z) uncompress -c "$full_path" > "${archive:t:r}"; rc=$? ;;
      *.zst) unzstd --stdout "$full_path" > "${archive:t:r}"; rc=$? ;;
      *.zip | *.war | *.jar | *.ear | *.sublime-package | *.ipa | *.ipsw | *.xpi | *.apk | *.aar | *.whl | *.vsix | *.crx | *.pk3 | *.pk4)
        unzip "$full_path"
        rc=$?
        ;;
      *.rar)
        if command -v unrar >/dev/null 2>&1; then
          unrar x -ad "$full_path"
          rc=$?
        elif command -v unar >/dev/null 2>&1; then
          unar -o . "$full_path"
          rc=$?
        else
          echo "${C_RED}Error: Install 'unrar' or 'unar' to extract '$archive'.${C_RESET}" >&2
          rc=1
        fi
        ;;
      *.rpm)
        if command -v rpm2cpio >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
          rpm2cpio "$full_path" | cpio --quiet -id
          rc=$?
        else
          echo "${C_RED}Error: rpm2cpio and cpio are required for '$archive'.${C_RESET}" >&2
          rc=1
        fi
        ;;
      *.7z | *.7z.[0-9]* | *.pk7)
        if command -v 7zz >/dev/null 2>&1; then
          7zz x "$full_path"
          rc=$?
        elif command -v 7z >/dev/null 2>&1; then
          7z x "$full_path"
          rc=$?
        elif command -v 7za >/dev/null 2>&1; then
          7za x "$full_path"
          rc=$?
        else
          echo "${C_RED}Error: Install '7zz', '7z', or '7za' to extract '$archive'.${C_RESET}" >&2
          rc=1
        fi
        ;;
      *.deb)
        if command -v ar >/dev/null 2>&1; then
          command mkdir -p control data &&
            ar vx "$full_path" >/dev/null &&
            (builtin cd -q control && extract ../control.tar.* >/dev/null) &&
            (builtin cd -q data && extract ../data.tar.* >/dev/null) &&
            command rm -f -- ./*.tar.* ./debian-binary
          rc=$?
        else
          echo "${C_RED}Error: 'ar' is required for '$archive'.${C_RESET}" >&2
          rc=1
        fi
        ;;
      *.cab | *.exe)
        if command -v cabextract >/dev/null 2>&1; then
          cabextract "$full_path"
          rc=$?
        else
          echo "${C_RED}Error: 'cabextract' is required for '$archive'.${C_RESET}" >&2
          rc=1
        fi
        ;;
      *.cpio | *.obscpio) cpio -idmvF "$full_path"; rc=$? ;;
      *.zpaq) zpaq x "$full_path"; rc=$? ;;
      *.zlib) zlib-flate -uncompress < "$full_path" > "${archive:r}"; rc=$? ;;
      *)
        echo "${C_RED}Error: Unsupported archive format for '$archive'${C_RESET}" >&2
        rc=1
        ;;
    esac

    # Restore original working directory before post-processing.
    builtin cd -q -- "$pwd"

    if (( rc == 0 )); then
      if (( remove_archive == 1 )); then
        command rm -f -- "$full_path"
      fi
      echo "${C_GREEN}Successfully extracted '$archive'${C_RESET}"
    else
      echo "${C_RED}Error: Extraction failed for '$archive'${C_RESET}" >&2
      had_errors=1
    fi

    # OMZ-style flattening: if extraction produced a single top-level entry,
    # move it up and remove the temporary extraction directory.
    local -a content
    content=("${extract_dir}"/*(DNY2))
    if [[ ${#content} -eq 1 && -e "${content[1]}" ]]; then
      if [[ "${content[1]:t}" == "$extract_dir" ]]; then
        local tmp_name="${extract_dir}.tmp.$$.$RANDOM"
        while [[ -e "$tmp_name" ]]; do
          tmp_name="${extract_dir}.tmp.$$.$RANDOM"
        done
        command mv -- "${content[1]}" "$tmp_name" \
          && command rmdir -- "$extract_dir" \
          && command mv -- "$tmp_name" "$extract_dir"
      elif [[ ! -e "${content[1]:t}" ]]; then
        command mv -- "${content[1]}" . \
          && command rmdir -- "$extract_dir"
      fi
    elif [[ ${#content} -eq 0 ]]; then
      command rmdir -- "$extract_dir" 2>/dev/null || :
    fi
  done

  return $had_errors
}

# OMZ compatibility alias.
alias x='extract'

# -----------------------------------------------------------------------------
# mktar
# @description Creates a tar archive named after a directory.
# @arg $1 path Directory to archive.
# @exitcode 1 If the directory argument is missing or archive creation fails.
# -----------------------------------------------------------------------------
mktar() {
  [[ -z "$1" ]] && { echo "${C_YELLOW}Usage: mktar <directory>${C_RESET}"; return 1; }
  tar -cvf "${1%%/}.tar" "${1%%/}/"
}

# -----------------------------------------------------------------------------
# mkgz
# @description Creates a gzip-compressed tar archive named after a directory.
# @arg $1 path Directory to archive.
# @exitcode 1 If the directory argument is missing or archive creation fails.
# -----------------------------------------------------------------------------
mkgz() {
  [[ -z "$1" ]] && { echo "${C_YELLOW}Usage: mkgz <directory>${C_RESET}"; return 1; }
  tar -czvf "${1%%/}.tar.gz" "${1%%/}/"
}

# -----------------------------------------------------------------------------
# mktbz
# @description Creates a bzip2-compressed tar archive named after a directory.
# @arg $1 path Directory to archive.
# @exitcode 1 If the directory argument is missing or archive creation fails.
# -----------------------------------------------------------------------------
mktbz() {
  [[ -z "$1" ]] && { echo "${C_YELLOW}Usage: mktbz <directory>${C_RESET}"; return 1; }
  tar -cjvf "${1%%/}.tar.bz2" "${1%%/}/"
}

# -----------------------------------------------------------------------------
# mkzip
# @description Creates a ZIP archive named after a directory.
# @arg $1 path Directory to archive.
# @exitcode 1 If the directory argument is missing or archive creation fails.
# -----------------------------------------------------------------------------
mkzip() {
  [[ -z "$1" ]] && { echo "${C_YELLOW}Usage: mkzip <directory>${C_RESET}"; return 1; }
  zip -r "${1%%/}.zip" "${1%%/}/"
}

# -----------------------------------------------------------------------------
# findlarge
# @description Lists files larger than a size threshold, sorted by size.
# @arg $1 integer Optional minimum size in MB; defaults to 100.
# @arg $2 path Optional directory to scan; defaults to the current directory.
# @exitcode 1 If the size argument is not numeric.
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
# @description Displays a .gitignore-aware directory tree using eza or tree.
# @arg $1 path Optional directory to display; defaults to the current directory.
# @exitcode 1 If neither eza nor tree is installed.
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
# @description Counts files, directories, symlinks, and hidden entries.
# Recursive mode scans to depth 5; root scanning requires explicit '/'.
# @arg $1 path Optional directory to inspect; defaults to the current directory.
# @option -r | --recursive Scan recursively to a maximum depth of 5.
# @option -a | --all Include symlinks even when none are found.
# @option -h | --help Show usage information.
# @exitcode 1 If options are invalid or the target cannot be scanned.
# -----------------------------------------------------------------------------
function count() {
  emulate -L zsh
  setopt localoptions pipefail
  _zsh_ui_load || return 1

  local target="."
  local recursive=0
  local show_all=0
  local max_depth=1
  local target_seen=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r | --recursive) recursive=1; max_depth=5; shift ;;
      -a | --all) show_all=1; shift ;;
      -h | --help)
        print -rl -- \
          "Usage: count [directory] [options]" \
          "" \
          "Options:" \
          "  -r, --recursive  Count recursively (max depth: 5)" \
          "  -a, --all        Show all item types including symlinks" \
          "  -h, --help       Show this help message" \
          "" \
          "Examples:" \
          "  count              Count items in current directory" \
          "  count /tmp         Count items in /tmp" \
          "  count -r           Count recursively" \
          "  count -a /var/log  Count all types in /var/log"
        return 0 ;;
      -*)
        _zsh_ui_log error "Unknown option '$1'. Run 'count --help'."
        return 1 ;;
      *)
        if (( target_seen )); then
          _zsh_ui_log error "Only one target directory can be counted."
          return 1
        fi
        target="$1"
        target_seen=1
        shift
        ;;
    esac
  done

  # Validate target exists before proceeding.
  if [[ ! -e "$target" ]]; then
    _zsh_ui_log error "'$target' does not exist."
    return 1
  fi

  if [[ ! -d "$target" ]]; then
    _zsh_ui_log error "'$target' is not a directory."
    return 1
  fi

  if [[ ! -r "$target" ]]; then
    _zsh_ui_log error "No read permission for '$target'."
    return 1
  fi

  # Convert target to absolute canonical path.
  # The -P flag resolves all symbolic links in the path to their real locations.
  local canonical_path
  canonical_path="$(cd -P "$target" 2>/dev/null && pwd)" || {
    _zsh_ui_log error "Cannot access '$target'."
    return 1
  }

  # Require explicit '/' argument when scanning root to prevent accidents.
  if [[ "$target" == "." && "$canonical_path" == "/" ]]; then
    _zsh_ui_log error \
      "Refusing an implicit root scan; pass '/' explicitly if intended."
    return 1
  fi

  # Initialize counters for different item types.
  local files=0 dirs=0 hidden=0 symlinks=0 total=0

  # Stream find output via -print0 to avoid ARG_MAX limits on huge directories
  # and to handle filenames with newlines/spaces safely. Capture stderr to a
  # temp file so we can report permission errors instead of silently swallowing
  # them. BSD find (macOS) has no -printf, so we test each entry's type in zsh.
  local item err_file
  err_file="$(command mktemp -t count-err.XXXXXX 2>/dev/null)" || err_file=""

  {
    if [[ -n "$err_file" ]]; then
      while IFS= read -r -d '' item; do
        if [[ -L "$item" ]]; then
          ((symlinks++))
        elif [[ -f "$item" ]]; then
          ((files++))
        elif [[ -d "$item" ]]; then
          ((dirs++))
        fi
      done < <(command find "$canonical_path" -mindepth 1 \
        -maxdepth "$max_depth" -print0 2>"$err_file")
    else
      while IFS= read -r -d '' item; do
        if [[ -L "$item" ]]; then
          ((symlinks++))
        elif [[ -f "$item" ]]; then
          ((files++))
        elif [[ -d "$item" ]]; then
          ((dirs++))
        fi
      done < <(command find "$canonical_path" -mindepth 1 \
        -maxdepth "$max_depth" -print0 2>/dev/null)
    fi

    while IFS= read -r -d '' item; do
      ((hidden++))
    done < <(command find "$canonical_path" -mindepth 1 \
      -maxdepth "$max_depth" -name '.*' -print0 2>/dev/null)

    if [[ -n "$err_file" && -s "$err_file" ]]; then
      local err_lines
      err_lines="$(command wc -l <"$err_file" 2>/dev/null | tr -d ' ')"
      _zsh_ui_log warn \
        "${err_lines:-Some} entries could not be scanned due to permissions."
    fi
  } always {
    [[ -n "$err_file" ]] &&
      command rm -f -- "$err_file" 2>/dev/null
  }

  # Calculate total.
  total=$((files + dirs + symlinks))

  local scope="Non-recursive"
  (( recursive )) && scope="Recursive · max depth $max_depth"
  _zsh_ui_sanitize_text "$canonical_path"
  local display_path="$REPLY"
  local -a summary=(
    "Location     $display_path"
    ""
    "Files        $files"
    "Directories  $dirs"
  )
  (( show_all || symlinks > 0 )) && summary+=("Symlinks     $symlinks")
  summary+=("Hidden       $hidden" "Total        $total")
  _zsh_ui_card "Directory count · $scope" "${summary[@]}"
}
# -----------------------------------------------------------------------------
# dirsize
# @description Delegates directory-size analysis to the repository's
# Python helper.
# @arg $@ string Optional directory and options forwarded to the dirsize helper.
# @exitcode 1 If the helper script is missing or the delegated command fails.
# -----------------------------------------------------------------------------
function dirsize() {
  emulate -L zsh
  setopt localoptions no_aliases pipefail
  _zsh_ui_load || return 1

  local python_script="$ZSH_CONFIG_DIR/scripts/python/dirsize.py"

  if [[ ! -f "$python_script" ]]; then
    _zsh_ui_log error "Directory-size backend not found: $python_script"
    return 1
  fi
  if ! (( $+commands[python3] )); then
    _zsh_ui_log error "Python 3 is required for directory-size analysis."
    return 1
  fi

  command python3 "$python_script" "$@"
}

# Create alias for dirsize.
alias ds='dirsize'

# ============================================================================ #
# End of files.zsh
