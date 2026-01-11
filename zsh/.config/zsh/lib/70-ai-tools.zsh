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
#   - Pattern aliases for direct command execution.
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
export FABRIC_OUTPUT_DIR="$HOME/Documents/Obsidian-Vault/XSPC-Vault/Fabric"

# Main Fabric alias (fabric-ai is the actual command).
alias fabric="fabric-ai"

# -----------------------------------------------------------------------------
# yt - YouTube Transcript Fetcher
# -----------------------------------------------------------------------------
# Fetch YouTube video transcripts with optional timestamps.
# Integrates with Fabric for processing video content.
#
# Usage:
#   yt <youtube-url>                 - Get transcript without timestamps
#   yt -t <youtube-url>              - Get transcript with timestamps
#   yt --timestamps <youtube-url>    - Get transcript with timestamps
#
# Example:
#   yt https://www.youtube.com/watch?v=dQw4w9WgXcQ
#   yt -t https://www.youtube.com/watch?v=dQw4w9WgXcQ | fabric --pattern summarize
# -----------------------------------------------------------------------------
yt() {
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

  # Get the video link.
  local video_link="$1"
  fabric -y "$video_link" $transcript_flag
}

# -----------------------------------------------------------------------------
# _fabric_lazy_init
# -----------------------------------------------------------------------------
# Build pattern aliases and Obsidian integration functions on demand.
# Deferred by default to keep startup fast.
#
# Enhanced pattern execution with automatic Obsidian note creation.
# When a title is provided, saves the output to a dated markdown file.
# Without a title, streams the output directly to stdout.
#
# For each pattern in ~/.config/fabric/patterns/, a function is created that:
#   - With title: Saves to $FABRIC_OUTPUT_DIR/YYYY-MM-DD-title.md
#   - Without title: Streams output directly
#
# Security:
#   - Pattern names are validated (alphanumeric, dash, underscore only)
#   - Titles are sanitized (path traversal prevention)
#
# Usage:
#   <pattern-name> [title]
#
# Examples:
#   summarize "Meeting Notes"           - Saves to Obsidian vault
#   echo "Some text" | summarize        - Streams to stdout
#   yt <url> | extract_wisdom "Video Summary"
# -----------------------------------------------------------------------------
_fabric_lazy_init() {
  setopt localoptions noxtrace noverbose
  unfunction _fabric_lazy_init 2>/dev/null

  if ! command -v fabric >/dev/null 2>&1; then
    return 0
  fi

  local fabric_patterns_dir="$HOME/.config/fabric/patterns"
  [[ -d "$fabric_patterns_dir" ]] || return 0

  # Create output directory if it doesn't exist.
  [[ ! -d "$FABRIC_OUTPUT_DIR" ]] && mkdir -p "$FABRIC_OUTPUT_DIR"

  # Factory function to create pattern wrappers.
  _fabric_create_pattern_function() {
    local pname="$1"
    eval "function ${pname}() {
      local title=\"\$1\"
      local date_stamp=\"\$(date +'%Y-%m-%d')\"

      if [[ -n \"\$title\" ]]; then
        # Sanitize title (security: prevent path traversal)
        title=\"\${title//\\//_}\"
        title=\"\${title//../_}\"

        local output_path=\"\$FABRIC_OUTPUT_DIR/\${date_stamp}-\${title}.md\"

        # Save to Obsidian vault with metadata
        {
          echo \"---\"
          echo \"title: \$title\"
          echo \"date: \$date_stamp\"
          echo \"pattern: ${pname}\"
          echo \"tags: [fabric, ${pname}]\"
          echo \"---\"
          echo \"\"
          fabric --pattern \"${pname}\"
        } > \"\$output_path\"
        echo \"\${C_GREEN}Saved to: \$output_path\${C_RESET}\"
      else
        # Stream output directly
        fabric --pattern \"${pname}\" --stream
      fi
    }"
  }

  # Pattern aliases and functions.
  for pattern_file in "$fabric_patterns_dir"/*; do
    [[ ! -f "$pattern_file" ]] && continue
    typeset pattern_name="$(basename "$pattern_file")"

    # Validate pattern name (security: prevent injection).
    [[ ! "$pattern_name" =~ ^[a-zA-Z0-9_-]+$ ]] && continue

    # Remove any existing alias before creating function.
    unalias "$pattern_name" 2>/dev/null

    _fabric_create_pattern_function "$pattern_name"
  done

  unset -f _fabric_create_pattern_function
}

# Initialize Fabric functions unless in fast start mode.
if [[ "${ZSH_FAST_START:-}" != "1" ]]; then
  if [[ "${ZSH_DEFER_FABRIC:-1}" == "1" ]] && typeset -f _zsh_defer >/dev/null 2>&1; then
    _zsh_defer _fabric_lazy_init
  else
    _fabric_lazy_init
  fi
fi

# -----------------------------------------------------------------------------
# fabric-update
# -----------------------------------------------------------------------------
# Update Fabric patterns and models.
# Convenience wrapper for keeping Fabric up-to-date.
#
# Usage:
#   fabric-update
# -----------------------------------------------------------------------------
fabric-update() {
  echo "${C_CYAN}Updating Fabric patterns...${C_RESET}"
  fabric --update
  echo "${C_GREEN}Fabric patterns updated successfully.${C_RESET}"
}

# -----------------------------------------------------------------------------
# fabric-list
# -----------------------------------------------------------------------------
# List all available Fabric patterns with descriptions.
#
# Usage:
#   fabric-list
# -----------------------------------------------------------------------------
fabric-list() {
  echo "${C_CYAN}Available Fabric patterns:${C_RESET}"
  fabric --list
}

# ============================================================================ #
# +++++++++++++++++++++++++++++++++ OPENCODE +++++++++++++++++++++++++++++++++ #
# ============================================================================ #

# -----------------------------------------------------------------------------
# OpenCode MCP Environment
# -----------------------------------------------------------------------------
# Load environment variables for OpenCode (API keys, model configs, etc.).
# The .env file is sourced if it exists and is readable.
# -----------------------------------------------------------------------------
if [[ -r "$HOME/.config/opencode/.env" ]]; then
    source "$HOME/.config/opencode/.env"
fi

# ============================================================================ #
# ++++++++++++++++++++++++++++ CLAUDE MCP SERVERS ++++++++++++++++++++++++++++ #
# ============================================================================ #

# -----------------------------------------------------------------------------
# Claude MCP Environment
# -----------------------------------------------------------------------------
# Load environment variables for Claude MCP servers (API keys, configs, etc.).
# The .env file is sourced if it exists and is readable.
#
# MCP Servers configured:
#   - Context7: Up-to-date code documentation for LLMs
#   - Everything: Demo server for testing MCP protocol features
# -----------------------------------------------------------------------------
if [[ -r "$HOME/.claude/.env" ]]; then
    source "$HOME/.claude/.env"
fi

# ============================================================================ #
# End of 70-ai-tools.zsh
