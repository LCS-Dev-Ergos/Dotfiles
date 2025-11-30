#!/usr/bin/env bash
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++ Toolchain Information Reporter +++++++++++++++++++ #
# ============================================================================ #
# Comprehensive C/C++ compiler toolchain analysis and reporting utility.
#
# This script provides detailed information about active compiler toolchains:
# - Compiler detection (cc, c++, gcc, g++, clang, clang++, versioned variants)
# - Vendor identification (Apple, Homebrew, GNU, LLVM, system packages)
# - Wrapper detection (ccache, symlinks, masquerading binaries)
# - Version reporting with origin attribution
# - Cross-platform support (macOS, Linux: Arch, Ubuntu, Debian)
#
# Features:
# - Automatic detection of Homebrew versioned GCC (gcc-14, gcc-15, etc.)
# - Symlink resolution to identify real compiler binaries
# - ccache wrapper detection with fallback resolution
# - Masquerading warnings (gcc pointing to clang, etc.)
# - Color-coded output with vendor/type highlighting
# - Environment variable override display (CC, CXX)
# - Debug mode for detailed path resolution information
#
# Usage:
#   get_toolchain_info              # Display comprehensive toolchain report
#   TOOLCHAIN_INFO_DEBUG=1 get_toolchain_info  # Enable debug output
#
# Author: XtremeXSPC
# License: MIT
# ============================================================================ #

# ++++++++++++++++++++++++++++++ Color Handling ++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _toolchain_info_init_colors
# -----------------------------------------------------------------------------
# Initializes terminal color codes for formatted toolchain output.
# Detects terminal capabilities and sets color variables. Preserves shell
# trace state to avoid polluting debug output.
#
# Usage:
#   _toolchain_info_init_colors
#
# Returns:
#   0 - Always succeeds.
#
# Side Effects:
#   - Sets global color variables: C_RESET, C_BOLD, C_RED, C_GREEN, etc.
#   - Temporarily disables VERBOSE and SOURCE_TRACE options.
# -----------------------------------------------------------------------------
_toolchain_info_init_colors() {
    # Preserve xtrace state.
    unsetopt VERBOSE SOURCE_TRACE

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
}

# ++++++++++++++++++++++++++++++ Helper Utils ++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _toolchain_detect_platform
# -----------------------------------------------------------------------------
# Detects operating system and Linux distribution for platform-specific logic.
# Returns human-readable platform string with distribution details.
#
# Usage:
#   platform=$(_toolchain_detect_platform)
#
# Returns:
#   0 - Always succeeds
#
# Side Effects:
#   - Outputs platform string to stdout.
#   - Temporarily disables VERBOSE and SOURCE_TRACE options.
# -----------------------------------------------------------------------------
_toolchain_detect_platform() {
    # Preserve xtrace state.
    unsetopt VERBOSE SOURCE_TRACE

    local os
    os=$(uname -s 2>/dev/null || printf "unknown")
    case "$os" in
    Darwin) echo "macOS" ;;
    Linux)
        if [[ -f "/etc/arch-release" ]]; then
            echo "Linux (Arch)"
        elif command -v lsb_release >/dev/null 2>&1; then
            echo "Linux ($(lsb_release -si 2>/dev/null))"
        else
            echo "Linux"
        fi
        ;;
    *) echo "$os" ;;
    esac
}

# -----------------------------------------------------------------------------
# _toolchain_path_without_ccache
# -----------------------------------------------------------------------------
# Filters PATH to exclude ccache directories.
# Used to find real compiler binaries when ccache wrappers are active.
#
# Usage:
#   filtered_path=$(_toolchain_path_without_ccache)
#
# Returns:
#   0 - Always succeeds.
#
# Side Effects:
#   - Outputs filtered PATH to stdout (colon-separated).
#   - Temporarily disables VERBOSE and SOURCE_TRACE options.
# -----------------------------------------------------------------------------
_toolchain_path_without_ccache() {
    # Preserve xtrace state.
    unsetopt VERBOSE SOURCE_TRACE

    local IFS=:
    local dir filtered=()
    for dir in $PATH; do
        [[ "$dir" == *ccache* ]] && continue
        filtered+=("$dir")
    done
    (
        IFS=:
        printf "%s" "${filtered[*]}"
    )
}

# -----------------------------------------------------------------------------
# _toolchain_portable_realpath
# -----------------------------------------------------------------------------
# Resolves symbolic links to absolute paths in portable way.
# Tries multiple methods with graceful fallback: realpath, python3, readlink.
#
# Usage:
#   real_path=$(_toolchain_portable_realpath <target>)
#
# Arguments:
#   target - File or symlink path to resolve (required).
#
# Returns:
#   0 - Always succeeds (returns original path if resolution fails).
#
# Side Effects:
#   - Outputs resolved path to stdout.
#   - Temporarily disables VERBOSE and SOURCE_TRACE options.
#
# Dependencies:
#   realpath - GNU coreutils (preferred, optional).
#   python3 - Python 3 interpreter (fallback, optional).
#   readlink - Symlink reader (fallback, optional).
# -----------------------------------------------------------------------------
_toolchain_portable_realpath() {
    # Preserve xtrace state.
    unsetopt VERBOSE SOURCE_TRACE

    local target="$1"

    if command -v realpath >/dev/null 2>&1; then
        realpath "$target" 2>/dev/null && return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$target" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
        return 0
    fi

    if command -v readlink >/dev/null 2>&1 && [[ -L "$target" ]]; then
        local link
        link=$(readlink "$target" 2>/dev/null) || true
        if [[ -n "$link" ]]; then
            printf "%s\n" "$link"
            return 0
        fi
    fi

    printf "%s\n" "$target"
}

# -----------------------------------------------------------------------------
# _toolchain_find_in_path
# -----------------------------------------------------------------------------
# Searches for executable binary in specified PATH or custom search path.
# Returns first matching executable found.
#
# Usage:
#   binary=$(_toolchain_find_in_path <name> [search_path])
#
# Arguments:
#   name - Binary name to search for (required).
#   search_path - Colon-separated path list (optional, default: $PATH).
#
# Returns:
#   0 - Binary found (outputs path to stdout).
#   1 - Binary not found.
#
# Side Effects:
#   - Outputs binary path to stdout on success.
#   - Temporarily disables VERBOSE and SOURCE_TRACE options.
# -----------------------------------------------------------------------------
_toolchain_find_in_path() {
    # Preserve xtrace state.
    unsetopt VERBOSE SOURCE_TRACE

    local name="$1" search_path="${2:-$PATH}" dir
    local IFS=:
    for dir in $search_path; do
        if [[ -x "$dir/$name" ]]; then
            printf "%s\n" "$dir/$name"
            return 0
        fi
    done
    return 1
}

# -----------------------------------------------------------------------------
# _toolchain_resolve_real_compiler
# -----------------------------------------------------------------------------
# Resolves real compiler binary from wrappers and symlinks.
# Handles ccache wrappers by searching for actual compiler in filtered PATH.
# Falls back to common compiler installation directories when needed.
#
# Usage:
#   real_compiler=$(_toolchain_resolve_real_compiler <compiler_path>)
#
# Arguments:
#   compiler_path - Compiler binary path to resolve (required).
#
# Returns:
#   0 - Always succeeds.
#
# Side Effects:
#   - Outputs resolved compiler path to stdout.
#   - Preserves xtrace state.
#
# Dependencies:
#   _toolchain_portable_realpath - Path resolution function.
#   _toolchain_path_without_ccache - ccache filter function.
# -----------------------------------------------------------------------------
_toolchain_resolve_real_compiler() {
    # Preserve xtrace state.
    emulate -L zsh
    setopt noxtrace noverbose

    local compiler_path="$1"
    local resolved
    resolved=$(_toolchain_portable_realpath "$compiler_path")

    if [[ "$compiler_path" == *ccache* ]]; then
        local compiler_name filtered_path alt_path
        compiler_name=$(basename "$compiler_path")
        filtered_path=$(_toolchain_path_without_ccache)
        alt_path=$(_toolchain_find_in_path "$compiler_name" "$filtered_path") || true
        if [[ -n "$alt_path" ]]; then
            resolved=$(_toolchain_portable_realpath "$alt_path")
        fi

        # Fallback: search common compiler locations if we still resolve to ccache.
        if [[ "$resolved" == *ccache* ]]; then
            local fallback_dirs=(
                "/usr/bin"
                "/usr/local/bin"
                "/opt/homebrew/bin"
                "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
            )
            local dir
            for dir in "${fallback_dirs[@]}"; do
                if [[ -x "$dir/$compiler_name" ]]; then
                    resolved=$(_toolchain_portable_realpath "$dir/$compiler_name")
                    break
                fi
            done
        fi
    fi

    printf "%s\n" "${resolved:-$compiler_path}"
}

# -----------------------------------------------------------------------------
# _toolchain_vendor_for_gcc
# -----------------------------------------------------------------------------
# Identifies GCC compiler vendor from version output and installation path.
# Distinguishes between Homebrew, Ubuntu, Debian, Arch, and system GCC.
#
# Usage:
#   vendor=$(_toolchain_vendor_for_gcc <version_info> <compiler_path>)
#
# Arguments:
#   version_info - Output from compiler --version (required).
#   compiler_path - Full path to compiler binary (required).
#
# Returns:
#   0 - Always succeeds.
#
# Side Effects:
#   - Outputs vendor string to stdout.
#   - Temporarily disables VERBOSE and SOURCE_TRACE options.
# -----------------------------------------------------------------------------
_toolchain_vendor_for_gcc() {
    # Preserve xtrace state.
    unsetopt VERBOSE SOURCE_TRACE

    local version_info="$1" compiler_path="$2"
    if [[ "$version_info" == *"Homebrew"* ]]; then
        echo "Homebrew GNU"
    elif [[ "$compiler_path" == /opt/homebrew/Cellar/gcc/* ]]; then
        echo "Homebrew GNU"
    elif [[ "$version_info" == *"Ubuntu"* ]]; then
        echo "GNU (Ubuntu)"
    elif [[ "$version_info" == *"Debian"* ]]; then
        echo "GNU (Debian)"
    elif [[ "$version_info" == *"Arch Linux"* || "$version_info" == *"Archlinux"* ]]; then
        echo "GNU (Arch)"
    elif [[ "$compiler_path" == /usr/bin/* ]]; then
        echo "GNU (system)"
    else
        echo "GNU"
    fi
}

# -----------------------------------------------------------------------------
# _toolchain_vendor_for_clang
# -----------------------------------------------------------------------------
# Identifies Clang/LLVM compiler vendor from version output and path.
# Distinguishes between Apple Clang, Homebrew LLVM, Ubuntu, Debian, and system.
#
# Usage:
#   vendor=$(_toolchain_vendor_for_clang <version_info> <compiler_path>)
#
# Arguments:
#   version_info - Output from compiler --version (required).
#   compiler_path - Full path to compiler binary (required).
#
# Returns:
#   0 - Always succeeds.
#
# Side Effects:
#   - Outputs vendor string to stdout.
#   - Preserves xtrace state.
# -----------------------------------------------------------------------------
_toolchain_vendor_for_clang() {
    # Preserve xtrace state.
    emulate -L zsh
    setopt noxtrace noverbose

    local version_info="$1" compiler_path="$2"
    if [[ "$version_info" == *"Apple clang"* ]]; then
        echo "Apple"
    elif [[ "$version_info" == *"Homebrew"* ]]; then
        echo "Homebrew LLVM"
    elif [[ "$version_info" == *"Ubuntu"* ]]; then
        echo "LLVM (Ubuntu)"
    elif [[ "$version_info" == *"Debian"* ]]; then
        echo "LLVM (Debian)"
    elif [[ "$compiler_path" == /usr/bin/* ]]; then
        echo "LLVM (system)"
    else
        echo "LLVM"
    fi
}

# -----------------------------------------------------------------------------
# _toolchain_compiler_details
# -----------------------------------------------------------------------------
# Extracts compiler type, vendor, and version information.
# Executes compiler with --version and parses output to identify toolchain.
# Returns pipe-delimited string: type|vendor|version
#
# Usage:
#   details=$(_toolchain_compiler_details <compiler_path>)
#   IFS='|' read -r type vendor version <<<"$details"
#
# Arguments:
#   compiler_path - Full path to compiler binary (required).
#
# Returns:
#   0 - Always succeeds.
#
# Side Effects:
#   - Outputs type|vendor|version to stdout.
#   - Preserves xtrace state.
# -----------------------------------------------------------------------------
_toolchain_compiler_details() {
    # Preserve xtrace state.
    emulate -L zsh
    setopt noxtrace noverbose

    local compiler_path="$1"
    local version_info toolchain_type="Unknown" vendor=""

    # Get version information.
    if ! version_info=$("$compiler_path" --version 2>/dev/null | head -n 1); then
        version_info="Version information unavailable"
        printf "%s|%s|%s\n" "$toolchain_type" "$vendor" "$version_info"
        return
    fi

    version_info="${version_info//$'\r'/}"

    # Determine toolchain type and vendor.
    if [[ "$version_info" == *"Apple clang"* || "$version_info" == *"clang version"* ]]; then
        toolchain_type="Clang"
        vendor=$(_toolchain_vendor_for_clang "$version_info" "$compiler_path")
    elif [[ "$version_info" == *"(GCC)"* || "$version_info" == *"gcc version"* || "$version_info" == *"Homebrew GCC"* ]]; then
        toolchain_type="GCC"
        vendor=$(_toolchain_vendor_for_gcc "$version_info" "$compiler_path")
    fi

    printf "%s|%s|%s\n" "$toolchain_type" "$vendor" "$version_info"
}

# ++++++++++++++++++++++++++++++ Main Function +++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# get_toolchain_info
# -----------------------------------------------------------------------------
# Generates comprehensive compiler toolchain report with vendor, version, and
# wrapper resolution details. Enumerates common compilers plus Homebrew GCC
# variants, resolves ccache/symlinks to real binaries, and warns on masqueraded
# toolchains (e.g., gcc → clang). Supports optional debug output.
#
# Usage:
#   get_toolchain_info
#   TOOLCHAIN_INFO_DEBUG=1 get_toolchain_info  # Enable debug logging
#
# Returns:
#   0 - Always succeeds.
#
# Side Effects:
#   - Prints formatted toolchain report to stdout.
#   - Reads environment variables: CC, CXX, TOOLCHAIN_INFO_DEBUG, PATH.
#
# Dependencies:
#   _toolchain_info_init_colors - Color setup helper.
#   _toolchain_detect_platform - Platform identification helper.
#   _toolchain_resolve_real_compiler - Wrapper resolution helper.
#   _toolchain_compiler_details - Compiler info parser.
#   brew/find/command/uname - External utilities used for detection.
# -----------------------------------------------------------------------------
get_toolchain_info() {
    # Preserve xtrace state.
    emulate -L zsh
    setopt noxtrace

    # Initialize colors.
    _toolchain_info_init_colors

    echo "${C_GREEN}/===--------------------------------------------------------------===/${C_RESET}"
    printf "%s%sAnalyzing C/C++ toolchain configuration (%s)...%s\n" \
        "$C_BOLD" "$C_CYAN" "$(_toolchain_detect_platform)" "$C_RESET"

    if [[ -n "${CC:-}" || -n "${CXX:-}" ]]; then
        printf "%sEnvironment variables (override defaults):%s\n" "$C_YELLOW" "$C_RESET"
        [[ -n "${CC:-}" ]] && printf "   %sCC  = %s%s%s\n" "$C_BOLD" "$C_CYAN" "$CC" "$C_RESET"
        [[ -n "${CXX:-}" ]] && printf "   %sCXX = %s%s%s\n" "$C_BOLD" "$C_CYAN" "$CXX" "$C_RESET"
        echo
    fi

    local -a compilers=("cc" "c++" "gcc" "g++" "clang" "clang++")
    local -A seen_compilers=()

    # Add Homebrew versioned GCC binaries if present (e.g., gcc-15, g++-15).
    if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
        local brew_prefix gcc_bin
        if command -v brew >/dev/null 2>&1; then
            brew_prefix=$(brew --prefix 2>/dev/null)
            if [[ -n "$brew_prefix" && -d "$brew_prefix/opt/gcc/bin" ]]; then
                gcc_bin="$brew_prefix/opt/gcc/bin"
            fi
        fi

        if [[ -z "$gcc_bin" && -d "/opt/homebrew/opt/gcc/bin" ]]; then
            gcc_bin="/opt/homebrew/opt/gcc/bin"
        fi

        if [[ -n "$gcc_bin" && -d "$gcc_bin" ]]; then
            while IFS= read -r compiler_entry; do
                local name=$(basename "$compiler_entry")
                if [[ -n "$name" ]]; then
                    compilers+=("$name")
                fi
            done < <(find "$gcc_bin" -maxdepth 1 -type f \( -name "gcc-[0-9]*" -o -name "g++-[0-9]*" \) -print 2>/dev/null | sort -V)
        fi
    fi

    # Deduplicate while preserving order.
    local -a unique=()
    local comp_name
    for comp_name in "${compilers[@]}"; do
        if [[ -z "${seen_compilers[$comp_name]:-}" ]]; then
            seen_compilers["$comp_name"]=1
            unique+=("$comp_name")
        fi
    done
    compilers=("${unique[@]}")

    printf "%sActive compilers in PATH:%s\n\n" "$C_BOLD" "$C_RESET"

    local compiler
    for compiler in "${compilers[@]}"; do
        local cpath=$(command -v "$compiler" 2>/dev/null)

        if [[ -n "$cpath" && -x "$cpath" ]]; then
            local real_cpath=$(_toolchain_resolve_real_compiler "$cpath")

            local wrapper_details=$(_toolchain_compiler_details "$cpath")
            local real_details=$(_toolchain_compiler_details "$real_cpath")

            IFS='|' read -r wrapper_type wrapper_vendor wrapper_version <<<"$wrapper_details"
            IFS='|' read -r real_type real_vendor real_version <<<"$real_details"

            printf "%s◆ %-10s%s %s%s%s\n" "$C_GREEN" "$compiler" "$C_RESET" "$C_CYAN" "$cpath" "$C_RESET"

            local has_wrapper=false
            if [[ "$cpath" == *"/ccache/"* || "$cpath" == *"ccache/bin"* ]]; then
                printf "  ├─ %sWrapper:%s ccache (caching)\n" "$C_YELLOW" "$C_RESET"
                has_wrapper=true
            elif [[ "$cpath" != "$real_cpath" ]]; then
                printf "  ├─ %sSymlink:%s → %s%s%s\n" "$C_YELLOW" "$C_RESET" "$C_CYAN" "$real_cpath" "$C_RESET"
                has_wrapper=true
            fi

            if [[ "$has_wrapper" == true ]]; then
                printf "  └─ %sReal compiler:%s %s %s\n" "$C_BLUE" "$C_RESET" "$real_vendor" "$real_type"
                printf "     %sVersion:%s %s\n" "$C_MAGENTA" "$C_RESET" "$real_version"
            else
                printf "  ├─ %sType:%s %s %s\n" "$C_BLUE" "$C_RESET" "$real_vendor" "$real_type"
                printf "  └─ %sVersion:%s %s\n" "$C_MAGENTA" "$C_RESET" "$real_version"
            fi

            if [[ ("$compiler" == "gcc" || "$compiler" == "g++") && "$real_type" == "Clang" ]]; then
                printf "     %sWarning:%s '%s' resolves to Clang, not GCC\n" "$C_YELLOW" "$C_RESET" "$compiler"
            elif [[ ("$compiler" == "clang" || "$compiler" == "clang++") && "$real_type" == "GCC" ]]; then
                printf "     %sWarning:%s '%s' resolves to GCC, not Clang\n" "$C_YELLOW" "$C_RESET" "$compiler"
            fi

            if [[ "${TOOLCHAIN_INFO_DEBUG:-0}" != "0" ]]; then
                printf "     %sDebug:%s compiler_path=%s%s%s\n" "$C_BOLD" "$C_RESET" "$C_CYAN" "$compiler_path" "$C_RESET"
                printf "            real_compiler_path=%s%s%s\n" "$C_CYAN" "$real_compiler_path" "$C_RESET"
                printf "            wrapper_details='%s%s%s|%s%s%s|%s%s%s'\n" \
                    "$C_BLUE" "$wrapper_type" "$C_RESET" "$C_YELLOW" "$wrapper_vendor" "$C_RESET" "$C_MAGENTA" "$wrapper_version" "$C_RESET"
                printf "            real_details='%s%s%s|%s%s%s|%s%s%s'\n" \
                    "$C_BLUE" "$real_type" "$C_RESET" "$C_YELLOW" "$real_vendor" "$C_RESET" "$C_MAGENTA" "$real_version" "$C_RESET"
            fi
            echo
        else
            printf "%s✗ %-10s%s Not found in PATH\n\n" "$C_RED" "$compiler" "$C_RESET"
        fi
    done

    echo "${C_GREEN}/===--------------------------------------------------------------===/${C_RESET}"
}

# ============================================================================ #
# End of script.
