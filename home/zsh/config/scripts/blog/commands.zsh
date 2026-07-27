#!/usr/bin/env zsh
# ============================================================================ #
# +++++++++++++++++++++++++ BLOG AUTOMATION COMMANDS +++++++++++++++++++++++++ #
# ============================================================================ #
# Comprehensive Hugo blog automation system with Obsidian vault integration.
#
# This script provides a complete blog publishing workflow that:
#  - Synchronizes markdown posts from an Obsidian vault to Hugo content directory
#  - Detects file changes using Git status or hash-based comparison
#  - Updates YAML frontmatter metadata in blog posts
#  - Processes and converts Obsidian-style image links to Hugo format
#  - Builds static site with Hugo generator
#  - Manages Git commits and deployment to remote repositories
#  - Supports multiple deployment targets (main branch and Hostinger)
#  - Implements security validation, backup/recovery, and comprehensive logging
#
# The script is platform-aware (macOS/Linux) with configurable paths, dry-run
# mode for testing, verbose logging, and timeout protection for long-running
# operations.
#
# Author: XtremeXSPC
# Version: 2.1.0 - Git-based change detection
# License: MIT
# ============================================================================ #

_blog_workflow_ready() {
    local fn
    for fn in blog_run_all blog_sync_posts blog_commit_changes blog_deploy_hostinger blog_status blog_help; do
        typeset -f "$fn" >/dev/null 2>&1 || return 1
    done
}

if [[ -n "${_BLOG_WORKFLOW_LOADED:-}" ]] && _blog_workflow_ready; then
    unfunction _blog_workflow_ready 2>/dev/null
    return 0
fi
unset _BLOG_WORKFLOW_LOADED

# Determine current script path.
# shellcheck disable=SC2296
SCRIPT_PATH="${(%):-%x}"

BLOG_SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd 2>/dev/null)"
VERSION="2.1.0"

# ++++++++++++++++++++++++++ SHARED HELPERS LOADER +++++++++++++++++++++++++++ #

_blog_helpers_primary="${BLOG_SCRIPT_DIR:h}/_shared-helpers.zsh"
_blog_helpers_fallback="${ZSH_CONFIG_DIR:-$HOME/.config/zsh}/scripts/_shared-helpers.zsh"
if [[ -r "$_blog_helpers_primary" ]]; then
    # shellcheck disable=SC1090
    source "$_blog_helpers_primary"
elif [[ -r "$_blog_helpers_fallback" ]]; then
    # shellcheck disable=SC1090
    source "$_blog_helpers_fallback"
else
    print -u2 "[ERROR] Shared helpers not found."
    print -u2 "Tried: $_blog_helpers_primary"
    print -u2 "Tried: $_blog_helpers_fallback"
    return 1 2>/dev/null || exit 1
fi
unset _blog_helpers_primary _blog_helpers_fallback

_blog_common_module="${BLOG_SCRIPT_DIR}/_common.zsh"
if [[ -r "$_blog_common_module" ]]; then
    source "$_blog_common_module"
else
    print -u2 "Blog common module not found: $_blog_common_module"
    return 1 2>/dev/null || exit 1
fi
unset _blog_common_module

# ++++++++++++++++++++++++ OPERATING SYSTEM DETECTION ++++++++++++++++++++++++ #

# Detect operating system and set allowed blog directory.
_shared_detect_platform
if [[ "${SHARED_PLATFORM:-Other}" == "macOS" ]]; then
    PLATFORM="macOS"
    ALLOWED_BLOG_ROOT="/Volumes/LCS.Data/Blog"
elif [[ "${SHARED_PLATFORM:-Other}" == "Linux" ]]; then
    PLATFORM="Linux"
    ALLOWED_BLOG_ROOT="/LCS.Data/Blog"
else
    PLATFORM="${SHARED_PLATFORM:-Other}"
    ALLOWED_BLOG_ROOT=""
fi

# ++++++++++++++++++++++++++++++ LOGGING SYSTEM ++++++++++++++++++++++++++++++ #

# Logging configuration.
BLOG_DRY_RUN=${BLOG_DRY_RUN:-false}
BLOG_VERBOSE=${BLOG_VERBOSE:-false}
BLOG_LOG_DIR="${BLOG_LOG_DIR:-$ALLOWED_BLOG_ROOT/logs}"
BLOG_LOCK_DIR="${BLOG_LOCK_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/blog_automation.lock}"

# -----------------------------------------------------------------------------
# _blog_init_logging
# @internal
# @description Lazily creates BLOG_LOG_DIR and sets BLOG_LOG_FILE on first log
# message; falls back to stderr if directory creation fails.
# @noargs
# -----------------------------------------------------------------------------
_blog_init_logging() {
    if [[ -z "$BLOG_LOG_FILE" ]]; then
        BLOG_LOG_FILE="${BLOG_LOG_DIR}/blog_automation_$(date +%Y%m%d_%H%M%S).log"
        mkdir -p "$BLOG_LOG_DIR" 2>/dev/null || {
            _zsh_ui_log warn "Cannot create log directory; using stderr."
            BLOG_LOG_FILE="/dev/stderr"
        }
    fi
}

# -----------------------------------------------------------------------------
# blog_log
# @description Logs a timestamped message to the terminal and BLOG_LOG_FILE.
# @arg $1 string Log level: INFO, WARN, ERROR, DEBUG, or SUCCESS.
# @arg $2 string Message text.
# -----------------------------------------------------------------------------
blog_log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local ui_level="info"
    local file_level="$level"

    # Initialize logging if not done yet.
    _blog_init_logging

    case "$level" in
        "INFO") ui_level="info" ;;
        "WARN") ui_level="warn" ;;
        "ERROR") ui_level="error" ;;
        "DEBUG") ui_level="info" ;;
        "SUCCESS") ui_level="ok"; file_level="INFO" ;;
        *) ui_level="error" ;;
    esac

    local log_entry="[$timestamp] [$file_level] $message"
    _zsh_ui_log "$ui_level" "[$timestamp] $message" >&2
    [[ "$BLOG_LOG_FILE" == "/dev/stderr" ]] || printf '%s\n' "$log_entry" >> "$BLOG_LOG_FILE"
}

# -----------------------------------------------------------------------------
# blog_info
# @description Logs a message at INFO level.
# @arg $1 string Message text.
# -----------------------------------------------------------------------------
blog_info() { blog_log "INFO" "$1"; }

# -----------------------------------------------------------------------------
# blog_warn
# @description Logs a message at WARN level.
# @arg $1 string Message text.
# -----------------------------------------------------------------------------
blog_warn() { blog_log "WARN" "$1"; }

# -----------------------------------------------------------------------------
# blog_error
# @description Logs a message at ERROR level.
# @arg $1 string Message text.
# -----------------------------------------------------------------------------
blog_error() { blog_log "ERROR" "$1"; }

# -----------------------------------------------------------------------------
# blog_success
# @description Logs a message at SUCCESS level.
# @arg $1 string Message text.
# -----------------------------------------------------------------------------
blog_success() { blog_log "SUCCESS" "$1"; }

# -----------------------------------------------------------------------------
# blog_debug
# @description Logs a DEBUG message only when BLOG_VERBOSE is true.
# @arg $1 string Message text.
# -----------------------------------------------------------------------------
blog_debug() {
    [[ "$BLOG_VERBOSE" == "true" ]] && blog_log "DEBUG" "$1"
}

# +++++++++++++++++++++++ SECURITY CHECKS & VALIDATION +++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# blog_validate_location
# @description Confirms the current directory is inside ALLOWED_BLOG_ROOT.
# @noargs
# @exitcode 1 If the root is missing or the current directory is outside it.
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
# @description Validates an absolute path against traversal and metacharacters.
# @arg $1 path Path to validate.
# @arg $2 string Description used in error messages.
# @exitcode 1 If the path is unsafe or not absolute.
# -----------------------------------------------------------------------------
blog_validate_path() {
    local target_path="$1"
    local description="$2"

    # Check for dangerous characters and shell metacharacters.
    if [[ "$target_path" == *".."* ]] || [[ "$target_path" == *";"* ]] || [[ "$target_path" == *"|"* ]] || \
       [[ "$target_path" == *$'\n'* ]] || [[ "$target_path" == *$'\r'* ]] || [[ "$target_path" == *$'\t'* ]]; then
        blog_error "Unsafe path detected in $description: $target_path"
        return 1
    fi

    # Must be absolute path.
    if [[ "$target_path" != /* ]]; then
        blog_error "Path must be absolute for $description: $target_path"
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# blog_validate_managed_path
# @description Validates a path remains safely under ALLOWED_BLOG_ROOT.
# @arg $1 path Path to validate.
# @arg $2 string Description used in error messages.
# @exitcode 1 If the path is unsafe or outside the managed blog root.
# -----------------------------------------------------------------------------
blog_validate_managed_path() {
    local target_path="$1"
    local description="$2"

    blog_validate_path "$target_path" "$description" || return 1

    case "$target_path" in
        "$ALLOWED_BLOG_ROOT" | "$ALLOWED_BLOG_ROOT"/*)
            return 0
            ;;
        *)
            blog_error "Path for $description must remain under $ALLOWED_BLOG_ROOT: $target_path"
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# blog_safe_clear_dir
# @description Deletes managed directory contents after safety checks.
# @arg $1 path Directory whose contents should be cleared.
# @exitcode 1 If the path is unsafe, outside the blog root, or not a directory.
# -----------------------------------------------------------------------------
blog_safe_clear_dir() {
    local target_dir="$1"

    blog_validate_managed_path "$target_dir" "cleanup target" || return 1
    [[ -d "$target_dir" ]] || {
        blog_error "Cleanup target is not a directory: $target_dir"
        return 1
    }
    [[ "$target_dir" != "/" ]] || {
        blog_error "Refusing to clear root directory"
        return 1
    }

    find "$target_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null
}

# -----------------------------------------------------------------------------
# _blog_validate_config_permissions
# @internal
# @description Validates that a config file is owned by the current user and
# not group/world-writable before sourcing it, preventing code injection.
# @arg $1 path Config file to validate.
# @exitcode 1 If ownership or permissions checks fail.
# -----------------------------------------------------------------------------
_blog_validate_config_permissions() {
    local file="$1"
    if ! _zsh_is_secure_file "$file"; then
        blog_error "Config file must be owned by the current user and not group/world-writable: $file"
        return 1
    fi

    return 0
}

# +++++++++++++++++++++++++ CONFIGURATION MANAGEMENT +++++++++++++++++++++++++ #

# Configuration file path.
BLOG_CONFIG_FILE="${ALLOWED_BLOG_ROOT}/blog_config.conf"

# -----------------------------------------------------------------------------
# blog_set_defaults
# @description Sets platform-aware defaults for BLOG_* configuration variables.
# @noargs
# -----------------------------------------------------------------------------
blog_set_defaults() {
    # Main directories.
    BLOG_DIR="${BLOG_DIR:-$ALLOWED_BLOG_ROOT/CS-Topics}"
    BLOG_SOURCE_PATH="${BLOG_SOURCE_PATH:-$HOME/Documents/Obsidian-Vault/XSPC-Vault/Blog/posts}"
    BLOG_IMAGES_PATH="${BLOG_IMAGES_PATH:-$HOME/Documents/Obsidian-Vault/XSPC-Vault/Blog/images}"
    BLOG_DEST_PATH="${BLOG_DEST_PATH:-$ALLOWED_BLOG_ROOT/CS-Topics/content/posts}"

    # Python scripts.
    # The dotfiles repository is canonical; the blog volume is data/deployment.
    BLOG_SCRIPTS_DIR="${BLOG_SCRIPTS_DIR:-$BLOG_SCRIPT_DIR/python}"
    BLOG_IMAGES_SCRIPT="${BLOG_IMAGES_SCRIPT:-$BLOG_SCRIPTS_DIR/images.py}"
    BLOG_HASH_GENERATOR="${BLOG_HASH_GENERATOR:-$BLOG_SCRIPTS_DIR/generate_hashes.py}"
    BLOG_FRONTMATTER_SCRIPT="${BLOG_FRONTMATTER_SCRIPT:-$BLOG_SCRIPTS_DIR/update_frontmatter.py}"
    BLOG_HASH_FILE="${BLOG_HASH_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/blog/.file_hashes}"

    # Repository configuration.
    BLOG_REPO_PATH="${BLOG_REPO_PATH:-$ALLOWED_BLOG_ROOT}"
    BLOG_REPO_URL="${BLOG_REPO_URL:-git@github.com:XtremeXSPC/CS-Topics-Blog.git}"

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
# @description Loads or creates BLOG_CONFIG_FILE and validates critical paths.
# @noargs
# @exitcode 1 If configuration permissions or path validation fails.
# -----------------------------------------------------------------------------
blog_load_config() {
    blog_set_defaults

    if [[ -f "$BLOG_CONFIG_FILE" ]]; then
        blog_debug "Loading configuration from: $BLOG_CONFIG_FILE"
        _blog_validate_config_permissions "$BLOG_CONFIG_FILE" || return 1
        source "$BLOG_CONFIG_FILE"
    else
        blog_warn "Configuration file not found: $BLOG_CONFIG_FILE"
        blog_create_config_template
    fi

    # Validate all critical paths.
    blog_validate_managed_path "$BLOG_DIR" "BLOG_DIR" || return 1
    blog_validate_path "$BLOG_SOURCE_PATH" "BLOG_SOURCE_PATH" || return 1
    blog_validate_managed_path "$BLOG_DEST_PATH" "BLOG_DEST_PATH" || return 1
    blog_validate_managed_path "$BLOG_REPO_PATH" "BLOG_REPO_PATH" || return 1
}

# -----------------------------------------------------------------------------
# blog_create_config_template
# @description Writes a default BLOG_CONFIG_FILE, unless BLOG_DRY_RUN is true.
# @noargs
# @exitcode 1 If the configuration template cannot be written.
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
BLOG_SCRIPTS_DIR="$BLOG_SCRIPT_DIR/python"
BLOG_IMAGES_SCRIPT="\$BLOG_SCRIPTS_DIR/images.py"
BLOG_HASH_GENERATOR="\$BLOG_SCRIPTS_DIR/generate_hashes.py"
BLOG_FRONTMATTER_SCRIPT="\$BLOG_SCRIPTS_DIR/update_frontmatter.py"
BLOG_HASH_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/blog/.file_hashes"

# Git repository:
BLOG_REPO_PATH="$ALLOWED_BLOG_ROOT"
BLOG_REPO_URL="git@github.com:XtremeXSPC/CS-Topics-Blog.git"

# Backup and performance:
BLOG_BACKUP_DIR="$ALLOWED_BLOG_ROOT/backups"
BLOG_KEEP_BACKUPS=5
BLOG_DEFAULT_TIMEOUT=300
BLOG_GIT_TIMEOUT=600
EOF
}

# +++++++++++++++++++++++++ FILE BACKUP AND RECOVERY +++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# blog_create_backup
# @description Creates a timestamped backup of a blog directory.
# @arg $1 path Source directory to back up.
# @arg $2 string Descriptive backup name.
# BLOG_DRY_RUN logs the planned backup without copying.
# @exitcode 1 If the source is missing or the backup fails.
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
# @description Removes old backups, retaining BLOG_KEEP_BACKUPS entries.
# Deletes the oldest timestamped backup directories beyond that limit.
# @noargs
# @exitcode 1 If backup cleanup fails.
# -----------------------------------------------------------------------------
blog_cleanup_backups() {
    if [[ "$BLOG_DRY_RUN" == "true" ]]; then
        blog_info "[DRY-RUN] Cleaning old backups (keeping last $BLOG_KEEP_BACKUPS)"
        return 0
    fi

    if [[ ! -d "$BLOG_BACKUP_DIR" ]]; then
        return 0
    fi

    local backup_count
    backup_count=$(find "$BLOG_BACKUP_DIR" -maxdepth 1 -type d -name "*_[0-9]*" | wc -l | tr -d ' ')
    if (( backup_count > BLOG_KEEP_BACKUPS )); then
        blog_info "Cleaning old backups (found: $backup_count, keeping: $BLOG_KEEP_BACKUPS)"
        local to_delete=$(( backup_count - BLOG_KEEP_BACKUPS ))
        find "$BLOG_BACKUP_DIR" -maxdepth 1 -type d -name "*_[0-9]*" | sort | head -n "$to_delete" | xargs rm -rf
    fi
}

# +++++++++++++++++++++++++++++ SYSTEM UTILITIES +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# blog_check_command
# @description Verifies that a command is available in PATH.
# @arg $1 string Command name.
# @exitcode 1 If the command is not available.
# -----------------------------------------------------------------------------
blog_check_command() {
    local cmd="$1"
    if ! _shared_has_command "$cmd"; then
        blog_error "Required command not found: $cmd"
        return 1
    fi
    blog_debug "Command found: $cmd"
    return 0
}

# -----------------------------------------------------------------------------
# blog_check_dir
# @description Verifies a directory and optionally creates it when missing.
# @arg $1 path Directory to check.
# @arg $2 string Description used in log messages.
# @arg $3 string Optional true to create a missing directory.
# @exitcode 1 If the directory is missing and cannot be created.
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
# @description Verifies that a required file exists.
# @arg $1 path File to check.
# @arg $2 string Description used in log messages.
# @exitcode 1 If the file does not exist.
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
# @description Runs a command with a timeout and logs its operation.
# Falls back to running without a timeout when timeout is unavailable.
# @arg $1 integer Timeout in seconds.
# @arg $2 string Operation description.
# @arg $3 string Command to run.
# @arg $@ string Optional command arguments.
# @exitcode 1 If the command fails.
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

    if _shared_has_command timeout; then
        timeout "${timeout}s" "$@"
        return $?
    else
        # Fallback without timeout.
        blog_warn "'timeout' command not available, executing without timeout"
        "$@"
        return $?
    fi
}

# ++++++++++++++++++++++++ GIT-BASED CHANGE DETECTION ++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# blog_detect_git_changes
# @description Detects changed Markdown posts using Git status.
# Sets BLOG_CHANGED_FILES to changed files under content/posts.
# @noargs
# @exitcode 1 If no Git changes are found or the repository is inaccessible.
# -----------------------------------------------------------------------------
blog_detect_git_changes() {
    local current_dir="$(pwd)"
    cd "$BLOG_REPO_PATH" || {
        blog_error "Cannot access repository: $BLOG_REPO_PATH"
        return 1
    }

    if [[ ! -d ".git" ]]; then
        blog_warn "Git repository not found, treating all files as changed"
        BLOG_CHANGED_FILES=()
        cd "$current_dir"
        return 0
    fi

    # Get list of changed files (modified, new, deleted).
    local git_status
    git_status=$(git status --porcelain 2>/dev/null)

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
            # Extract status code and filename.
            local status_code="${line:0:2}"
            local raw_file="${line:3}"
            # For renames/copies, use the destination name.
            local file
            if [[ "$status_code" == R* ]] || [[ "$status_code" == C* ]]; then
                file="${raw_file##* -> }"
            else
                file="$raw_file"
            fi
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
# @description Generates and caches hashes for blog Markdown files.
# Backs up the previous hash file before updating it.
# @noargs
# @exitcode 1 If Python, required files, or hash generation fails.
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
    mkdir -p "${BLOG_HASH_FILE:h}" 2>/dev/null || {
        blog_error "Cannot create hash cache directory: ${BLOG_HASH_FILE:h}"
        return 1
    }

    if blog_run_with_timeout $BLOG_DEFAULT_TIMEOUT "python hash generator" python3 "$BLOG_HASH_GENERATOR" "$BLOG_DEST_PATH" "$BLOG_HASH_FILE"; then
        blog_success "Hash generation completed"

        if [[ "$BLOG_DRY_RUN" != "true" ]] && [[ -f "$BLOG_HASH_FILE" ]]; then
            local hash_count
            hash_count=$(wc -l < "$BLOG_HASH_FILE" | tr -d ' ')
            blog_info "Generated hashes for $hash_count files"
        fi
        return 0
    else
        blog_error "Hash generation failed"
        return 1
    fi
}

# +++++++++++++++++++++++++++ MAIN BLOG FUNCTIONS ++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _blog_ensure_valid_location
# @internal
# @description Validates location and loads configuration; called by every
# main blog function to ensure security and proper setup.
# @noargs
# @exitcode 1 If location validation or configuration loading fails.
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
# @description Backs up a non-empty destination before synchronization.
# Outputs the backup path, or an empty line when no backup is needed.
# @arg $1 path Destination directory to protect.
# @exitcode 1 If a required backup fails.
# -----------------------------------------------------------------------------
blog_backup_before_sync() {
    local dest_path="$1"
    local backup_path=""

    if [[ -d "$dest_path" ]] && [[ "$(ls -A "$dest_path" 2>/dev/null)" ]]; then
        backup_path=$(blog_create_backup "$dest_path" "posts_sync") || return 1
        [[ -n "$backup_path" ]] || return 1
    fi

    echo "$backup_path"
}

# -----------------------------------------------------------------------------
# blog_init_git
# @description Initializes the blog Git repository and its origin remote.
# Creates a repository when needed and requires BLOG_REPO_URL.
# @noargs
# @exitcode 1 If the location, Git setup, or remote configuration fails.
# -----------------------------------------------------------------------------
blog_init_git() {
    _zsh_ui_section "Git initialization" >&2

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
# @description Mirrors Markdown posts from the source into the Hugo content dir.
# Creates a backup first and deletes destination files absent from the source.
# @noargs
# @exitcode 1 If validation, rsync, or recovery fails.
# -----------------------------------------------------------------------------
blog_sync_posts() {
    _zsh_ui_section "Posts synchronization" >&2

    _blog_ensure_valid_location || return 1

    blog_check_dir "$BLOG_SOURCE_PATH" "Source" || return 1
    blog_check_dir "$BLOG_DEST_PATH" "Destination" true || return 1

    # Refuse a destructive mirror when the source is empty or unexpectedly
    # unavailable. This guard runs before backup and before rsync --delete.
    local src_count
    src_count=$(find "$BLOG_SOURCE_PATH" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$src_count" =~ ^[0-9]+$ ]] || src_count=0
    if (( src_count < ${BLOG_MIN_SOURCE_MARKDOWN:-1} )); then
        blog_error "Refusing sync: source contains no plausible Markdown set ($src_count files): $BLOG_SOURCE_PATH"
        return 1
    fi

    # Create a recoverable snapshot before the destructive mirror.
    local backup_path=""
    if [[ "$BLOG_DRY_RUN" != "true" ]]; then
        backup_path="$(blog_backup_before_sync "$BLOG_DEST_PATH")" || {
            blog_error "Pre-sync backup failed; refusing rsync --delete"
            return 1
        }
    fi

    blog_info "Synchronizing: $BLOG_SOURCE_PATH -> $BLOG_DEST_PATH"

    if [[ "$BLOG_DRY_RUN" == "true" ]]; then
        blog_info "[DRY-RUN] rsync -av --delete $BLOG_SOURCE_PATH/ $BLOG_DEST_PATH/"
    else
        if blog_run_with_timeout $BLOG_DEFAULT_TIMEOUT "rsync sync" rsync -av --delete "$BLOG_SOURCE_PATH/" "$BLOG_DEST_PATH/"; then
            blog_success "Synchronization completed"

            # Verify integrity post-sync.
            local dest_count
            dest_count=$(find "$BLOG_DEST_PATH" -name "*.md" -type f | wc -l | tr -d ' ')
            blog_info "Markdown files - Source: $src_count, Destination: $dest_count"

            if [[ $src_count -ne $dest_count ]]; then
                blog_warn "File count differs after synchronization"
            fi
        else
            blog_error "Synchronization failed"

            # Attempt recovery from backup.
            if [[ -n "$backup_path" ]] && [[ -d "$backup_path" ]]; then
                blog_warn "Attempting recovery from backup: $backup_path"
                blog_safe_clear_dir "$BLOG_DEST_PATH" || return 1
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
# @description Detects blog changes using Git or hash comparison.
# The method is selected by BLOG_CHANGE_DETECTION; unknown values use Git.
# @noargs
# @exitcode 1 If location validation or the selected detector fails.
# -----------------------------------------------------------------------------
blog_detect_changes() {
    _zsh_ui_section "Change detection" >&2

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
# @description Updates YAML frontmatter in changed or all blog Markdown files.
# Uses BLOG_CHANGE_DETECTION and BLOG_CHANGED_FILES to select the file set.
# @noargs
# @exitcode 1 If Python, the update script, or processing fails.
# -----------------------------------------------------------------------------
blog_update_frontmatter() {
    _zsh_ui_section "Frontmatter update" >&2

    _blog_ensure_valid_location || return 1

    blog_check_command python3 || return 1
    blog_check_file "$BLOG_FRONTMATTER_SCRIPT" "Frontmatter script" || return 1
    blog_check_dir "$BLOG_DEST_PATH" "Destination" || return 1

    # For hash-based detection, verify hash file exists.
    if [[ "$BLOG_CHANGE_DETECTION" == "hash" ]]; then
        local -a frontmatter_hash_args=("$BLOG_HASH_FILE")
        if [[ ! -f "$BLOG_HASH_FILE" ]]; then
            blog_warn "Hash file not found, generating hashes first"
            blog_detect_hash_changes || return 1
            # The fresh hash file reflects the current files, so hash-based
            # skipping would treat everything as unchanged; process all files.
            frontmatter_hash_args=()
        fi

        blog_info "Updating frontmatter for: $BLOG_DEST_PATH"

        if blog_run_with_timeout $BLOG_DEFAULT_TIMEOUT "python frontmatter update" python3 "$BLOG_FRONTMATTER_SCRIPT" "$BLOG_DEST_PATH" "${frontmatter_hash_args[@]}"; then
            blog_success "Frontmatter update completed"
            return 0
        else
            blog_error "Frontmatter update failed"
            return 1
        fi
    else
        # Git mode processes changed files, or all files when none are listed.
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
# @description Converts Obsidian image links to Hugo-compatible Markdown.
# @noargs
# @exitcode 1 If Python, the image script, or processing fails.
# -----------------------------------------------------------------------------
blog_process_images() {
    _zsh_ui_section "Image processing" >&2

    _blog_ensure_valid_location || return 1

    blog_check_command python3 || return 1
    blog_check_file "$BLOG_IMAGES_SCRIPT" "Images script" || return 1

    blog_info "Processing markdown images"

    if blog_run_with_timeout $BLOG_DEFAULT_TIMEOUT "python images processor" python3 "$BLOG_IMAGES_SCRIPT" "$BLOG_DEST_PATH" "$BLOG_IMAGES_PATH" "$BLOG_DIR/static/images"; then
        blog_success "Image processing completed"
        return 0
    else
        blog_error "Image processing failed"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# blog_build_hugo
# @description Builds the Hugo site and verifies its public output directory.
# @noargs
# @exitcode 1 If Hugo is unavailable, the build fails, or output is missing.
# -----------------------------------------------------------------------------
blog_build_hugo() {
    _zsh_ui_section "Hugo site build" >&2

    _blog_ensure_valid_location || return 1

    blog_check_command hugo || return 1
    blog_check_dir "$BLOG_DIR" "Blog" || return 1

    blog_info "Building Hugo in: $BLOG_DIR"

    local build_result=0
    # Run Hugo in a subshell to preserve the caller's working directory.
    (
        cd "$BLOG_DIR" || { blog_error "Cannot access: $BLOG_DIR"; exit 1; }
        blog_run_with_timeout $BLOG_DEFAULT_TIMEOUT "hugo build" hugo
    ) || build_result=$?

    if (( build_result != 0 )); then
        blog_error "Hugo build failed"
        return 1
    fi

    if [[ -d "$BLOG_DIR/public" ]]; then
        local file_count
        file_count=$(find "$BLOG_DIR/public" -type f | wc -l | tr -d ' ')
        blog_success "Hugo build completed - $file_count files generated"
        return 0
    else
        blog_error "Build completed but 'public' directory not found"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# blog_commit_changes
# @description Stages and commits all blog repository changes.
# BLOG_DRY_RUN logs the Git operations without changing the repository.
# @noargs
# @exitcode 1 If Git setup or the commit fails.
# -----------------------------------------------------------------------------
blog_commit_changes() {
    _zsh_ui_section "Commit changes" >&2

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
        blog_info "[DRY-RUN] git add CS-Topics/ .gitignore .gitmodules .github/"
        blog_info "[DRY-RUN] git commit -m '$commit_message'"
    else
        git add -- CS-Topics/ .gitignore .gitmodules .github/ && git add -u || {
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
# @description Ensures the main branch exists and pushes it to origin.
# May create or switch branches before pushing; BLOG_DRY_RUN logs operations.
# @noargs
# @exitcode 1 If branch setup or the push fails.
# -----------------------------------------------------------------------------
blog_push_main() {
    _zsh_ui_section "Push to main branch" >&2

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
# @description Deploys the Hugo public tree to Hostinger's hostinger branch.
# Uses a temporary subtree and force-with-lease; BLOG_DRY_RUN previews it.
# @noargs
# @exitcode 1 If the public tree, subtree operation, or push is unavailable.
# -----------------------------------------------------------------------------
blog_deploy_hostinger() {
    _zsh_ui_section "Deploy to Hostinger" >&2

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
        blog_info "[DRY-RUN] git push origin hostinger-deploy:hostinger --force-with-lease"
        blog_info "[DRY-RUN] git branch -D hostinger-deploy"
    else
        # Create subtree from public directory.
        if ! git subtree split --prefix "$public_dir" -b hostinger-deploy; then
            blog_error "Subtree creation failed"
            cd "$current_dir"
            return 1
        fi

        # Push to hostinger branch.
        if ! blog_run_with_timeout $BLOG_GIT_TIMEOUT "git push hostinger" git push origin hostinger-deploy:hostinger --force-with-lease; then
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

# +++++++++++++++++++++++++ ORCHESTRATION FUNCTIONS ++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# blog_run_all
# @description Runs the blog workflow from Git setup through main-branch push.
# Stops at the first failure, uses a lock, and cleans old backups on success.
# @noargs
# @exitcode 1 If any workflow step fails.
# -----------------------------------------------------------------------------
blog_run_all() {
    setopt localtraps
    _blog_acquire_lock || return 1
    trap '_blog_release_lock' EXIT INT TERM

    _zsh_ui_heading \
        "Blog automation" \
        "Running the complete publishing workflow" >&2

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
        # Deployment is handled by GitHub Actions on push to main.
    )

    # Execute all steps.
    for step in "${steps[@]}"; do
        blog_info ">>> Executing: $step"
        if ! $step; then
            failed_step="$step"
            break
        fi
        blog_info "<<< Completed: $step"
        print -r -- "" >&2
    done

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [[ -n "$failed_step" ]]; then
        blog_error "Process interrupted at step: $failed_step"
        blog_error "Duration before failure: ${duration}s"
        _blog_release_lock
        trap - EXIT INT TERM
        return 1
    else
        blog_success "Process completed successfully"
        blog_info "Total duration: ${duration}s"

        # Cleanup old backups.
        blog_cleanup_backups

        _blog_release_lock
        trap - EXIT INT TERM
        return 0
    fi
}

# +++++++++++++++++++++++++ UTILITY & HELP FUNCTIONS +++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# blog_status
# @description Displays blog paths, configuration, dependencies, and location.
# Loads defaults and the configuration file for the status report.
# @noargs
# -----------------------------------------------------------------------------
blog_status() {
    blog_set_defaults
    if [[ -f "$BLOG_CONFIG_FILE" ]]; then
        _blog_validate_config_permissions "$BLOG_CONFIG_FILE" && source "$BLOG_CONFIG_FILE"
    fi

    _zsh_ui_heading "Blog automation status" "v$VERSION · $PLATFORM" ||
        return 1
    local -a overview_rows=(
        "Allowed blog directory"$'\t'"${ALLOWED_BLOG_ROOT:-Not configured}"
        "Current directory"$'\t'"$(pwd)"
    )
    _zsh_ui_table $'Context\tValue' "${overview_rows[@]}" || return 1

    print -r -- ""
    _zsh_ui_section "Configuration" || return 1
    local -a config_rows=(
        "BLOG_DIR"$'\t'"${BLOG_DIR:-NOT SET}"
        "BLOG_SOURCE_PATH"$'\t'"${BLOG_SOURCE_PATH:-NOT SET}"
        "BLOG_DEST_PATH"$'\t'"${BLOG_DEST_PATH:-NOT SET}"
        "BLOG_CHANGE_DETECTION"$'\t'"${BLOG_CHANGE_DETECTION:-NOT SET}"
        "BLOG_DRY_RUN"$'\t'"${BLOG_DRY_RUN:-false}"
        "BLOG_VERBOSE"$'\t'"${BLOG_VERBOSE:-false}"
    )
    _zsh_ui_table $'Setting\tValue' "${config_rows[@]}" || return 1

    print -r -- ""
    _zsh_ui_section "Dependencies" || return 1
    local -a dependency_rows=()
    local cmd cmd_path
    for cmd in python3 hugo git rsync; do
        if cmd_path=$(command -v "$cmd" 2>/dev/null); then
            dependency_rows+=("$cmd"$'\tAvailable\t'"$cmd_path")
        else
            dependency_rows+=("$cmd"$'\tMissing\t-')
        fi
    done
    _zsh_ui_table \
        $'Command\tStatus\tPath' "${dependency_rows[@]}" || return 1

    print -r -- ""
    _zsh_ui_section "Workflow files" || return 1
    local -a file_rows=()
    local file
    for file in "$BLOG_HASH_GENERATOR" "$BLOG_FRONTMATTER_SCRIPT" "$BLOG_IMAGES_SCRIPT"; do
        if [[ -f "$file" ]]; then
            file_rows+=("$(basename "$file")"$'\tAvailable\t'"$file")
        else
            file_rows+=("$(basename "$file")"$'\tMissing\t'"$file")
        fi
    done
    _zsh_ui_table $'File\tStatus\tPath' "${file_rows[@]}" || return 1

    print -r -- ""
    _zsh_ui_section "Location" || return 1
    local root_status="Missing" location_status="Unavailable"
    local current_dir="$(pwd)"
    if [[ -d "$ALLOWED_BLOG_ROOT" ]]; then
        root_status="Available"
        case "$current_dir" in
            "$ALLOWED_BLOG_ROOT"|"$ALLOWED_BLOG_ROOT"/*)
                location_status="Inside blog directory" ;;
            *) location_status="Outside blog directory" ;;
        esac
    fi
    _zsh_ui_table $'Check\tStatus\tPath' \
        "Blog root"$'\t'"$root_status"$'\t'"${ALLOWED_BLOG_ROOT:-Not configured}" \
        "Current location"$'\t'"$location_status"$'\t'"$current_dir" ||
        return 1
    [[ "$location_status" != "Outside blog directory" ]] ||
        _zsh_ui_log warn "Run: cd $ALLOWED_BLOG_ROOT"
}

# -----------------------------------------------------------------------------
# blog_help
# @description Prints usage, configuration, restrictions, and examples.
# @noargs
# -----------------------------------------------------------------------------
blog_help() {
    _zsh_ui_heading \
        "BLOG AUTOMATION" \
        "v$VERSION · $PLATFORM · Publishing workflow commands" || return 1
    _zsh_ui_rule || return 1
    print -r -- ""

    _zsh_ui_subsection "USAGE" || return 1
    _zsh_ui_definition_list \
        $'blog_<command>\tOptional environment overrides may precede the command.' ||
        return 1
    print -r -- ""

    _zsh_ui_subsection "COMMANDS" || return 1
    _zsh_ui_definition_list \
        $'blog_run_all\tRun the complete publishing workflow.' \
        $'blog_init_git\tInitialize the Git repository.' \
        $'blog_sync_posts\tSynchronize posts from Obsidian.' \
        $'blog_detect_changes\tDetect Git or hash changes.' \
        $'blog_update_frontmatter\tUpdate post frontmatter.' \
        $'blog_process_images\tProcess images in posts.' \
        $'blog_build_hugo\tBuild the Hugo site.' \
        $'blog_commit_changes\tCommit generated changes.' \
        $'blog_push_main\tPush main and trigger deployment.' \
        $'blog_status\tShow configuration and dependencies.' \
        $'blog_help\tShow this help.' || return 1
    print -r -- ""

    _zsh_ui_subsection "ENVIRONMENT" || return 1
    _zsh_ui_definition_list \
        $'BLOG_DRY_RUN=true\tPreview without applying changes.' \
        $'BLOG_VERBOSE=true\tEnable debug logging.' \
        $'BLOG_CHANGE_DETECTION=git|hash\tSelect the detection strategy.' ||
        return 1
    print -r -- ""

    _zsh_ui_subsection "PATHS" || return 1
    _zsh_ui_definition_list \
        "Allowed root"$'\t'"${ALLOWED_BLOG_ROOT:-Not configured}" \
        "Current path"$'\t'"$(pwd)" \
        "Configuration"$'\t'"$BLOG_CONFIG_FILE" \
        "Logs"$'\t'"$BLOG_LOG_DIR/" \
        "Backups"$'\t'"${BLOG_BACKUP_DIR:-$ALLOWED_BLOG_ROOT/backups}/" ||
        return 1
    print -r -- ""

    _zsh_ui_subsection "EXAMPLES" || return 1
    _zsh_ui_definition_list \
        "blog_run_all" \
        "BLOG_DRY_RUN=true blog_run_all" \
        "BLOG_CHANGE_DETECTION=git blog_run_all"
}

_BLOG_WORKFLOW_LOADED=1
unfunction _blog_workflow_ready 2>/dev/null

# ============================================================================ #
# End of blog/commands.zsh
