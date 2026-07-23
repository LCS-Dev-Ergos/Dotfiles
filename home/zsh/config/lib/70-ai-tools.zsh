#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
#           █████╗ ██╗    ████████╗ ██████╗  ██████╗ ██╗     ███████╗
#          ██╔══██╗██║    ╚══██╔══╝██╔═══██╗██╔═══██╗██║     ██╔════╝
#          ███████║██║       ██║   ██║   ██║██║   ██║██║     ███████╗
#          ██╔══██║██║       ██║   ██║   ██║██║   ██║██║     ╚════██║
#          ██║  ██║██║       ██║   ╚██████╔╝╚██████╔╝███████╗███████║
#          ╚═╝  ╚═╝╚═╝       ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝╚══════╝
# ============================================================================ #
# +++++++++++++++++++++++++++++ AI TOOLS CONFIG ++++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Configuration for AI-powered tools, coding agents, and assistants.
#
# Tools:
#   - Fabric: LLM interaction via predefined patterns with Obsidian integration.
#   - OpenCode: AI coding assistant with MCP support.
#
# Features (Fabric):
#   - Namespaced pattern execution through `fabric-pattern`.
#   - YouTube transcript extraction (yt function).
#   - Obsidian integration with automatic markdown file creation.
#   - Frontmatter metadata for Obsidian compatibility.
#   - Dual-mode operation (stream vs. save).
#
# Documentation:
#   - Fabric: https://github.com/danielmiessler/fabric
#   - OpenCode: https://github.com/opencode-ai/opencode
#
# ============================================================================ #

# Configure Obsidian integration path (adjust to your Obsidian vault).
export FABRIC_OUTPUT_DIR="${FABRIC_OUTPUT_DIR:-\
$HOME/Documents/Obsidian-Vault/XSPC-Vault/Fabric}"

# Enable EXA Web Search in OpenCode.
export OPENCODE_ENABLE_EXA="true"

# Main Fabric alias (fabric-ai is the actual command).
alias fabric="fabric-ai"

# Remove top-level wrappers created by the previous implementation. Compare
# function bodies so a user replacement with the same name is never removed.
if (( ${+parameters[_FABRIC_PATTERN_WRAPPERS]} )); then
  local _fabric_legacy_name _fabric_current_body _fabric_owned_body
  for _fabric_legacy_name in "${(k)_FABRIC_PATTERN_WRAPPERS[@]}"; do
    _fabric_current_body="${functions[$_fabric_legacy_name]-}"
    _fabric_owned_body="${_FABRIC_PATTERN_WRAPPERS[$_fabric_legacy_name]}"
    if [[ "${_fabric_current_body//[[:space:]]/}" == \
          "${_fabric_owned_body//[[:space:]]/}" ]]; then
      unfunction -- "$_fabric_legacy_name" 2>/dev/null
    fi
  done
  unset _fabric_legacy_name _fabric_current_body _fabric_owned_body
  unset _FABRIC_PATTERN_WRAPPERS
fi

# Completion discovery is lazy and cached for the current shell. A successful
# pattern update invalidates it.
typeset -ga _FABRIC_PATTERN_NAMES=()
typeset -gi _FABRIC_PATTERN_CACHE_READY=0

# -----------------------------------------------------------------------------
# yt
# @description Fetches a YouTube transcript through Fabric.
# @arg $@ string URL, optionally preceded by -t or --timestamps.
# @exitcode 1 If the URL or argument count is invalid.
# -----------------------------------------------------------------------------
yt() {
  if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    echo "Usage: yt [-t|--timestamps] <youtube-link>"
    return 0
  fi
  # Validate arguments.
  if [[ "$#" -eq 0 ]] || [[ "$#" -gt 2 ]]; then
    echo "${C_RED}Usage: yt [-t | --timestamps] <youtube-link>${C_RESET}" >&2
    return 1
  fi

  # Determine transcript flag.
  local transcript_flag="--transcript"
  if [[ "$1" == "-t" ]] || [[ "$1" == "--timestamps" ]]; then
    transcript_flag="--transcript-with-timestamps"
    shift
  fi

  # Validate URL is present after optional flag consumption.
  if [[ -z "${1:-}" ]]; then
    echo "${C_RED}Usage: yt [-t | --timestamps] <youtube-link>${C_RESET}" >&2
    return 1
  fi

  # Get the video link.
  local video_link="$1"
  (( $+commands[fabric-ai] )) || {
    print -u2 "yt: fabric-ai is unavailable"
    return 1
  }
  command fabric-ai -y "$video_link" "$transcript_flag"
}

# -----------------------------------------------------------------------------
# _fabric_pattern_exists
# @internal
# @description Checks whether a safe pattern name identifies a readable
# directory-based or legacy flat-file Fabric pattern.
# @arg $1 string Pattern name.
# @exitcode 1 If the name is unsafe or the pattern is unavailable.
# -----------------------------------------------------------------------------
_fabric_pattern_exists() {
  local pattern_name="$1"
  [[ "$pattern_name" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
  local fabric_patterns_dir="$HOME/.config/fabric/patterns"
  local pattern_path="$fabric_patterns_dir/$pattern_name"
  [[ -d "$pattern_path" && -r "$pattern_path/system.md" ]] ||
    [[ -f "$pattern_path" && -s "$pattern_path" ]]
}

# -----------------------------------------------------------------------------
# _fabric_pattern_names
# @internal
# @description Populates reply with safe Fabric pattern names, scanning once
# per shell or after a successful pattern update.
# @noargs
# @set reply array Available pattern names in lexical order.
# -----------------------------------------------------------------------------
_fabric_pattern_names() {
  if (( _FABRIC_PATTERN_CACHE_READY )); then
    reply=("${_FABRIC_PATTERN_NAMES[@]}")
    return 0
  fi

  local patterns_dir="$HOME/.config/fabric/patterns"
  local pattern_entry pattern_name
  local -aU discovered=()
  for pattern_entry in "$patterns_dir"/*(N); do
    pattern_name="${pattern_entry:t}"
    [[ "$pattern_name" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
    _fabric_pattern_exists "$pattern_name" && discovered+=("$pattern_name")
  done
  _FABRIC_PATTERN_NAMES=("${(on)discovered[@]}")
  _FABRIC_PATTERN_CACHE_READY=1
  reply=("${_FABRIC_PATTERN_NAMES[@]}")
}

# -----------------------------------------------------------------------------
# _fabric_pattern_completion
# @internal
# @description Completes the pattern operand accepted by fabric-pattern.
# @noargs
# -----------------------------------------------------------------------------
_fabric_pattern_completion() {
  setopt localoptions
  local context state state_descr line
  typeset -A opt_args
  _arguments -C \
    '(-h --help)'{-h,--help}'[show command help]' \
    '(-l --list)'{-l,--list}'[list available patterns]' \
    '1:Fabric pattern:->patterns' \
    '2::Obsidian note title:' \
    '*:: :_message "no more arguments"'

  if [[ "$state" == patterns ]]; then
    _fabric_pattern_names
    compadd -a reply
  fi
}

# -----------------------------------------------------------------------------
# _fabric_run_pattern
# @internal
# @description Executes one validated Fabric pattern, streaming without a
# title or atomically publishing a private Obsidian note when a title is given.
# @arg $1 string Fabric pattern name.
# @arg $2 string Optional Obsidian note title.
# @exitcode 1 If validation, Fabric execution, or note publication fails.
# -----------------------------------------------------------------------------
_fabric_run_pattern() {
  emulate -L zsh
  setopt localoptions localtraps pipefail

  local pname="$1"
  local title="${2:-}"

  if [[ -n "$title" ]]; then
    title="${title//[\/\\]/_}"
    title="${title//\.\./_}"
    title="${title//[[:cntrl:]]/}"
    while [[ "$title" == ' '* ]]; do title="${title# }"; done
    while [[ "$title" == *' ' ]]; do title="${title% }"; done

    if [[ -z "$title" || ! "$title" =~ ^[A-Za-z0-9_.\ -]+$ ]]; then
      print -u2 \
        "${C_RED}fabric-pattern: invalid title${C_RESET}"
      return 1
    fi

    if [[ ! -d "$FABRIC_OUTPUT_DIR" ]] &&
        ! command mkdir -p -- "$FABRIC_OUTPUT_DIR"; then
      print -u2 \
        "${C_RED}fabric-pattern: could not create output directory${C_RESET}"
      return 1
    fi

    local date_stamp
    date_stamp="$(date +'%Y-%m-%d')"
    local output_path="$FABRIC_OUTPUT_DIR/${date_stamp}-${title}.md"
    local response_path=""
    local note_path=""
    trap 'command rm -f -- "${response_path:-}" "${note_path:-}" \
      2>/dev/null; return 130' INT TERM HUP

    response_path="$(
      mktemp "$FABRIC_OUTPUT_DIR/.fabric-response.XXXXXX" 2>/dev/null
    )" || {
      print -u2 \
        "${C_RED}fabric-pattern: could not create temporary output${C_RESET}"
      return 1
    }
    command chmod 600 "$response_path" 2>/dev/null || {
      command rm -f -- "$response_path" 2>/dev/null
      return 1
    }

    command fabric-ai --pattern "$pname" >| "$response_path"
    local rc=$?
    if (( rc != 0 )); then
      command rm -f -- "$response_path" 2>/dev/null
      print -u2 \
        "${C_RED}fabric-pattern: '$pname' failed; no note was saved.${C_RESET}"
      return $rc
    fi

    note_path="$(
      mktemp "$FABRIC_OUTPUT_DIR/.fabric-note.XXXXXX" 2>/dev/null
    )" || {
      command rm -f -- "$response_path" 2>/dev/null
      return 1
    }
    command chmod 600 "$note_path" 2>/dev/null || {
      command rm -f -- "$response_path" "$note_path" 2>/dev/null
      return 1
    }

    if ! {
      printf '%s\n' \
        "---" \
        "title: $title" \
        "date: $date_stamp" \
        "pattern: $pname" \
        "tags: [fabric, $pname]" \
        "---" \
        "" &&
        command cat -- "$response_path"
    } >| "$note_path"; then
      command rm -f -- "$response_path" "$note_path" 2>/dev/null
      return 1
    fi

    command rm -f -- "$response_path"
    response_path=""
    if ! command mv -f -- "$note_path" "$output_path"; then
      command rm -f -- "$note_path" 2>/dev/null
      return 1
    fi
    note_path=""
    print "${C_GREEN}Saved to: $output_path${C_RESET}"
  else
    command fabric-ai --pattern "$pname" --stream
  fi
}

# -----------------------------------------------------------------------------
# fabric-pattern
# @description Runs a Fabric pattern without creating a global function for
# that pattern. Streams to stdout unless an optional title is supplied, in
# which case the result is saved atomically as a private Obsidian note.
# @arg $1 string Pattern name, or --list.
# @arg $2 string Optional Obsidian note title.
# @exitcode 1 If arguments are invalid or pattern execution fails.
# @example
#   fabric-pattern summarize
#   echo "Some text" | fabric-pattern extract_wisdom "Video Summary"
# -----------------------------------------------------------------------------
fabric-pattern() {
  case "${1:-}" in
    -h|--help|"")
      print "Usage: fabric-pattern <pattern> [note-title]"
      print "       fabric-pattern --list"
      [[ -n "${1:-}" ]] && return 0 || return 1
      ;;
    -l|--list)
      (( $# == 1 )) || return 1
      fabric-list
      return
      ;;
  esac

  (( $# <= 2 )) || {
    print -u2 "fabric-pattern: expected a pattern and optional note title"
    return 1
  }
  local pattern_name="$1"
  if ! _fabric_pattern_exists "$pattern_name"; then
    print -u2 "fabric-pattern: unknown or unsafe pattern '$pattern_name'"
    print -u2 "Run 'fabric-pattern --list' to inspect available patterns."
    return 1
  fi
  (( $+commands[fabric-ai] )) || {
    print -u2 "fabric-pattern: fabric-ai is unavailable"
    return 1
  }
  _fabric_run_pattern "$pattern_name" "${2:-}"
}

# -----------------------------------------------------------------------------
# fabric-update
# @description Updates the locally installed Fabric patterns.
# @noargs
# @exitcode 1 If the Fabric update fails.
# -----------------------------------------------------------------------------
fabric-update() {
  (( $+commands[fabric-ai] )) || {
    print -u2 "fabric-update: fabric-ai is unavailable"
    return 1
  }
  echo "${C_CYAN}Updating Fabric patterns...${C_RESET}"
  command fabric-ai --updatepatterns || return 1
  _FABRIC_PATTERN_NAMES=()
  _FABRIC_PATTERN_CACHE_READY=0
  echo "${C_GREEN}Fabric patterns updated successfully.${C_RESET}"
}

# -----------------------------------------------------------------------------
# fabric-list
# @description Lists available Fabric patterns and descriptions.
# @noargs
# @exitcode 1 If Fabric is unavailable or listing fails.
# -----------------------------------------------------------------------------
fabric-list() {
  (( $+commands[fabric-ai] )) || {
    print -u2 "fabric-list: fabric-ai is unavailable"
    return 1
  }
  echo "${C_CYAN}Available Fabric patterns:${C_RESET}"
  command fabric-ai --listpatterns
}

# ++++++++++++++++++++++++++++++++ GITHUB PAT ++++++++++++++++++++++++++++++++ #
#
# Loads GITHUB_PAT from 1Password lazily — deferred to keep startup fast.
# Required by Claude Code GitHub MCP and OpenCode GitHub MCP server
# (configured as {env:GITHUB_PAT} in their respective configs).

_GITHUB_PAT_OP_REF="op://Personal/GITHUB_PAT/credential"
typeset -g _CACHED_GITHUB_PAT="${_CACHED_GITHUB_PAT:-}"

# -----------------------------------------------------------------------------
# _load_github_pat
# @internal
# @description Reads GITHUB_PAT from 1Password via the op CLI, caching it in
# _CACHED_GITHUB_PAT; a no-op if already set or op is unavailable.
# @noargs
# @exitcode 1 If op is unavailable or the key cannot be read.
# -----------------------------------------------------------------------------
_load_github_pat() {
  [[ -n "${GITHUB_PAT:-${_CACHED_GITHUB_PAT:-}}" ]] && return 0
  command -v op &>/dev/null || return 1

  local key
  key=$(op read "$_GITHUB_PAT_OP_REF" 2>/dev/null) || return 1
  [[ -z "$key" ]] && return 1

  _CACHED_GITHUB_PAT="$key"
}

# -----------------------------------------------------------------------------
# github-pat-unlock
# @description Discards and reloads GITHUB_PAT from 1Password.
# @noargs
# @exitcode 1 If 1Password is unavailable or the key cannot be read.
# -----------------------------------------------------------------------------
github-pat-unlock() {
  unset -v GITHUB_PAT _CACHED_GITHUB_PAT
  if _load_github_pat; then
    print "${C_GREEN}GITHUB_PAT loaded from 1Password.${C_RESET}"
  else
    print "${C_RED}Could not load GITHUB_PAT — is 1Password unlocked and the item set up?${C_RESET}" >&2
    return 1
  fi
}

# +++++++++++++++++++++++++++++ CONTEXT7 API KEY +++++++++++++++++++++++++++++ #
#
# Loads CONTEXT7_API_KEY from 1Password lazily to keep startup fast.
# Required by Claude Code Context7 MCP and OpenCode Context7 MCP server
# (configured as {env:CONTEXT7_API_KEY} in their respective configs).

_CONTEXT7_OP_REF="op://Personal/CONTEXT7_API_KEY/credential"
typeset -g _CACHED_CONTEXT7_API_KEY="${_CACHED_CONTEXT7_API_KEY:-}"

# -----------------------------------------------------------------------------
# _load_context7_api_key
# @internal
# @description Reads CONTEXT7_API_KEY from 1Password via the op CLI, caching
# it in _CACHED_CONTEXT7_API_KEY; a no-op if already set or op is unavailable.
# @noargs
# @exitcode 1 If op is unavailable or the key cannot be read.
# -----------------------------------------------------------------------------
_load_context7_api_key() {
  [[ -n "${CONTEXT7_API_KEY:-${_CACHED_CONTEXT7_API_KEY:-}}" ]] && return 0
  command -v op &>/dev/null || return 1

  local key
  key=$(op read "$_CONTEXT7_OP_REF" 2>/dev/null) || return 1
  [[ -z "$key" ]] && return 1

  _CACHED_CONTEXT7_API_KEY="$key"
}

# -----------------------------------------------------------------------------
# context7-unlock
# @description Discards and reloads CONTEXT7_API_KEY from 1Password.
# @noargs
# @exitcode 1 If 1Password is unavailable or the key cannot be read.
# -----------------------------------------------------------------------------
context7-unlock() {
  unset CONTEXT7_API_KEY _CACHED_CONTEXT7_API_KEY
  if _load_context7_api_key; then
    print "${C_GREEN}CONTEXT7_API_KEY loaded from 1Password.${C_RESET}"
  else
    print "${C_RED}Could not load CONTEXT7_API_KEY — is 1Password unlocked and the item set up?${C_RESET}" >&2
    return 1
  fi
}

# Keys are loaded on-demand inside the claude/opencode wrappers below.

# ++++++++++++++++++++++++++++++++ GEMINI CLI ++++++++++++++++++++++++++++++++ #
#
# Loads GEMINI_API_KEY from 1Password lazily — only on the first invocation of
# the gemini wrapper function in a shell session, then cached in the
# environment so subsequent calls do not re-prompt the 1Password vault.
#
# Required by Gemini CLI v0.41+ when auth type is set to "gemini-api-key"
# (configured in ~/.gemini/settings.json).
#
# One-time setup — create the item in 1Password:
#   1. Open 1Password -> New Item -> API Credential
#   2. Title: "Gemini API Key"  |  Vault: Personal
#   3. Field "credential": paste the key from https://aistudio.google.com/apikey
#
# Or via CLI:
#   op item create --category="API Credential" --title="Gemini API Key" \
#     --vault=Personal --field label=credential,value=<your-key>

# 1Password reference — adjust vault/item name if different.
_GEMINI_OP_REF="op://Personal/Gemini API Key/credential"
typeset -g _CACHED_GEMINI_API_KEY="${_CACHED_GEMINI_API_KEY:-}"

# -----------------------------------------------------------------------------
# _load_gemini_api_key
# @internal
# @description Reads GEMINI_API_KEY from 1Password via the op CLI, caching it
# in _CACHED_GEMINI_API_KEY; a no-op if already set or op is unavailable.
# @noargs
# @exitcode 1 If op is unavailable, the item is missing, or the vault is
# locked/unauthenticated.
# -----------------------------------------------------------------------------
_load_gemini_api_key() {
  [[ -n "${GEMINI_API_KEY:-${_CACHED_GEMINI_API_KEY:-}}" ]] && return 0
  command -v op &>/dev/null       || return 1   # op not installed

  local key
  key=$(op read "$_GEMINI_OP_REF" 2>/dev/null) || return 1
  [[ -z "$key" ]]                 && return 1   # item not found or vault locked

  _CACHED_GEMINI_API_KEY="$key"
}

# -----------------------------------------------------------------------------
# gemini
# @description Loads GEMINI_API_KEY from 1Password, then runs Gemini.
# The key is cached in the environment for the rest of the session.
# @arg $@ string Arguments forwarded to the Gemini command.
# @exitcode 1 If the key cannot be loaded.
# -----------------------------------------------------------------------------
gemini() {
  if [[ -z "${GEMINI_API_KEY:-${_CACHED_GEMINI_API_KEY:-}}" ]]; then
    if ! _load_gemini_api_key; then
      print "${C_RED}gemini: Could not load GEMINI_API_KEY from 1Password.${C_RESET}" >&2
      print "${C_YELLOW}Make sure 1Password is unlocked and the item exists at: ${_GEMINI_OP_REF}${C_RESET}" >&2
      return 1
    fi
  fi
  local gemini_key="${GEMINI_API_KEY:-${_CACHED_GEMINI_API_KEY:-}}"
  GEMINI_API_KEY="$gemini_key" command gemini "$@"
}

# -----------------------------------------------------------------------------
# gemini-unlock
# @description Discards and reloads GEMINI_API_KEY from 1Password.
# @noargs
# @exitcode 1 If 1Password is unavailable or the key cannot be read.
# -----------------------------------------------------------------------------
gemini-unlock() {
  unset GEMINI_API_KEY _CACHED_GEMINI_API_KEY
  if _load_gemini_api_key; then
    print "${C_GREEN}GEMINI_API_KEY loaded from 1Password.${C_RESET}"
  else
    print "${C_RED}Could not load GEMINI_API_KEY — is 1Password unlocked and the item set up?${C_RESET}" >&2
    print "${C_YELLOW}Run: op item create --category=\"API Credential\" --title=\"Gemini API Key\" --vault=Personal --field label=credential,value=<key>${C_RESET}" >&2
    return 1
  fi
}

# -----------------------------------------------------------------------------
# claude
# @description Loads optional GitHub and Context7 keys, then runs Claude.
# Keys are cached in the environment for the rest of the session.
# @arg $@ string Arguments forwarded to the Claude command.
# -----------------------------------------------------------------------------
claude() {
  if [[ -z "${GITHUB_PAT:-${_CACHED_GITHUB_PAT:-}}" ]] && ! _load_github_pat; then
    print "${C_YELLOW}claude: Could not load GITHUB_PAT from 1Password (GitHub MCP may be unavailable).${C_RESET}" >&2
  fi
  if [[ -z "${CONTEXT7_API_KEY:-${_CACHED_CONTEXT7_API_KEY:-}}" ]] && ! _load_context7_api_key; then
    print "${C_YELLOW}claude: Could not load CONTEXT7_API_KEY from 1Password (Context7 MCP may be unavailable).${C_RESET}" >&2
  fi
  local github_pat="${GITHUB_PAT:-${_CACHED_GITHUB_PAT:-}}"
  local context7_key="${CONTEXT7_API_KEY:-${_CACHED_CONTEXT7_API_KEY:-}}"
  GITHUB_PAT="$github_pat" CONTEXT7_API_KEY="$context7_key" command claude "$@"
}

# +++++++++++++++++++++++++++++++ KILO GATEWAY +++++++++++++++++++++++++++++++ #
#
# Loads KILO_API_KEY from 1Password lazily — only on the first invocation of
# the opencode wrapper function in a shell session, then cached in the
# environment so subsequent calls do not re-prompt the 1Password vault.
#
# Required by OpenCode's kilopass provider (configured in opencode.json as
# {env:KILO_API_KEY}).
#
# One-time setup — create the item in 1Password:
#   1. Open 1Password -> New Item -> API Credential
#   2. Title: "Kilo API Key"  |  Vault: Personal
#   3. Field "credential": paste the key from https://kilo.ai/settings/api-keys
#
# Or via CLI:
#   op item create --category="API Credential" --title="Kilo API Key" \
#     --vault=Personal --field label=credential,value=<your-key>

# 1Password reference — adjust vault/item name if different.
_KILO_OP_REF="op://Personal/Kilo API Key/credential"
typeset -g _CACHED_KILO_API_KEY="${_CACHED_KILO_API_KEY:-}"

# -----------------------------------------------------------------------------
# _load_kilo_api_key
# @internal
# @description Reads KILO_API_KEY from 1Password via the op CLI, caching it
# in _CACHED_KILO_API_KEY; a no-op if already set or op is unavailable.
# @noargs
# @exitcode 1 If op is unavailable, the item is missing, or the vault is
# locked/unauthenticated.
# -----------------------------------------------------------------------------
_load_kilo_api_key() {
  [[ -n "${KILO_API_KEY:-${_CACHED_KILO_API_KEY:-}}" ]] && return 0
  command -v op &>/dev/null       || return 1   # op not installed

  local key
  key=$(op read "$_KILO_OP_REF" 2>/dev/null) || return 1
  [[ -z "$key" ]]                 && return 1   # item not found or vault locked

  _CACHED_KILO_API_KEY="$key"
}

# -----------------------------------------------------------------------------
# opencode
# @description Loads optional provider keys, then runs OpenCode.
# Keys are cached in the environment for the rest of the session.
# @arg $@ string Arguments forwarded to the OpenCode command.
# -----------------------------------------------------------------------------
opencode() {
  if [[ -z "${KILO_API_KEY:-${_CACHED_KILO_API_KEY:-}}" ]]; then
    if ! _load_kilo_api_key; then
      print "${C_YELLOW}opencode: Could not load KILO_API_KEY from 1Password (kilopass provider may be unavailable).${C_RESET}" >&2
    fi
  fi
  [[ -z "${GITHUB_PAT:-${_CACHED_GITHUB_PAT:-}}" ]] && _load_github_pat
  [[ -z "${CONTEXT7_API_KEY:-${_CACHED_CONTEXT7_API_KEY:-}}" ]] && _load_context7_api_key
  local kilo_key="${KILO_API_KEY:-${_CACHED_KILO_API_KEY:-}}"
  local github_pat="${GITHUB_PAT:-${_CACHED_GITHUB_PAT:-}}"
  local context7_key="${CONTEXT7_API_KEY:-${_CACHED_CONTEXT7_API_KEY:-}}"
  KILO_API_KEY="$kilo_key" GITHUB_PAT="$github_pat" CONTEXT7_API_KEY="$context7_key" command opencode "$@"
}

# -----------------------------------------------------------------------------
# kilo-unlock
# @description Discards and reloads KILO_API_KEY from 1Password.
# @noargs
# @exitcode 1 If 1Password is unavailable or the key cannot be read.
# -----------------------------------------------------------------------------
kilo-unlock() {
  unset KILO_API_KEY _CACHED_KILO_API_KEY
  if _load_kilo_api_key; then
    print "${C_GREEN}KILO_API_KEY loaded from 1Password.${C_RESET}"
  else
    print "${C_RED}Could not load KILO_API_KEY — is 1Password unlocked and the item set up?${C_RESET}" >&2
    print "${C_YELLOW}Run: op item create --category=\"API Credential\" --title=\"Kilo API Key\" --vault=Personal --field label=credential,value=<key>${C_RESET}" >&2
    return 1
  fi
}

# ============================================================================ #
# End of lib/70-ai-tools.zsh
