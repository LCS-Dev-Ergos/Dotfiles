#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++ LANGUAGE ENVIRONMENT MANAGERS +++++++++++++++++++++++ #
# ============================================================================ #
#
# Initialization of programming language version managers and runtime environments.
# Organized into static (Nix, Homebrew, Haskell, OCaml) and dynamic managers
# (SDKMAN, pyenv, conda, rbenv, fnm).
#
# Loading order is critical:
#   1. Static environment managers (don't modify PATH dynamically).
#   2. Dynamic environment managers (modify PATH per-directory or per-shell).
#
# Performance optimizations:
#   - Lazy loading where possible.
#   - Conditional initialization based on command availability.
#   - Platform-aware detection.
#
# ============================================================================ #

# +++++++++++++++++++++++ STATIC ENVIRONMENT MANAGERS ++++++++++++++++++++++++ #

# --------------- Nix --------------- #
# This setup is platform-aware. It checks for standard Nix installation
# paths, which can differ between multi-user and single-user setups.
if [[ "$PLATFORM" == 'macOS' ]] || [[ "$PLATFORM" == 'Linux' ]]; then
    # Standard path for multi-user Nix installations (recommended).
    if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
        . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
        # Fallback for single-user Nix installations.
    elif [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
        . "$HOME/.nix-profile/etc/profile.d/nix.sh"
    fi
fi

# ------- Homebrew / Linuxbrew ------ #
# This logic is now strictly separated by platform to avoid incorrect detection.
if [[ "$PLATFORM" == 'macOS' ]]; then
    # On macOS, check for the Apple Silicon path first, then the Intel path.
    if [[ -x "/opt/homebrew/bin/brew" ]]; then # macOS Apple Silicon
        export HOMEBREW_PREFIX="/opt/homebrew"
        export HOMEBREW_CELLAR="/opt/homebrew/Cellar"
        export HOMEBREW_REPOSITORY="/opt/homebrew"
        export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
        export MANPATH="/opt/homebrew/share/man${MANPATH:+:$MANPATH}"
        export INFOPATH="/opt/homebrew/share/info${INFOPATH:+:$INFOPATH}"
    elif [[ -x "/usr/local/bin/brew" ]]; then # macOS Intel
        export HOMEBREW_PREFIX="/usr/local"
        export HOMEBREW_CELLAR="/usr/local/Cellar"
        export HOMEBREW_REPOSITORY="/usr/local/Homebrew"
        export PATH="/usr/local/bin:/usr/local/sbin:$PATH"
        export MANPATH="/usr/local/share/man${MANPATH:+:$MANPATH}"
        export INFOPATH="/usr/local/share/info${INFOPATH:+:$INFOPATH}"
    fi
elif [[ "$PLATFORM" == 'Linux' ]]; then
    # On Linux, check for the standard Linuxbrew path.
    if [[ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]]; then
        export HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
        export HOMEBREW_CELLAR="/home/linuxbrew/.linuxbrew/Cellar"
        export HOMEBREW_REPOSITORY="/home/linuxbrew/.linuxbrew/Homebrew"
        export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"
        export MANPATH="/home/linuxbrew/.linuxbrew/share/man${MANPATH:+:$MANPATH}"
        export INFOPATH="/home/linuxbrew/.linuxbrew/share/info${INFOPATH:+:$INFOPATH}"
    fi
fi

# ------- Haskell (ghcup-env) ------- #
[[ -f "$HOME/.ghcup/env" ]] && . "$HOME/.ghcup/env"

# -------------- Opam --------------- #
# OCaml: Build and package manager optimization.
export OPAMJOBS=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo "4") # Parallel builds.
export DUNE_CACHE=enabled                                                         # Enable Dune build cache.
export DUNE_CACHE_TRANSPORT=direct                                                # Faster cache access.
# export OPAMYES=1  # Auto-confirm opam operations.

[[ ! -r "$HOME/.opam/opam-init/init.zsh" ]] || source "$HOME/.opam/opam-init/init.zsh" >/dev/null 2>/dev/null

# ============================================================================ #
# ++++++++++++++++++++++ DYNAMIC ENVIRONMENT MANAGERS  +++++++++++++++++++++++ #

# ===================== LANGUAGES AND DEVELOPMENT TOOLS ====================== #

# -------------------- Java - Smart JAVA_HOME Management --------------------- #
# First, prioritize SDKMAN! if it is installed.
if [[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]]; then
    # SDKMAN! found. Let it manage everything.
    export SDKMAN_DIR="$HOME/.sdkman"
    if [[ -f "$HOME/.sdkman/bin/sdkman-init.sh" ]]; then
        source "$HOME/.sdkman/bin/sdkman-init.sh"
    else
        echo "${C_YELLOW}Warning: SDKMAN init script not found.${C_RESET}"
    fi
else
    # -------------------------------------------------------------------------
    # setup_java_home_fallback
    # -------------------------------------------------------------------------
    # Auto-detect and configure JAVA_HOME when SDKMAN is not available.
    # Platform-aware detection using system utilities and standard JVM paths.
    #
    # Detection methods:
    #   macOS: /usr/libexec/java_home utility
    #   Linux: update-alternatives, archlinux-java, or /usr/lib/jvm search
    #
    # Sets:
    #   JAVA_HOME - Java installation directory
    #   PATH      - Adds $JAVA_HOME/bin
    # -------------------------------------------------------------------------
    setup_java_home_fallback() {
        # Cache file location
        local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
        local cache_file="$cache_dir/java_home"

        # Check if cache exists and is less than 7 days old
        if [[ -f "$cache_file" ]]; then
            # Check modification time (macOS/Linux compatible)
            local cache_valid=false
            if [[ "$PLATFORM" == 'macOS' ]]; then
                # stat -f %m returns modification time in seconds
                local mtime=$(stat -f %m "$cache_file")
                local now=$(date +%s)
                # 604800 seconds = 7 days
                if ((now - mtime < 604800)); then
                    cache_valid=true
                fi
            else
                # Linux find -mtime -7
                if [[ -n $(find "$cache_file" -mtime -7 2>/dev/null) ]]; then
                    cache_valid=true
                fi
            fi

            if $cache_valid; then
                source "$cache_file"
                return
            fi
        fi

        # Fallback to manual detection if cache is invalid or doesn't exist.
        if [[ "$PLATFORM" == 'macOS' ]]; then
            # On macOS, use the system-provided utility.
            if [[ -x "/usr/libexec/java_home" ]]; then
                local java_home_result
                java_home_result=$(/usr/libexec/java_home 2>/dev/null)
                if [[ $? -eq 0 && -n "$java_home_result" ]]; then
                    export JAVA_HOME="$java_home_result"
                    export PATH="$JAVA_HOME/bin:$PATH"
                fi
            fi
        elif [[ "$PLATFORM" == 'Linux' ]]; then
            local found_java_home=""
            # Method 1: For Debian/Ubuntu/Fedora based systems (uses update-alternatives).
            if command -v update-alternatives &>/dev/null && command -v java &>/dev/null; then
                local java_path=$(readlink -f "$(which java)" 2>/dev/null)
                if [[ -n "$java_path" ]]; then
                    found_java_home="${java_path%/bin/java}"
                fi
            fi
            # Method 2: For Arch Linux systems (uses archlinux-java).
            if [[ -z "$found_java_home" ]] && command -v archlinux-java &>/dev/null; then
                local java_env=$(archlinux-java get)
                if [[ -n "$java_env" ]]; then
                    found_java_home="/usr/lib/jvm/$java_env"
                fi
            fi
            # Method 3: Generic fallback by searching in "/usr/lib/jvm".
            if [[ -z "$found_java_home" ]] && [[ -d "/usr/lib/jvm" ]]; then
                found_java_home=$(find /usr/lib/jvm -maxdepth 1 -type d -name "java-*-openjdk*" | sort -V | tail -n 1)
            fi
            # Export variables only if we found a valid path.
            if [[ -n "$found_java_home" && -d "$found_java_home" ]]; then
                export JAVA_HOME="$found_java_home"
                export PATH="$JAVA_HOME/bin:$PATH"
            else
                echo "${C_YELLOW}⚠️ Warning: Unable to automatically determine JAVA_HOME and SDKMAN! is not installed.${C_RESET}"
                echo "   ${C_YELLOW}Please install Java and/or SDKMAN!, or set JAVA_HOME manually.${C_RESET}"
            fi
        fi

        # Save to cache if JAVA_HOME was found
        if [[ -n "$JAVA_HOME" ]]; then
            mkdir -p "$cache_dir"
            echo "export JAVA_HOME='$JAVA_HOME'" >"$cache_file"
            echo "export PATH='\$JAVA_HOME/bin:\$PATH'" >>"$cache_file"
        fi
    }
    # Execute the fallback function.
    setup_java_home_fallback
fi

# -------------- PyENV -------------- #
if command -v pyenv >/dev/null 2>&1; then
    export PYENV_ROOT="$HOME/.pyenv"
    [[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init -)" 2>/dev/null || echo "${C_YELLOW}Warning: pyenv init failed.${C_RESET}"
    eval "$(pyenv virtualenv-init -)" 2>/dev/null || echo "${C_YELLOW}Warning: pyenv virtualenv-init failed.${C_RESET}"
fi

# ------------- Python -------------- #
# Python: Bytecode caching and pip best practices.
export PYTHONDONTWRITEBYTECODE=1   # Avoid .pyc files cluttering directories.
export PIP_REQUIRE_VIRTUALENV=true # Safety: only allow pip in virtual environments.
export PIPENV_VENV_IN_PROJECT=1    # Store .venv in project directory.

# -------------- Rust --------------- #
# Rust: Parallel compilation and incremental builds.
if command -v sysctl >/dev/null 2>&1; then
    export CARGO_BUILD_JOBS=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo "4")
fi
export CARGO_INCREMENTAL=1

# -------------- CONDA -------------- #
# >>> Conda initialize >>>
# -----------------------------------------------------------------------------
# __conda_init
# -----------------------------------------------------------------------------
# Initialize Conda/Miniforge with platform-aware path detection.
# Supports both Arch Linux system installation and user installation.
#
# Paths checked:
#   Linux (Arch): /opt/miniconda3/bin/conda
#   User:         ~/.miniforge3/bin/conda
#
# Configuration:
#   - Disables conda's prompt modification (changeps1 false).
# -----------------------------------------------------------------------------
__conda_init() {
    local conda_path=""
    # Arch specific path.
    if [[ "$PLATFORM" == 'Linux' && -f "/opt/miniconda3/bin/conda" ]]; then
        conda_path="/opt/miniconda3/bin/conda"
        # User path (macOS or other Linux).
    elif [[ -f "$HOME/.miniforge3/bin/conda" ]]; then
        conda_path="$HOME/.miniforge3/bin/conda"
    fi

    if [[ -n "$conda_path" ]]; then
        __conda_setup="$("$conda_path" 'shell.zsh' 'hook' 2>/dev/null)"
        if [[ $? -eq 0 ]]; then
            eval "$__conda_setup"
        else
            local conda_dir=$(dirname "$(dirname "$conda_path")")
            if [[ -f "$conda_dir/etc/profile.d/conda.sh" ]]; then
                . "$conda_dir/etc/profile.d/conda.sh"
            else
                export PATH="$(dirname "$conda_path"):$PATH"
            fi
        fi
        unset __conda_setup

        # Disable conda's built-in prompt modification
        conda config --set changeps1 false 2>/dev/null
    fi
}
__conda_init
unset -f __conda_init
# <<< Conda initialize <<<

# ------------ Perl CPAN ------------ #
# Only run if the local::lib directory exists.
local_perl_dir="$HOME/.perl5"
if [[ -d "$local_perl_dir" ]]; then
    if command -v perl >/dev/null 2>&1; then
        eval "$(perl -I"$local_perl_dir/lib/perl5" -Mlocal::lib="$local_perl_dir")" 2>/dev/null
    fi
fi

# -------------- rbenv -------------- #
if command -v rbenv >/dev/null 2>&1; then
    export RBENV_ROOT="$HOME/.rbenv"
    [[ -d $RBENV_ROOT/bin ]] && export PATH="$RBENV_ROOT/bin:$PATH"
    eval "$(rbenv init - zsh)" 2>/dev/null || echo "${C_YELLOW}Warning: rbenv init failed.${C_RESET}"
fi

# ----- FNM (Fast Node Manager) ----- #
if command -v fnm &>/dev/null; then

    # Node.js: npm optimization and memory settings.
    export NPM_CONFIG_FUND=false                    # Disable funding messages.
    export NPM_CONFIG_AUDIT=false                   # Disable audit during install (run manually).
    export NODE_OPTIONS="--max-old-space-size=4096" # Increase V8 heap size.

    # Declare a command counter (of integer type) specific to this session.
    typeset -i FNM_CMD_COUNTER=0

    # -------------------------------------------------------------------------
    # _fnm_update_timestamp
    # -------------------------------------------------------------------------
    # Heartbeat function to keep fnm multishell session alive.
    # Updates symlink timestamp every 50 commands to prevent cleanup.
    #
    # Called by:
    #   precmd hook on every command.
    #
    # Behavior:
    #   - Increments command counter.
    #   - Updates timestamp when counter exceeds 30.
    #   - Resets counter after update.
    # -------------------------------------------------------------------------
    _fnm_update_timestamp() {
        # Increment the counter on every command.
        ((FNM_CMD_COUNTER++))
        # Only update if the counter has exceeded 50 (reduced frequency).
        if ((FNM_CMD_COUNTER > 50)); then
            if [ -n "$FNM_MULTISHELL_PATH" ] && [ -L "$FNM_MULTISHELL_PATH" ]; then
                # Update the timestamp of the link.
                touch -h "$FNM_MULTISHELL_PATH" 2>/dev/null
            fi
            # Reset the counter to zero.
            FNM_CMD_COUNTER=0
        fi
    }

    # Set a global default version if it doesn't exist.
    if ! fnm default >/dev/null 2>&1; then
        latest_installed=$(fnm list | grep -o 'v[0-9.]\+' | sort -V | tail -n 1)
        if [ -n "$latest_installed" ]; then
            fnm default "$latest_installed"
        fi
    fi

    # Initialize fnm.
    if command -v fnm >/dev/null 2>&1; then
        eval "$(fnm env --use-on-cd --shell zsh)" 2>/dev/null || echo "${C_YELLOW}Warning: fnm env failed.${C_RESET}"
    fi

    # Register the zsh hook to keep the session link fresh.
    autoload -U add-zsh-hook
    add-zsh-hook precmd _fnm_update_timestamp
fi

# ============================================================================ #
