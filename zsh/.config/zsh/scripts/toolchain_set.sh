#!/bin/bash

# ============================================================================ #
# Functions to dynamically switch the C/C++ toolchain for the current
# terminal session.
#
# Usage:
#   use_llvm    # Activate the LLVM toolchain installed via Homebrew
#   use_gnu     # Activate the GNU GCC toolchain installed via Homebrew
#   use_system  # Restore the default system toolchain (e.g., Apple Clang)
#
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

# Save the original PATH on shell startup if not already saved.
# This allows us to reliably restore the initial state.
if [[ -z "${ORIGINAL_PATH}" ]]; then
    export ORIGINAL_PATH="${PATH}"
fi

# ----------------------------- Helper Functions ----------------------------- #

# Validate and get Homebrew prefix.
_get_homebrew_prefix() {
    local prefix
    if command -v brew &>/dev/null; then
        prefix=$(brew --prefix 2>/dev/null)
        if [[ $? -eq 0 && -d "${prefix}" ]]; then
            echo "${prefix}"
            return 0
        fi
    fi

    # Fallback detection based on architecture.
    case "$(uname -m)" in
    arm64) prefix="/opt/homebrew" ;;
    x86_64) prefix="/usr/local" ;;
    *) prefix="/opt/homebrew" ;;
    esac

    if [[ -d "${prefix}" ]]; then
        echo "${prefix}"
        return 0
    fi

    return 1
}

# Validate directory existence and permissions.
_validate_toolchain_dir() {
    local dir="$1"
    local name="$2"

    if [[ ! -d "${dir}" ]]; then
        echo -e "${C_BOLD}${C_RED}[ERROR] ${name} directory not found at '${dir}'.${C_RESET}" >&2
        echo -e "${C_YELLOW}[HINT] Install ${name} with: brew install ${name,,}${C_RESET}" >&2
        return 1
    fi

    if [[ ! -r "${dir}" ]]; then
        echo -e "${C_BOLD}${C_RED}[ERROR] No read permission for ${name} directory '${dir}'.${C_RESET}" >&2
        return 1
    fi

    return 0
}

# Clean PATH by removing previous toolchain entries.
_clean_path() {
    local homebrew_prefix="$1"
    local cleaned_path="${ORIGINAL_PATH}"

    # Remove known toolchain paths.
    cleaned_path=$(echo "${cleaned_path}" | sed -E "s|${homebrew_prefix}/opt/[^:]*bin:||g")

    echo "${cleaned_path}"
}

# Verify compiler installation.
_verify_compiler() {
    local compiler="$1"
    local version_flag="${2:---version}"

    if command -v "${compiler}" &>/dev/null; then
        local version_output
        version_output=$("${compiler}" "${version_flag}" 2>/dev/null | head -n 1)
        if [[ $? -eq 0 && -n "${version_output}" ]]; then
            echo -e "${C_GREEN}[INFO] ${compiler}: ${version_output}${C_RESET}"
            return 0
        fi
    fi

    echo -e "${C_YELLOW}[WARN] Compiler '${compiler}' not found or not working properly.${C_RESET}" >&2
    return 1
}

# ------------------------- Main Toolchain Functions ------------------------- #

# Function to activate the LLVM toolchain.
use_llvm() {
    echo -e "${C_BOLD}${C_CYAN}[+] Activating LLVM toolchain...${C_RESET}"

    local homebrew_prefix
    homebrew_prefix=$(_get_homebrew_prefix)
    if [[ $? -ne 0 ]]; then
        echo -e "${C_BOLD}${C_RED}[ERROR] Cannot determine Homebrew prefix.${C_RESET}" >&2
        return 1
    fi

    local llvm_prefix="${homebrew_prefix}/opt/llvm"

    # Validate LLVM installation.
    if ! _validate_toolchain_dir "${llvm_prefix}" "LLVM"; then
        return 1
    fi

    # Check if LLVM bin directory exists and is executable.
    if [[ ! -d "${llvm_prefix}/bin" ]] || [[ ! -x "${llvm_prefix}/bin" ]]; then
        echo -e "${C_BOLD}${C_RED}[ERROR] LLVM bin directory not accessible.${C_RESET}" >&2
        return 1
    fi

    # Clean and set PATH.
    local clean_path
    clean_path=$(_clean_path "${homebrew_prefix}")
    export PATH="${llvm_prefix}/bin:${clean_path}"

    # Export compiler and linker flags as recommended by Homebrew.
    export LDFLAGS="-L${llvm_prefix}/lib ${LDFLAGS:-}"
    export CPPFLAGS="-I${llvm_prefix}/include ${CPPFLAGS:-}"

    # Set default compilers.
    export CC="clang"
    export CXX="clang++"

    # Verify installation
    if _verify_compiler "clang" && _verify_compiler "clang++"; then
        echo -e "${C_GREEN}[OK] LLVM toolchain is now active.${C_RESET}"
        echo -e "${C_CYAN}[INFO] Use 'get_toolchain_info' to verify the setup.${C_RESET}"
    else
        echo -e "${C_YELLOW}[WARN] LLVM toolchain activated but compilers may not be working properly.${C_RESET}"
    fi
}

# Function to activate the GNU GCC toolchain.
use_gnu() {
    echo -e "${C_BOLD}${C_CYAN}[+] Activating GNU GCC toolchain...${C_RESET}"

    local homebrew_prefix
    homebrew_prefix=$(_get_homebrew_prefix)
    if [[ $? -ne 0 ]]; then
        echo -e "${C_BOLD}${C_RED}[ERROR] Cannot determine Homebrew prefix.${C_RESET}" >&2
        return 1
    fi

    local gcc_prefix="${homebrew_prefix}/opt/gcc"

    # Validate GCC installation.
    if ! _validate_toolchain_dir "${gcc_prefix}" "GCC"; then
        return 1
    fi

    # Clean and set PATH.
    local clean_path
    clean_path=$(_clean_path "${homebrew_prefix}")
    export PATH="${gcc_prefix}/bin:${clean_path}"

    # Clear potentially conflicting flags from other toolchains.
    unset LDFLAGS CPPFLAGS

    # Find the versioned GCC executables with better error handling.
    local gcc_executable gxx_executable
    gcc_executable=$(find "${gcc_prefix}/bin" -name "gcc-[0-9]*" -type f -executable | sort -V | tail -n 1)
    gxx_executable=$(find "${gcc_prefix}/bin" -name "g++-[0-9]*" -type f -executable | sort -V | tail -n 1)

    if [[ -n "${gcc_executable}" && -n "${gxx_executable}" ]]; then
        export CC=$(basename "${gcc_executable}")
        export CXX=$(basename "${gxx_executable}")

        # Verify installation.
        if _verify_compiler "${CC}" && _verify_compiler "${CXX}"; then
            echo -e "${C_GREEN}[OK] GNU GCC toolchain is now active.${C_RESET}"
            echo -e "${C_CYAN}[INFO] CC='${C_BOLD}${CC}${C_RESET}${C_CYAN}', CXX='${C_BOLD}${CXX}${C_RESET}${C_CYAN}'${C_RESET}"
        else
            echo -e "${C_YELLOW}[WARN] GCC toolchain activated but compilers may not be working properly.${C_RESET}"
        fi
    else
        echo -e "${C_BOLD}${C_RED}[ERROR] Versioned GCC compilers not found in ${gcc_prefix}/bin.${C_RESET}" >&2
        echo -e "${C_YELLOW}[HINT] Ensure GCC is properly installed via Homebrew.${C_RESET}" >&2
        return 1
    fi
}

# Function to restore the system's default toolchain.
use_system() {
    echo -e "${C_BOLD}${C_YELLOW}[*] Restoring system default toolchain...${C_RESET}"

    # Validate that ORIGINAL_PATH is set.
    if [[ -z "${ORIGINAL_PATH}" ]]; then
        echo -e "${C_BOLD}${C_RED}[ERROR] ORIGINAL_PATH not set. Cannot restore system PATH.${C_RESET}" >&2
        echo -e "${C_YELLOW}[HINT] Restart your shell to reinitialize the toolchain system.${C_RESET}" >&2
        return 1
    fi

    # Restore the original PATH.
    export PATH="${ORIGINAL_PATH}"

    # Unset all custom environment variables.
    unset LDFLAGS CPPFLAGS CC CXX

    # Verify system compilers.
    echo -e "${C_CYAN}[INFO] Verifying system compilers...${C_RESET}"
    local system_cc system_cxx
    system_cc=$(command -v cc || command -v clang || command -v gcc)
    system_cxx=$(command -v c++ || command -v clang++ || command -v g++)

    if [[ -n "${system_cc}" ]] && _verify_compiler "${system_cc}"; then
        echo -e "${C_GREEN}[OK] System C compiler: ${system_cc}${C_RESET}"
    fi

    if [[ -n "${system_cxx}" ]] && _verify_compiler "${system_cxx}"; then
        echo -e "${C_GREEN}[OK] System C++ compiler: ${system_cxx}${C_RESET}"
    fi

    echo -e "${C_GREEN}[OK] System toolchain restored.${C_RESET}"
}

# ============================================================================ #
# End of script.
