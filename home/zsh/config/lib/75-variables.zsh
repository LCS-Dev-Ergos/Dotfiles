#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
#     ██╗   ██╗ █████╗ ██████╗ ██╗ █████╗ ██████╗ ██╗     ███████╗███████╗
#     ██║   ██║██╔══██╗██╔══██╗██║██╔══██╗██╔══██╗██║     ██╔════╝██╔════╝
#     ██║   ██║███████║██████╔╝██║███████║██████╔╝██║     █████╗  ███████╗
#     ╚██╗ ██╔╝██╔══██║██╔══██╗██║██╔══██║██╔══██╗██║     ██╔══╝  ╚════██║
#      ╚████╔╝ ██║  ██║██║  ██║██║██║  ██║██████╔╝███████╗███████╗███████║
#       ╚═══╝  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚══════╝╚══════╝
# ============================================================================ #
# ++++++++++++++++++++++++ GLOBAL VARIABLES & EXPORTS ++++++++++++++++++++++++ #
# ============================================================================ #
#
# Environment variables and configuration for development tools, build systems,
# and project-specific paths. Organized by category for maintainability.
#
# Categories:
#   - JVM & Build Tools (Java, Gradle, Maven, SBT).
#   - Scala Configuration.
#   - Clang-Format.
#   - OpenSSL.
#   - Go Language.
#   - Project Directories (LCS.Data, Blog).
#   - Platform-specific exports.
#
# ============================================================================ #

# ------------- Homebrew ------------- #
export HOMEBREW_REQUIRE_TAP_TRUST="1"

# Precompute shared volume path before use in later sections.
if [[ "$PLATFORM" == 'macOS' ]]; then
  export LCS_Data="/Volumes/LCS.Data"
elif [[ "$PLATFORM" == 'Linux' && "$ARCH_LINUX" == true ]]; then
  export LCS_Data="/LCS.Data"
fi

# -------- JVM & Build Tools --------- #
# JVM: Performance optimization flags for local development.
export JAVA_TOOL_OPTIONS="-XX:+TieredCompilation -XX:MaxRAMPercentage=75.0"

# Gradle: Performance tuning with daemon, parallel builds, and caching.
export GRADLE_OPTS="-Xmx4g -Xms512m -XX:+UseG1GC -XX:MaxGCPauseMillis=200 \
  -Dorg.gradle.daemon=true -Dorg.gradle.parallel=true \
  -Dorg.gradle.caching=true -Dorg.gradle.configureondemand=true \
  -Dorg.gradle.vfs.watch=true"

# Maven: Performance tuning with increased heap and fast compilation.
export MAVEN_OPTS="-Xmx3g -Xms512m -XX:+UseG1GC -XX:+TieredCompilation"

# SBT: Scala build tool optimization.
export SBT_OPTS="-Xmx3g -Xms512m -XX:+UseG1GC -XX:MaxMetaspaceSize=1g -XX:ReservedCodeCacheSize=256m"

# ---------- Scala Configs ----------- #
# Scala: Use Java 17 LTS to avoid sun.misc.Unsafe warnings.
# Dynamically find Java 17 installation via SDKMAN (no subshell fork).
() {
  local sdkman_java="${SDKMAN_DIR:-$HOME/.sdkman}/candidates/java"
  # Try 'current' symlink for Java 17 if explicitly set.
  if [[ -d "$sdkman_java/17-tem" ]]; then
    JAVA_HOME_17="$sdkman_java/17-tem"
    return
  fi
  # Find any Java 17.x installation (prefer Temurin, then any).
  local -a java17_dirs
  java17_dirs=("$sdkman_java"/17*(N-/))
  if (( ${#java17_dirs} )); then
    JAVA_HOME_17="${java17_dirs[1]}"
    return
  fi
  # Fallback to current Java if no 17 found.
  [[ -d "$sdkman_java/current" ]] && JAVA_HOME_17="$sdkman_java/current"
}
export JAVA_HOME_17

# Wrapper function for scala commands to use Java 17.
if [[ -n "$JAVA_HOME_17" ]]; then
  # -------------------------------------------------------------------------
  # scala
  # @description Runs Scala with the configured Java 17 installation.
  # @arg $@ string Arguments forwarded to scala.
  # -------------------------------------------------------------------------
  scala() {
    JAVA_HOME="$JAVA_HOME_17" command scala "$@"
  }

  # -------------------------------------------------------------------------
  # scalac
  # @description Runs the Scala compiler with Java 17.
  # @arg $@ string Arguments forwarded to scalac.
  # -------------------------------------------------------------------------
  scalac() {
    JAVA_HOME="$JAVA_HOME_17" command scalac "$@"
  }
fi

# ----------- Clang-Format ----------- #
# Clang-Format Configuration.
export CLANG_FORMAT_CONFIG="$HOME/.config/clang-format/.clang-format"

# --------- OpenSSL Configs ---------- #
# OpenSSL for some Python packages (specific to environments that require it).
if [[ "$PLATFORM" == "Linux" ]]; then
  export CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1
fi

# ------------- Starship ------------- #
# Starship prompt configuration directory.
export STARSHIP_CONFIG="$HOME/.config/starship/starship.toml"

# Starship prompt cache directory.
export STARSHIP_CACHE_DIR="$HOME/.cache/starship"

# ----------- Zsh Tooling ------------ #
# Shared directory for standalone Zsh tools (not shell startup plugins).
export ZSH_TOOLS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zsh/tools"
export ZSH_BENCH_DIR="${ZSH_TOOLS_DIR}/zsh-bench"

# -------- OS-specific environment variables -------- #
if [[ "$PLATFORM" == 'macOS' ]]; then
  # Keep compiler/linker selection project-local. `use_llvm`, `use_gnu`, and
  # `use_system` own toolchain flags explicitly and reversibly.

  # Give terminal-launched Emacs the libgccjit paths it needs without leaking
  # LIBRARY_PATH into every compiler, build, hook, and child process.
  local gcc_target_dir=(/opt/homebrew/opt/gcc/lib/gcc/current/gcc/*/*(N))
  if (( ${#gcc_target_dir} )); then
    typeset -g _EMACS_NATIVE_LIBRARY_PATH="${gcc_target_dir[1]}:/opt/homebrew/opt/gcc/lib/gcc/current:/opt/homebrew/opt/libgccjit/lib/gcc/current"
    # -------------------------------------------------------------------------
    # emacs
    # @description Runs Emacs with the Homebrew native library path.
    # @arg $@ string Arguments forwarded to emacs.
    # -------------------------------------------------------------------------
    emacs() {
      LIBRARY_PATH="${_EMACS_NATIVE_LIBRARY_PATH}${LIBRARY_PATH:+:$LIBRARY_PATH}" command emacs "$@"
    }
  fi

  # GO Language.
  # Note: PATH is handled by 90-path.zsh via $GOPATH/bin.
  if command -v go >/dev/null 2>&1; then
    export GOPATH="$HOME/.go"
    # Go: Module and build cache optimization.
    export GOCACHE="$HOME/Library/Caches/go-build"
    export GOMODCACHE="$GOPATH/pkg/mod"
  fi

  # Android Home for Platform Tools.
  export ANDROID_HOME="$HOME/Library/Android/Sdk"

  # Ruby Gems.
  export GEM_HOME="$HOME/.gem"

  # Bun JavaScript runtime.
  export BUN_INSTALL="$HOME/.bun"

  # LCS.Data Volume.
  if [[ ! -d "$LCS_Data" ]]; then
    if [[ -t 1 ]] && [[ -z "${ZSH_SILENCE_LCS_DATA_WARN:-}" ]] && [[ -z "${LCS_DATA_WARNED:-}" ]]; then
      echo "${C_YELLOW}⚠️ Warning: LCS.Data volume is not mounted${C_RESET}"
      LCS_DATA_WARNED=1
    fi
  fi
fi

if [[ "$PLATFORM" == 'Linux' && "$ARCH_LINUX" == true ]]; then
  # 1Password SSH agent socket.
  export SSH_AUTH_SOCK="$HOME/.1password/agent.sock"

  # Set Electron flags.
  export ELECTRON_OZONE_PLATFORM_HINT="wayland"
  export NATIVE_WAYLAND="1"

  # Docker Context for "Docker Desktop".
  export DOCKER_CONTEXT='default'

  # Bun JavaScript runtime.
  export BUN_INSTALL="$HOME/.bun"

  # GO Language.
  # Note: PATH is handled by 90-path.zsh via $GOPATH/bin.
  if command -v go >/dev/null 2>&1; then
    export GOPATH="$HOME/.go"
    # Go: Module and build cache optimization.
    export GOCACHE="$HOME/.cache/go-build"
    export GOMODCACHE="$GOPATH/pkg/mod"
  fi

  # LCS.Data Volume.
  if [[ ! -d "$LCS_Data" ]]; then
    if [[ -t 1 ]] && [[ -z "${ZSH_SILENCE_LCS_DATA_WARN:-}" ]] && [[ -z "${LCS_DATA_WARNED:-}" ]]; then
      echo "${C_YELLOW}⚠️ Warning: LCS.Data volume does not appear to be mounted in $LCS_Data${C_RESET}"
      LCS_DATA_WARNED=1
    fi
  fi
fi

# --------------- Blog --------------- #
# Blog directories and scripts.
if [[ -n "${LCS_Data:-}" ]]; then
  export BLOG_POSTS_DIR="$LCS_Data/Blog/CS-Topics/content/posts/"
  export BLOG_STATIC_IMAGES_DIR="$LCS_Data/Blog/CS-Topics/static/images"
  export IMAGES_SCRIPT_PATH="${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}/scripts/blog/python/images.py"
fi
export OBSIDIAN_ATTACHMENTS_DIR="$HOME/Documents/Obsidian-Vault/XSPC-Vault/Blog/images"

# ============================================================================ #
# End of lib/75-variables.zsh
