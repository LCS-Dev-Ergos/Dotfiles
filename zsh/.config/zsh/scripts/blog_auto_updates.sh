#!/usr/bin/env zsh
# ============================================================================ #
# ++++++++++++++++++++++++++ Blog Automation Script ++++++++++++++++++++++++++ #
# ============================================================================ #
# Comprehensive Hugo blog automation system with Obsidian vault integration.
#
# This script provides a complete blog publishing workflow that:
# - Synchronizes markdown posts from an Obsidian vault to Hugo content directory
# - Detects file changes using Git status or hash-based comparison
# - Updates YAML frontmatter metadata in blog posts
# - Processes and converts Obsidian-style image links to Hugo format
# - Builds static site with Hugo generator
# - Manages Git commits and deployment to remote repositories
# - Supports multiple deployment targets (main branch and Hostinger)
# - Implements security validation, backup/recovery, and comprehensive logging
#
# The script is platform-aware (macOS/Linux) with configurable paths,
# dry-run mode for testing, verbose logging, and timeout protection
# for long-running operations.
#
# Author: XtremeXSPC
# Version: 2.1.0 - Git-based change detection
# License: MIT
# ============================================================================ #

# Determine current script path.
if [[ -n "${ZSH_VERSION}" ]]; then
    SCRIPT_PATH="${(%):-%x}"
elif [[ -n "${BASH_VERSION}" ]]; then
    SCRIPT_PATH="${BASH_SOURCE[0]}"
else
    SCRIPT_PATH="$0"
fi

BLOG_SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd 2>/dev/null)"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
VERSION="2.1.0"

# ============================================================================ #
# ++++++++++++ Operating system detection and path configuration +++++++++++++ #
# ============================================================================ #

# Detect operating system and set allowed blog directory.
if [[ "$(uname)" == "Darwin" ]]; then
    PLATFORM="macOS"
    ARCH_LINUX=false
    ALLOWED_BLOG_ROOT="/Volumes/LCS.Data/Blog"
elif [[ "$(uname)" == "Linux" ]]; then
    PLATFORM="Linux"
    ALLOWED_BLOG_ROOT="/LCS.Data/Blog"
    # Check if we're on Arch Linux
    if [[ -f "/etc/arch-release" ]]; then
        ARCH_LINUX=true
    else
        ARCH_LINUX=false
    fi
else
    PLATFORM="Other"
    ARCH_LINUX=false
    ALLOWED_BLOG_ROOT=""
fi

# ============================================================================ #
# +++++++++++++++++++++++++++++ Color Support ++++++++++++++++++++++++++++++++ #
# ============================================================================ #

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null) -ge 8 ]]; then
    C_RESET=$'\e[0m'
    C_BOLD=$'\e[1m'
    C_RED=$'\e[31m'
    C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m'
    C_MAGENTA=$'\e[35m'
    C_CYAN=$'\e[36m'
else
    C_RESET=""
    C_BOLD=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_MAGENTA=""
    C_CYAN=""
fi

# ============================================================================ #
# ++++++++++++++++++++++++++++++ Logging System ++++++++++++++++++++++++++++++ #
# ============================================================================ #

# Logging configuration.
BLOG_DRY_RUN=${BLOG_DRY_RUN:-false}
BLOG_VERBOSE=${BLOG_VERBOSE:-false}
BLOG_LOG_DIR="${BLOG_LOG_DIR:-$ALLOWED_BLOG_ROOT/logs}"

# -----------------------------------------------------------------------------
# _blog_init_logging
# -----------------------------------------------------------------------------
# Initializes the logging system by creating log directory and file path.
# This function is called lazily on first log message to avoid creating
# log files when they're not needed. Falls back to stdout if directory
# creation fails.
#
# Usage:
#   _blog_init_logging
#
# Returns:
#   0 - Always succeeds (uses stdout as fallback).
#
# Side Effects:
#   - Creates BLOG_LOG_DIR if it doesn't exist.
#   - Sets BLOG_LOG_FILE global variable.
# -----------------------------------------------------------------------------
_blog_init_logging() {
    if [[ -z "$BLOG_LOG_FILE" ]]; then
        BLOG_LOG_FILE="${BLOG_LOG_DIR}/blog_automation_$(date +%Y%m%d_%H%M%S).log"
        mkdir -p "$BLOG_LOG_DIR" 2>/dev/null || {
            echo "[WARNING] Cannot create log directory, using stdout"
            BLOG_LOG_FILE="/dev/stdout"
        }
    fi
}

# -----------------------------------------------------------------------------
# blog_log
# -----------------------------------------------------------------------------
# Core logging function with timestamp, level, and color support.
# Outputs to both terminal (with colors) and log file (plain text).
# Automatically initializes logging system on first use.
#
# Usage:
#   blog_log <level> <message>
#
# Arguments:
#   level - Log level: INFO, WARN, ERROR, DEBUG, SUCCESS (required).
#   message - Log message text (required).
#
# Returns:
#   0 - Always succeeds.
#
# Side Effects:
#   - Initializes logging if not already done.
#   - Writes to BLOG_LOG_FILE.
#   - Outputs colored text to terminal.
# -----------------------------------------------------------------------------
blog_log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local color=""
    local log_entry=""

    # Initialize logging if not done yet.
    _blog_init_logging

    # Set color based on level.
    case "$level" in
        "INFO")  color="" ;;
        "WARN")  color="$C_YELLOW" ;;
        "ERROR") color="$C_RED" ;;
        "DEBUG") color="$C_CYAN" ;;
        "SUCCESS") color="$C_GREEN"; level="INFO" ;;
    esac

    # Create log entry with color for terminal, plain for file.
    if [[ -t 1 ]] && [[ "$BLOG_LOG_FILE" != "/dev/stdout" ]]; then
        # Terminal output with color.
        echo "${color}[$timestamp] [$level] $message${C_RESET}"
        # Plain text to file.
        echo "[$timestamp] [$level] $message" >> "$BLOG_LOG_FILE"
    else
        # Plain text output.
        log_entry="[$timestamp] [$level] $message"
        echo "$log_entry" | tee -a "$BLOG_LOG_FILE"
    fi
}

# -----------------------------------------------------------------------------
# blog_info / blog_warn / blog_error / blog_success / blog_debug
# -----------------------------------------------------------------------------
# Convenience wrappers for blog_log function with predefined log levels.
# These functions provide simplified logging interface for common use cases.
#
# Usage:
#   blog_info <message>
#   blog_warn <message>
#   blog_error <message>
#   blog_success <message>
#   blog_debug <message>  # Only logs when BLOG_VERBOSE=true
#
# Arguments:
#   message - Log message text (required).
#
# Returns:
#   0 - Always succeeds.
# -----------------------------------------------------------------------------
blog_info() { blog_log "INFO" "$1"; }
blog_warn() { blog_log "WARN" "$1"; }
blog_error() { blog_log "ERROR" "$1"; }
blog_success() { blog_log "SUCCESS" "$1"; }
blog_debug() {
    [[ "$BLOG_VERBOSE" == "true" ]] && blog_log "DEBUG" "$1"
}

# ============================================================================ #
# ++++++++++++++++++++++ Security checks and validation ++++++++++++++++++++++ #
# ============================================================================ #

# -----------------------------------------------------------------------------
# blog_validate_location
# -----------------------------------------------------------------------------
# Validates that the script is running within the allowed blog directory.
# This security check prevents unauthorized execution in system directories
# or locations outside the designated blog workspace.
#
# Usage:
#   blog_validate_location
#
# Returns:
#   0 - Current directory is within allowed blog root.
#   1 - Directory validation failed or unsupported platform.
#
# Dependencies:
#   ALLOWED_BLOG_ROOT - Must be set by platform detection.
# -----------------------------------------------------------------------------
blog_validate_location() {
    if [[ -z "$ALLOWED_BLOG_ROOT" ]]; then
        blog_error "Unsupported operating system: $PLATFORM"
        return 1
    fi

    if [[ ! -d "$ALLOWED_BLOG_ROOT" ]]; then
        blog_error "Blog directory not found: $ALLOWED_BLOG_ROOT"
        return 1
    fi

    # Verify we're in an allowed subdirectory.
    local current_dir="$(pwd)"
    case "$current_dir" in
        "$ALLOWED_BLOG_ROOT"*)
            blog_debug "Location validated: $current_dir"
            return 0
            ;;
        *)
            blog_error "This script can only be used in: $ALLOWED_BLOG_ROOT"
            blog_error "Current directory: $current_dir"
            blog_error "Please change to the blog directory first: cd $ALLOWED_BLOG_ROOT"
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# blog_validate_path
# -----------------------------------------------------------------------------
# Validates file paths for security vulnerabilities.
# Prevents path traversal attacks, command injection, and enforces
# absolute path requirements for all file operations.
#
# Usage:
#   blog_validate_path <path> <description>
#
# Arguments:
#   path - File or directory path to validate (required).
#   description - Human-readable path description for error messages (required).
#
# Returns:
#   0 - Path is valid and secure.
#   1 - Path contains dangerous characters or is not absolute.
# -----------------------------------------------------------------------------
blog_validate_path() {
    local path="$1"
    local description="$2"

    # Check for dangerous characters.
    if [[ "$path" == *".."* ]] || [[ "$path" == *";"* ]] || [[ "$path" == *"|"* ]]; then
        blog_error "Unsafe path detected in $description: $path"
        return 1
    fi

    # Must be absolute path.
    if [[ "$path" != /* ]]; then
        blog_error "Path must be absolute for $description: $path"
        return 1
    fi

    return 0
}

# ============================================================================ #
# +++++++++++++++++++++++++ Configuration Management +++++++++++++++++++++++++ #
# ============================================================================ #

# Configuration file path.
BLOG_CONFIG_FILE="${ALLOWED_BLOG_ROOT}/blog_config.conf"

# -----------------------------------------------------------------------------
# blog_set_defaults
# -----------------------------------------------------------------------------
# Establishes default configuration values for all script variables.
# These defaults can be overridden by the configuration file or environment
# variables, providing a flexible three-tier configuration system.
#
# Usage:
#   blog_set_defaults
#
# Returns:
#   0 - Always succeeds.
#
# Side Effects:
#   - Sets all BLOG_* global variables with platform-specific defaults.
# -----------------------------------------------------------------------------
blog_set_defaults() {
    # Main directories.
    BLOG_DIR="${BLOG_DIR:-$ALLOWED_BLOG_ROOT/CS-Topics}"
    BLOG_SOURCE_PATH="${BLOG_SOURCE_PATH:-$HOME/Documents/Obsidian-Vault/XSPC-Vault/Blog/posts}"
    BLOG_IMAGES_PATH="${BLOG_IMAGES_PATH:-$HOME/Documents/Obsidian-Vault/XSPC-Vault/Blog/images}"
    BLOG_DEST_PATH="${BLOG_DEST_PATH:-$ALLOWED_BLOG_ROOT/CS-Topics/content/posts}"

    # Python scripts.
    BLOG_SCRIPTS_DIR="${BLOG_SCRIPT_DIR/python}"
    BLOG_IMAGES_SCRIPT="${BLOG_IMAGES_SCRIPT:-$BLOG_SCRIPTS_DIR/images.py}"
    BLOG_HASH_GENERATOR="${BLOG_HASH_GENERATOR:-$BLOG_SCRIPTS_DIR/generate_hashes.py}"
    BLOG_FRONTMATTER_SCRIPT="${BLOG_FRONTMATTER_SCRIPT:-$BLOG_SCRIPTS_DIR/update_frontmatter.py}"
    BLOG_HASH_FILE="${BLOG_HASH_FILE:-$BLOG_SCRIPTS_DIR/.file_hashes}"

    # Repository configuration.
    BLOG_REPO_PATH="${BLOG_REPO_PATH:-$ALLOWED_BLOG_ROOT}"
    BLOG_REPO_URL="${BLOG_REPO_URL:-git@github.com:XtremeXSPC/LCS.Dev-Blog.git}"

    # Backup settings.
    BLOG_BACKUP_DIR="${BLOG_BACKUP_DIR:-$ALLOWED_BLOG_ROOT/backups}"
    BLOG_KEEP_BACKUPS="${BLOG_KEEP_BACKUPS:-5}"

    # Timeout settings (seconds).
    BLOG_DEFAULT_TIMEOUT="${BLOG_DEFAULT_TIMEOUT:-300}"
    BLOG_GIT_TIMEOUT="${BLOG_GIT_TIMEOUT:-600}"

    # Change detection method: 'git' or 'hash'.
    BLOG_CHANGE_DETECTION="${BLOG_CHANGE_DETECTION:-git}"
}

# -----------------------------------------------------------------------------
# blog_load_config
# -----------------------------------------------------------------------------
# Loads configuration from file and validates all critical paths.
# If configuration file doesn't exist, creates a template with defaults.
# Performs security validation on all loaded paths.
#
# Usage:
#   blog_load_config
#
# Returns:
#   0 - Configuration loaded and validated successfully.
#   1 - Path validation failed.
#
# Side Effects:
#   - Sources BLOG_CONFIG_FILE if it exists.
#   - Creates config template if file missing.
# -----------------------------------------------------------------------------
blog_load_config() {
    blog_set_defaults

    if [[ -f "$BLOG_CONFIG_FILE" ]]; then
        blog_debug "Loading configuration from: $BLOG_CONFIG_FILE"
        source "$BLOG_CONFIG_FILE"
    else
        blog_warn "Configuration file not found: $BLOG_CONFIG_FILE"
        blog_create_config_template
    fi

    # Validate all critical paths.
    blog_validate_path "$BLOG_DIR" "BLOG_DIR" || return 1
    blog_validate_path "$BLOG_SOURCE_PATH" "BLOG_SOURCE_PATH" || return 1
    blog_validate_path "$BLOG_DEST_PATH" "BLOG_DEST_PATH" || return 1
    blog_validate_path "$BLOG_REPO_PATH" "BLOG_REPO_PATH" || return 1
}

# -----------------------------------------------------------------------------
# blog_create_config_template
# -----------------------------------------------------------------------------
# Creates a configuration template file with platform-specific defaults.
# Generates a ready-to-use config file with all available settings documented.
#
# Usage:
#   blog_create_config_template
#
# Returns:
#   0 - Template created successfully or in dry-run mode.
#   1 - Not applicable (function always succeeds).
#
# Side Effects:
#   - Creates BLOG_CONFIG_FILE with default values.
#   - Respects BLOG_DRY_RUN mode.
# -----------------------------------------------------------------------------
blog_create_config_template() {
    if [[ "$BLOG_DRY_RUN" == "true" ]]; then
        blog_info "[DRY-RUN] Creating configuration template"
        return 0
    fi

    blog_info "Creating configuration template: $BLOG_CONFIG_FILE"
    cat > "$BLOG_CONFIG_FILE" << EOF
# Blog Automation - Configuration file.
# Auto-generated on $(date +'%Y-%m-%d %H:%M:%S')
# System: $PLATFORM

# General settings:
BLOG_DRY_RUN=false
BLOG_VERBOSE=false

# Change detection method: 'git' or 'hash':
BLOG_CHANGE_DETECTION=git

# Main directories (customize if needed):
BLOG_DIR="$ALLOWED_BLOG_ROOT/CS-Topics"
BLOG_SOURCE_PATH="$HOME/Documents/Obsidian-Vault/XSPC-Vault/Blog/posts"
BLOG_IMAGES_PATH="$HOME/Documents/Obsidian-Vault/XSPC-Vault/Blog/images"
BLOG_DEST_PATH="$ALLOWED_BLOG_ROOT/CS-Topics/content/posts"

# Python scripts:
BLOG_SCRIPTS_DIR="$ALLOWED_BLOG_ROOT/Automatic-Updates"
BLOG_IMAGES_SCRIPT="\$BLOG_SCRIPTS_DIR/images.py"
BLOG_HASH_GENERATOR="\$BLOG_SCRIPTS_DIR/generate_hashes.py"
BLOG_FRONTMATTER_SCRIPT="\$BLOG_SCRIPTS_DIR/update_frontmatter.py"
BLOG_HASH_FILE="\$BLOG_SCRIPTS_DIR/.file_hashes"

# Git repository:
BLOG_REPO_PATH="$ALLOWED_BLOG_ROOT"
BLOG_REPO_URL="git@github.com:XtremeXSPC/LCS.Dev-Blog.git"

# Backup and performance:
BLOG_BACKUP_DIR="$ALLOWED_BLOG_ROOT/backups"
BLOG_KEEP_BACKUPS=5
BLOG_DEFAULT_TIMEOUT=300
BLOG_GIT_TIMEOUT=600
EOF
}

# ============================================================================ #
# ++++++++++++++++++++++++ Backup and recovery system ++++++++++++++++++++++++ #
# ============================================================================ #

# -----------------------------------------------------------------------------
# blog_create_backup
# -----------------------------------------------------------------------------
# Creates a timestamped backup of a directory for disaster recovery.
# Uses cp with recursive copy to preserve directory structure and permissions.
#
# Usage:
#   blog_create_backup <source_directory> <backup_name>
#
# Arguments:
#   source_directory - Directory to backup (required).
#   backup_name - Descriptive name for backup (required).
#
# Returns:
#   0 - Backup created successfully.
#   1 - Source directory doesn't exist or copy failed.
#
# Side Effects:
#   - Creates BLOG_BACKUP_DIR if needed.
#   - Outputs backup path to stdout on success.
# -----------------------------------------------------------------------------
blog_create_backup() {
    local source_dir="$1"
    local backup_name="$2"
    local backup_path="$BLOG_BACKUP_DIR/${backup_name}_$(date +%Y%m%d_%H%M%S)"

    if [[ "$BLOG_DRY_RUN" == "true" ]]; then
        blog_info "[DRY-RUN] Backup $source_dir -> $backup_path"
        return 0
    fi

    if [[ ! -d "$source_dir" ]]; then
        blog_warn "Source directory for backup doesn't exist: $source_dir"
        return 1
    fi

    mkdir -p "$BLOG_BACKUP_DIR"
    blog_info "Creating backup: $backup_path"

    if cp -r "$source_dir" "$backup_path" 2>/dev/null; then
        blog_success "Backup completed: $backup_path"
        echo "$backup_path"  # Return backup path.
        return 0
    else
        blog_error "Backup failed: $source_dir -> $backup_path"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# blog_cleanup_backups
# -----------------------------------------------------------------------------
# Removes old backup directories, retaining only the most recent ones.
# Uses BLOG_KEEP_BACKUPS setting to determine retention count.
#
# Usage:
#   blog_cleanup_backups
#
# Returns:
#   0 - Always succeeds.
#
# Side Effects:
#   - Deletes oldest backup directories exceeding retention limit.
#
# Dependencies:
#   BLOG_KEEP_BACKUPS - Number of backups to retain.
# -----------------------------------------------------------------------------
blog_cleanup_backups() {
    if [[ "$BLOG_DRY_RUN" == "true" ]]; then
        blog_info "[DRY-RUN] Cleaning old backups (keeping last $BLOG_KEEP_BACKUPS)"
        return 0
    fi

    if [[ ! -d "$BLOG_BACKUP_DIR" ]]; then
        return 0
    fi

    local backup_count=$(find "$BLOG_BACKUP_DIR" -maxdepth 1 -type d -name "*_[0-9]*" | wc -l)
    if [[ $backup_count -gt $BLOG_KEEP_BACKUPS ]]; then
        blog_info "Cleaning old backups (found: $backup_count, keeping: $BLOG_KEEP_BACKUPS)"
        find "$BLOG_BACKUP_DIR" -maxdepth 1 -type d -name "*_[0-9]*" | sort | head -n -$BLOG_KEEP_BACKUPS | xargs rm -rf
    fi
}

# ============================================================================ #
# +++++++++++++++++++++++++++++ System utilities +++++++++++++++++++++++++++++ #
# ============================================================================ #

# -----------------------------------------------------------------------------
# blog_check_command
# -----------------------------------------------------------------------------
# Verifies that a required command exists in the system PATH.
# Logs error if command is not found.
#
# Usage:
#   blog_check_command <command_name>
#
# Arguments:
#   command_name - Name of command to check (required).
#
# Returns:
#   0 - Command found in PATH.
#   1 - Command not found.
# -----------------------------------------------------------------------------
blog_check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        blog_error "Required command not found: $cmd"
        return 1
    fi
    blog_debug "Command found: $cmd"
    return 0
}

# -----------------------------------------------------------------------------
# blog_check_dir
# -----------------------------------------------------------------------------
# Validates directory existence and optionally creates it if missing.
# Supports auto-creation for cases where directory is expected to be created
# during initialization.
#
# Usage:
#   blog_check_dir <directory> <description> [create_if_missing]
#
# Arguments:
#   directory - Directory path to check (required).
#   description - Human-readable description for logging (required).
#   create_if_missing - Create if doesn't exist: true/false (optional, default: false).
#
# Returns:
#   0 - Directory exists or was created successfully.
#   1 - Directory doesn't exist and creation failed/disabled.
# -----------------------------------------------------------------------------
blog_check_dir() {
    local dir="$1"
    local description="$2"
    local create_if_missing="${3:-false}"

    if [[ ! -d "$dir" ]]; then
        if [[ "$create_if_missing" == "true" ]]; then
            blog_warn "$description directory doesn't exist, creating: $dir"
            if [[ "$BLOG_DRY_RUN" == "true" ]]; then
                blog_info "[DRY-RUN] mkdir -p $dir"
                return 0
            else
                mkdir -p "$dir" || {
                    blog_error "Cannot create $description directory: $dir"
                    return 1
                }
            fi
        else
            blog_error "$description directory not found: $dir"
            return 1
        fi
    fi

    blog_debug "$description directory: $dir ✓"
    return 0
}

# -----------------------------------------------------------------------------
# blog_check_file
# -----------------------------------------------------------------------------
# Validates that a required file exists at the specified path.
#
# Usage:
#   blog_check_file <file_path> <description>
#
# Arguments:
#   file_path - Path to file (required).
#   description - Human-readable description for logging (required).
#
# Returns:
#   0 - File exists.
#   1 - File not found.
# -----------------------------------------------------------------------------
blog_check_file() {
    local file="$1"
    local description="$2"

    if [[ ! -f "$file" ]]; then
        blog_error "$description file not found: $file"
        return 1
    fi

    blog_debug "$description file: $file ✓"
    return 0
}

# -----------------------------------------------------------------------------
# blog_run_with_timeout
# -----------------------------------------------------------------------------
# Executes a command with timeout protection to prevent hanging operations.
# Falls back to execution without timeout if timeout command is unavailable.
#
# Usage:
#   blog_run_with_timeout <timeout_seconds> <description> <command> [args...]
#
# Arguments:
#   timeout_seconds - Maximum execution time in seconds (required).
#   description - Human-readable operation description (required).
#   command - Command to execute (required).
#   args - Command arguments (optional).
#
# Returns:
#   Exit code of the executed command.
#
# Dependencies:
#   timeout - GNU timeout command (optional, graceful degradation).
# -----------------------------------------------------------------------------
blog_run_with_timeout() {
    local timeout="$1"
    local description="$2"
    shift 2

    if [[ "$BLOG_DRY_RUN" == "true" ]]; then
        blog_info "[DRY-RUN] $description: $*"
        return 0
    fi

    blog_debug "Executing with ${timeout}s timeout: $*"

    if command -v timeout &>/dev/null; then
        timeout "${timeout}s" "$@"
        return $?
    else
        # Fallback without timeout.
        blog_warn "'timeout' command not available, executing without timeout"
        "$@"
        return $?
    fi
}

# ============================================================================ #
# ++++++++++++++++++++++++ Git-based change detection ++++++++++++++++++++++++ #
# ============================================================================ #

# -----------------------------------------------------------------------------
# blog_detect_git_changes
# -----------------------------------------------------------------------------
# Detects changed markdown files using Git status output.
# Parses git status --porcelain to identify modified, new, or deleted files
# in the content/posts directory. More efficient than hash-based detection.
#
# Usage:
#   blog_detect_git_changes
#
# Returns:
#   0 - Changes detected or no Git repo (treats all as changed).
#   1 - No changes detected.
#
# Side Effects:
#   - Sets BLOG_CHANGED_FILES array with list of changed markdown files.
#
# Dependencies:
#   git - Git version control system.
# -----------------------------------------------------------------------------
blog_detect_git_changes() {
    local current_dir="$(pwd)"
    cd "$BLOG_REPO_PATH" || {
        blog_error "Cannot access repository: $BLOG_REPO_PATH"
        return 1
    }

    if [[ ! -d ".git" ]]; then
        blog_warn "Git repository not found, treating all files as changed"
        cd "$current_dir"
        return 0
    fi

    # Get list of changed files (modified, new, deleted).
    local git_status=$(git status --porcelain 2>/dev/null)

    if [[ -z "$git_status" ]]; then
        blog_info "No changes detected by Git"
        BLOG_CHANGED_FILES=()
        cd "$current_dir"
        return 1
    fi

    # Parse git status output to get list of changed markdown files.
    BLOG_CHANGED_FILES=()
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            # Extract filename (remove status indicators).
            local file=$(echo "$line" | sed 's/^...//')
            # Only include markdown files in content/posts.
            if [[ "$file" == *"content/posts"*".md" ]]; then
                BLOG_CHANGED_FILES+=("$file")
            fi
        fi
    done <<< "$git_status"

    local change_count=${#BLOG_CHANGED_FILES[@]}
    if [[ $change_count -gt 0 ]]; then
        blog_info "Git detected $change_count changed markdown files"
        blog_debug "Changed files: ${BLOG_CHANGED_FILES[*]}"
    fi

    cd "$current_dir"
    return 0
}

# -----------------------------------------------------------------------------
# blog_detect_hash_changes
# -----------------------------------------------------------------------------
# Detects file changes using SHA256 hash comparison (fallback method).
# Generates hashes for all markdown files and compares with previous run.
# More portable but slower than Git-based detection.
#
# Usage:
#   blog_detect_hash_changes
#
# Returns:
#   0 - Hash generation completed successfully.
#   1 - Python not available or hash generation failed.
#
# Side Effects:
#   - Creates/updates BLOG_HASH_FILE.
#   - Backs up previous hash file.
#
# Dependencies:
#   python3 - Python 3 interpreter.
#   BLOG_HASH_GENERATOR - Python script for hash generation.
# -----------------------------------------------------------------------------
blog_detect_hash_changes() {
    blog_info "Using hash-based change detection"

    blog_check_command python3 || return 1
    blog_check_file "$BLOG_HASH_GENERATOR" "Hash generator script" || return 1
    blog_check_dir "$BLOG_DEST_PATH" "Destination" || return 1

    # Backup previous hash file.
    if [[ -f "$BLOG_HASH_FILE" ]] && [[ "$BLOG_DRY_RUN" != "true" ]]; then
        cp "$BLOG_HASH_FILE" "${BLOG_HASH_FILE}.backup" || {
            blog_warn "Cannot backup hash file"
        }
    fi

    blog_info "Generating hashes for: $BLOG_DEST_PATH"

    if blog_run_with_timeout $BLOG_DEFAULT_TIMEOUT "python hash generator" python3 "$BLOG_HASH_GENERATOR" "$BLOG_DEST_PATH"; then
        blog_success "Hash generation completed"

        if [[ "$BLOG_DRY_RUN" != "true" ]] && [[ -f "$BLOG_HASH_FILE" ]]; then
            local hash_count=$(wc -l < "$BLOG_HASH_FILE")
            blog_info "Generated hashes for $hash_count files"
        fi
        return 0
    else
        blog_error "Hash generation failed"
        return 1
    fi
}

# ============================================================================ #
# +++++++++++++++++++++++++++ Main blog functions ++++++++++++++++++++++++++++ #
# ============================================================================ #

# -----------------------------------------------------------------------------
# _blog_ensure_valid_location
# -----------------------------------------------------------------------------
# Internal wrapper that validates location and loads configuration.
# Called by all main blog functions to ensure security and proper setup.
#
# Usage:
#   _blog_ensure_valid_location
#
# Returns:
#   0 - Location valid and configuration loaded.
#   1 - Validation or configuration loading failed.
# -----------------------------------------------------------------------------
_blog_ensure_valid_location() {
    if ! blog_validate_location; then
        return 1
    fi
    if ! blog_load_config; then
        blog_error "Configuration loading error"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# blog_backup_before_sync
# -----------------------------------------------------------------------------
# Creates a backup before synchronization if destination contains data.
# Prevents data loss during sync operations.
#
# Usage:
#   blog_backup_before_sync <destination_path>
#
# Arguments:
#   destination_path - Directory to backup before sync (required).
#
# Returns:
#   0 - Always succeeds (backup is optional safety measure).
#
# Side Effects:
#   - Outputs backup path to stdout if backup created.
#   - Outputs empty string if no backup needed.
# -----------------------------------------------------------------------------
blog_backup_before_sync() {
    local dest_path="$1"
    local backup_path=""

    if [[ -d "$dest_path" ]] && [[ "$(ls -A "$dest_path" 2>/dev/null)" ]]; then
        backup_path=$(blog_create_backup "$dest_path" "posts_sync")
        if [[ -z "$backup_path" ]]; then
            blog_warn "Backup failed, continuing anyway"
        fi
    fi

    echo "$backup_path"
}

# -----------------------------------------------------------------------------
# blog_init_git
# -----------------------------------------------------------------------------
# Initializes Git repository with remote origin configuration.
# Creates new repository if needed or verifies existing setup.
# Ensures remote origin points to correct blog repository URL.
#
# Usage:
#   blog_init_git
#
# Returns:
#   0 - Git repository initialized and configured.
#   1 - Git initialization or remote configuration failed.
#
# Dependencies:
#   git - Git version control system.
#   BLOG_REPO_URL - Remote repository URL.
# -----------------------------------------------------------------------------
blog_init_git() {
    blog_info "${C_BOLD}=== Git Initialization ===${C_RESET}"

    _blog_ensure_valid_location || return 1

    # Change to blog repository directory.
    local current_dir="$(pwd)"
    cd "$BLOG_REPO_PATH" || {
        blog_error "Cannot access: $BLOG_REPO_PATH"
        return 1
    }

    # Initialize Git repository if not present.
    if [[ ! -d ".git" ]]; then
        blog_info "Initializing new Git repository"
        blog_run_with_timeout $BLOG_GIT_TIMEOUT "git init" git init || {
            cd "$current_dir"
            return 1
        }
        blog_run_with_timeout $BLOG_GIT_TIMEOUT "git remote add" git remote add origin "$BLOG_REPO_URL" || {
            cd "$current_dir"
            return 1
        }
    else
        blog_info "Git repository already initialized"

        # Verify remote origin exists and is correct.
        if ! git remote get-url origin &>/dev/null; then
            blog_info "Adding remote origin"
            blog_run_with_timeout $BLOG_GIT_TIMEOUT "git remote add" git remote add origin "$BLOG_REPO_URL" || {
                cd "$current_dir"
                return 1
            }
        fi
    fi

    cd "$current_dir"
    blog_success "Git initialization completed"
    return 0
}

# -----------------------------------------------------------------------------
# blog_sync_posts
# -----------------------------------------------------------------------------
# Synchronizes markdown posts from Obsidian vault to Hugo content directory.
# Uses rsync for efficient file synchronization with --delete flag to mirror
# source directory. Includes integrity verification post-sync.
#
# Usage:
#   blog_sync_posts
#
# Returns:
#   0 - Synchronization completed successfully.
#   1 - Source/destination validation failed or rsync failed.
#
# Side Effects:
#   - Creates destination directory if it doesn't exist.
#   - Deletes files in destination not present in source.
#   - Attempts recovery from backup on failure.
#
# Dependencies:
#   rsync - File synchronization tool.
# -----------------------------------------------------------------------------
blog_sync_posts() {
    blog_info "${C_BOLD}=== Posts Synchronization ===${C_RESET}"

    _blog_ensure_valid_location || return 1

    blog_check_dir "$BLOG_SOURCE_PATH" "Source" || return 1
    blog_check_dir "$BLOG_DEST_PATH" "Destination" true || return 1

    # Create backup before synchronization.
    # local backup_path=$(blog_backup_before_sync "$BLOG_DEST_PATH")

    blog_info "Synchronizing: $BLOG_SOURCE_PATH -> $BLOG_DEST_PATH"

    if [[ "$BLOG_DRY_RUN" == "true" ]]; then
        blog_info "[DRY-RUN] rsync -av --delete $BLOG_SOURCE_PATH/ $BLOG_DEST_PATH/"
    else
        if blog_run_with_timeout $BLOG_DEFAULT_TIMEOUT "rsync sync" rsync -av --delete "$BLOG_SOURCE_PATH/" "$BLOG_DEST_PATH/"; then
            blog_success "Synchronization completed"

            # Verify integrity post-sync.
            local src_count=$(find "$BLOG_SOURCE_PATH" -name "*.md" -type f | wc -l)
            local dest_count=$(find "$BLOG_DEST_PATH" -name "*.md" -type f | wc -l)
            blog_info "Markdown files - Source: $src_count, Destination: $dest_count"

            if [[ $src_count -ne $dest_count ]]; then
                blog_warn "File count differs after synchronization"
            fi
        else
            blog_error "Synchronization failed"

            # Attempt recovery from backup.
            if [[ -n "$backup_path" ]] && [[ -d "$backup_path" ]]; then
                blog_warn "Attempting recovery from backup: $backup_path"
                rm -rf "$BLOG_DEST_PATH"/*
                cp -r "$backup_path/." "$BLOG_DEST_PATH/" || {
                    blog_error "Recovery from backup failed"
                }
            fi
            return 1
        fi
    fi

    return 0
}

# -----------------------------------------------------------------------------
# blog_detect_changes
# -----------------------------------------------------------------------------
# Main change detection orchestrator that delegates to Git or hash method.
# Uses BLOG_CHANGE_DETECTION setting to determine which detection
# method to use (git or hash).
#
# Usage:
#   blog_detect_changes
#
# Returns:
#   0 - Change detection completed (delegates to selected method).
#   1 - Location validation failed.
#
# Dependencies:
#   BLOG_CHANGE_DETECTION - Detection method: 'git' or 'hash'.
# -----------------------------------------------------------------------------
blog_detect_changes() {
    blog_info "${C_BOLD}=== Change Detection ===${C_RESET}"

    _blog_ensure_valid_location || return 1

    # Determine detection method.
    case "$BLOG_CHANGE_DETECTION" in
        "git")
            blog_info "Using Git-based change detection"
            blog_detect_git_changes
            ;;
        "hash")
            blog_info "Using hash-based change detection"
            blog_detect_hash_changes
            ;;
        *)
            blog_warn "Unknown change detection method: $BLOG_CHANGE_DETECTION, using Git"
            blog_detect_git_changes
            ;;
    esac
}

# -----------------------------------------------------------------------------
# blog_update_frontmatter
# -----------------------------------------------------------------------------
# Updates YAML frontmatter metadata in markdown files.
# Intelligently processes only changed files (Git mode) or uses hash-based
# detection to minimize unnecessary processing. Updates fields like date,
# modified, tags, and other metadata.
#
# Usage:
#   blog_update_frontmatter
#
# Returns:
#   0 - Frontmatter update completed successfully.
#   1 - Python unavailable, script missing, or update failed.
#
# Dependencies:
#   python3 - Python 3 interpreter.
#   BLOG_FRONTMATTER_SCRIPT - Python script for frontmatter updates.
#   BLOG_CHANGED_FILES - Array of changed files (Git mode).
# -----------------------------------------------------------------------------
blog_update_frontmatter() {
    blog_info "${C_BOLD}=== Frontmatter Update ===${C_RESET}"

    _blog_ensure_valid_location || return 1

    blog_check_command python3 || return 1
    blog_check_file "$BLOG_FRONTMATTER_SCRIPT" "Frontmatter script" || return 1
    blog_check_dir "$BLOG_DEST_PATH" "Destination" || return 1

    # For hash-based detection, verify hash file exists.
    if [[ "$BLOG_CHANGE_DETECTION" == "hash" ]]; then
        if [[ ! -f "$BLOG_HASH_FILE" ]]; then
            blog_warn "Hash file not found, generating hashes first"
            blog_detect_hash_changes || return 1
        fi

        blog_info "Updating frontmatter for: $BLOG_DEST_PATH"

        if blog_run_with_timeout $BLOG_DEFAULT_TIMEOUT "python frontmatter update" python3 "$BLOG_FRONTMATTER_SCRIPT" "$BLOG_DEST_PATH" "$BLOG_HASH_FILE"; then
            blog_success "Frontmatter update completed"
            return 0
        else
            blog_error "Frontmatter update failed"
            return 1
        fi
    else
        # Git-based: process only changed files or all if no specific changes detected.
        if [[ ${#BLOG_CHANGED_FILES[@]} -eq 0 ]]; then
            blog_info "No specific changed files, processing all files"
            if blog_run_with_timeout $BLOG_DEFAULT_TIMEOUT "python frontmatter update" python3 "$BLOG_FRONTMATTER_SCRIPT" "$BLOG_DEST_PATH"; then
                blog_success "Frontmatter update completed"
                return 0
            else
                blog_error "Frontmatter update failed"
                return 1
            fi
        else
            blog_info "Processing ${#BLOG_CHANGED_FILES[@]} changed files"
            for file in "${BLOG_CHANGED_FILES[@]}"; do
                local full_path="$BLOG_REPO_PATH/$file"
                if [[ -f "$full_path" ]]; then
                    blog_debug "Processing: $file"
                    if ! blog_run_with_timeout $BLOG_DEFAULT_TIMEOUT "python frontmatter update file" python3 "$BLOG_FRONTMATTER_SCRIPT" "$full_path"; then
                        blog_error "Frontmatter update failed for: $file"
                        return 1
                    fi
                fi
            done
            blog_success "Frontmatter update completed for changed files"
        fi
    fi

    return 0
}

# -----------------------------------------------------------------------------
# blog_process_images
# -----------------------------------------------------------------------------
# Processes and converts image links in markdown files.
# Transforms Obsidian-style image references (![[image.png]]) to Hugo-compatible
# markdown format (![alt](path/to/image.png)).
#
# Usage:
#   blog_process_images
#
# Returns:
#   0 - Image processing completed successfully.
#   1 - Python unavailable, script missing, or processing failed.
#
# Dependencies:
#   python3 - Python 3 interpreter.
#   BLOG_IMAGES_SCRIPT - Python script for image processing.
# -----------------------------------------------------------------------------
blog_process_images() {
    blog_info "${C_BOLD}=== Image Processing ===${C_RESET}"

    _blog_ensure_valid_location || return 1

    blog_check_command python3 || return 1
    blog_check_file "$BLOG_IMAGES_SCRIPT" "Images script" || return 1

    blog_info "Processing markdown images"

    if blog_run_with_timeout $BLOG_DEFAULT_TIMEOUT "python images processor" python3 "$BLOG_IMAGES_SCRIPT"; then
        blog_success "Image processing completed"
        return 0
    else
        blog_error "Image processing failed"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# blog_build_hugo
# -----------------------------------------------------------------------------
# Builds the Hugo static site from markdown content.
# Generates HTML, CSS, JavaScript, and assets in the 'public' directory
# ready for deployment. Verifies build success by checking output directory.
#
# Usage:
#   blog_build_hugo
#
# Returns:
#   0 - Hugo build completed and public directory created.
#   1 - Hugo unavailable, build failed, or public directory missing.
#
# Side Effects:
#   - Creates/updates 'public' directory in BLOG_DIR.
#   - Reports count of generated files.
# -----------------------------------------------------------------------------
blog_build_hugo() {
    blog_info "${C_BOLD}=== Hugo Site Build ===${C_RESET}"

    _blog_ensure_valid_location || return 1

    blog_check_command hugo || return 1
    blog_check_dir "$BLOG_DIR" "Blog" || return 1

    local current_dir="$(pwd)"
    cd "$BLOG_DIR" || {
        blog_error "Cannot access: $BLOG_DIR"
        return 1
    }

    blog_info "Building Hugo in: $BLOG_DIR"

    if blog_run_with_timeout $BLOG_DEFAULT_TIMEOUT "hugo build" hugo; then
        if [[ -d "public" ]]; then
            local file_count=$(find public -type f | wc -l)
            blog_success "Hugo build completed - $file_count files generated"
            cd "$current_dir"
            return 0
        else
            blog_error "Build completed but 'public' directory not found"
            cd "$current_dir"
            return 1
        fi
    else
        blog_error "Hugo build failed"
        cd "$current_dir"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# blog_commit_changes
# -----------------------------------------------------------------------------
# Commits all changes to the Git repository with timestamped message.
# Stages all modified, new, and deleted files. Skips commit if working
# directory is clean.
#
# Usage:
#   blog_commit_changes
#
# Returns:
#   0 - Changes committed or no changes to commit.
#   1 - Git repository not initialized or commit failed.
#
# Side Effects:
#   - Stages all changes with git add.
#   - Creates commit with platform-specific timestamp.
# -----------------------------------------------------------------------------
blog_commit_changes() {
    blog_info "${C_BOLD}=== Commit Changes ===${C_RESET}"

    _blog_ensure_valid_location || return 1

    local current_dir="$(pwd)"
    cd "$BLOG_REPO_PATH" || {
        blog_error "Cannot access: $BLOG_REPO_PATH"
        return 1
    }

    if [[ ! -d ".git" ]]; then
        blog_error "Git repository not initialized"
        cd "$current_dir"
        return 1
    fi

    # Check if there are changes to commit.
    if git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
        blog_info "No changes to commit"
        cd "$current_dir"
        return 0
    fi

    local commit_message="Blog update $(date +'%Y-%m-%d %H:%M:%S') from $PLATFORM"
    blog_info "Committing changes: $commit_message"

    if [[ "$BLOG_DRY_RUN" == "true" ]]; then
        blog_info "[DRY-RUN] git add ."
        blog_info "[DRY-RUN] git commit -m '$commit_message'"
    else
        git add . || {
            blog_error "Git add failed"
            cd "$current_dir"
            return 1
        }

        git commit -m "$commit_message" || {
            blog_error "Git commit failed"
            cd "$current_dir"
            return 1
        }
    fi

    cd "$current_dir"
    blog_success "Commit completed"
    return 0
}

# -----------------------------------------------------------------------------
# blog_push_main
# -----------------------------------------------------------------------------
# Pushes committed changes to the main branch on remote repository.
# Ensures main branch exists and switches to it before pushing.
# Creates main branch if it doesn't exist.
#
# Usage:
#   blog_push_main
#
# Returns:
#   0 - Push completed successfully.
#   1 - Branch creation/switch failed or push failed.
# -----------------------------------------------------------------------------
blog_push_main() {
    blog_info "${C_BOLD}=== Push to Main Branch ===${C_RESET}"

    _blog_ensure_valid_location || return 1

    local current_dir="$(pwd)"
    cd "$BLOG_REPO_PATH" || {
        blog_error "Cannot access: $BLOG_REPO_PATH"
        return 1
    }

    # Ensure we're on the main branch.
    if ! git rev-parse --verify main &>/dev/null; then
        blog_info "Creating main branch"
        if [[ "$BLOG_DRY_RUN" == "true" ]]; then
            blog_info "[DRY-RUN] git checkout -b main"
        else
            git checkout -b main || {
                blog_error "Cannot create main branch"
                cd "$current_dir"
                return 1
            }
        fi
    else
        blog_info "Switching to main branch"
        if [[ "$BLOG_DRY_RUN" != "true" ]]; then
            git checkout main || {
                blog_error "Cannot switch to main"
                cd "$current_dir"
                return 1
            }
        fi
    fi

    blog_info "Pushing to remote repository"

    if blog_run_with_timeout $BLOG_GIT_TIMEOUT "git push" git push origin main; then
        blog_success "Push completed"
        cd "$current_dir"
        return 0
    else
        blog_error "Push failed"
        cd "$current_dir"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# blog_deploy_hostinger
# -----------------------------------------------------------------------------
# Deploys Hugo-generated public directory to Hostinger hosting branch.
# Uses git subtree to split public directory into separate deployment branch.
# Force-pushes to hostinger branch for clean deployment.
#
# Usage:
#   blog_deploy_hostinger
#
# Returns:
#   0 - Deployment completed successfully.
#   1 - Public directory missing, subtree creation failed, or push failed.
#
# Side Effects:
#   - Creates temporary hostinger-deploy branch.
#   - Force-pushes to remote hostinger branch.
#   - Cleans up temporary branch after deployment.
#
# Dependencies:
#   git - Git version control system with subtree support.
# -----------------------------------------------------------------------------
blog_deploy_hostinger() {
    blog_info "${C_BOLD}=== Deploy to Hostinger ===${C_RESET}"

    _blog_ensure_valid_location || return 1

    local current_dir="$(pwd)"
    cd "$BLOG_REPO_PATH" || {
        blog_error "Cannot access: $BLOG_REPO_PATH"
        return 1
    }

    # Verify public directory exists.
    local public_dir="CS-Topics/public"
    if [[ ! -d "$public_dir" ]]; then
        blog_error "Public directory not found: $public_dir"
        cd "$current_dir"
        return 1
    fi

    # Remove temporary branch if exists.
    if git rev-parse --verify hostinger-deploy &>/dev/null; then
        blog_info "Removing temporary hostinger-deploy branch"
        if [[ "$BLOG_DRY_RUN" != "true" ]]; then
            git branch -D hostinger-deploy || blog_warn "Cannot remove temporary branch"
        fi
    fi

    blog_info "Creating subtree for deployment"

    if [[ "$BLOG_DRY_RUN" == "true" ]]; then
        blog_info "[DRY-RUN] git subtree split --prefix '$public_dir' -b hostinger-deploy"
        blog_info "[DRY-RUN] git push origin hostinger-deploy:hostinger --force"
        blog_info "[DRY-RUN] git branch -D hostinger-deploy"
    else
        # Create subtree from public directory.
        if ! git subtree split --prefix "$public_dir" -b hostinger-deploy; then
            blog_error "Subtree creation failed"
            cd "$current_dir"
            return 1
        fi

        # Push to hostinger branch.
        if ! blog_run_with_timeout $BLOG_GIT_TIMEOUT "git push hostinger" git push origin hostinger-deploy:hostinger --force; then
            blog_error "Push to hostinger failed"
            cd "$current_dir"
            return 1
        fi

        # Cleanup temporary branch.
        git branch -D hostinger-deploy || blog_warn "Temporary branch cleanup failed"
    fi

    cd "$current_dir"
    blog_success "Deployment to Hostinger completed"
    return 0
}

# ============================================================================ #
# +++++++++++++++++++++++++ Orchestration functions ++++++++++++++++++++++++++ #
# ============================================================================ #

# -----------------------------------------------------------------------------
# blog_run_all
# -----------------------------------------------------------------------------
# Orchestrates complete blog automation workflow from sync to deployment.
# Executes all blog automation steps in sequence with timing and error tracking.
# Stops on first error and reports which step failed.
#
# Usage:
#   blog_run_all
#
# Returns:
#   0 - All steps completed successfully.
#   1 - One or more steps failed.
#
# Side Effects:
#   - Executes all blog workflow functions in order.
#   - Cleans up old backups on success.
#   - Reports total execution time.
# -----------------------------------------------------------------------------
blog_run_all() {
    blog_info "${C_BOLD}${C_MAGENTA}=== Starting Complete Blog Automation Process ===${C_RESET}"

    local start_time=$(date +%s)
    local failed_step=""

    # Array of all steps in execution order.
    local steps=(
        "blog_init_git"
        "blog_sync_posts"
        "blog_detect_changes"
        # "blog_update_frontmatter"
        "blog_process_images"
        "blog_build_hugo"
        "blog_commit_changes"
        "blog_push_main"
        "blog_deploy_hostinger"
    )

    # Execute all steps.
    for step in "${steps[@]}"; do
        blog_info ">>> Executing: $step"
        if ! $step; then
            failed_step="$step"
            break
        fi
        blog_info "<<< Completed: $step"
        echo ""
    done

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [[ -n "$failed_step" ]]; then
        blog_error "Process interrupted at step: $failed_step"
        blog_error "Duration before failure: ${duration}s"
        return 1
    else
        blog_success "${C_BOLD}=== Process Completed Successfully ===${C_RESET}"
        blog_info "Total duration: ${duration}s"

        # Cleanup old backups.
        blog_cleanup_backups

        return 0
    fi
}

# ============================================================================ #
# ++++++++++++++++++++++++ Utility and help functions ++++++++++++++++++++++++ #
# ============================================================================ #

# -----------------------------------------------------------------------------
# blog_status
# -----------------------------------------------------------------------------
# Displays comprehensive system status and configuration information.
# Shows platform details, paths, dependency checks, and location validation.
# Useful for debugging, troubleshooting, and verifying setup.
#
# Usage:
#   blog_status
#
# Returns:
#   0 - Always succeeds (informational only).
#
# Side Effects:
#   - Loads default configuration for display.
#   - Does not require location validation.
# -----------------------------------------------------------------------------
blog_status() {
    blog_info "${C_BOLD}=== Blog Automation Status ===${C_RESET}"

    # This function doesn't require location validation as it's just showing info.
    blog_set_defaults
    if [[ -f "$BLOG_CONFIG_FILE" ]]; then
        source "$BLOG_CONFIG_FILE"
    fi

    blog_info "Version: $VERSION"
    blog_info "Platform: $PLATFORM"
    blog_info "Allowed blog directory: $ALLOWED_BLOG_ROOT"
    blog_info "Current directory: $(pwd)"

    echo ""
    blog_info "=== Configuration ==="
    blog_info "BLOG_DIR: ${BLOG_DIR:-NOT SET}"
    blog_info "BLOG_SOURCE_PATH: ${BLOG_SOURCE_PATH:-NOT SET}"
    blog_info "BLOG_DEST_PATH: ${BLOG_DEST_PATH:-NOT SET}"
    blog_info "BLOG_CHANGE_DETECTION: ${BLOG_CHANGE_DETECTION:-NOT SET}"
    blog_info "BLOG_DRY_RUN: ${BLOG_DRY_RUN:-false}"
    blog_info "BLOG_VERBOSE: ${BLOG_VERBOSE:-false}"

    echo ""
    blog_info "=== Dependency Check ==="
    for cmd in python3 hugo git rsync; do
        if command -v "$cmd" &>/dev/null; then
            blog_info "$cmd: ${C_GREEN}✓${C_RESET} $(command -v "$cmd")"
        else
            blog_warn "$cmd: ${C_RED}✗ NOT FOUND${C_RESET}"
        fi
    done

    echo ""
    blog_info "=== File Check ==="
    for file in "$BLOG_HASH_GENERATOR" "$BLOG_FRONTMATTER_SCRIPT" "$BLOG_IMAGES_SCRIPT"; do
        if [[ -f "$file" ]]; then
            blog_info "$(basename "$file"): ${C_GREEN}✓${C_RESET}"
        else
            blog_warn "$(basename "$file"): ${C_RED}✗${C_RESET} $file"
        fi
    done

    echo ""
    blog_info "=== Location Check ==="
    if [[ -d "$ALLOWED_BLOG_ROOT" ]]; then
        blog_info "Blog root: ${C_GREEN}✓${C_RESET} $ALLOWED_BLOG_ROOT"
        local current_dir="$(pwd)"
        case "$current_dir" in
            "$ALLOWED_BLOG_ROOT"*)
                blog_info "Current location: ${C_GREEN}✓ Valid${C_RESET}"
                ;;
            *)
                blog_warn "Current location: ${C_YELLOW}⚠ Outside blog directory${C_RESET}"
                blog_info "To use blog functions, run: ${C_CYAN}cd $ALLOWED_BLOG_ROOT${C_RESET}"
                ;;
        esac
    else
        blog_error "Blog root: ${C_RED}✗ Not found${C_RESET}"
    fi
}

# -----------------------------------------------------------------------------
# blog_help
# -----------------------------------------------------------------------------
# Displays comprehensive help information for blog automation script.
# Shows usage examples, available functions, environment variables,
# restrictions, and configuration file locations.
#
# Usage:
#   blog_help
#
# Returns:
#   0 - Always succeeds.
# -----------------------------------------------------------------------------
blog_help() {
    cat << EOF
${C_BOLD}Blog Automation Script v$VERSION - System: $PLATFORM${C_RESET}

${C_BOLD}USAGE:${C_RESET}
    Individual functions:
        ${C_CYAN}blog_init_git${C_RESET}              - Initialize Git repository
        ${C_CYAN}blog_sync_posts${C_RESET}            - Sync posts from Obsidian
        ${C_CYAN}blog_detect_changes${C_RESET}        - Detect changes (Git or hash-based)
        ${C_CYAN}blog_update_frontmatter${C_RESET}    - Update post frontmatter
        ${C_CYAN}blog_process_images${C_RESET}        - Process images in posts
        ${C_CYAN}blog_build_hugo${C_RESET}            - Build Hugo site
        ${C_CYAN}blog_commit_changes${C_RESET}        - Commit changes to Git
        ${C_CYAN}blog_push_main${C_RESET}             - Push to main branch
        ${C_CYAN}blog_deploy_hostinger${C_RESET}      - Deploy to hostinger branch

    Orchestration:
        ${C_GREEN}blog_run_all${C_RESET}               - Execute all steps in sequence

    Utilities:
        ${C_YELLOW}blog_status${C_RESET}                - Show system status
        ${C_YELLOW}blog_help${C_RESET}                  - Show this help

${C_BOLD}ENVIRONMENT VARIABLES:${C_RESET}
    ${C_CYAN}BLOG_DRY_RUN=true${C_RESET}              - Dry-run mode (default: false)
    ${C_CYAN}BLOG_VERBOSE=true${C_RESET}              - Verbose output (default: false)
    ${C_CYAN}BLOG_CHANGE_DETECTION=git${C_RESET}      - Change detection method (git/hash)

${C_BOLD}RESTRICTIONS:${C_RESET}
    This script only works in: ${C_YELLOW}$ALLOWED_BLOG_ROOT${C_RESET}
    Current directory: $(pwd)

${C_BOLD}CONFIGURATION:${C_RESET}
    File: $BLOG_CONFIG_FILE
    Logs: $BLOG_LOG_DIR/
    Backups: ${BLOG_BACKUP_DIR:-$ALLOWED_BLOG_ROOT/backups}/

${C_BOLD}EXAMPLES:${C_RESET}
    # Complete execution
    ${C_GREEN}blog_run_all${C_RESET}

    # Dry-run mode
    ${C_CYAN}BLOG_DRY_RUN=true blog_run_all${C_RESET}

    # Sync only
    ${C_CYAN}blog_sync_posts${C_RESET}

    # Status check
    ${C_YELLOW}blog_status${C_RESET}

    # Git-based change detection
    ${C_CYAN}BLOG_CHANGE_DETECTION=git blog_run_all${C_RESET}
EOF
}

# ============================================================================ #
# End of script.
