#!/bin/zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++++ USEFUL FUNCTIONS +++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# This file contains a collection of useful Zsh functions for daily workflow:
#   - Weather information and public IP lookups
#   - File and archive management utilities
#   - Interactive tools with fzf integration
#   - Git helpers and stash management
#   - Network utilities and port scanning
#   - Docker container access
#   - Note-taking and directory bookmarks
#   - System information and cleanup
#
# Each function includes comprehensive error handling, input validation, and
# colored output for better user experience.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# weather
# -----------------------------------------------------------------------------
# Get weather information for a specified location using wttr.in service.
# Implements caching (1 hour) to reduce API calls and improve performance.
#
# Usage:
#   weather [city]
#
# Arguments:
#   city - Location name (default: Bari)
#
# Returns:
#   0 - Weather data fetched or retrieved from cache.
#   1 - Network error and no cached data available.
# -----------------------------------------------------------------------------
function weather() {
    local location="${1:-Bari}"
    local cache_file="/tmp/weather_${location}.cache"
    local current_time=$(date +%s)
    local cache_age=3600 # 1 hour cache

    # Check if cache exists and is fresh
    if [[ -f "$cache_file" ]]; then
        local file_time=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
        if [[ $((current_time - file_time)) -lt $cache_age ]]; then
            cat "$cache_file"
            return 0
        fi
    fi

    # Fetch new data
    if curl -s --fail --connect-timeout 5 "https://wttr.in/${location}?lang=it" >"$cache_file"; then
        cat "$cache_file"
    else
        echo "${C_RED}Error: Unable to fetch weather data. Check your internet connection.${C_RESET}" >&2
        # If fetch fails but we have old cache, show it with a warning
        if [[ -f "$cache_file" ]]; then
            echo "${C_YELLOW}(Showing cached data)${C_RESET}"
            cat "$cache_file"
        else
            rm -f "$cache_file"
            return 1
        fi
    fi
}

# -----------------------------------------------------------------------------
# bak
# -----------------------------------------------------------------------------
# Create a timestamped backup of a file in the same directory.
# The backup file will have the format: original.YYYY-MM-DD_HH-MM-SS.bak
#
# Usage:
#   bak <file>
#
# Arguments:
#   file - Path to the file to backup (required)
#
# Returns:
#   0 - Backup created successfully.
#   1 - File not found or backup creation failed.
# -----------------------------------------------------------------------------
function bak() {
    if [[ $# -eq 0 ]]; then
        echo "${C_YELLOW}Usage: bak <file>${C_RESET}" >&2
        return 1
    fi

    if [[ -f "$1" ]]; then
        local backup_file="${1}.$(date +'%Y-%m-%d_%H-%M-%S').bak"
        if cp -p "$1" "$backup_file" 2>/dev/null; then
            echo "${C_GREEN}Backup created: ${backup_file}${C_RESET}"
        else
            echo "${C_RED}Error: Failed to create backup.${C_RESET}" >&2
            return 1
        fi
    else
        echo "${C_RED}Error: File '$1' not found.${C_RESET}" >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# fkill
# -----------------------------------------------------------------------------
# Interactively find and kill processes using fzf for selection.
# Allows multi-selection and sends specified signal to selected processes.
#
# Usage:
#   fkill [signal]
#
# Arguments:
#   signal - Signal number to send (default: 15/SIGTERM)
#
# Returns:
#   0 - Process(es) killed successfully or no selection made.
#   1 - fzf not available or kill operation failed.
# -----------------------------------------------------------------------------
function fkill() {
    if ! command -v fzf >/dev/null 2>&1; then
        echo "${C_RED}Error: fzf is required for this function.${C_RESET}" >&2
        return 1
    fi

    local pid
    # Use ps to get processes, pipe to fzf for selection, and awk to get the PID.
    # Added -r to read to prevent backslash interpretation
    pid=$(ps -ef | sed 1d | fzf -m --tac --header='Select process(es) to kill. Press CTRL-C to cancel' | awk '{print $2}')

    if [[ -n "$pid" ]]; then
        # Kill the selected process(es) with SIGTERM (15) by default, or specified signal.
        local signal="${1:-15}"
        # Use quotes to handle multiple PIDs correctly
        echo "$pid" | xargs kill -"${signal}" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            echo "${C_GREEN}Process(es) with PID(s): $pid killed with signal ${signal}.${C_RESET}"
        else
            echo "${C_RED}Error: Failed to kill some processes. Try with sudo.${C_RESET}" >&2
            return 1
        fi
    else
        echo "${C_YELLOW}No process selected.${C_RESET}"
    fi
}

# -----------------------------------------------------------------------------
# serve
# -----------------------------------------------------------------------------
# Start a simple HTTP server in the current directory using Python.
# Supports both local-only and public access modes with port validation.
#
# Usage:
#   serve [port] [--public]
#
# Arguments:
#   port     - Port number (default: 8000, range: 1-65535)
#   --public - Bind to 0.0.0.0 instead of 127.0.0.1 for network access
#
# Returns:
#   0 - Server started successfully.
#   1 - Invalid arguments or Python not available.
# -----------------------------------------------------------------------------
function serve() {
    local port="8000"
    local bind_address="127.0.0.1"
    local public_mode=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --public)
            public_mode=true
            bind_address="0.0.0.0"
            shift
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                port="$1"
            else
                echo "${C_RED}Error: Invalid argument '$1'. Usage: serve [port] [--public]${C_RESET}" >&2
                return 1
            fi
            shift
            ;;
        esac
    done

    # Validate port number.
    if [[ $port -lt 1 || $port -gt 65535 ]]; then
        echo "${C_RED}Error: Invalid port number. Use a number between 1 and 65535.${C_RESET}" >&2
        return 1
    fi

    # Check if port is already in use.
    if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo "${C_YELLOW}Warning: Port $port is already in use.${C_RESET}" >&2
        echo -n "Choose another port or press Enter to continue anyway: "
        read -r new_port
        if [[ -n "$new_port" ]]; then
            port="$new_port"
        fi
    fi

    local url_msg
    if [[ "$public_mode" == true ]]; then
        local ip=$(ipconfig getifaddr en0 2>/dev/null || hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")
        url_msg="http://${ip}:${port} (Public)"
    else
        url_msg="http://localhost:${port} (Local only)"
    fi

    echo "${C_CYAN}Serving current directory on ${url_msg}${C_RESET}"
    echo "${C_CYAN}Press Ctrl+C to stop the server${C_RESET}"

    # Python 3.
    if command -v python3 &>/dev/null; then
        python3 -m http.server "$port" --bind "$bind_address"
        return
    fi
    # Python 2 (fallback).
    if command -v python &>/dev/null; then
        if [[ "$public_mode" == true ]]; then
            python -m SimpleHTTPServer "$port"
        else
            # Python 2 SimpleHTTPServer doesn't support --bind easily without a custom script
            echo "${C_YELLOW}Warning: Python 2 SimpleHTTPServer binds to all interfaces by default.${C_RESET}"
            python -m SimpleHTTPServer "$port"
        fi
        return
    fi

    echo "${C_RED}Error: Python not found. Cannot start server.${C_RESET}" >&2
    return 1
}

# -----------------------------------------------------------------------------
# portscan
# -----------------------------------------------------------------------------
# Simple port scanner for a specified host using netcat or bash /dev/tcp.
# Scans a range of ports and reports which ones are open.
#
# Usage:
#   portscan <host> [start_port] [end_port]
#
# Arguments:
#   host       - Target hostname or IP address (required)
#   start_port - Starting port number (default: 1)
#   end_port   - Ending port number (default: 1000)
#
# Returns:
#   0 - Scan completed successfully.
#   1 - Invalid arguments.
# -----------------------------------------------------------------------------
function portscan() {
    if [[ $# -lt 1 ]]; then
        echo "${C_YELLOW}Usage: portscan <host> [start_port] [end_port]${C_RESET}" >&2
        echo "Default range: 1-1000" >&2
        return 1
    fi

    local host="$1"
    local start_port="${2:-1}"
    local end_port="${3:-1000}"

    # Validate port numbers.
    if ! [[ "$start_port" =~ ^[0-9]+$ ]] || ! [[ "$end_port" =~ ^[0-9]+$ ]]; then
        echo "${C_RED}Error: Port numbers must be positive integers.${C_RESET}" >&2
        return 1
    fi

    echo "${C_CYAN}Scanning ports $start_port-$end_port on $host...${C_RESET}"

    # Use nc (netcat) if available for faster scanning
    if command -v nc >/dev/null 2>&1; then
        # -z: zero-I/O mode (scanning)
        # -v: verbose (to see output)
        # -w 1: timeout 1 second
        nc -z -v -w 1 "$host" "$start_port"-"$end_port" 2>&1 | grep "succeeded" | sed "s/^/${C_GREEN}/;s/$/${C_RESET}/"
    else
        # Fallback to pure bash/zsh method
        for port in $(seq "$start_port" "$end_port"); do
            (echo >/dev/tcp/"$host"/"$port") &>/dev/null && echo "${C_GREEN}Port $port: OPEN${C_RESET}"
        done
    fi
}

# -----------------------------------------------------------------------------
# preview
# -----------------------------------------------------------------------------
# Interactively preview and select files using fzf with bat/eza integration.
# Shows directory tree for folders and syntax-highlighted content for files.
#
# Usage:
#   preview
#
# Returns:
#   0 - File selected or preview exited.
#   1 - fzf not available.
# -----------------------------------------------------------------------------
function preview() {
    if ! command -v fzf >/dev/null 2>&1; then
        echo "${C_RED}Error: fzf is required for this function.${C_RESET}" >&2
        return 1
    fi

    # Use eza for directory listings, bat for file previews.
    fzf --preview '
    if [ -d {} ]; then
      command -v eza >/dev/null 2>&1 && eza --tree --color=always {} || ls -la {}
    else
      command -v bat >/dev/null 2>&1 && bat --color=always --style=numbers --line-range=:200 {} || head -200 {}
    fi'
}

# -----------------------------------------------------------------------------
# mktar, mkgz, mktbz, mkzip
# -----------------------------------------------------------------------------
# Quick helpers to create different types of compressed archives from directories.
#
# Usage:
#   mktar <directory>  - Create .tar archive
#   mkgz <directory>   - Create .tar.gz archive
#   mktbz <directory>  - Create .tar.bz2 archive
#   mkzip <directory>  - Create .zip archive
#
# Arguments:
#   directory - Path to directory to archive (required)
#
# Returns:
#   0 - Archive created successfully.
#   1 - No directory specified.
# -----------------------------------------------------------------------------
mktar() {
    [[ -z "$1" ]] && {
        echo "${C_YELLOW}Usage: mktar <directory>${C_RESET}"
        return 1
    }
    tar -cvf "${1%%/}.tar" "${1%%/}/"
}

mkgz() {
    [[ -z "$1" ]] && {
        echo "${C_YELLOW}Usage: mkgz <directory>${C_RESET}"
        return 1
    }
    tar -czvf "${1%%/}.tar.gz" "${1%%/}/"
}

mktbz() {
    [[ -z "$1" ]] && {
        echo "${C_YELLOW}Usage: mktbz <directory>${C_RESET}"
        return 1
    }
    tar -cjvf "${1%%/}.tar.bz2" "${1%%/}/"
}

mkzip() {
    [[ -z "$1" ]] && {
        echo "${C_YELLOW}Usage: mkzip <directory>${C_RESET}"
        return 1
    }
    zip -r "${1%%/}.zip" "${1%%/}/"
}

# -----------------------------------------------------------------------------
# extract
# -----------------------------------------------------------------------------
# Universal extraction function supporting multiple archive formats.
# Automatically detects archive type by extension and uses appropriate tool.
#
# Supported formats:
#   .tar.bz2, .tbz2, .tar.gz, .tgz, .tar.xz, .txz, .tar, .bz2,
#   .rar, .gz, .zip, .Z, .7z, .xz
#
# Usage:
#   extract <archive>
#
# Arguments:
#   archive - Path to archive file (required)
#
# Returns:
#   0 - Extraction successful.
#   1 - File not found, unsupported format, or extraction failed.
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
# findlarge
# -----------------------------------------------------------------------------
# Find and list files larger than specified size in a directory tree.
# Results are sorted by size in descending order (largest first).
#
# Usage:
#   findlarge [size_in_MB] [directory]
#
# Arguments:
#   size_in_MB - Minimum file size in megabytes (default: 100)
#   directory  - Directory to search in (default: current directory)
#
# Returns:
#   0 - Search completed successfully.
#   1 - Invalid size parameter.
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
# gbr
# -----------------------------------------------------------------------------
# Show local git branches sorted by most recent commit date.
# Displays branch name, commit hash, subject, author, and relative date.
#
# Usage:
#   gbr
#
# Returns:
#   0 - Branch list displayed successfully.
#   1 - Not in a git repository.
# -----------------------------------------------------------------------------
function gbr() {
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "${C_RED}Error: Not in a git repository.${C_RESET}" >&2
        return 1
    fi

    git for-each-ref \
        --sort=-committerdate refs/heads/ \
        --format='%(HEAD) %(color:yellow)%(refname:short)%(color:reset) - \
        %(color:red)%(objectname:short)%(color:reset) - %(contents:subject) - \
        %(authorname) (%(color:green)%(committerdate:relative)%(color:reset))'
}

# -----------------------------------------------------------------------------
# gstash
# -----------------------------------------------------------------------------
# Interactive git stash management using fzf for selection.
# Preview shows the diff for each stash entry before applying.
#
# Usage:
#   gstash
#
# Returns:
#   0 - Stash applied successfully or no selection made.
#   1 - Not in git repository or fzf not available.
# -----------------------------------------------------------------------------
function gstash() {
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "${C_RED}Error: Not in a git repository.${C_RESET}" >&2
        return 1
    fi

    if ! command -v fzf >/dev/null 2>&1; then
        echo "${C_RED}Error: fzf is required for this function.${C_RESET}" >&2
        return 1
    fi

    local stash
    stash=$(git stash list | fzf --preview 'git stash show -p $(echo {} | cut -d: -f1)' \
        --header='Select stash to apply. Press CTRL-C to cancel')

    if [[ -n "$stash" ]]; then
        local stash_id=$(echo "$stash" | cut -d: -f1)
        echo "${C_CYAN}Applying stash: $stash_id${C_RESET}"
        git stash apply "$stash_id"
    fi
}

# -----------------------------------------------------------------------------
# note
# -----------------------------------------------------------------------------
# Quick note-taking function with automatic timestamping and monthly organization.
# Notes are stored in markdown format in monthly files.
#
# Usage:
#   note [text]           - Add note with text as arguments
#   note                  - Interactive mode (Ctrl+D to finish)
#
# Environment:
#   NOTES_DIR - Custom notes directory (default: ~/.notes)
#
# Returns:
#   0 - Note saved successfully.
# -----------------------------------------------------------------------------
function note() {
    local notes_dir="${NOTES_DIR:-$HOME/.notes}"
    local notes_file="$notes_dir/notes_$(date +'%Y-%m').md"

    # Create notes directory if it doesn't exist.
    [[ ! -d "$notes_dir" ]] && mkdir -p "$notes_dir"

    local timestamp="$(date +'%Y-%m-%d %H:%M:%S')"

    if [[ $# -eq 0 ]]; then
        # Interactive mode.
        echo "${C_CYAN}Enter note (Ctrl+D to finish):${C_RESET}"
        local note_content
        note_content=$(cat)
        if [[ -n "$note_content" ]]; then
            echo -e "\n## $timestamp\n$note_content" >>"$notes_file"
            echo "${C_GREEN}Note saved to $notes_file${C_RESET}"
        fi
    else
        # Quick mode with arguments.
        echo -e "\n## $timestamp\n$*" >>"$notes_file"
        echo "${C_GREEN}Note saved to $notes_file${C_RESET}"
    fi
}

# -----------------------------------------------------------------------------
# dshell
# -----------------------------------------------------------------------------
# Interactively access shell in a running Docker container using fzf.
# Attempts to use bash, falls back to sh if not available.
#
# Usage:
#   dshell
#
# Returns:
#   0 - Shell session completed successfully.
#   1 - Docker or fzf not available, or no container selected.
# -----------------------------------------------------------------------------
function dshell() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "${C_RED}Error: Docker is not installed.${C_RESET}" >&2
        return 1
    fi

    if ! command -v fzf >/dev/null 2>&1; then
        echo "${C_RED}Error: fzf is required for this function.${C_RESET}" >&2
        return 1
    fi

    local container
    container=$(docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}" |
        fzf --header-lines=1 --header='Select container for shell access' |
        awk '{print $1}')

    if [[ -n "$container" ]]; then
        echo "${C_CYAN}Accessing shell in container: $container${C_RESET}"
        docker exec -it "$container" sh -c 'bash || sh'
    fi
}

# -----------------------------------------------------------------------------
# shorten
# -----------------------------------------------------------------------------
# Shorten URL using is.gd service and optionally copy to clipboard.
# Automatically adds https:// prefix if missing.
#
# Usage:
#   shorten <url>
#
# Arguments:
#   url - URL to shorten (required)
#
# Returns:
#   0 - URL shortened and copied to clipboard (if available).
#   1 - No URL provided or shortening failed.
# -----------------------------------------------------------------------------
function shorten() {
    if [[ $# -eq 0 ]]; then
        echo "${C_YELLOW}Usage: shorten <url>${C_RESET}" >&2
        return 1
    fi

    local url="$1"
    local short_url

    # Basic URL validation.
    if [[ ! "$url" =~ ^https?:// ]]; then
        echo "${C_YELLOW}Warning: URL should start with http:// or https://${C_RESET}"
        url="https://$url"
    fi

    short_url=$(curl -s "https://is.gd/create.php?format=simple&url=$(printf '%s' "$url" | jq -sRr @uri)" 2>/dev/null)

    if [[ -n "$short_url" ]]; then
        echo "${C_GREEN}Short URL: $short_url${C_RESET}"
        # Copy to clipboard if possible.
        if command -v pbcopy >/dev/null 2>&1; then
            echo -n "$short_url" | pbcopy
            echo "${C_BLUE}Copied to clipboard!${C_RESET}"
        elif command -v xclip >/dev/null 2>&1; then
            echo -n "$short_url" | xclip -selection clipboard
            echo "${C_BLUE}Copied to clipboard!${C_RESET}"
        fi
    else
        echo "${C_RED}Error: Failed to shorten URL.${C_RESET}" >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# sysinfo
# -----------------------------------------------------------------------------
# Display comprehensive system information including OS, CPU, memory, disk,
# network interfaces, and uptime. Platform-aware (macOS/Linux).
#
# Usage:
#   sysinfo
#
# Returns:
#   0 - System information displayed successfully.
# -----------------------------------------------------------------------------
function sysinfo() {
    echo "${C_CYAN}/===----------- System Information -----------===/${C_RESET}"

    # OS Information.
    echo "${C_YELLOW}OS:${C_RESET}"
    if [[ "$PLATFORM" == "macOS" ]]; then
        sw_vers
    elif [[ "$PLATFORM" == "Linux" ]]; then
        if [[ -f /etc/os-release ]]; then
            . /etc/os-release
            echo "  $NAME $VERSION"
        fi
        uname -a
    fi

    # CPU Information.
    echo -e "\n${C_YELLOW}CPU:${C_RESET}"
    if [[ "$PLATFORM" == "macOS" ]]; then
        sysctl -n machdep.cpu.brand_string
        echo "  Cores: $(sysctl -n hw.ncpu)"
    elif [[ "$PLATFORM" == "Linux" ]]; then
        grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2
        echo "  Cores: $(nproc)"
    fi

    # Memory Information.
    echo -e "\n${C_YELLOW}Memory:${C_RESET}"
    if [[ "$PLATFORM" == "macOS" ]]; then
        local total_mem=$(($(sysctl -n hw.memsize) / 1024 / 1024 / 1024))
        echo "  Total: ${total_mem}GB"
    elif [[ "$PLATFORM" == "Linux" ]]; then
        free -h | grep "^Mem:" | awk '{print "  Total: " $2 ", Used: " $3 ", Free: " $4}'
    fi

    # Disk Information.
    echo -e "\n${C_YELLOW}Disk Usage:${C_RESET}"
    df -h | grep -E "^/dev/" | awk '{print "  " $1 ": " $5 " used (" $4 " free)"}'

    # Network Information.
    echo -e "\n${C_YELLOW}Network:${C_RESET}"
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk '{print "  " $2}'
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print "  " $2}'
    fi

    # Uptime.
    echo -e "\n${C_YELLOW}Uptime:${C_RESET}"
    uptime
}

# -----------------------------------------------------------------------------
# bm
# -----------------------------------------------------------------------------
# Simple bookmark system for directories with add/delete/list/jump operations.
# Bookmarks are stored in ~/.directory_bookmarks
#
# Usage:
#   bm add <name>    - Bookmark current directory
#   bm del <name>    - Delete bookmark
#   bm list          - List all bookmarks (default)
#   bm <name>        - Jump to bookmarked directory
#
# Arguments:
#   action - Operation to perform (add|del|list|<name>)
#   name   - Bookmark name (for add/del/jump)
#
# Returns:
#   0 - Operation completed successfully.
#   1 - Invalid usage or bookmark not found.
# -----------------------------------------------------------------------------
function bm() {
    local bookmarks_file="$HOME/.directory_bookmarks"
    local action="${1:-list}"
    local name="$2"

    case "$action" in
    add)
        if [[ -z "$name" ]]; then
            echo "${C_YELLOW}Usage: bm add <name>${C_RESET}" >&2
            return 1
        fi
        local current_dir="$(pwd)"
        echo "$name=$current_dir" >>"$bookmarks_file"
        echo "${C_GREEN}Bookmark '$name' added for $current_dir${C_RESET}"
        ;;

    del)
        if [[ -z "$name" ]]; then
            echo "${C_YELLOW}Usage: bm del <name>${C_RESET}" >&2
            return 1
        fi
        if [[ -f "$bookmarks_file" ]]; then
            grep -v "^$name=" "$bookmarks_file" >"${bookmarks_file}.tmp"
            mv "${bookmarks_file}.tmp" "$bookmarks_file"
            echo "${C_GREEN}Bookmark '$name' deleted${C_RESET}"
        fi
        ;;

    list)
        if [[ -f "$bookmarks_file" ]]; then
            echo "${C_CYAN}Directory Bookmarks:${C_RESET}"
            while IFS='=' read -r name dir; do
                echo "  ${C_YELLOW}$name${C_RESET} → $dir"
            done <"$bookmarks_file"
        else
            echo "${C_YELLOW}No bookmarks found.${C_RESET}"
        fi
        ;;

    *)
        # Try to jump to bookmark.
        if [[ -f "$bookmarks_file" ]]; then
            local dir=$(grep "^$action=" "$bookmarks_file" | cut -d= -f2-)
            if [[ -n "$dir" ]]; then
                cd "$dir"
                echo "${C_GREEN}Jumped to bookmark '$action': $(pwd)${C_RESET}"
            else
                echo "${C_RED}Error: Bookmark '$action' not found.${C_RESET}" >&2
                return 1
            fi
        else
            echo "${C_RED}Error: No bookmarks file found.${C_RESET}" >&2
            return 1
        fi
        ;;
    esac
}

# -----------------------------------------------------------------------------
# cleanup
# -----------------------------------------------------------------------------
# Clean various temporary and cache files across the system.
# Supports dry-run mode to preview what will be deleted.
#
# Cleaned locations:
#   - System temp directories (/tmp, /private/var/tmp)
#   - User caches (~/.cache, ~/Library/Caches on macOS)
#   - Package manager caches (npm, yarn)
#
# Usage:
#   cleanup [--dry-run]
#
# Arguments:
#   --dry-run - Show what would be deleted without actually removing files
#
# Returns:
#   0 - Cleanup completed successfully.
# -----------------------------------------------------------------------------
function cleanup() {
    local dry_run=false
    [[ "$1" == "--dry-run" ]] && dry_run=true

    echo "${C_CYAN}Cleaning temporary files...${C_RESET}"

    local total_size=0
    local files_to_clean=()

    # Add directories to clean based on platform.
    if [[ "$PLATFORM" == "macOS" ]]; then
        files_to_clean+=(
            "$HOME/Library/Caches/*"
            "$HOME/.Trash/*"
            "/private/var/tmp/*"
        )
    fi

    # Common directories for all platforms.
    files_to_clean+=(
        "/tmp/*"
        "$HOME/.cache/*"
        "$HOME/.npm/_cacache/*"
        "$HOME/.yarn/cache/*"
    )

    if [[ "$dry_run" == true ]]; then
        echo "${C_YELLOW}DRY RUN - No files will be deleted${C_RESET}"
        for pattern in "${files_to_clean[@]}"; do
            if ls $pattern >/dev/null 2>&1; then
                du -sh $pattern 2>/dev/null | while read size path; do
                    echo "  Would remove: $path ($size)"
                done
            fi
        done
    else
        for pattern in "${files_to_clean[@]}"; do
            if ls $pattern >/dev/null 2>&1; then
                rm -rf $pattern 2>/dev/null
            fi
        done
        echo "${C_GREEN}Cleanup completed!${C_RESET}"
    fi
}

# -----------------------------------------------------------------------------
# clang_format_link
# -----------------------------------------------------------------------------
# Create a symbolic link to the global .clang-format configuration file
# in the current directory. Prompts before overwriting existing files.
#
# Usage:
#   clang_format_link
#
# Returns:
#   0 - Symbolic link created successfully or operation cancelled.
#   1 - Global config file not found or link creation failed.
# -----------------------------------------------------------------------------
function clang_format_link() {
    local config_file="$HOME/.config/clang-format/.clang-format"
    local target_file="./.clang-format"

    # Check if global config file exists.
    if [[ ! -f "$config_file" ]]; then
        echo "${C_RED}Error: Global .clang-format file not found at '$config_file'${C_RESET}" >&2
        return 1
    fi

    # Check if target already exists.
    if [[ -e "$target_file" ]]; then
        if [[ -L "$target_file" ]]; then
            local current_target=$(readlink "$target_file")
            if [[ "$current_target" == "$config_file" ]]; then
                echo "${C_YELLOW}Symbolic link already exists and points to the correct file.${C_RESET}"
                return 0
            else
                echo "${C_YELLOW}Symbolic link exists but points to: $current_target${C_RESET}"
            fi
        else
            echo "${C_YELLOW}File '.clang-format' already exists in current directory.${C_RESET}"
        fi

        echo -n "${C_YELLOW}Replace existing file/link? (y/N): ${C_RESET}"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "${C_CYAN}Operation cancelled.${C_RESET}"
            return 0
        fi

        rm -f "$target_file"
    fi

    # Create the symbolic link.
    echo "${C_CYAN}Creating symbolic link to .clang-format configuration...${C_RESET}"

    if ln -s "$config_file" "$target_file" 2>/dev/null; then
        echo "${C_GREEN}✓ Successfully created symbolic link: .clang-format → $config_file${C_RESET}"

        # Show the link details.
        if command -v ls >/dev/null 2>&1; then
            ls -la "$target_file"
        fi
    else
        echo "${C_RED}Error: Failed to create symbolic link.${C_RESET}" >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# mkcd
# -----------------------------------------------------------------------------
# Create a directory (including parent directories) and change into it.
# Combines mkdir -p and cd in one convenient command.
#
# Usage:
#   mkcd <directory>
#
# Arguments:
#   directory - Path to directory to create and enter (required)
#
# Returns:
#   0 - Directory created and changed successfully.
#   1 - No directory specified or operation failed.
# -----------------------------------------------------------------------------
function mkcd() {
    if [[ -z "$1" ]]; then
        echo "${C_YELLOW}Usage: mkcd <directory>${C_RESET}" >&2
        return 1
    fi
    mkdir -p "$1" && cd "$1" || return 1
}

# -----------------------------------------------------------------------------
# up
# -----------------------------------------------------------------------------
# Navigate up N directories in the filesystem hierarchy.
# Provides quick traversal without typing multiple '../' sequences.
#
# Usage:
#   up [n]
#
# Arguments:
#   n - Number of directories to go up (default: 1)
#
# Returns:
#   0 - Navigation successful.
#   1 - Invalid argument or cannot go up specified levels.
# -----------------------------------------------------------------------------
function up() {
    local d=""
    local limit="${1:-1}"

    # Validate input
    if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
        echo "${C_RED}Error: Argument must be a positive integer.${C_RESET}" >&2
        return 1
    fi

    for ((i = 1; i <= limit; i++)); do
        d="../$d"
    done

    # Perform cd
    if ! cd "$d"; then
        echo "${C_RED}Error: Cannot go up $limit directories.${C_RESET}" >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# myip
# -----------------------------------------------------------------------------
# Get public IP address and geolocation information using ipinfo.io service.
# Displays IP, city, region, country, and ISP organization.
#
# Usage:
#   myip
#
# Returns:
#   0 - IP information fetched successfully.
# -----------------------------------------------------------------------------
function myip() {
    echo "${C_CYAN}Fetching public IP info...${C_RESET}"
    curl -s "https://ipinfo.io/json" |
        grep -E '"ip"|"city"|"region"|"country"|"org"' |
        sed 's/^  //;s/[",]//g' |
        awk -F: -v color="${C_GREEN}" -v reset="${C_RESET}" '{printf "%s%s%s%s\n", $1 ":", color, $2, reset}'
}

# -----------------------------------------------------------------------------
# cheat
# -----------------------------------------------------------------------------
# Get a cheat sheet for a command using cheat.sh service.
# Displays practical examples and common usage patterns.
#
# Usage:
#   cheat <command>
#
# Arguments:
#   command - Command name to get cheat sheet for (required)
#
# Returns:
#   0 - Cheat sheet displayed successfully.
#   1 - No command specified.
# -----------------------------------------------------------------------------
function cheat() {
    if [[ -z "$1" ]]; then
        echo "${C_YELLOW}Usage: cheat <command>${C_RESET}" >&2
        return 1
    fi
    curl -s "cheat.sh/$1" | less -R
}

# -----------------------------------------------------------------------------
# tre
# -----------------------------------------------------------------------------
# Display directory tree view respecting .gitignore rules.
# Uses eza if available, falls back to tree command.
#
# Usage:
#   tre [directory]
#
# Arguments:
#   directory - Directory to display tree for (default: current directory)
#
# Returns:
#   0 - Tree displayed successfully.
#   1 - Neither eza nor tree available.
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
# qr
# -----------------------------------------------------------------------------
# Generate a QR code in the terminal using qrenco.de service.
# Useful for quickly sharing text, URLs, or WiFi credentials.
#
# Usage:
#   qr <text>
#
# Arguments:
#   text - Text or URL to encode in QR code (required)
#
# Returns:
#   0 - QR code generated successfully.
#   1 - No text provided.
# -----------------------------------------------------------------------------
function qr() {
    if [[ -z "$1" ]]; then
        echo "${C_YELLOW}Usage: qr <text>${C_RESET}" >&2
        return 1
    fi
    curl -sF-="\<-" qrenco.de <<<"$1"
}

# ============================================================================ #
# End of script.
