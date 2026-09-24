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
# HOMEBREW_REQUIRE_TAP_TRUST is deliberately absent. Homebrew 7 deprecated it
# because requiring `brew trust` for non-official taps is now the default;
# setting it only printed a deprecation warning on every invocation. The
# behaviour it asked for is still in force unless HOMEBREW_NO_REQUIRE_TAP_TRUST
# is set, which this configuration never does.

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
[[ -n "${JAVA_HOME_17:-}" ]] && export JAVA_HOME_17

# Wrapper function for scala commands to use Java 17.
if [[ -n "$JAVA_HOME_17" ]]; then
  # ---------------------------------------------------------------------------
  # scala
  # @description Runs Scala with the configured Java 17 installation.
  # @arg $@ string Arguments forwarded to scala.
  # ---------------------------------------------------------------------------
  scala() {
    JAVA_HOME="$JAVA_HOME_17" command scala "$@"
  }

  # ---------------------------------------------------------------------------
  # scalac
  # @description Runs the Scala compiler with Java 17.
  # @arg $@ string Arguments forwarded to scalac.
  # ---------------------------------------------------------------------------
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
export STARSHIP_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/starship"

# ----------- Zsh Tooling ------------ #
# Shared directory for standalone Zsh tools (not shell startup plugins).
export ZSH_TOOLS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zsh/tools"
export ZSH_BENCH_DIR="${ZSH_TOOLS_DIR}/zsh-bench"

# --------------- Ruby --------------- #
# No RUBY_CONFIGURE_OPTS: the compiler behind CC (home/llvm) builds against the
# host macOS SDK, which carries zlib, readline and libffi itself, and
# ruby-build supplies openssl, libyaml and gmp from Homebrew on its own.

# --------------- Node --------------- #
# npm installs global packages into the ACTIVE Node version, so selecting a new
# FNM default or removing an old version takes every globally installed CLI
# with it. A prefix outside the version tree keeps those tools installed across
# Node upgrades. Only packages with native addons need a `npm rebuild -g` after
# a major Node change; pure JavaScript CLIs survive untouched.
export NPM_CONFIG_PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/npm-global"

# ---------------- Go ---------------- #
# 90-path.zsh adds $GOPATH/bin once it exists. GOCACHE and GOMODCACHE keep
# Go's own defaults (the platform user cache dir and $GOPATH/pkg/mod). This
# does not probe for `go`: PATH is only final after 90-path.zsh.
export GOPATH="$HOME/.go"

# --------------- Bun ---------------- #
export BUN_INSTALL="$HOME/.bun"

# -------- OS-specific environment variables -------- #
if [[ "$PLATFORM" == 'macOS' ]]; then
  # Keep compiler/linker selection project-local. `use_llvm`, `use_gnu`, and
  # `use_system` own toolchain flags explicitly and reversibly.

  # Give terminal-launched Emacs the libgccjit paths it needs without leaking
  # LIBRARY_PATH into every compiler, build, hook, and child process.
  () {
    local -a gcc_target_dir=(/opt/homebrew/opt/gcc/lib/gcc/current/gcc/*/*(N))
    (( ${#gcc_target_dir} )) || return 0
    typeset -g _EMACS_NATIVE_LIBRARY_PATH="${gcc_target_dir[1]}:/opt/homebrew/opt/gcc/lib/gcc/current:/opt/homebrew/opt/libgccjit/lib/gcc/current"
  }
  if [[ -n "${_EMACS_NATIVE_LIBRARY_PATH:-}" ]]; then
    # -------------------------------------------------------------------------
    # emacs
    # @description Runs Emacs with the Homebrew native library path.
    # @arg $@ string Arguments forwarded to emacs.
    # -------------------------------------------------------------------------
    emacs() {
      LIBRARY_PATH="${_EMACS_NATIVE_LIBRARY_PATH}${LIBRARY_PATH:+:$LIBRARY_PATH}" command emacs "$@"
    }
  fi

  # Android Home for Platform Tools.
  export ANDROID_HOME="$HOME/Library/Android/Sdk"

  # Ruby gems are deliberately NOT redirected with GEM_HOME. rbenv keeps one
  # gem tree per Ruby version; a global GEM_HOME overrides that and pools every
  # version's gems in one directory, which is how ~/.gem ended up holding
  # orphaned 2.6.0 and 3.4.0 trees after Homebrew moved Ruby to 4.x.
fi

if [[ "$PLATFORM" == 'Linux' && "$ARCH_LINUX" == true ]]; then
  # 1Password SSH agent socket.
  export SSH_AUTH_SOCK="$HOME/.1password/agent.sock"

  # Set Electron flags.
  export ELECTRON_OZONE_PLATFORM_HINT="wayland"
  export NATIVE_WAYLAND="1"

  # Docker Context for "Docker Desktop".
  export DOCKER_CONTEXT='default'
fi

# LCS.Data volume: warn once per terminal session (exported LCS_DATA_WARNED
# silences nested shells) when the shared volume is missing.
if [[ -n "${LCS_Data:-}" && ! -d "$LCS_Data" && -t 2 &&
      -z "${ZSH_SILENCE_LCS_DATA_WARN:-}" && -z "${LCS_DATA_WARNED:-}" ]]; then
  print -u2 "${C_YELLOW}Warning: the LCS.Data volume is not mounted at $LCS_Data${C_RESET}"
  export LCS_DATA_WARNED=1
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
