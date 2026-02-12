#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++ NETWORK FUNCTIONS +++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Network and web-related utilities.
# Tools for fetching information, scanning ports, and serving files.
#
# Functions:
#   - weather    Get weather information.
#   - myip       Get public IP and geolocation.
#   - portscan   Simple port scanner.
#   - serve      Start HTTP server in current directory.
#   - shorten    Shorten URL using is.gd.
#   - cheat      Get cheat sheet for a command.
#   - qr         Generate QR code in terminal.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# weather
# -----------------------------------------------------------------------------
# Get weather information using wttr.in service.
# Implements 1-hour caching to reduce API calls.
#
# Usage:
#   weather [city]
#
# Arguments:
#   city - Location name (default: Bari)
# -----------------------------------------------------------------------------
function weather() {
  local location="${1:-Bari}"
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/weather"
  local location_key="${location//[^A-Za-z0-9._-]/_}"
  local cache_file="$cache_dir/${location_key}.cache"
  local location_url="${location// /%20}"
  local current_time=$(date +%s)
  local cache_age=3600

  command mkdir -p -- "$cache_dir" 2>/dev/null || {
    echo "${C_RED}Error: Unable to create weather cache directory.${C_RESET}" >&2
    return 1
  }

  if [[ -f "$cache_file" ]]; then
    local file_time
    if [[ "$PLATFORM" == "macOS" ]]; then
      file_time=$(stat -f %m "$cache_file" 2>/dev/null || echo 0)
    else
      file_time=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
    fi
    if [[ $((current_time - file_time)) -lt $cache_age ]]; then
      cat "$cache_file"
      return 0
    fi
  fi

  local tmp_file
  tmp_file="$(mktemp "${cache_dir}/.weather.${location_key}.XXXXXX" 2>/dev/null)" || {
    echo "${C_RED}Error: Unable to allocate temporary cache file.${C_RESET}" >&2
    return 1
  }

  if curl -s --fail --connect-timeout 5 "https://wttr.in/${location_url}?lang=it" >"$tmp_file"; then
    chmod 600 "$tmp_file" 2>/dev/null || :
    mv -f "$tmp_file" "$cache_file"
    cat "$cache_file"
  else
    rm -f -- "$tmp_file" 2>/dev/null
    echo "${C_RED}Error: Unable to fetch weather data.${C_RESET}" >&2
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
# myip
# -----------------------------------------------------------------------------
# Get public IP address and geolocation information.
#
# Usage:
#   myip
# -----------------------------------------------------------------------------
function myip() {
  echo "${C_CYAN}Fetching public IP info...${C_RESET}"
  curl -s "https://ipinfo.io/json" |
    grep -E '"ip"|"city"|"region"|"country"|"org"' |
    sed 's/^  //;s/[",]//g' |
    awk -F: -v color="${C_GREEN}" -v reset="${C_RESET}" '{printf "%s%s%s%s\n", $1 ":", color, $2, reset}'
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
# -----------------------------------------------------------------------------
function serve() {
  local port="8000"
  local bind_address="127.0.0.1"
  local public_mode=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --public) public_mode=true; bind_address="0.0.0.0"; shift ;;
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

  # Display server info.
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
      # Python 2 SimpleHTTPServer doesn't support --bind easily without a custom script.
      echo "${C_YELLOW}Warning: Python 2 SimpleHTTPServer binds to all interfaces by default.${C_RESET}"
      python -m SimpleHTTPServer "$port"
    fi
    return
  fi

  echo "${C_RED}Error: Python not found. Cannot start server.${C_RESET}" >&2
  return 1
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
# -----------------------------------------------------------------------------
function shorten() {
  if [[ $# -eq 0 ]]; then
    echo "${C_YELLOW}Usage: shorten <url>${C_RESET}" >&2
    return 1
  fi

  local url="$1"

  # Basic URL validation.
  if [[ ! "$url" =~ ^https?:// ]]; then
    echo "${C_YELLOW}Warning: URL should start with http:// or https://${C_RESET}"
    url="https://$url"
  fi

  # Shorten the URL.
  local short_url
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
# cheat
# -----------------------------------------------------------------------------
# Get a cheat sheet for a command using cheat.sh service.
# Displays practical examples and common usage patterns.
#
# Usage:
#   cheat <command>
# -----------------------------------------------------------------------------
function cheat() {
  if [[ -z "$1" ]]; then
    echo "${C_YELLOW}Usage: cheat <command>${C_RESET}" >&2
    return 1
  fi
  curl -s "cheat.sh/$1" | less -R
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
# -----------------------------------------------------------------------------
function qr() {
  if [[ -z "$1" ]]; then
    echo "${C_YELLOW}Usage: qr <text>${C_RESET}" >&2
    return 1
  fi
  curl -sF-="\<-" qrenco.de <<<"$1"
}

# ============================================================================ #
