#!/usr/bin/env bash
# shellcheck shell=zsh
# ============================================================================ #
# Toolchain switcher for macOS (Homebrew/Xcode) and Linux (Arch/Ubuntu).
# Provides safe toggles between LLVM/Clang and GNU GCC toolchains, handling
# common installation layouts from Homebrew and distro packages.
#
# Usage:
#   use_llvm    # Prefer LLVM/Clang toolchain (Homebrew on macOS, system on Linux)
#   use_gnu     # Prefer GNU GCC toolchain (Homebrew on macOS, system on Linux)
#   use_system  # Restore the original environment
# ============================================================================ #

# ------------------------------ Color Handling ------------------------------ #
_toolchain_init_colors() {
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null) -ge 8 ]]; then
        C_RESET=$'\e[0m'
        C_BOLD=$'\e[1m'
        C_RED=$'\e[31m'
        C_GREEN=$'\e[32m'
        C_YELLOW=$'\e[33m'
        C_BLUE=$'\e[34m'
        C_CYAN=$'\e[36m'
    else
        C_RESET=""
        C_BOLD=""
        C_RED=""
        C_GREEN=""
        C_YELLOW=""
        C_BLUE=""
        C_CYAN=""
    fi
}

# ------------------------------ Platform Probe ------------------------------ #
_toolchain_detect_platform() {
    if [[ -n "${TOOLCHAIN_OS:-}" ]]; then
        return
    fi

    case "$(uname -s 2>/dev/null)" in
    Darwin) TOOLCHAIN_OS="macOS" ;;
    Linux) TOOLCHAIN_OS="Linux" ;;
    *) TOOLCHAIN_OS="Other" ;;
    esac

    if [[ "$TOOLCHAIN_OS" == "Linux" && -f "/etc/arch-release" ]]; then
        TOOLCHAIN_DISTRO="Arch"
    fi
}

# ------------------------------ State Storage ------------------------------- #
# Ensure PATH is not empty; otherwise, fall back to a sane default to avoid
# breaking builtin utilities when this file is sourced in a bad environment.
if [[ -z "${PATH:-}" ]]; then
    PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
fi

if [[ -z "${ORIGINAL_PATH:-}" ]]; then
    export ORIGINAL_PATH="${PATH}"
fi
: "${TOOLCHAIN_ORIGINAL_PATH:=${ORIGINAL_PATH}}"

if [[ -z "${_TOOLCHAIN_SAVED_ENV:-}" ]]; then
    _TOOLCHAIN_SAVED_ENV=1
    TOOLCHAIN_ORIGINAL_LDFLAGS="${LDFLAGS-__TOOLCHAIN_UNSET__}"
    TOOLCHAIN_ORIGINAL_CPPFLAGS="${CPPFLAGS-__TOOLCHAIN_UNSET__}"
    TOOLCHAIN_ORIGINAL_PKG_CONFIG_PATH="${PKG_CONFIG_PATH-__TOOLCHAIN_UNSET__}"
    TOOLCHAIN_ORIGINAL_CC="${CC-__TOOLCHAIN_UNSET__}"
    TOOLCHAIN_ORIGINAL_CXX="${CXX-__TOOLCHAIN_UNSET__}"
fi

# ------------------------------- Log Helpers -------------------------------- #
_toolchain_log() {
    local level="$1"
    shift
    case "$level" in
    info) printf "%s[INFO]%s %s\n" "$C_CYAN" "$C_RESET" "$*" ;;
    ok) printf "%s[OK]%s   %s\n" "$C_GREEN" "$C_RESET" "$*" ;;
    warn) printf "%s[WARN]%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2 ;;
    error) printf "%s[ERROR]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2 ;;
    esac
}

_toolchain_restore_var() {
    local name="$1" value="$2"
    if [[ "$value" == "__TOOLCHAIN_UNSET__" ]]; then
        unset "$name"
    else
        export "$name=$value"
    fi
}

_toolchain_reset_env_to_original() {
    _toolchain_restore_var LDFLAGS "$TOOLCHAIN_ORIGINAL_LDFLAGS"
    _toolchain_restore_var CPPFLAGS "$TOOLCHAIN_ORIGINAL_CPPFLAGS"
    _toolchain_restore_var PKG_CONFIG_PATH "$TOOLCHAIN_ORIGINAL_PKG_CONFIG_PATH"
    _toolchain_restore_var CC "$TOOLCHAIN_ORIGINAL_CC"
    _toolchain_restore_var CXX "$TOOLCHAIN_ORIGINAL_CXX"
}

_toolchain_set_path() {
    local bin_dir="$1"
    local base="${TOOLCHAIN_ORIGINAL_PATH}"
    if [[ -z "$base" ]]; then
        base="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    fi
    if [[ -n "$bin_dir" ]]; then
        export PATH="${bin_dir}:${base}"
        TOOLCHAIN_ACTIVE_BIN="$bin_dir"
    else
        export PATH="${base}"
        TOOLCHAIN_ACTIVE_BIN=""
    fi
}

_toolchain_get_homebrew_prefix() {
    if [[ -n "${HOMEBREW_PREFIX:-}" && -d "${HOMEBREW_PREFIX}" ]]; then
        echo "${HOMEBREW_PREFIX}"
        return 0
    fi

    if command -v brew >/dev/null 2>&1; then
        local prefix
        prefix=$(brew --prefix 2>/dev/null)
        if [[ -n "$prefix" && -d "$prefix" ]]; then
            echo "$prefix"
            return 0
        fi
    fi

    for prefix in /opt/homebrew /usr/local; do
        if [[ -d "$prefix" ]]; then
            echo "$prefix"
            return 0
        fi
    done

    return 1
}

_toolchain_find_best_binary() {
    local base="$1"
    shift
    local fallback="" best="" best_ver=-1 dir candidate_path ver ver_str

    local -a dirs=()
    local IFS=:
    for dir in $PATH; do
        dirs+=("$dir")
    done
    for dir in "$@"; do
        dirs+=("$dir")
    done

    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        if [[ -x "$dir/$base" && -z "$fallback" ]]; then
            fallback="$dir/$base"
        fi

        # Prefer versioned binaries (e.g., clang-17, gcc-14) without relying on shell globbing.
        while IFS= read -r candidate_path; do
            ver_str="${candidate_path##*-}"
            case "$ver_str" in
            '' | *[!0-9]*) continue ;;
            esac
            ver=$ver_str
            if ((ver > best_ver)); then
                best_ver=$ver
                best="$candidate_path"
            fi
        done < <(find "$dir" -maxdepth 1 -type f -name "$base-[0-9]*" -print 2>/dev/null)
    done

    if [[ -n "$best" ]]; then
        printf "%s\n" "$best"
    elif [[ -n "$fallback" ]]; then
        printf "%s\n" "$fallback"
    fi
}

_toolchain_select_llvm_bin_dir() {
    local -a candidates=()

    if [[ "$TOOLCHAIN_OS" == "macOS" ]]; then
        local brew_prefix
        brew_prefix=$(_toolchain_get_homebrew_prefix 2>/dev/null) || true
        if [[ -n "$brew_prefix" && -d "$brew_prefix/opt/llvm/bin" ]]; then
            candidates+=("$brew_prefix/opt/llvm/bin")
        fi
        [[ -d "/usr/local/opt/llvm/bin" ]] && candidates+=("/usr/local/opt/llvm/bin")
        [[ -d "/opt/homebrew/opt/llvm/bin" ]] && candidates+=("/opt/homebrew/opt/llvm/bin")
    else
        candidates+=(
            /usr/lib/llvm*/bin
            /usr/lib64/llvm*/bin
            /usr/local/llvm*/bin
            /opt/llvm*/bin
        )
    fi

    local best="" best_ver=-1 dir dir_no_bin ver resolved
    for dir in "${candidates[@]}"; do
        for resolved in $dir; do
            [[ -d "$resolved" ]] || continue
            dir_no_bin="${resolved%/bin}"
            ver="${dir_no_bin##*-}"
            case "$ver" in
            '' | *[!0-9]*) ver=0 ;;
            esac
            if ((ver > best_ver)); then
                best_ver=$ver
                best="$resolved"
            fi
        done
    done

    if [[ -n "$best" ]]; then
        printf "%s\n" "$best"
    fi
}

_toolchain_select_gcc_bin_dir() {
    if [[ "$TOOLCHAIN_OS" == "macOS" ]]; then
        local brew_prefix
        brew_prefix=$(_toolchain_get_homebrew_prefix 2>/dev/null) || true
        if [[ -n "$brew_prefix" && -d "$brew_prefix/opt/gcc/bin" ]]; then
            printf "%s\n" "$brew_prefix/opt/gcc/bin"
            return 0
        fi
    fi
    return 1
}

_toolchain_verify_compiler() {
    local compiler="$1"
    if command -v "$compiler" >/dev/null 2>&1; then
        local version_output
        version_output=$("$compiler" --version 2>/dev/null | head -n 1)
        if [[ -n "$version_output" ]]; then
            _toolchain_log ok "${compiler}: ${version_output}"
            return 0
        fi
    fi
    _toolchain_log warn "Compiler '${compiler}' not found or not working properly."
    return 1
}

# ------------------------- Main Toolchain Functions ------------------------- #
use_llvm() {
    _toolchain_init_colors
    _toolchain_detect_platform
    printf "%s%s[+] Activating LLVM/Clang toolchain...%s\n" "$C_BOLD" "$C_CYAN" "$C_RESET"

    _toolchain_reset_env_to_original

    local llvm_bin_dir clang_bin cxx_bin prefix_for_flags
    llvm_bin_dir=$(_toolchain_select_llvm_bin_dir) || true

    clang_bin=$(_toolchain_find_best_binary "clang" "$llvm_bin_dir") || true
    cxx_bin=$(_toolchain_find_best_binary "clang++" "$llvm_bin_dir") || true

    if [[ -z "$clang_bin" || -z "$cxx_bin" ]]; then
        _toolchain_log error "No Clang toolchain found. Install with Homebrew (macOS) or your package manager (e.g., pacman -S clang / apt install clang)."
        return 1
    fi

    local bin_dir_for_path
    bin_dir_for_path="$(dirname "$clang_bin")"
    _toolchain_set_path "$bin_dir_for_path"

    prefix_for_flags="${bin_dir_for_path%/bin}"
    if [[ "$TOOLCHAIN_OS" == "macOS" && -d "$prefix_for_flags/lib" ]]; then
        local base_ldflags base_cppflags
        [[ "$TOOLCHAIN_ORIGINAL_LDFLAGS" == "__TOOLCHAIN_UNSET__" ]] && base_ldflags="" || base_ldflags="$TOOLCHAIN_ORIGINAL_LDFLAGS"
        [[ "$TOOLCHAIN_ORIGINAL_CPPFLAGS" == "__TOOLCHAIN_UNSET__" ]] && base_cppflags="" || base_cppflags="$TOOLCHAIN_ORIGINAL_CPPFLAGS"

        export LDFLAGS="-L${prefix_for_flags}/lib${base_ldflags:+ ${base_ldflags}}"
        export CPPFLAGS="-I${prefix_for_flags}/include${base_cppflags:+ ${base_cppflags}}"
    fi

    export CC
    export CXX
    CC=$(basename "$clang_bin")
    CXX=$(basename "$cxx_bin")

    _toolchain_log info "PATH=${PATH}"
    _toolchain_log ok "CC='${CC}', CXX='${CXX}'"
    _toolchain_verify_compiler "$CC"
    _toolchain_verify_compiler "$CXX"
}

use_gnu() {
    _toolchain_init_colors
    _toolchain_detect_platform
    printf "%s%s[+] Activating GNU GCC toolchain...%s\n" "$C_BOLD" "$C_CYAN" "$C_RESET"

    _toolchain_reset_env_to_original

    local gcc_bin_dir gcc_bin gxx_bin
    gcc_bin_dir=$(_toolchain_select_gcc_bin_dir) || true

    gcc_bin=$(_toolchain_find_best_binary "gcc" "$gcc_bin_dir") || true
    gxx_bin=$(_toolchain_find_best_binary "g++" "$gcc_bin_dir") || true

    if [[ -z "$gcc_bin" || -z "$gxx_bin" ]]; then
        _toolchain_log error "GCC not found. Install via Homebrew (macOS) or your distro packages (e.g., pacman -S gcc / apt install build-essential)."
        return 1
    fi

    local bin_dir_for_path
    bin_dir_for_path="$(dirname "$gcc_bin")"
    _toolchain_set_path "$bin_dir_for_path"

    export CC
    export CXX
    CC=$(basename "$gcc_bin")
    CXX=$(basename "$gxx_bin")

    _toolchain_log info "PATH=${PATH}"
    _toolchain_log ok "CC='${CC}', CXX='${CXX}'"
    _toolchain_verify_compiler "$CC"
    _toolchain_verify_compiler "$CXX"
}

use_system() {
    _toolchain_init_colors
    printf "%s%s[*] Restoring system/default toolchain...%s\n" "$C_BOLD" "$C_YELLOW" "$C_RESET"

    if [[ -z "${TOOLCHAIN_ORIGINAL_PATH:-}" ]]; then
        _toolchain_log error "TOOLCHAIN_ORIGINAL_PATH not set. Restart the shell if restoration fails."
        return 1
    fi

    _toolchain_set_path ""
    _toolchain_reset_env_to_original

    local system_cc system_cxx
    system_cc=$(command -v cc 2>/dev/null || command -v clang 2>/dev/null || command -v gcc 2>/dev/null)
    system_cxx=$(command -v c++ 2>/dev/null || command -v clang++ 2>/dev/null || command -v g++ 2>/dev/null)

    if [[ -n "$system_cc" ]]; then
        _toolchain_log ok "System C compiler: $system_cc"
        _toolchain_verify_compiler "$system_cc"
    else
        _toolchain_log warn "No system C compiler detected in PATH."
    fi

    if [[ -n "$system_cxx" ]]; then
        _toolchain_log ok "System C++ compiler: $system_cxx"
        _toolchain_verify_compiler "$system_cxx"
    else
        _toolchain_log warn "No system C++ compiler detected in PATH."
    fi

    _toolchain_log ok "System toolchain restored."
}

# ============================================================================ #
# End of script.
