#!/bin/zsh

# ============================================================================ #
# +++++++++++++++++++++++++++++ USEFUL FUNCTIONS +++++++++++++++++++++++++++++ #
# ============================================================================ #

# ----------------------------- Weather Forecast ----------------------------- #
# Get weather information for a specified location.
# Usage: weather <city> (e.g., weather Rome).
function weather() {
    local location="${1:-Bari}" # Default to Bari if no location is provided.
    # Add error handling for network issues.
    if ! curl -s --fail --connect-timeout 5 "https://wttr.in/${location}?lang=it" 2>/dev/null; then
        echo "${C_RED}Error: Unable to fetch weather data. Check your internet connection.${C_RESET}" >&2
        return 1
    fi
}

# ------------------------------- Quick Backup ------------------------------- #
# Create a timestamped backup of a file.
# Usage: bak <file>
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

# ------------------------ Interactive Process Killer ------------------------ #
# Interactively find and kill processes using fzf.
# Usage: fkill [signal]
function fkill() {
    if ! command -v fzf >/dev/null 2>&1; then
        echo "${C_RED}Error: fzf is required for this function.${C_RESET}" >&2
        return 1
    fi

    local pid
    # Use ps to get processes, pipe to fzf for selection, and awk to get the PID.
    pid=$(ps -ef | sed 1d | fzf -m --tac --header='Select process(es) to kill. Press CTRL-C to cancel' | awk '{print $2}')

    if [[ -n "$pid" ]]; then
        # Kill the selected process(es) with SIGTERM (15) by default, or specified signal.
        local signal="${1:-15}"
        echo "$pid" | xargs kill -${signal} 2>/dev/null
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

# ---------------------------- Quick HTTP Server ----------------------------- #
# Start a simple HTTP server in the current directory.
# Requires Python to be installed.
# Usage: serve [port]
function serve() {
    local port="${1:-8000}"

    # Validate port number.
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ $port -lt 1 || $port -gt 65535 ]]; then
        echo "${C_RED}Error: Invalid port number. Use a number between 1 and 65535.${C_RESET}" >&2
        return 1
    fi

    # Check if port is already in use.
    if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo "${C_YELLOW}Warning: Port $port is already in use.${C_RESET}" >&2
        echo -n "Choose another port or press Enter to continue anyway: "
        read new_port
        if [[ -n "$new_port" ]]; then
            port="$new_port"
        fi
    fi

    local ip=$(ipconfig getifaddr en0 2>/dev/null || hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")
    echo "${C_CYAN}Serving current directory on http://${ip}:${port}${C_RESET}"
    echo "${C_CYAN}Press Ctrl+C to stop the server${C_RESET}"

    # Python 3.
    if command -v python3 &>/dev/null; then
        python3 -m http.server "$port"
        return
    fi
    # Python 2 (fallback).
    if command -v python &>/dev/null; then
        python -m SimpleHTTPServer "$port"
        return
    fi

    echo "${C_RED}Error: Python not found. Cannot start server.${C_RESET}" >&2
    return 1
}

# --------------------------- Network Port Scanner --------------------------- #
# Simple port scanner for a host.
# Usage: portscan <host> [start_port] [end_port]
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

    for port in $(seq $start_port $end_port); do
        (echo >/dev/tcp/$host/$port) &>/dev/null && echo "${C_GREEN}Port $port: OPEN${C_RESET}"
    done
}

# ---------------------------- fzf File Previewer ---------------------------- #
# Interactively preview files in the current directory using fzf and bat/eza.
# Usage: preview
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

# ------------------------- Create Archives Quickly -------------------------- #
# Quick helpers to create different types of archives.
# Usage: mktar <dir>, mkgz <dir>, etc.
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

# --------------------------- Extract Any Archive ---------------------------- #
# Universal extraction function for various archive formats.
# Usage: extract <archive>
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

# --------------------------- PDF Page Extraction ---------------------------- #
# Extract specific pages from a PDF document using qpdf.
# Usage: pdfextract <input.pdf> <start_page> <end_page> [output.pdf]
function pdfextract() {
    # Check if qpdf is installed
    if ! command -v qpdf >/dev/null 2>&1; then
        echo "${C_RED}Error: qpdf is not installed.${C_RESET}" >&2
        echo "Please install qpdf first:" >&2
        if [[ "$PLATFORM" == "macOS" ]]; then
            echo "  brew install qpdf" >&2
        elif [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
            echo "  sudo pacman -S qpdf" >&2
        elif [[ "$PLATFORM" == "Linux" ]]; then
            echo "  sudo apt install qpdf (Debian/Ubuntu)" >&2
            echo "  sudo dnf install qpdf (Fedora)" >&2
        fi
        return 1
    fi

    # Check if correct number of arguments is provided.
    if [[ $# -lt 3 || $# -gt 4 ]]; then
        echo "${C_YELLOW}Usage: pdfextract <input.pdf> <start_page> <end_page> [output.pdf]${C_RESET}" >&2
        echo "Example: pdfextract document.pdf 5 10 pages_5-10.pdf" >&2
        return 1
    fi

    local input_file="$1"
    local start_page="$2"
    local end_page="$3"
    local output_file="${4:-}"

    # Check if input file exists and is a PDF.
    if [[ ! -f "$input_file" ]]; then
        echo "${C_RED}Error: Input file '$input_file' not found.${C_RESET}" >&2
        return 1
    fi

    if [[ ! "$input_file" =~ \.(pdf|PDF)$ ]]; then
        echo "${C_RED}Error: Input file must be a PDF document.${C_RESET}" >&2
        return 1
    fi

    # Validate page numbers (must be positive integers).
    if ! [[ "$start_page" =~ ^[1-9][0-9]*$ ]] || ! [[ "$end_page" =~ ^[1-9][0-9]*$ ]]; then
        echo "${C_RED}Error: Page numbers must be positive integers.${C_RESET}" >&2
        return 1
    fi

    # Check if start page is less than or equal to end page.
    if [[ $start_page -gt $end_page ]]; then
        echo "${C_RED}Error: Start page ($start_page) cannot be greater than end page ($end_page).${C_RESET}" >&2
        return 1
    fi

    # Get total number of pages in the PDF.
    local total_pages
    total_pages=$(qpdf --show-npages "$input_file" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo "${C_RED}Error: Unable to read PDF file. File may be corrupted or password-protected.${C_RESET}" >&2
        return 1
    fi

    # Validate page range against document length.
    if [[ $start_page -gt $total_pages ]]; then
        echo "${C_RED}Error: Start page ($start_page) exceeds document length ($total_pages pages).${C_RESET}" >&2
        return 1
    fi

    if [[ $end_page -gt $total_pages ]]; then
        echo "${C_YELLOW}Warning: End page ($end_page) exceeds document length. Using page $total_pages instead.${C_RESET}"
        end_page=$total_pages
    fi

    # Generate output filename if not provided.
    if [[ -z "$output_file" ]]; then
        local base_name="${input_file%.*}"
        output_file="${base_name}_pages_${start_page}-${end_page}.pdf"
    fi

    # Check if output file already exists and ask for confirmation.
    if [[ -f "$output_file" ]]; then
        echo -n "${C_YELLOW}Output file '$output_file' already exists. Overwrite? (y/N): ${C_RESET}"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "${C_CYAN}Operation cancelled.${C_RESET}"
            return 0
        fi
    fi

    # Perform the extraction.
    echo "${C_CYAN}Extracting pages $start_page-$end_page from '$input_file'...${C_RESET}"

    if qpdf "$input_file" --pages . "$start_page-$end_page" -- "$output_file" 2>/dev/null; then
        echo "${C_GREEN}✓ Successfully extracted pages to '$output_file'${C_RESET}"

        # Show file size information.
        if command -v du >/dev/null 2>&1; then
            local input_size=$(du -h "$input_file" | cut -f1)
            local output_size=$(du -h "$output_file" | cut -f1)
            echo "${C_BLUE}Original: $input_size → Extracted: $output_size${C_RESET}"
        fi
    else
        echo "${C_RED}Error: Failed to extract pages. Please check the PDF file and try again.${C_RESET}" >&2
        return 1
    fi
}

# ---------------------------- Find Large Files ----------------------------- #
# Find files larger than specified size (default 100MB).
# Usage: findlarge [size_in_MB] [directory]
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

# --------------------------- Recent Git Branches ---------------------------- #
# Show local git branches, sorted by most recent commit date.
# Usage: gbr
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

# ---------------------------- Git Stash Manager ----------------------------- #
# Interactive git stash management with fzf.
# Usage: gstash
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

# ---------------------------- Quick Note Taking ----------------------------- #
# Quick note-taking function that appends timestamped notes to a file.
# Usage: note [text] or just 'note' for interactive mode
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

# -------------------------- Docker Container Shell -------------------------- #
# Quickly access shell in a Docker container using fzf.
# Usage: dshell
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

# ------------------------------ URL Shortener ------------------------------- #
# Shorten URL using is.gd service.
# Usage: shorten <url>
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

# ---------------------------- System Information ---------------------------- #
# Display comprehensive system information.
# Usage: sysinfo
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

# --------------------------- Directory Bookmarks ---------------------------- #
# Simple bookmark system for directories.
# Usage: bm [add|del|list] [name]
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

# ---------------------------- Cleanup Temp Files ---------------------------- #
# Clean various temporary and cache files.
# Usage: cleanup [--dry-run]
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

# +++++++++++++++++++++++++++++++ END OF FILE ++++++++++++++++++++++++++++++++ #
