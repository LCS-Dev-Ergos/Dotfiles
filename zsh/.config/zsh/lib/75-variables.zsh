#!/usr/bin/env zsh
# shellcheck shell=zsh
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
#   - Project Directories (LCS.Data, Blog).
#   - Platform-specific exports.
#
# ============================================================================ #

# Precompute shared volume path before use in later sections.
if [[ "$PLATFORM" == 'macOS' ]]; then
  export LCS_Data="/Volumes/LCS.Data"
elif [[ "$PLATFORM" == 'Linux' && "$ARCH_LINUX" == true ]]; then
  export LCS_Data="/LCS.Data"
fi

# -------- JVM & Build Tools --------- #
# JVM: Performance optimization flags for local development.
export JAVA_TOOL_OPTIONS="-XX:+UseG1GC -XX:MaxRAMPercentage=75.0 -XX:+TieredCompilation"

# Gradle: Performance tuning with daemon, parallel builds, and caching.
export GRADLE_OPTS="-Dorg.gradle.daemon=true -Dorg.gradle.parallel=true -Dorg.gradle.caching=true -Xmx2g"

# Maven: Performance tuning with increased heap and fast compilation.
export MAVEN_OPTS="-Xmx2g -XX:+TieredCompilation -XX:TieredStopAtLevel=1"

# SBT: Scala build tool optimization.
export SBT_OPTS="-Xmx2g -XX:+UseG1GC -XX:MaxMetaspaceSize=512m"

# ---------- Scala Configs ----------- #
# Scala: Use Java 17 LTS to avoid sun.misc.Unsafe warnings.
export JAVA_HOME_17="$HOME/.sdkman/candidates/java/17.0.13-tem"

# Wrapper function for scala commands to use Java 17.
scala() {
  JAVA_HOME="$JAVA_HOME_17" command scala "$@"
}

scalac() {
  JAVA_HOME="$JAVA_HOME_17" command scalac "$@"
}

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

# -------- OS-specific environment variables -------- #
if [[ "$PLATFORM" == 'macOS' ]]; then
  # Force the use of system binaries to avoid conflicts.
  export LD="/usr/bin/ld"
  export AR="/usr/bin/ar"
  # Activate these flags if you intend to use Homebrew's LLVM.
  export CPATH="/opt/homebrew/include"
  export LDFLAGS="-L/opt/homebrew/opt/llvm/lib"
  export CPPFLAGS="-I/opt/homebrew/opt/llvm/include"

  # GO Language.
  export GOROOT="/usr/local/go"
  export GOPATH="$HOME/.go"

  # Android Home for Platform Tools.
  export ANDROID_HOME="$HOME/Library/Android/Sdk"

  # Ruby Gems.
  export GEM_HOME="$HOME/.gem"

  # LCS.Data Volume.
  if [[ ! -d "$LCS_Data" ]]; then
    if [[ -t 1 ]] && [[ -z "${ZSH_SILENCE_LCS_DATA_WARN:-}" ]] && [[ -z "${LCS_DATA_WARNED:-}" ]]; then
      echo "${C_YELLOW}⚠️ Warning: LCS.Data volume is not mounted${C_RESET}"
      LCS_DATA_WARNED=1
    fi
  fi
fi

if [[ "$PLATFORM" == 'Linux' && "$ARCH_LINUX" == true ]]; then
  # Set Electron flags.
  export ELECTRON_OZONE_PLATFORM_HINT="wayland"
  export NATIVE_WAYLAND="1"

  # Docker Context for "Docker Desktop".
  export DOCKER_CONTEXT='default'

  # GO Language.
  if command -v go >/dev/null 2>&1; then
    export GOPATH="$HOME/go"
    # Go: Module and build cache optimization.
    export GOCACHE="$HOME/.cache/go-build"
    export GOMODCACHE="$GOPATH/pkg/mod"
    go_bin=$(go env GOBIN 2>/dev/null)
    go_path=$(go env GOPATH 2>/dev/null)
    [[ -n "$go_bin" ]] && export PATH="$PATH:$go_bin"
    [[ -n "$go_path" ]] && export PATH="$PATH:$go_path/bin"
    unset go_bin go_path
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
  export IMAGES_SCRIPT_PATH="$LCS_Data/Blog/Automatic-Updates/images.py"
fi
export OBSIDIAN_ATTACHMENTS_DIR="$HOME/Documents/Obsidian-Vault/XSPC-Vault/Blog/images"

# ============================================================================ #
