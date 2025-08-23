# =========================================================================== #
# --------------------- CMake Toolchain File for Clang ---------------------- #
# =========================================================================== #
#
# Description:
#   This file configures CMake to use Clang for sanitizer builds, particularly
#   useful on macOS where GCC lacks sanitizer runtime libraries.
#   It ensures proper sanitizer support and uses PCH.h instead of bits/stdc++.h.
#
# Usage:
#   Used automatically by 'cppconf Sanitize clang' via:
#   cmake -DCMAKE_TOOLCHAIN_FILE=clang-toolchain.cmake -DCMAKE_BUILD_TYPE=Sanitize
#
# ============================================================================ #

# Prevent duplicate execution of this toolchain file
if(DEFINED _CLANG_TOOLCHAIN_LOADED)
    return()
endif()
set(_CLANG_TOOLCHAIN_LOADED TRUE)

message(STATUS "Using Clang Toolchain File for Sanitizer builds")

# Platform detection
if(APPLE)
    set(PLATFORM_NAME "macOS")
elseif(CMAKE_SYSTEM_NAME MATCHES "Linux")
    set(PLATFORM_NAME "Linux")
else()
    set(PLATFORM_NAME "Unix")
endif()

message(STATUS "Detected platform: ${PLATFORM_NAME}")

# Check for cached Clang path
if(DEFINED CACHE{CACHED_CLANG_EXECUTABLE} AND EXISTS "${CACHED_CLANG_EXECUTABLE}")
    set(CLANG_EXECUTABLE "${CACHED_CLANG_EXECUTABLE}")
    message(STATUS "Using cached Clang compiler: ${CLANG_EXECUTABLE}")
else()
    # Search for Clang compiler
    if(APPLE)
        # On macOS, prefer LLVM clang (has best sanitizer support)
        set(COMPILER_SEARCH_NAMES 
            clang++                    # LLVM clang (preferred)
            clang++-20 clang++-19 clang++-18 clang++-17 clang++-16
        )
        set(COMPILER_SEARCH_PATHS 
            /opt/homebrew/opt/llvm/bin  # Homebrew LLVM
            /usr/local/opt/llvm/bin     # Homebrew LLVM (Intel)
            /opt/local/bin              # MacPorts
            /usr/bin                    # System (AppleClang)
        )
    else()
        # Linux
        set(COMPILER_SEARCH_NAMES 
            clang++-20 clang++-19 clang++-18 clang++-17 clang++-16 clang++-15 clang++
        )
        set(COMPILER_SEARCH_PATHS 
            /usr/bin
            /usr/local/bin
            /opt/llvm/bin
            $ENV{HOME}/.local/bin
        )
    endif()

    # Find Clang executable
    find_program(CLANG_EXECUTABLE
        NAMES ${COMPILER_SEARCH_NAMES}
        PATHS ${COMPILER_SEARCH_PATHS}
        DOC "Path to the clang++ executable"
        NO_DEFAULT_PATH
    )

    # Fallback to system PATH
    if(NOT CLANG_EXECUTABLE)
        find_program(CLANG_EXECUTABLE
            NAMES ${COMPILER_SEARCH_NAMES}
            DOC "Path to the clang++ executable"
        )
    endif()

    # Cache the result
    if(CLANG_EXECUTABLE)
        set(CACHED_CLANG_EXECUTABLE "${CLANG_EXECUTABLE}" CACHE INTERNAL "Cached Clang executable path")
    endif()
endif()

# Error if Clang not found
if(NOT CLANG_EXECUTABLE)
    message(FATAL_ERROR 
        "\n"
        "//===----------------------------------------------------------------------===//\n"
        "                          CLANG COMPILER NOT FOUND!                             \n"
        "//===----------------------------------------------------------------------===//\n"
        "\n"
        "Clang is required for sanitizer builds on this platform.\n"
        "\n"
        "Installation instructions:\n")
    
    if(APPLE)
        message(FATAL_ERROR
            "  macOS:\n"
            "    Xcode Command Line Tools: xcode-select --install\n"
            "    Homebrew LLVM: brew install llvm\n"
            "\n"
            "After installation, re-run 'cppconf Sanitize clang'.\n"
            "//===----------------------------------------------------------------------===//\n")
    else()
        message(FATAL_ERROR
            "  Linux:\n"
            "    Debian/Ubuntu: sudo apt install clang\n"
            "    Fedora/RHEL: sudo dnf install clang\n"
            "    Arch: sudo pacman -S clang\n"
            "\n"
            "After installation, re-run 'cppconf Sanitize clang'.\n"
            "//===----------------------------------------------------------------------===//\n")
    endif()
endif()

# Verify it's actually Clang
execute_process(
    COMMAND ${CLANG_EXECUTABLE} --version
    OUTPUT_VARIABLE CLANG_VERSION_OUTPUT
    ERROR_VARIABLE CLANG_VERSION_ERROR
    RESULT_VARIABLE CLANG_VERSION_RESULT
    OUTPUT_STRIP_TRAILING_WHITESPACE
    TIMEOUT 5
)

if(NOT CLANG_VERSION_RESULT EQUAL 0)
    message(FATAL_ERROR 
        "Failed to execute ${CLANG_EXECUTABLE} --version.\n"
        "Error: ${CLANG_VERSION_ERROR}")
endif()

# Extract version information
if(CLANG_VERSION_OUTPUT MATCHES "Apple clang version ([0-9]+\\.[0-9]+)")
    set(CLANG_VERSION "${CMAKE_MATCH_1}")
    set(IS_APPLE_CLANG TRUE)
    message(STATUS "Detected Apple Clang version: ${CLANG_VERSION}")
elseif(CLANG_VERSION_OUTPUT MATCHES "clang version ([0-9]+\\.[0-9]+)")
    set(CLANG_VERSION "${CMAKE_MATCH_1}")
    set(IS_APPLE_CLANG FALSE)
    message(STATUS "Detected LLVM Clang version: ${CLANG_VERSION}")
else()
    message(WARNING "Could not determine Clang version")
    set(CLANG_VERSION "unknown")
endif()

# Find corresponding C compiler
get_filename_component(CLANG_DIR ${CLANG_EXECUTABLE} DIRECTORY)
get_filename_component(CLANG_NAME ${CLANG_EXECUTABLE} NAME)

# Create C compiler name
string(REPLACE "clang++" "clang" C_COMPILER_NAME ${CLANG_NAME})
string(REPLACE "++" "" CPP_COMPILER_NAME ${CLANG_NAME})

find_program(C_COMPILER_PATH
    NAMES ${C_COMPILER_NAME} ${CPP_COMPILER_NAME}
    HINTS ${CLANG_DIR}
    NO_DEFAULT_PATH
)

if(NOT C_COMPILER_PATH)
    # Try broader search
    find_program(C_COMPILER_PATH
        NAMES clang++-20 clang++-19 clang++-18 clang++-17 clang++-16 clang
        PATHS ${COMPILER_SEARCH_PATHS}
    )
endif()

if(NOT C_COMPILER_PATH)
    message(WARNING "Could not find matching Clang C compiler. Using clang++ for both C and C++.")
    set(C_COMPILER_PATH ${CLANG_EXECUTABLE})
endif()

# Set the compilers
set(CMAKE_C_COMPILER   ${C_COMPILER_PATH} CACHE PATH "C compiler"   FORCE)
set(CMAKE_CXX_COMPILER ${CLANG_EXECUTABLE} CACHE PATH "C++ compiler" FORCE)

# Set compiler IDs
set(CMAKE_C_COMPILER_ID "Clang" CACHE STRING "C compiler ID" FORCE)
set(CMAKE_CXX_COMPILER_ID "Clang" CACHE STRING "C++ compiler ID" FORCE)

# Ensure standard support
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Set C++23 standard
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++23" CACHE STRING "" FORCE)

# Set default build type to Sanitize
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Sanitize CACHE STRING "Default build type for sanitizers" FORCE)
endif()

# Success message
message(STATUS "")
message(STATUS "//===----------------------------------------------------------------------===//")
message(STATUS "                   Clang Toolchain Successfully Configured                      ")
message(STATUS "//===----------------------------------------------------------------------===//")
message(STATUS "  C++ compiler : ${CMAKE_CXX_COMPILER}")
message(STATUS "  Clang version: ${CLANG_VERSION}")
if(IS_APPLE_CLANG)
    message(STATUS "  Type         : Apple Clang (Xcode)")
else()
    message(STATUS "  Type         : LLVM Clang")
endif()
message(STATUS "  C compiler   : ${CMAKE_C_COMPILER}")
message(STATUS "  Build type   : ${CMAKE_BUILD_TYPE}")
message(STATUS "")
message(STATUS "  Note: Using PCH.h instead of bits/stdc++.h for sanitizer builds")
message(STATUS "//===----------------------------------------------------------------------===//")
message(STATUS "")

# ============================================================================ #
# End of Clang Toolchain File