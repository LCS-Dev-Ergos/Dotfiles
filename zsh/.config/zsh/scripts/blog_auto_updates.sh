#!/usr/bin/env zsh

# ============================================================================ #
# ++++++++++++++++++++++++++ Blog Automation Script ++++++++++++++++++++++++++ #
# ============================================================================ #
# This script automates the Hugo blog synchronization, build and deployment 
# process. It syncs markdown files from an Obsidian vault, uses Git-based 
# change detection, updates frontmatter, processes images, builds the static 
# site with Hugo, and deploys it to a Git repository.
#
# Author: XtremeXSPC
# Version: 2.1.0 - Git-based change detection
# ============================================================================ #

# Determine current script path.
if [[ -n "${ZSH_VERSION}" ]]; then
    SCRIPT_PATH="${(%):-%x}"
elif [[ -n "${BASH_VERSION}" ]]; then
    SCRIPT_PATH="${BASH_SOURCE[0]}"
else
    SCRIPT_PATH="$0"
fi

SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd 2>/dev/null)"
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

# Check if terminal supports colors.
if test -t 1; then
    N_COLORS=$(tput colors)
    if test -n "$N_COLORS" && test $N_COLORS -ge 8; then
        BOLD="$(tput bold)"
        BLUE="$(tput setaf 4)"
        CYAN="$(tput setaf 6)"
        GREEN="$(tput setaf 2)"
        RED="$(tput setaf 1)"
        YELLOW="$(tput setaf 3)"
        MAGENTA="$(tput setaf 5)"
        RESET="$(tput sgr0)"
    fi
fi

# ============================================================================ #
# ++++++++++++++++++++++++++++++ Logging System ++++++++++++++++++++++++++++++ #
# ============================================================================ #

# Logging configuration.
BLOG_DRY_RUN=${BLOG_DRY_RUN:-false}
BLOG_VERBOSE=${BLOG_VERBOSE:-false}
BLOG_LOG_DIR="${BLOG_LOG_DIR:-$ALLOWED_BLOG_ROOT/logs}"

# Initialize log directory only when needed.
_blog_init_logging() {
    if [[ -z "$BLOG_LOG_FILE" ]]; then
        BLOG_LOG_FILE="${BLOG_LOG_DIR}/blog_automation_$(date +%Y%m%d_%H%M%S).log"
        mkdir -p "$BLOG_LOG_DIR" 2>/dev/null || {
            echo "[WARNING] Cannot create log directory, using stdout"
            BLOG_LOG_FILE="/dev/stdout"
        }
    fi
}

# Logging functions with timestamp, level and color support.
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
        "WARN")  color="$YELLOW" ;;
        "ERROR") color="$RED" ;;
        "DEBUG") color="$CYAN" ;;
        "SUCCESS") color="$GREEN"; level="INFO" ;;
    esac
    
    # Create log entry with color for terminal, plain for file.
    if [[ -t 1 ]] && [[ "$BLOG_LOG_FILE" != "/dev/stdout" ]]; then
        # Terminal output with color.
        echo "${color}[$timestamp] [$level] $message${RESET}"
        # Plain text to file.
        echo "[$timestamp] [$level] $message" >> "$BLOG_LOG_FILE"
    else
        # Plain text output.
        log_entry="[$timestamp] [$level] $message"
        echo "$log_entry" | tee -a "$BLOG_LOG_FILE"
    fi
}

# Logging level functions.
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

# Validates that we're running in the allowed blog directory.
# This prevents the script from running in unauthorized locations.
# NOTE: Only called when blog functions are actually used.
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

# Validates paths for security (prevents path traversal and injection attacks).
# Args: $1=path, $2=description
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

# Sets default configuration values.
# These can be overridden by the configuration file or environment variables.
blog_set_defaults() {
    # Main directories.
    BLOG_DIR="${BLOG_DIR:-$ALLOWED_BLOG_ROOT/CS-Topics}"
    BLOG_SOURCE_PATH="${BLOG_SOURCE_PATH:-$HOME/Documents/Obsidian-Vault/XSPC-Vault/Blog/posts}"
    BLOG_IMAGES_PATH="${BLOG_IMAGES_PATH:-$HOME/Documents/Obsidian-Vault/XSPC-Vault/Blog/images}"
    BLOG_DEST_PATH="${BLOG_DEST_PATH:-$ALLOWED_BLOG_ROOT/CS-Topics/content/posts}"
    
    # Python scripts.
    BLOG_SCRIPTS_DIR="${SCRIPT_DIR/python}"
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

# Loads configuration from file and validates all paths.
# Returns: 0 on success, 1 on failure.
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

# Creates a configuration template file with platform-specific defaults.
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

# Creates a timestamped backup of a directory.
# Args: $1=source_directory, $2=backup_name
# Returns: backup path on success, empty string on failure.
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

# Cleans up old backup directories, keeping only the most recent ones.
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

# Checks if a command exists in PATH.
# Args: $1=command_name
# Returns: 0 if found, 1 if not found.
blog_check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        blog_error "Required command not found: $cmd"
        return 1
    fi
    blog_debug "Command found: $cmd"
    return 0
}

# Checks if a directory exists and optionally creates it.
# Args: $1=directory, $2=description, $3=create_if_missing (optional, default: false).
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

# Checks if a file exists.
# Args: $1=file_path, $2=description
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

# Executes a command with timeout support.
# Args: $1=timeout_seconds, $2=description, $3...$n=command_and_args
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

# Detects changed files using Git status.
# Returns: 0 if changes found, 1 if no changes, sets BLOG_CHANGED_FILES array.
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

# Hash-based change detection (fallback method).
# Returns: 0 on success, 1 on failure.
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

# Wrapper function to ensure location validation before any blog operation.
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

# Initializes Git repository with remote origin.
# Ensures the repository is properly set up for blog automation.
blog_init_git() {
    blog_info "${BOLD}=== Git Initialization ===${RESET}"
    
    _blog_ensure_valid_location || return 1
    
    local current_dir="$(pwd)"
    cd "$BLOG_REPO_PATH" || {
        blog_error "Cannot access: $BLOG_REPO_PATH"
        return 1
    }
    
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

# Synchronizes posts from Obsidian vault to Hugo content directory.
# Uses rsync for efficient synchronization with backup protection.
blog_sync_posts() {
    blog_info "${BOLD}=== Posts Synchronization ===${RESET}"
    
    _blog_ensure_valid_location || return 1
    
    blog_check_dir "$BLOG_SOURCE_PATH" "Source" || return 1
    blog_check_dir "$BLOG_DEST_PATH" "Destination" true || return 1
    
    # Create backup before synchronization.
    # local backup_path=""
    # if [[ -d "$BLOG_DEST_PATH" ]] && [[ "$(ls -A "$BLOG_DEST_PATH" 2>/dev/null)" ]]; then
    #     backup_path=$(blog_create_backup "$BLOG_DEST_PATH" "posts_sync")
    #     if [[ -z "$backup_path" ]]; then
    #         blog_warn "Backup failed, continuing anyway"
    #     fi
    # fi
    
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

# Detects changes using the configured method (Git or hash-based).
# This is the main change detection function.
blog_detect_changes() {
    blog_info "${BOLD}=== Change Detection ===${RESET}"
    
    _blog_ensure_valid_location || return 1
    
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

# Updates frontmatter in markdown files using change detection.
# Only processes files that have been modified since last run.
blog_update_frontmatter() {
    blog_info "${BOLD}=== Frontmatter Update ===${RESET}"
    
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

# Processes images in markdown files.
# Converts Obsidian-style image links to Hugo-compatible markdown.
blog_process_images() {
    blog_info "${BOLD}=== Image Processing ===${RESET}"
    
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

# Builds the Hugo static site.
# Generates the final website in the 'public' directory.
blog_build_hugo() {
    blog_info "${BOLD}=== Hugo Site Build ===${RESET}"
    
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

# Commits all changes to the Git repository.
# Creates a timestamped commit with all modifications.
blog_commit_changes() {
    blog_info "${BOLD}=== Commit Changes ===${RESET}"
    
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

# Pushes committed changes to the main branch on the remote repository.
blog_push_main() {
    blog_info "${BOLD}=== Push to Main Branch ===${RESET}"
    
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

# Deploys the Hugo-generated public directory to the Hostinger branch.
# Uses git subtree to create a deployment-specific branch.
blog_deploy_hostinger() {
    blog_info "${BOLD}=== Deploy to Hostinger ===${RESET}"
    
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

# Executes all blog automation steps in sequence.
# Provides complete blog update workflow from sync to deployment.
blog_run_all() {
    blog_info "${BOLD}${MAGENTA}=== Starting Complete Blog Automation Process ===${RESET}"
    
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
        blog_success "${BOLD}=== Process Completed Successfully ===${RESET}"
        blog_info "Total duration: ${duration}s"
        
        # Cleanup old backups.
        blog_cleanup_backups
        
        return 0
    fi
}

# ============================================================================ #
# ++++++++++++++++++++++++ Utility and help functions ++++++++++++++++++++++++ #
# ============================================================================ #

# Shows current system status and configuration.
# Useful for debugging and system verification.
blog_status() {
    blog_info "${BOLD}=== Blog Automation Status ===${RESET}"
    
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
            blog_info "$cmd: ${GREEN}✓${RESET} $(command -v "$cmd")"
        else
            blog_warn "$cmd: ${RED}✗ NOT FOUND${RESET}"
        fi
    done
    
    echo ""
    blog_info "=== File Check ==="
    for file in "$BLOG_HASH_GENERATOR" "$BLOG_FRONTMATTER_SCRIPT" "$BLOG_IMAGES_SCRIPT"; do
        if [[ -f "$file" ]]; then
            blog_info "$(basename "$file"): ${GREEN}✓${RESET}"
        else
            blog_warn "$(basename "$file"): ${RED}✗${RESET} $file"
        fi
    done
    
    echo ""
    blog_info "=== Location Check ==="
    if [[ -d "$ALLOWED_BLOG_ROOT" ]]; then
        blog_info "Blog root: ${GREEN}✓${RESET} $ALLOWED_BLOG_ROOT"
        local current_dir="$(pwd)"
        case "$current_dir" in
            "$ALLOWED_BLOG_ROOT"*)
                blog_info "Current location: ${GREEN}✓ Valid${RESET}"
                ;;
            *)
                blog_warn "Current location: ${YELLOW}⚠ Outside blog directory${RESET}"
                blog_info "To use blog functions, run: ${CYAN}cd $ALLOWED_BLOG_ROOT${RESET}"
                ;;
        esac
    else
        blog_error "Blog root: ${RED}✗ Not found${RESET}"
    fi
}

# Shows comprehensive help information.
blog_help() {
    cat << EOF
${BOLD}Blog Automation Script v$VERSION - System: $PLATFORM${RESET}

${BOLD}USAGE:${RESET}
    Individual functions:
        ${CYAN}blog_init_git${RESET}              - Initialize Git repository
        ${CYAN}blog_sync_posts${RESET}            - Sync posts from Obsidian
        ${CYAN}blog_detect_changes${RESET}        - Detect changes (Git or hash-based)
        ${CYAN}blog_update_frontmatter${RESET}    - Update post frontmatter
        ${CYAN}blog_process_images${RESET}        - Process images in posts
        ${CYAN}blog_build_hugo${RESET}            - Build Hugo site
        ${CYAN}blog_commit_changes${RESET}        - Commit changes to Git
        ${CYAN}blog_push_main${RESET}             - Push to main branch
        ${CYAN}blog_deploy_hostinger${RESET}      - Deploy to hostinger branch
        
    Orchestration:
        ${GREEN}blog_run_all${RESET}               - Execute all steps in sequence
        
    Utilities:
        ${YELLOW}blog_status${RESET}                - Show system status
        ${YELLOW}blog_help${RESET}                  - Show this help
        
${BOLD}ENVIRONMENT VARIABLES:${RESET}
    ${CYAN}BLOG_DRY_RUN=true${RESET}              - Dry-run mode (default: false)
    ${CYAN}BLOG_VERBOSE=true${RESET}              - Verbose output (default: false)
    ${CYAN}BLOG_CHANGE_DETECTION=git${RESET}      - Change detection method (git/hash)
    
${BOLD}RESTRICTIONS:${RESET}
    This script only works in: ${YELLOW}$ALLOWED_BLOG_ROOT${RESET}
    Current directory: $(pwd)
    
${BOLD}CONFIGURATION:${RESET}
    File: $BLOG_CONFIG_FILE
    Logs: $BLOG_LOG_DIR/
    Backups: ${BLOG_BACKUP_DIR:-$ALLOWED_BLOG_ROOT/backups}/

${BOLD}EXAMPLES:${RESET}
    # Complete execution
    ${GREEN}blog_run_all${RESET}
    
    # Dry-run mode
    ${CYAN}BLOG_DRY_RUN=true blog_run_all${RESET}
    
    # Sync only
    ${CYAN}blog_sync_posts${RESET}
    
    # Status check
    ${YELLOW}blog_status${RESET}
    
    # Git-based change detection
    ${CYAN}BLOG_CHANGE_DETECTION=git blog_run_all${RESET}
EOF
}

# ============================================================================ #
# End of script.