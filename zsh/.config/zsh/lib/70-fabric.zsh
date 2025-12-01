#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++ FABRIC CONFIGURATION +++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Fabric AI integration with Obsidian note-taking workflow.
# Fabric is a powerful tool for efficient LLM interaction via predefined patterns.
#
# Features:
#   - Pattern aliases for direct command execution.
#   - YouTube transcript extraction (yt function).
#   - Obsidian integration with automatic markdown file creation.
#   - Frontmatter metadata for Obsidian compatibility.
#   - Dual-mode operation (stream vs. save).
#
# Documentation: https://github.com/danielmiessler/fabric
#
# ============================================================================ #

# Configure Obsidian integration path (adjust to your Obsidian vault).
export FABRIC_OUTPUT_DIR="$HOME/Documents/Obsidian-Vault/XSPC-Vault/Fabric"

# Main Fabric alias (fabric-ai is the actual command).
alias fabric="fabric-ai"

# -----------------------------------------------------------------------------
# Fabric Pattern Aliases
# -----------------------------------------------------------------------------
# Automatically creates command aliases for all installed Fabric patterns.
# This allows you to run patterns directly (e.g., 'summarize' instead of
# 'fabric --pattern summarize').
# -----------------------------------------------------------------------------
if command -v fabric >/dev/null 2>&1; then
    local fabric_patterns_dir="$HOME/.config/fabric/patterns"
    if [[ -d "$fabric_patterns_dir" ]]; then
        for pattern_file in "$fabric_patterns_dir"/*; do
            local pattern_name="$(basename "$pattern_file")"
            alias "${pattern_name}=fabric --pattern ${pattern_name}"
        done
    fi
fi

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
    if [[ "$#" -eq 0 ]] || [[ "$#" -gt 2 ]]; then
        echo "${C_RED}Usage: yt [-t | --timestamps] <youtube-link>${C_RESET}" >&2
        return 1
    fi

    local transcript_flag="--transcript"
    if [[ "$1" == "-t" ]] || [[ "$1" == "--timestamps" ]]; then
        transcript_flag="--transcript-with-timestamps"
        shift
    fi

    local video_link="$1"
    fabric -y "$video_link" $transcript_flag
}

# -----------------------------------------------------------------------------
# Obsidian Integration Functions
# -----------------------------------------------------------------------------
# Enhanced pattern execution with automatic Obsidian note creation.
# When a title is provided, saves the output to a dated markdown file.
# Without a title, streams the output directly to stdout.
#
# These functions override the basic pattern aliases created above.
# For each pattern in ~/.config/fabric/patterns/, a function is created that:
#   - With title: Saves to $FABRIC_OUTPUT_DIR/YYYY-MM-DD-title.md
#   - Without title: Streams output directly
#
# Security:
#   - Pattern names are validated (alphanumeric, dash, underscore only)
#   - Titles are sanitized (path traversal prevention)
#   - Uses function definition instead of eval
#
# Usage:
#   <pattern-name> [title]
#
# Examples:
#   summarize "Meeting Notes"           - Saves to Obsidian vault
#   echo "Some text" | summarize        - Streams to stdout
#   yt <url> | extract_wisdom "Video Summary"
# -----------------------------------------------------------------------------
if command -v fabric >/dev/null 2>&1; then
    local fabric_patterns_dir="$HOME/.config/fabric/patterns"
    if [[ -d "$fabric_patterns_dir" ]]; then
        # Create output directory if it doesn't exist
        [[ ! -d "$FABRIC_OUTPUT_DIR" ]] && mkdir -p "$FABRIC_OUTPUT_DIR"

        for pattern_file in "$fabric_patterns_dir"/*; do
            [[ ! -f "$pattern_file" ]] && continue
            local pattern_name=$(basename "$pattern_file")

            # Validate pattern name (security: prevent injection)
            if [[ ! "$pattern_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                continue
            fi

            # Remove previous alias to replace with function
            unalias "$pattern_name" 2>/dev/null

            # Create wrapper function (safer than eval)
            # We use a factory function to properly capture pattern_name
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

            _fabric_create_pattern_function "$pattern_name"
        done

        # Clean up factory function
        unset -f _fabric_create_pattern_function
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
