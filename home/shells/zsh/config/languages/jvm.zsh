#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++ JVM AND SDKMAN INTEGRATION ++++++++++++++++++++++++ #
# ============================================================================ #

# First, prioritize SDKMAN! if it is installed.
if [[ -s "${SDKMAN_DIR:-$HOME/.sdkman}/bin/sdkman-init.sh" ]]; then
  # SDKMAN! found. Use a lazy init to avoid startup cost.
  export SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"

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
        local java_path="${commands[java]:A}"
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
        print -u2 "${C_YELLOW}Warning: Unable to determine JAVA_HOME automatically, and SDKMAN! is not installed.${C_RESET}"
        print -u2 "   ${C_YELLOW}Please install Java and/or SDKMAN!, or set JAVA_HOME manually.${C_RESET}"
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

# An unavailable optional integration is a successful no-op.
:
