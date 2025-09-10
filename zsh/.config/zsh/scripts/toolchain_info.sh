#!/bin/bash

# ============================================================================ #
# Function to identify the active C/C++ toolchain on the system.
# It analyzes gcc, g++, clang, and clang++ commands to determine their
# origin (Apple, GNU, LLVM) and version. It also detects common wrappers
# like ccache and name masquerading (e.g., gcc being clang).
#
# Usage:
#   get_toolchain_info
# ============================================================================ #

get_toolchain_info() {
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

    echo "/===--------------------------------------------------------------===/"
    echo -e "${C_BOLD}${C_CYAN}Analyzing C/C++ toolchain configuration...${C_RESET}"

    # Check for CC and CXX environment variables.
    if [[ -n "${CC:-}" || -n "${CXX:-}" ]]; then
        echo -e "${C_YELLOW}Environment variables (override defaults):${C_RESET}"
        [[ -n "${CC:-}" ]] && echo -e "   ${C_BOLD}CC  = ${C_CYAN}${CC}${C_RESET}"
        [[ -n "${CXX:-}" ]] && echo -e "   ${C_BOLD}CXX = ${C_CYAN}${CXX}${C_RESET}"
        echo
    fi

    # Function to resolve the real compiler behind wrappers.
    resolve_real_compiler() {
        local compiler_path="$1"
        local real_path="$compiler_path"

        # Follow symlinks.
        if [[ -L "$compiler_path" ]]; then
            real_path=$(readlink -f "$compiler_path" 2>/dev/null || readlink "$compiler_path")
        fi

        # Check if it's a ccache wrapper.
        if [[ "$compiler_path" == *"/ccache/"* ]]; then
            # Try to find the real compiler ccache would use.
            local compiler_name
            compiler_name=$(basename "$compiler_path")

            # Look for the real compiler in common locations.
            local search_paths=(
                "/usr/bin"
                "/usr/local/bin"
                "/opt/homebrew/bin"
                "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
            )

            for path in "${search_paths[@]}"; do
                if [[ -x "$path/$compiler_name" && "$path/$compiler_name" != "$compiler_path" ]]; then
                    real_path="$path/$compiler_name"
                    break
                fi
            done
        fi

        echo "$real_path"
    }

    # Function to get detailed compiler info.
    get_compiler_details() {
        local compiler_path="$1"
        local version_info
        local toolchain_type="Unknown"
        local vendor=""

        if ! version_info=$(timeout 5 "$compiler_path" --version 2>/dev/null | head -n 1); then
            version_info="Version information unavailable"
            echo "$toolchain_type|$vendor|$version_info"
            return
        fi

        # Sanitize version_info.
        version_info="${version_info//[^[:print:]]/ }"

        # Determine toolchain type and vendor.
        if [[ "$version_info" == *"Apple clang"* ]]; then
            toolchain_type="Clang"
            vendor="Apple"
        elif [[ "$version_info" == *"Homebrew clang"* ]]; then
            toolchain_type="Clang"
            vendor="Homebrew LLVM"
        elif [[ "$version_info" == *"clang version"* ]]; then
            toolchain_type="Clang"
            vendor="LLVM"
        elif [[ "$version_info" == *"(GCC)"* || "$version_info" == *"gcc version"* ]]; then
            toolchain_type="GCC"
            if [[ "$version_info" == *"Homebrew"* ]]; then
                vendor="Homebrew GNU"
            else
                vendor="GNU"
            fi
        fi

        echo "$toolchain_type|$vendor|$version_info"
    }

    # Array of compilers to check.
    local -a compilers=("gcc" "g++" "clang" "clang++")

    echo -e "${C_BOLD}Active compilers in PATH:${C_RESET}"
    echo

    # Iterate over each compiler.
    for compiler in "${compilers[@]}"; do
        local compiler_path
        compiler_path=$(command -v "$compiler" 2>/dev/null)

        if [[ -n "$compiler_path" && -x "$compiler_path" ]]; then
            # Resolve real compiler.
            local real_compiler_path
            real_compiler_path=$(resolve_real_compiler "$compiler_path")

            # Get details for both wrapper and real compiler.
            local wrapper_details real_details
            wrapper_details=$(get_compiler_details "$compiler_path")
            real_details=$(get_compiler_details "$real_compiler_path")

            IFS='|' read -r wrapper_type wrapper_vendor wrapper_version <<<"$wrapper_details"
            IFS='|' read -r real_type real_vendor real_version <<<"$real_details"

            # Print compiler name and path.
            printf "${C_GREEN}◆ %-10s${C_RESET} ${C_CYAN}%s${C_RESET}\n" "$compiler" "$compiler_path"

            # Detect and show wrapper.
            local has_wrapper=false
            if [[ "$compiler_path" == *"/ccache/"* ]]; then
                printf "  ├─ ${C_YELLOW}Wrapper:${C_RESET} ccache (caching)\n"
                has_wrapper=true
            elif [[ "$compiler_path" != "$real_compiler_path" ]]; then
                printf "  ├─ ${C_YELLOW}Symlink:${C_RESET} → ${C_CYAN}%s${C_RESET}\n" "$real_compiler_path"
                has_wrapper=true
            fi

            # Show real compiler details.
            if [[ "$has_wrapper" == true ]]; then
                printf "  └─ ${C_BLUE}Real compiler:${C_RESET} %s %s\n" "$real_vendor" "$real_type"
                printf "     ${C_MAGENTA}Version:${C_RESET} %s\n" "$real_version"
            else
                printf "  ├─ ${C_BLUE}Type:${C_RESET} %s %s\n" "$real_vendor" "$real_type"
                printf "  └─ ${C_MAGENTA}Version:${C_RESET} %s\n" "$real_version"
            fi

            # Check for name masquerading.
            if [[ ("$compiler" == "gcc" || "$compiler" == "g++") && "$real_type" == "Clang" ]]; then
                printf "     ${C_YELLOW}⚠ Warning: '$compiler' is actually Clang, not GCC${C_RESET}\n"
            elif [[ ("$compiler" == "clang" || "$compiler" == "clang++") && "$real_type" == "GCC" ]]; then
                printf "     ${C_YELLOW}⚠ Warning: '$compiler' is actually GCC, not Clang${C_RESET}\n"
            fi

            # Debug information (formatted for consistency).
            printf "     ${C_BOLD}Debug:${C_RESET} compiler_path=${C_CYAN}%s${C_RESET}\n" "$compiler_path"
            printf "            real_compiler_path=${C_CYAN}%s${C_RESET}\n" "$real_compiler_path"
            printf "            wrapper_details='${C_BLUE}%s${C_RESET}|${C_YELLOW}%s${C_RESET}|${C_MAGENTA}%s${C_RESET}'\n" "$wrapper_type" "$wrapper_vendor" "$wrapper_version"
            printf "            real_details='${C_BLUE}%s${C_RESET}|${C_YELLOW}%s${C_RESET}|${C_MAGENTA}%s${C_RESET}'\n" "$real_type" "$real_vendor" "$real_version"

            echo
        else
            printf "${C_RED}✗ %-10s${C_RESET} Not found in PATH\n\n" "$compiler"
        fi
    done

    echo "/===--------------------------------------------------------------===/"
}

# ============================================================================ #
# End of script.
