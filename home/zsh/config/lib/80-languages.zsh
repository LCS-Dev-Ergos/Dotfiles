#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ██╗      █████╗ ███╗   ██╗ ██████╗ ██╗   ██╗ █████╗  ██████╗ ███████╗███████╗
# ██║     ██╔══██╗████╗  ██║██╔════╝ ██║   ██║██╔══██╗██╔════╝ ██╔════╝██╔════╝
# ██║     ███████║██╔██╗ ██║██║  ███╗██║   ██║███████║██║  ███╗█████╗  ███████╗
# ██║     ██╔══██║██║╚██╗██║██║   ██║██║   ██║██╔══██║██║   ██║██╔══╝  ╚════██║
# ███████╗██║  ██║██║ ╚████║╚██████╔╝╚██████╔╝██║  ██║╚██████╔╝███████╗███████║
# ╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚══════╝
# ============================================================================ #
# ++++++++++++++++++++++ LANGUAGE ENVIRONMENT MANAGERS +++++++++++++++++++++++ #
# ============================================================================ #
#
# Initializes language version managers and runtime environments.
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
# Contract: the fnm lazy initializer calls zsh_rebuild_path when the later PATH
# module is available, preserving the active fnm multishell directory.
#
# ============================================================================ #

typeset -f _zsh_cache_is_fresh >/dev/null 2>&1 ||
  source "${${(%):-%N}:A:h:h}/runtime-helpers.zsh"

# +++++++++++++++++++++++ STATIC ENVIRONMENT MANAGERS ++++++++++++++++++++++++ #

# --------------- Nix ---------------- #
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

# ------- Homebrew / Linuxbrew ------- #
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

# ------- Haskell (ghcup-env) -------- #
[[ -f "$HOME/.ghcup/env" ]] && . "$HOME/.ghcup/env"

# --------------- Opam --------------- #
# OCaml: Build and package manager optimization.
export OPAMJOBS="${_ZSH_NCPUS:-4}"  # Parallel builds (uses cached CPU count from 00-initialization.zsh).
export DUNE_CACHE=enabled           # Enable Dune build cache.
export DUNE_CACHE_TRANSPORT=direct  # Faster cache access.
# export OPAMYES=1  # Auto-confirm opam operations.

[[ ! -r "$HOME/.opam/opam-init/init.zsh" ]] || source "$HOME/.opam/opam-init/init.zsh" >/dev/null 2>/dev/null

# +++++++++++++++++++++ LANGUAGES AND DEVELOPMENT TOOLS ++++++++++++++++++++++ #

# -------------------- Java - Smart JAVA_HOME Management --------------------- #
# First, prioritize SDKMAN! if it is installed.
if [[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]]; then
  # SDKMAN! found. Use a lazy init to avoid startup cost.
  export SDKMAN_DIR="$HOME/.sdkman"

  # Provide JAVA_HOME eagerly if possible (fast, avoids waiting for sdk init).
  if [[ -z "${JAVA_HOME:-}" && -d "$SDKMAN_DIR/candidates/java/current" ]]; then
    export JAVA_HOME="$SDKMAN_DIR/candidates/java/current"
  fi

  # ---------------------------------------------------------------------------
  # _sdkman_lazy_init
  # @internal
  # @description Sources SDKMAN's init script once, guarded against
  # re-running.
  # @noargs
  # ---------------------------------------------------------------------------
  _sdkman_lazy_init() {
    [[ -n "${_SDKMAN_LAZY_INIT:-}" ]] && return 0
    _SDKMAN_LAZY_INIT=1
    source "$SDKMAN_DIR/bin/sdkman-init.sh"
  }

  # ---------------------------------------------------------------------------
  # sdk
  # @description Lazily initializes SDKMAN, then runs its sdk command.
  # @arg $@ string Arguments forwarded to SDKMAN.
  # ---------------------------------------------------------------------------
  sdk() {
    unfunction sdk 2>/dev/null
    _sdkman_lazy_init
    sdk "$@"
  }
else
  # ---------------------------------------------------------------------------
  # _setup_java_home_fallback
  # @internal
  # @description Detects JAVA_HOME when SDKMAN is unavailable.
  # Uses platform tools and caches a secure result for later shells.
  # @noargs
  # ---------------------------------------------------------------------------
  _setup_java_home_fallback() {
    # Cache file location.
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
    local cache_file="$cache_dir/java_home"
    # Check if cache exists, is safe, and is less than 7 days old.
    if _zsh_cache_is_fresh "$cache_file" 604800; then
      source "$cache_file"
      return
    elif [[ -f "$cache_file" ]] && ! _zsh_is_secure_file "$cache_file"; then
      echo "${C_YELLOW}Warning: skipping insecure Java cache file: $cache_file${C_RESET}" >&2
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
      # Method 1: Debian, Ubuntu, or Fedora via update-alternatives.
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
        local -a jvm_dirs=(/usr/lib/jvm/java-*-openjdk*(N/On))
        (( ${#jvm_dirs[@]} )) && found_java_home="${jvm_dirs[1]}"
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

    # Save to cache if JAVA_HOME was found.
    if [[ -n "$JAVA_HOME" ]]; then
      {
        print -r -- "export JAVA_HOME=${(qq)JAVA_HOME}"
        print -r -- 'export PATH="$JAVA_HOME/bin:$PATH"'
      } | _zsh_cache_put "$cache_file"
    fi
  }
  # Execute the fallback function.
  _setup_java_home_fallback
  unfunction _setup_java_home_fallback 2>/dev/null
fi

# -------------- PyENV --------------- #
if [[ -d "$HOME/.pyenv" ]]; then
  export PYENV_ROOT="$HOME/.pyenv"
  [[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"

  if command -v pyenv >/dev/null 2>&1; then
    # -------------------------------------------------------------------------
    # _pyenv_lazy_init
    # @internal
    # @description Evaluates pyenv init and virtualenv-init once, guarded
    # against re-running.
    # @noargs
    # -------------------------------------------------------------------------
    _pyenv_lazy_init() {
      [[ -n "${_PYENV_LAZY_INIT:-}" ]] && return 0
      _PYENV_LAZY_INIT=1
      eval "$(command pyenv init -)" 2>/dev/null || echo "${C_YELLOW}Warning: pyenv init failed.${C_RESET}"
      eval "$(command pyenv virtualenv-init -)" 2>/dev/null || echo "${C_YELLOW}Warning: pyenv virtualenv-init failed.${C_RESET}"
    }

    # -------------------------------------------------------------------------
    # pyenv
    # @description Lazily initializes pyenv, then runs its command.
    # @arg $@ string Arguments forwarded to pyenv.
    # -------------------------------------------------------------------------
    pyenv() {
      unfunction pyenv 2>/dev/null
      _pyenv_lazy_init
      pyenv "$@"
    }
  fi
fi

# -------------- Python -------------- #
# Python: Bytecode caching and pip best practices.
export PYTHONDONTWRITEBYTECODE=1   # Avoid .pyc files cluttering directories.
export PIP_REQUIRE_VIRTUALENV=true # Safety: only allow pip in virtual environments.
export PIPENV_VENV_IN_PROJECT=1    # Store .venv in project directory.

# --------------- Rust --------------- #
# Rust: Parallel compilation and incremental builds.
export CARGO_BUILD_JOBS="${_ZSH_NCPUS:-4}" # Uses cached CPU count from 00-initialization.zsh.
export CARGO_INCREMENTAL=1

# -------------- C/C++ --------------- #
# Conservative C/C++ defaults: keep them tool-friendly and non-invasive.
# Avoid global optimization flags here; project build files should own those.
if command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ccache"
  export CCACHE_COMPRESS=1
  export CCACHE_COMPRESSLEVEL="${CCACHE_COMPRESSLEVEL:-5}"
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-10G}"

  # CMake launcher variables (used by CMake projects when available).
  export CMAKE_C_COMPILER_LAUNCHER="ccache"
  export CMAKE_CXX_COMPILER_LAUNCHER="ccache"
fi

# Enable compile_commands.json generation for LSP/tooling in CMake projects.
: "${CMAKE_EXPORT_COMPILE_COMMANDS:=1}"
export CMAKE_EXPORT_COMPILE_COMMANDS

# -------------- CONDA --------------- #
# >>> Conda initialize >>>
# -----------------------------------------------------------------------------
# _conda_lazy_init
# @internal
# @description Initializes Conda/Miniforge once, guarded against re-running,
# checking the Arch system path and the user Miniforge install in turn, and
# disabling conda's own prompt modification.
# @noargs
# -----------------------------------------------------------------------------
_conda_lazy_init() {
  [[ -n "${_CONDA_LAZY_INIT:-}" ]] && return 0
  _CONDA_LAZY_INIT=1

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
      local conda_dir
      conda_dir=$(dirname "$(dirname "$conda_path")")
      if [[ -f "$conda_dir/etc/profile.d/conda.sh" ]]; then
        . "$conda_dir/etc/profile.d/conda.sh"
      else
        export PATH="$(dirname "$conda_path"):$PATH"
      fi
    fi
    unset __conda_setup

    # Disable conda's built-in prompt modification (runs on first use only).
    conda config --set changeps1 false 2>/dev/null
  fi
}

if [[ -f "/opt/miniconda3/bin/conda" || -f "$HOME/.miniforge3/bin/conda" ]]; then
  # ---------------------------------------------------------------------------
  # conda
  # @description Lazily initializes Conda, then runs its command.
  # @arg $@ string Arguments forwarded to conda.
  # ---------------------------------------------------------------------------
  conda() {
    unfunction conda 2>/dev/null
    _conda_lazy_init
    conda "$@"
  }
fi
# <<< Conda initialize <<<

# ------------ Perl CPAN ------------- #
# Only run if the local::lib directory exists. The eval output is a fixed set
# of environment exports derived from the directory path, so cache it keyed to
# the Perl executable instead of forking perl in every interactive shell.
() {
  local local_perl_dir="$HOME/.perl5"
  [[ -d "$local_perl_dir" ]] || return 0
  command -v perl >/dev/null 2>&1 || return 0

  local perl_bin="${commands[perl]}"
  local cache_file="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/perl-local-lib.zsh"
  local cache_header="# perl-bin: $perl_bin"
  local cached_header=""
  if _zsh_cache_is_fresh "$cache_file"; then
    IFS= read -r cached_header < "$cache_file"
    if [[ "$cached_header" == "$cache_header" &&
          "$cache_file" -nt "$perl_bin" ]]; then
      source "$cache_file"
      return 0
    fi
  fi

  local init_code
  init_code="$(perl -I"$local_perl_dir/lib/perl5" \
    -Mlocal::lib="$local_perl_dir" 2>/dev/null)" || return 0
  [[ -n "$init_code" ]] || return 0
  eval "$init_code" 2>/dev/null
  {
    print -r -- "$cache_header"
    print -r -- "$init_code"
  } | _zsh_cache_put "$cache_file" 2>/dev/null
}

# -------------- rbenv --------------- #
if [[ -d "$HOME/.rbenv" ]]; then
  export RBENV_ROOT="$HOME/.rbenv"
  [[ -d "$RBENV_ROOT/bin" ]] && export PATH="$RBENV_ROOT/bin:$PATH"

  if command -v rbenv >/dev/null 2>&1; then
    # -------------------------------------------------------------------------
    # _rbenv_lazy_init
    # @internal
    # @description Evaluates rbenv init once, guarded against re-running.
    # @noargs
    # -------------------------------------------------------------------------
    _rbenv_lazy_init() {
      [[ -n "${_RBENV_LAZY_INIT:-}" ]] && return 0
      _RBENV_LAZY_INIT=1
      eval "$(command rbenv init - zsh)" 2>/dev/null || echo "${C_YELLOW}Warning: rbenv init failed.${C_RESET}"
    }

    # -------------------------------------------------------------------------
    # rbenv
    # @description Lazily initializes rbenv, then runs its command.
    # @arg $@ string Arguments forwarded to rbenv.
    # -------------------------------------------------------------------------
    rbenv() {
      unfunction rbenv 2>/dev/null
      _rbenv_lazy_init
      rbenv "$@"
    }
  fi
fi

# ----- FNM (Fast Node Manager) ------ #
if command -v fnm &>/dev/null; then
  # ---------------------------------------------------------------------------
  # _fnm_lazy_init
  # @internal
  # @description Initializes the fnm multishell environment once per active
  # symlink, sets a default Node version when none is aliased, and rebuilds
  # PATH afterward.
  # @noargs
  # @exitcode 1 If `fnm env` fails.
  # ---------------------------------------------------------------------------
  _fnm_lazy_init() {
    if [[ -n "${_FNM_LAZY_INIT:-}" ]]; then
      if [[ -n "${FNM_MULTISHELL_PATH:-}" && -d "$FNM_MULTISHELL_PATH/bin" ]] \
        && [[ ":$PATH:" == *":$FNM_MULTISHELL_PATH/bin:"* ]]; then
        return 0
      fi
      unset _FNM_LAZY_INIT
    fi

    emulate -L zsh
    setopt noxtrace noverbose

    # Node.js: npm optimization and memory settings.
    export NPM_CONFIG_FUND=false                    # Disable funding messages.
    export NPM_CONFIG_AUDIT=false                   # Disable audit during install (run manually).
    export NODE_OPTIONS="--max-old-space-size=4096" # Increase V8 heap size.

    # Set a global default version only when no alias/default exists.
    local fnm_alias_default="${FNM_DIR:-$HOME/.local/share/fnm}/aliases/default"
    if [[ ! -e "$fnm_alias_default" ]]; then
      local latest_installed
      latest_installed=$(
        command fnm list 2>/dev/null \
          | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^v[0-9][0-9.]*$/) print $i}' \
          | sort -V \
          | tail -n 1
      )
      if [[ -n "$latest_installed" ]]; then
        command fnm default "$latest_installed" >/dev/null 2>&1
      fi
    fi

    # Initialize fnm environment on demand.
    # This sets FNM_MULTISHELL_PATH and adds fnm to PATH.
    local fnm_env_output
    fnm_env_output="$(command fnm env --use-on-cd --shell zsh 2>/dev/null)" || {
      echo "${C_YELLOW}Warning: fnm env failed.${C_RESET}"
      return 1
    }

    if eval "$fnm_env_output"; then
      _FNM_LAZY_INIT=1

      if typeset -f zsh_rebuild_path >/dev/null 2>&1; then
        zsh_rebuild_path
      fi
      return 0
    fi

    echo "${C_YELLOW}Warning: fnm env failed.${C_RESET}"
    return 1
  }

  # ---------------------------------------------------------------------------
  # _fnm_setup_heartbeat
  # @internal
  # @description Registers a precmd hook that periodically touches the fnm
  # multishell symlink so it is not reaped as stale; runs once per session.
  # @noargs
  # ---------------------------------------------------------------------------
  _fnm_setup_heartbeat() {
    [[ -n "${_FNM_HEARTBEAT_SETUP:-}" ]] && return 0
    _FNM_HEARTBEAT_SETUP=1

    # Declare a command counter (of integer type) specific to this session.
    typeset -gi FNM_CMD_COUNTER=0

    # -------------------------------------------------------------------------
    # _fnm_update_timestamp
    # @internal
    # @description Touches the fnm multishell symlink every 50 precmd calls to
    # keep the session alive.
    # @noargs
    # -------------------------------------------------------------------------
    _fnm_update_timestamp() {
      ((FNM_CMD_COUNTER++))
      if ((FNM_CMD_COUNTER >= 50)); then
        if [[ -n "$FNM_MULTISHELL_PATH" && -L "$FNM_MULTISHELL_PATH" ]]; then
          touch -h "$FNM_MULTISHELL_PATH" 2>/dev/null
        fi
        FNM_CMD_COUNTER=0
      fi
    }

    # Register the zsh hook to keep the session link fresh.
    autoload -U add-zsh-hook
    add-zsh-hook precmd _fnm_update_timestamp
  }

  # ---------------------------------------------------------------------------
  # _fnm_ensure_ready
  # @internal
  # @description Ensures fnm is initialized and its heartbeat hook is armed.
  # @noargs
  # @exitcode 1 If fnm initialization fails.
  # ---------------------------------------------------------------------------
  _fnm_ensure_ready() {
    _fnm_lazy_init || return 1
    _fnm_setup_heartbeat
  }

  if [[ "${ZSH_FAST_START:-}" == "1" ]]; then
    : # skip during fast start.
  elif typeset -f _zsh_defer >/dev/null 2>&1; then
    _zsh_defer _fnm_lazy_init
  else
    add-zsh-hook precmd _fnm_lazy_init
  fi

  # ---------------------------------------------------------------------------
  # fnm
  # @description Initializes fnm on demand, then runs its command.
  # @arg $@ string Arguments forwarded to fnm.
  # ---------------------------------------------------------------------------
  fnm() {
    if ! _fnm_ensure_ready; then
      command fnm "$@"
      return $?
    fi
    unfunction fnm 2>/dev/null
    command fnm "$@"
  }

  # Ensure fnm and its heartbeat before each Node-related command.
  # ---------------------------------------------------------------------------
  # node
  # @description Ensures fnm is ready, then runs Node.js.
  # @arg $@ string Arguments forwarded to node.
  # @exitcode 1 If fnm initialization fails.
  # ---------------------------------------------------------------------------
  node() {
    _fnm_ensure_ready || return 1
    command node "$@"
  }

  # ---------------------------------------------------------------------------
  # npm
  # @description Ensures fnm is ready, then runs npm.
  # @arg $@ string Arguments forwarded to npm.
  # @exitcode 1 If fnm initialization fails.
  # ---------------------------------------------------------------------------
  npm() {
    _fnm_ensure_ready || return 1
    command npm "$@"
  }

  # ---------------------------------------------------------------------------
  # npx
  # @description Ensures fnm is ready, then runs npx.
  # @arg $@ string Arguments forwarded to npx.
  # @exitcode 1 If fnm initialization fails.
  # ---------------------------------------------------------------------------
  npx() {
    _fnm_ensure_ready || return 1
    command npx "$@"
  }

  # ---------------------------------------------------------------------------
  # corepack
  # @description Ensures fnm is ready, then runs Corepack.
  # @arg $@ string Arguments forwarded to corepack.
  # @exitcode 1 If fnm initialization fails.
  # ---------------------------------------------------------------------------
  corepack() {
    _fnm_ensure_ready || return 1
    command corepack "$@"
  }

  # ---------------------------------------------------------------------------
  # pi
  # @description Initializes the default fnm Node environment, then launches
  # the Pi coding agent installed in that environment.
  # @arg $@ string Arguments forwarded to Pi.
  # @exitcode 1 If fnm initialization fails; 127 if Pi is not installed.
  # ---------------------------------------------------------------------------
  pi() {
    _fnm_ensure_ready || return 1

    local pi_bin="$(whence -p pi 2>/dev/null)"
    if [[ -z "$pi_bin" ]]; then
      print -u2 "pi: executable not found in the active Node environment"
      return 127
    fi

    unfunction pi 2>/dev/null
    "$pi_bin" "$@"
  }
fi

# ============================================================================ #
# End of lib/80-languages.zsh
