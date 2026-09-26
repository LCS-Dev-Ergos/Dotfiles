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
#   - Claude Code, Gemini CLI, OpenCode: wrappers that hand each tool only the
#     1Password credentials it needs.
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

# ++++++++++++++++++++++++++ 1PASSWORD CREDENTIALS +++++++++++++++++++++++++++ #
#
# The claude, gemini, and opencode wrappers read their API credentials from
# 1Password on first use. Each value is then cached for the session in
# _AI_SECRET_CACHE, which is never exported, so a key only reaches the child
# process of the wrapper that needs it. A variable already exported under the
# same name always wins over 1Password.
#
#   GITHUB_PAT        GitHub MCP server in Claude Code and OpenCode.
#   CONTEXT7_API_KEY  Context7 MCP server in Claude Code and OpenCode.
#   GEMINI_API_KEY    Gemini CLI v0.41+ with the "gemini-api-key" auth type
#                     (~/.gemini/settings.json); required by `gemini`.
#   KILO_API_KEY      OpenCode's kilopass provider ({env:KILO_API_KEY}).
#
# Creating a missing item, e.g. the Gemini key from
# https://aistudio.google.com/apikey (Kilo: https://kilo.ai/settings/api-keys):
#   op item create --category="API Credential" --title="Gemini API Key" \
#     --vault=Personal --field label=credential,value=<your-key>

# 1Password references; adjust the vault or item name here if they differ.
typeset -gA _AI_SECRET_REFS=(
  GITHUB_PAT       "op://Personal/GITHUB_PAT/credential"
  CONTEXT7_API_KEY "op://Personal/CONTEXT7_API_KEY/credential"
  GEMINI_API_KEY   "op://Personal/Gemini API Key/credential"
  KILO_API_KEY     "op://Personal/Kilo API Key/credential"
)
# Declared without a value so re-sourcing this module keeps unlocked keys.
typeset -gA _AI_SECRET_CACHE

# -----------------------------------------------------------------------------
# _ai_secret_load
# @internal
# @description Resolves a credential from the environment, the session cache,
# or 1Password, in that order, and caches what 1Password returns. Callers
# declare `local REPLY` so the value never lingers in the global REPLY.
# @arg $1 string Credential variable name; a key of _AI_SECRET_REFS.
# @exitcode 1 If op is unavailable, the vault is locked, or the item is
# missing or empty.
# @set REPLY string The credential; empty on failure.
# -----------------------------------------------------------------------------
_ai_secret_load() {
  local name="$1"
  REPLY="${(P)name:-${_AI_SECRET_CACHE[$name]-}}"
  [[ -n "$REPLY" ]] && return 0

  local ref="${_AI_SECRET_REFS[$name]-}"
  [[ -n "$ref" ]] && (( $+commands[op] )) || return 1
  REPLY="$(command op read "$ref" 2>/dev/null)" && [[ -n "$REPLY" ]] || {
    REPLY=""
    return 1
  }
  _AI_SECRET_CACHE[$name]="$REPLY"
}

# -----------------------------------------------------------------------------
# _ai_secret_unlock
# @internal
# @description Discards a credential from the shell and the session cache,
# then reads it again from 1Password.
# @arg $1 string Credential variable name; a key of _AI_SECRET_REFS.
# @exitcode 1 If the credential cannot be read.
# -----------------------------------------------------------------------------
_ai_secret_unlock() {
  local name="$1" REPLY
  unset -v "$name"
  unset "_AI_SECRET_CACHE[$name]"
  if _ai_secret_load "$name"; then
    print "${C_GREEN}$name loaded from 1Password.${C_RESET}"
    return 0
  fi
  # op://<vault>/<item>/<field>, split to spell out the command that creates
  # a missing item.
  local -a ref_parts=("${(@s:/:)${_AI_SECRET_REFS[$name]#op://}}")
  print -u2 "${C_RED}Could not load $name — is 1Password unlocked and the item set up?${C_RESET}"
  print -u2 "${C_YELLOW}Run: op item create --category=\"API Credential\" --title=\"${ref_parts[2]}\" --vault=${ref_parts[1]} --field label=${ref_parts[3]},value=<key>${C_RESET}"
  return 1
}

# -----------------------------------------------------------------------------
# github-pat-unlock
# @description Discards and reloads GITHUB_PAT from 1Password.
# @noargs
# @exitcode 1 If 1Password is unavailable or the key cannot be read.
# -----------------------------------------------------------------------------
github-pat-unlock() { _ai_secret_unlock GITHUB_PAT; }

# -----------------------------------------------------------------------------
# context7-unlock
# @description Discards and reloads CONTEXT7_API_KEY from 1Password.
# @noargs
# @exitcode 1 If 1Password is unavailable or the key cannot be read.
# -----------------------------------------------------------------------------
context7-unlock() { _ai_secret_unlock CONTEXT7_API_KEY; }

# -----------------------------------------------------------------------------
# gemini-unlock
# @description Discards and reloads GEMINI_API_KEY from 1Password.
# @noargs
# @exitcode 1 If 1Password is unavailable or the key cannot be read.
# -----------------------------------------------------------------------------
gemini-unlock() { _ai_secret_unlock GEMINI_API_KEY; }

# -----------------------------------------------------------------------------
# kilo-unlock
# @description Discards and reloads KILO_API_KEY from 1Password.
# @noargs
# @exitcode 1 If 1Password is unavailable or the key cannot be read.
# -----------------------------------------------------------------------------
kilo-unlock() { _ai_secret_unlock KILO_API_KEY; }

# -----------------------------------------------------------------------------
# gemini
# @description Loads GEMINI_API_KEY from 1Password, then runs Gemini.
# The key stays cached, unexported, for the rest of the session.
# @arg $@ string Arguments forwarded to the Gemini command.
# @exitcode 1 If the key cannot be loaded.
# -----------------------------------------------------------------------------
gemini() {
  local REPLY
  if ! _ai_secret_load GEMINI_API_KEY; then
    print -u2 "${C_RED}gemini: Could not load GEMINI_API_KEY from 1Password.${C_RESET}"
    print -u2 "${C_YELLOW}Make sure 1Password is unlocked and the item exists at: ${_AI_SECRET_REFS[GEMINI_API_KEY]}${C_RESET}"
    return 1
  fi
  GEMINI_API_KEY="$REPLY" command gemini "$@"
}

# -----------------------------------------------------------------------------
# claude
# @description Loads optional GitHub and Context7 keys, then runs Claude.
# The keys stay cached, unexported, for the rest of the session.
# @arg $@ string Arguments forwarded to the Claude command.
# -----------------------------------------------------------------------------
claude() {
  local REPLY github_pat="" context7_key=""
  if _ai_secret_load GITHUB_PAT; then
    github_pat="$REPLY"
  else
    print -u2 "${C_YELLOW}claude: Could not load GITHUB_PAT from 1Password (GitHub MCP may be unavailable).${C_RESET}"
  fi
  if _ai_secret_load CONTEXT7_API_KEY; then
    context7_key="$REPLY"
  else
    print -u2 "${C_YELLOW}claude: Could not load CONTEXT7_API_KEY from 1Password (Context7 MCP may be unavailable).${C_RESET}"
  fi
  GITHUB_PAT="$github_pat" CONTEXT7_API_KEY="$context7_key" command claude "$@"
}

# -----------------------------------------------------------------------------
# opencode
# @description Loads optional provider and MCP keys, then runs OpenCode.
# The keys stay cached, unexported, for the rest of the session.
# @arg $@ string Arguments forwarded to the OpenCode command.
# -----------------------------------------------------------------------------
opencode() {
  local REPLY kilo_key="" github_pat="" context7_key=""
  if _ai_secret_load KILO_API_KEY; then
    kilo_key="$REPLY"
  else
    print -u2 "${C_YELLOW}opencode: Could not load KILO_API_KEY from 1Password (kilopass provider may be unavailable).${C_RESET}"
  fi
  _ai_secret_load GITHUB_PAT && github_pat="$REPLY"
  _ai_secret_load CONTEXT7_API_KEY && context7_key="$REPLY"
  KILO_API_KEY="$kilo_key" GITHUB_PAT="$github_pat" \
    CONTEXT7_API_KEY="$context7_key" command opencode "$@"
}

# ============================================================================ #
# End of lib/70-ai-tools.zsh
