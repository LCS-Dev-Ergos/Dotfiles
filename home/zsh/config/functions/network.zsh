#!/usr/bin/env zsh
# shellcheck shell=zsh
# zsh-load: deferred
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

typeset -f _zsh_cache_is_fresh >/dev/null 2>&1 ||
  source "${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}/runtime-helpers.zsh"

# -----------------------------------------------------------------------------
# weather
# @description Displays weather for a city using wttr.in, caching results for
# one hour and falling back to cached data when fetching fails.
# @arg $1 string Optional city name; defaults to Bari.
# @option -h | --help Show usage information.
# @exitcode 1 If the cache cannot be created or no weather data is available.
# -----------------------------------------------------------------------------
function weather() {
  if [[ "$1" == -h || "$1" == --help ]]; then
    echo "Usage: weather [city]"
    return 0
  fi
  local location="${1:-Bari}"
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/weather"
  local location_key="${location//[^A-Za-z0-9._-]/_}"
  local cache_file="$cache_dir/${location_key}.cache"
  local location_url="${location// /%20}"
  local cache_age=3600

  command mkdir -p -- "$cache_dir" 2>/dev/null || {
    echo "${C_RED}Error: Unable to create weather cache directory.${C_RESET}" >&2
    return 1
  }

  if _zsh_cache_is_fresh "$cache_file" "$cache_age"; then
    cat "$cache_file"
    return 0
  fi

  local tmp_file
  tmp_file="$(mktemp "${cache_dir}/.weather.${location_key}.XXXXXX" 2>/dev/null)" || {
    echo "${C_RED}Error: Unable to allocate temporary cache file.${C_RESET}" >&2
    return 1
  }

  if curl -fsS --max-time 15 --connect-timeout 5 "https://wttr.in/${location_url}?lang=it" >"$tmp_file"; then
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
      return 1
    fi
  fi
}

# -----------------------------------------------------------------------------
# myip
# @description Fetches public IP and geolocation details from ipinfo.io.
# @option -h | --help Show usage information.
# @exitcode 1 If the public IP information cannot be fetched.
# -----------------------------------------------------------------------------
function myip() {
  emulate -L zsh
  setopt localoptions pipefail
  _zsh_ui_load || return 1

  if [[ "$1" == -h || "$1" == --help ]]; then
    echo "Usage: myip"
    return 0
  fi
  _zsh_ui_log info "Fetching public IP information."
  local response
  if ! response="$(curl -fsS --max-time 10 --connect-timeout 5 \
      "https://ipinfo.io/json" 2>/dev/null)"; then
    _zsh_ui_log error "Unable to fetch public IP information."
    return 1
  fi
  if (( $+commands[jq] )); then
    local details
    details="$(print -r -- "$response" | command jq -r '
      [
        ["IP address", (.ip // "Unknown")],
        ["City", (.city // "Unknown")],
        ["Region", (.region // "Unknown")],
        ["Country", (.country // "Unknown")],
        ["Network", (.org // "Unknown")]
      ][] | @tsv
    ')" || {
      _zsh_ui_log error "ipinfo.io returned invalid JSON."
      return 1
    }
    _zsh_ui_section "Public IP information"
    _zsh_ui_table $'Field\tValue' "${(@f)details}"
    return $?
  fi

  _zsh_ui_log warn "jq is unavailable; printing raw ipinfo.io JSON."
  print -r -- "$response"
}

# -----------------------------------------------------------------------------
# portscan
# @description Scans a host over a port range and reports open ports.
# @arg $1 string Hostname or IP address to scan.
# @arg $2 integer Optional starting port; defaults to 1.
# @arg $3 integer Optional ending port; defaults to 1000.
# @option -h | --help Show usage information.
# @exitcode 1 If a port is invalid or no supported scanner is available.
# -----------------------------------------------------------------------------
function portscan() {
  emulate -L zsh
  setopt localoptions pipefail
  _zsh_ui_load || return 1

  if [[ "$1" == -h || "$1" == --help ]]; then
    echo "Usage: portscan <host> [start_port] [end_port]"
    return 0
  fi
  if [[ $# -lt 1 ]]; then
    echo "${C_YELLOW}Usage: portscan <host> [start_port] [end_port]${C_RESET}" >&2
    echo "Default range: 1-1000" >&2
    return 1
  fi
  if (( $# > 3 )); then
    _zsh_ui_log error "Usage: portscan <host> [start_port] [end_port]"
    return 1
  fi

  local host="$1"
  local start_port="${2:-1}"
  local end_port="${3:-1000}"

  if [[ -z "$host" || "$host" == -* || "$host" == *[[:space:]]* ||
        "$host" == *[[:cntrl:]]* ]]; then
    _zsh_ui_log error \
      "Hostnames cannot be empty, option-like, or contain whitespace."
    return 1
  fi

  # Validate port numbers.
  if ! [[ "$start_port" =~ ^[0-9]+$ ]] || ! [[ "$end_port" =~ ^[0-9]+$ ]]; then
    _zsh_ui_log error "Port numbers must be positive integers."
    return 1
  fi
  if (( start_port < 1 || end_port > 65535 || start_port > end_port )); then
    _zsh_ui_log error "Use a valid ascending port range within 1-65535."
    return 1
  fi

  _zsh_ui_heading \
    "Port scan" \
    "$host · ports $start_port-$end_port"

  # Detect netcat flavor. BSD nc (macOS default) supports `port1-port2` range
  # syntax; nmap-ncat/openbsd-netcat on Linux generally do not. Probe the help
  # output once to decide whether to scan in a single nc call or loop.
  local nc_supports_range=0
  if command -v nc >/dev/null 2>&1; then
    if [[ "$PLATFORM" == "macOS" ]]; then
      nc_supports_range=1
    elif command nc -h 2>&1 | command grep -qE 'port\[s\]|port range'; then
      nc_supports_range=1
    fi
  fi

  if (( nc_supports_range )); then
    # -z: zero-I/O scan, -v: verbose, -w 1: 1s timeout.
    local scan_output line
    scan_output="$(command nc -z -v -w 1 "$host" \
      "$start_port"-"$end_port" 2>&1 | command grep "succeeded")" || true
    if [[ -n "$scan_output" ]]; then
      for line in "${(@f)scan_output}"; do
        _zsh_ui_log ok "$line"
      done
    else
      _zsh_ui_log info "No open ports found in the selected range."
    fi
  elif command -v nc >/dev/null 2>&1; then
    # Linux nc fallback: iterate per port.
    local port
    for ((port = start_port; port <= end_port; port++)); do
      if command nc -z -w 1 "$host" "$port" 2>/dev/null; then
        _zsh_ui_log ok "Port $port is open."
      fi
    done
  elif zmodload zsh/net/tcp 2>/dev/null; then
    local port fd
    for ((port = start_port; port <= end_port; port++)); do
      if ztcp "$host" "$port" >/dev/null 2>&1; then
        fd="$REPLY"
        ztcp -c "$fd" >/dev/null 2>&1 || :
        _zsh_ui_log ok "Port $port is open."
      fi
    done
  else
    _zsh_ui_log error \
      "Neither netcat nor the zsh/net/tcp module is available."
    return 1
  fi
}

# -----------------------------------------------------------------------------
# serve
# @description Starts a Python HTTP server for the current directory,
# binding locally by default; --public exposes it on all interfaces.
# @arg $1 integer Optional port; defaults to 8000.
# @option --public Bind to 0.0.0.0 instead of localhost.
# @option -h | --help Show usage information.
# @exitcode 1 If the port is invalid, approval is denied, or Python is missing.
# -----------------------------------------------------------------------------
function serve() {
  emulate -L zsh
  setopt localoptions pipefail
  _zsh_ui_load || return 1

  if [[ "$1" == -h || "$1" == --help ]]; then
    echo "Usage: serve [port] [--public]"
    return 0
  fi
  local port="8000"
  local bind_address="127.0.0.1"
  local public_mode=false
  local port_seen=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --public) public_mode=true; bind_address="0.0.0.0"; shift ;;
      *)
        if [[ "$1" =~ ^[0-9]+$ ]]; then
          if [[ "$port_seen" == true ]]; then
            _zsh_ui_log error "Only one port can be specified."
            return 1
          fi
          port="$1"
          port_seen=true
        else
          _zsh_ui_log error \
            "Invalid argument '$1'. Usage: serve [port] [--public]"
          return 1
        fi
        shift
        ;;
    esac
  done

  # Validate port number.
  if [[ $port -lt 1 || $port -gt 65535 ]]; then
    _zsh_ui_log error "Use a port number between 1 and 65535."
    return 1
  fi

  # Check if port is already in use.
  if (( $+commands[lsof] )) &&
      command lsof -Pi :"$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
    _zsh_ui_log warn "Port $port is already in use."
    printf 'Choose another port or press Enter to continue anyway: '
    read -r new_port
    if [[ -n "$new_port" ]]; then
      if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [[ $new_port -lt 1 || $new_port -gt 65535 ]]; then
        _zsh_ui_log error "Use a port number between 1 and 65535."
        return 1
      fi
      port="$new_port"
      if (( $+commands[lsof] )) &&
          command lsof -Pi :"$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
        _zsh_ui_log error "Port $port is still in use."
        return 1
      fi
    fi
  fi

  # Warn before exposing sensitive directories over HTTP.
  case "$PWD" in
    "$HOME"|"$HOME/.ssh"*|"$HOME/.gnupg"*|"$HOME/.aws"*|"$HOME/.config"*)
      _zsh_ui_log warn "Serving '$PWD' may expose sensitive files."
      _zsh_ui_confirm "Continue and expose this directory?" || {
        _zsh_ui_log info "Server start cancelled."
        return 1
      }
      ;;
  esac

  # Display server info.
  local url_msg
  if [[ "$public_mode" == true ]]; then
    local ip="127.0.0.1"
    if [[ "$PLATFORM" == "macOS" ]]; then
      ip="$(command ipconfig getifaddr en0 2>/dev/null ||
        command ipconfig getifaddr en1 2>/dev/null ||
        print -r -- "127.0.0.1")"
    elif [[ "$PLATFORM" == "Linux" ]]; then
      ip="$(command hostname -I 2>/dev/null | command awk '{print $1}')"
      [[ -z "$ip" ]] && ip="127.0.0.1"
    fi
    url_msg="http://${ip}:${port} (Public)"
  else
    url_msg="http://localhost:${port} (Local only)"
  fi

  _zsh_ui_sanitize_text "$PWD"
  local display_directory="$REPLY"
  _zsh_ui_card \
    "HTTP server" \
    "Directory  $display_directory" \
    "URL        $url_msg" \
    "Stop       Ctrl+C"

  if ! (( $+commands[python3] )); then
    _zsh_ui_log error "Python 3 is required to start the server safely."
    return 1
  fi
  command python3 -m http.server "$port" --bind "$bind_address"
}

# -----------------------------------------------------------------------------
# shorten
# @description Sends a URL to is.gd and displays the shortened result.
# Adds https:// when no scheme is present and copies it when possible.
# @arg $1 string URL to shorten.
# @option -h | --help Show usage information.
# @exitcode 1 If the URL, encoder, or shortening request fails.
# -----------------------------------------------------------------------------
function shorten() {
  emulate -L zsh
  setopt localoptions pipefail
  _zsh_ui_load || return 1

  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: shorten <url>  # sends the URL to is.gd"
    return 0
  fi
  if [[ $# -ne 1 ]]; then
    echo "${C_YELLOW}Usage: shorten <url>${C_RESET}" >&2
    return 1
  fi

  local url="$1"

  if [[ "$url" == *[[:cntrl:]]* ]]; then
    _zsh_ui_log error "URLs cannot contain terminal control characters."
    return 1
  fi

  # Basic URL validation.
  if [[ ! "$url" =~ ^https?:// ]]; then
    _zsh_ui_log warn "URL has no scheme; assuming https://."
    url="https://$url"
  fi

  # omz_urlencode owns all URL encoding and includes its own fallbacks.
  local encoded_url
  if ! typeset -f omz_urlencode >/dev/null 2>&1; then
    _zsh_ui_log error "omz_urlencode is unavailable."
    return 1
  fi
  encoded_url="$(omz_urlencode -r -P "$url")" || return 1

  if ! (( $+commands[curl] )); then
    _zsh_ui_log error "curl is required to contact is.gd."
    return 1
  fi

  _zsh_ui_log warn "Sending this URL to the third-party is.gd service."

  # Shorten the URL.
  local short_url
  short_url="$(command curl -fsS --max-time 15 --connect-timeout 5 \
    "https://is.gd/create.php?format=simple&url=${encoded_url}" \
    2>/dev/null)" || short_url=""

  if [[ "$short_url" == https://is.gd/* &&
        "$short_url" != *[[:cntrl:]]* ]]; then
    local clipboard_status="Not available"
    # Copy to clipboard if possible.
    if command -v pbcopy >/dev/null 2>&1; then
      print -rn -- "$short_url" | command pbcopy
      clipboard_status="Copied"
    elif command -v xclip >/dev/null 2>&1; then
      print -rn -- "$short_url" | command xclip -selection clipboard
      clipboard_status="Copied"
    fi
    _zsh_ui_card \
      "Short URL" \
      "$short_url" \
      "Clipboard  $clipboard_status"
  else
    _zsh_ui_log error "Failed to shorten the URL."
    return 1
  fi
}

# -----------------------------------------------------------------------------
# cheat
# @description Fetches a command cheat sheet from cheat.sh and opens it
# in a pager.
# @arg $1 string Command or query to look up.
# @option -h | --help Show usage information.
# @exitcode 1 If the query is missing or the URL encoder is unavailable.
# -----------------------------------------------------------------------------
function cheat() {
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: cheat <command>"
    return 0
  fi
  if [[ -z "$1" ]]; then
    echo "${C_YELLOW}Usage: cheat <command>${C_RESET}" >&2
    return 1
  fi
  typeset -f omz_urlencode >/dev/null 2>&1 || {
    echo "${C_RED}Error: omz_urlencode is unavailable.${C_RESET}" >&2
    return 1
  }
  local query
  query="$(omz_urlencode -r -P "$1")" || return 1
  curl -fsS --max-time 15 --connect-timeout 5 "https://cheat.sh/${query}" | less -R
}

# -----------------------------------------------------------------------------
# qr
# @description Renders a terminal QR code with qrencode, or sends text
# to qrenco.de when qrencode is unavailable.
# The remote fallback should not be used for secrets.
# @arg $1 string Text or URL to encode.
# @option -h | --help Show usage information.
# @exitcode 1 If the text is missing or QR generation fails.
# -----------------------------------------------------------------------------
function qr() {
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: qr <text>  # local with qrencode; otherwise sends text to qrenco.de"
    return 0
  fi
  if [[ -z "$1" ]]; then
    echo "${C_YELLOW}Usage: qr <text>${C_RESET}" >&2
    return 1
  fi
  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$1" | qrencode -t ANSIUTF8 -o -
    return $?
  fi
  echo "${C_YELLOW}Privacy: qrencode is unavailable; sending text to qrenco.de. Do not use this fallback for credentials.${C_RESET}" >&2
  curl -fsSF-="\<-" --max-time 10 --connect-timeout 5 "https://qrenco.de" <<<"$1"
}

# ============================================================================ #
# End of network.zsh
