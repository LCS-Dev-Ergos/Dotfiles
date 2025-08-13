# =========================================================================== #
# ------------ Project Configuration for Competitive Programming ------------ #
# =========================================================================== #
# This CMake file is designed to be simple and robust. The complexity of
# compiler selection is handled by the `gcc-toolchain.cmake` file, which
# ensures GCC is used. This allows clangd to work correctly out-of-the-box
# by reading the GCC-generated compile commands.
# --------------------------------------------------------------------------- #
cmake_minimum_required(VERSION 3.20)
project(competitive_programming LANGUAGES CXX)

# ----------------------------- ANSI Color Codes ---------------------------- #
# Define variables for ANSI color codes to make message() output more readable.
# This works on most modern terminals (Linux, macOS, VS Code, Windows Terminal).
if(UNIX OR APPLE OR CMAKE_HOST_WIN32)
    string(ASCII 27 Esc)
    set(ANSI_COLOR_RED     "${Esc}[31m")
    set(ANSI_COLOR_GREEN   "${Esc}[32m")
    set(ANSI_COLOR_YELLOW  "${Esc}[33m")
    set(ANSI_COLOR_BLUE    "${Esc}[34m")
    set(ANSI_COLOR_CYAN    "${Esc}[36m")
    set(ANSI_COLOR_BOLD    "${Esc}[1m")
    set(ANSI_COLOR_RESET   "${Esc}[0m")
endif()

# -------------------------- Compiler Verification -------------------------- #
# This block ensures that the project is being configured with GCC, as intended
# by the toolchain file. If another compiler (like Clang) if detected, it means 
# CMake is using a stale cache. We stop the process with a helpful error 
# message, guiding the user to the correct fix.

if(NOT CMAKE_CXX_COMPILER_ID MATCHES "GNU")
    message(FATAL_ERROR "Incorrect compiler detected: ${CMAKE_CXX_COMPILER_ID}. "
            "This project requires GCC. The build cache is likely stale.\n"
            "Please run 'cppclean' or manually delete the 'build' directory, "
            "then re-run the configuration using the 'cppconf' command.")
endif()

# ------------ GCC System Include Path Auto-Detection for Clangd ------------ #
# This block is crucial for clangd integration. It finds the system include
# directories for the active GCC compiler and adds them to the compile commands.

# This function uses platform-specific logic:
# - On macOS: It uses a hardcoded, selective path-finding method based on
#   Homebrew's layout. This is proven to be more reliable for clangd as it
#   avoids including conflicting system headers.
# - On other platforms (e.g., Linux): It uses a generic method that parses
#   the compiler's verbose output to find include paths.
function(detect_gcc_system_includes OUTPUT_VARIABLE)

    # ------------------------- macOS Specific Logic ------------------------ #
    if(APPLE)
        message(STATUS "Clangd Assist: Using selective path detection for macOS.")

        # Try to get exact brew prefix first, fallback to common locations.
        execute_process(
            COMMAND brew --prefix
            OUTPUT_VARIABLE BREW_PREFIX
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
        )
        if(NOT BREW_PREFIX)
            if(IS_DIRECTORY "/opt/homebrew")
                set(BREW_PREFIX "/opt/homebrew")
            elseif(IS_DIRECTORY "/usr/local")
                set(BREW_PREFIX "/usr/local")
            endif()
        endif()

        if(NOT BREW_PREFIX)
            message(WARNING "Homebrew prefix not found; skipping GCC include auto-detection.")
            set(${OUTPUT_VARIABLE} "" PARENT_SCOPE)
            return()
        endif()

        # Get GCC full version, fall back if needed
        execute_process(
            COMMAND ${CMAKE_CXX_COMPILER} -dumpfullversion
            OUTPUT_VARIABLE GCC_FULL_VERSION
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
        )
        if(NOT GCC_FULL_VERSION)
            execute_process(
                COMMAND ${CMAKE_CXX_COMPILER} -dumpversion
                OUTPUT_VARIABLE GCC_FULL_VERSION
                OUTPUT_STRIP_TRAILING_WHITESPACE
            )
        endif()
        
        # Derive major version number (e.g. "15")
        string(REGEX MATCH "^[0-9]+" GCC_VERSION ${GCC_FULL_VERSION})
        if(NOT GCC_VERSION)
            set(GCC_VERSION ${GCC_FULL_VERSION})
        endif()

        # Machine triple (e.g. aarch64-apple-darwin23)
        execute_process(
            COMMAND ${CMAKE_CXX_COMPILER} -dumpmachine
            OUTPUT_VARIABLE GCC_MACHINE
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
        )
        
        # Candidate paths from the original working script
        set(GCC_INCLUDE_PATHS
            "${BREW_PREFIX}/opt/gcc/include/c++/${GCC_VERSION}"
            "${BREW_PREFIX}/include/c++/${GCC_VERSION}"
            "${BREW_PREFIX}/opt/gcc/include/c++/${GCC_VERSION}/${GCC_MACHINE}"
            "${BREW_PREFIX}/include/c++/${GCC_VERSION}/${GCC_MACHINE}"
            "${BREW_PREFIX}/opt/gcc/include/c++/${GCC_VERSION}/backward"
            "${BREW_PREFIX}/include/c++/${GCC_VERSION}/backward"
            "${BREW_PREFIX}/opt/gcc/lib/gcc/${GCC_VERSION}/include"
            "${BREW_PREFIX}/lib/gcc/${GCC_VERSION}/include"
            "${BREW_PREFIX}/opt/gcc/lib/gcc/${GCC_VERSION}/include-fixed"
            "${BREW_PREFIX}/lib/gcc/${GCC_VERSION}/include-fixed"
            "${BREW_PREFIX}/include/gcc-${GCC_VERSION}" 
        )

        # Keep only directories that actually exist
        set(FOUND_PATHS "")
        foreach(p IN LISTS GCC_INCLUDE_PATHS)
            if(IS_DIRECTORY "${p}")
                list(APPEND FOUND_PATHS "${p}")
            endif()
        endforeach()

        if(FOUND_PATHS)
            string(REPLACE ";" "\n   " PATHS_NL "${FOUND_PATHS}")
            message(STATUS "Clangd Assist: Found GCC include dirs:\n   ${PATHS_NL}")
            set(${OUTPUT_VARIABLE} "${FOUND_PATHS}" PARENT_SCOPE)
        else()
            message(WARNING "Could not find any GCC include dirs under ${BREW_PREFIX}")
            set(${OUTPUT_VARIABLE} "" PARENT_SCOPE)
        endif()

    # ---------------------- Generic Logic (for Linux) ---------------------- #
    else()
        message(STATUS "Clangd Assist: Using generic compiler output parsing.")
        
        execute_process(
            COMMAND ${CMAKE_CXX_COMPILER} -E -x c++ -v /dev/null
            OUTPUT_VARIABLE GCC_VERBOSE_OUTPUT
            ERROR_VARIABLE GCC_VERBOSE_OUTPUT
            RESULT_VARIABLE EXIT_CODE
        )

        if(EXIT_CODE)
            message(WARNING "Failed to get include paths from '${CMAKE_CXX_COMPILER} -v' (Exit code: ${EXIT_CODE}).")
            set(${OUTPUT_VARIABLE} "" PARENT_SCOPE)
            return()
        endif()
        
        string(REPLACE "\n" ";" OUTPUT_LINES "${GCC_VERBOSE_OUTPUT}")
        set(DETECTED_PATHS "")
        set(IS_PARSING_INCLUDES FALSE)
        
        foreach(line ${OUTPUT_LINES})
            if(line MATCHES "^#include <...> search starts here:")
                set(IS_PARSING_INCLUDES TRUE)
                continue()
            endif()
            if(line MATCHES "^End of search list.")
                break()
            endif()
            if(IS_PARSING_INCLUDES)
                string(STRIP "${line}" path)
                if(IS_DIRECTORY "${path}")
                    list(APPEND DETECTED_PATHS "${path}")
                endif()
            endif()
        endforeach()
        
        if(DETECTED_PATHS)
            list(REMOVE_DUPLICATES DETECTED_PATHS)
            set(${OUTPUT_VARIABLE} "${DETECTED_PATHS}" PARENT_SCOPE)
            string(REPLACE ";" "\n   " PATHS_NL "${DETECTED_PATHS}")
            message(STATUS "Clangd Assist: Found GCC system include paths:\n   ${PATHS_NL}")
        else()
            message(WARNING "Clangd Assist: Could not auto-detect GCC system include paths.")
            set(${OUTPUT_VARIABLE} "" PARENT_SCOPE)
        endif()
    endif()
endfunction()

# Call the function to detect the paths and store them in a variable.
detect_gcc_system_includes(GCC_SYSTEM_INCLUDE_PATHS)

# ----------------------------- Project Settings ---------------------------- #
# Set the C++ standard and export compile commands for IDEs like VS Code (clangd).
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Set output directories for executables and libraries.
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/bin)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/lib)

# Create output directories if they don't exist
file(MAKE_DIRECTORY ${CMAKE_RUNTIME_OUTPUT_DIRECTORY})
file(MAKE_DIRECTORY ${CMAKE_ARCHIVE_OUTPUT_DIRECTORY})

# =========================================================================== #
# -------------------- Helper Function to Add a Problem --------------------- #
# =========================================================================== #

# Defines a standard way to add a new problem executable with all required
# compiler flags and include paths.
# Usage: cp_add_problem(TARGET_NAME SOURCE_FILE)
function(cp_add_problem TARGET_NAME SOURCE_FILE)
    add_executable(${TARGET_NAME} ${SOURCE_FILE})

    # ----- Target-specific compiler definitions ----- #
    target_compile_definitions(${TARGET_NAME} PRIVATE
        # Define LOCAL for debug builds to enable custom debug headers.
        $<$<CONFIG:Debug,Sanitize>:LOCAL>
        # Define NDEBUG for release builds to disable asserts.
        $<$<CONFIG:Release>:NDEBUG>
    )

    # ----- Target-specific compiler options ----- #
    # Define release flags based on the compiler
    if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
        set(RELEASE_FLAGS -O2)
        # If we're on macOS ARM, force the correct target
        if(APPLE AND CMAKE_SYSTEM_PROCESSOR MATCHES "arm64")
            list(APPEND RELEASE_FLAGS -target arm64-apple-macos)
        endif()
    else()
        # GCC or other compilers, keep -march=native
        set(RELEASE_FLAGS -O2 -march=native)
    endif()

    target_compile_options(${TARGET_NAME} PRIVATE
        # Common warning flags
        -Wall -Wextra -Wpedantic -Wshadow
        
        # Suppress warnings that are often just noise in CP
        -Wno-unused-const-variable
        -Wno-sign-conversion

        # Debug flags: full debug info, no optimization
        $<$<CONFIG:Debug>:-g2 -O0>
        
        # Release flags (condizionali)
        $<$<CONFIG:Release>:${RELEASE_FLAGS}>
        
        # Sanitize flags
        $<$<CONFIG:Sanitize>:-g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer>
    )

    # ----- Target-specific include directories --------- #
    if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/algorithms)
        target_include_directories(${TARGET_NAME} PRIVATE 
            ${CMAKE_CURRENT_SOURCE_DIR}/algorithms
        )
    endif()

    # ----- START: Platform-Specific Toolchain Flags ----- #
    if(APPLE)
        target_compile_options(${TARGET_NAME} PRIVATE -stdlib=libstdc++)
        target_link_options(${TARGET_NAME} PRIVATE -stdlib=libstdc++)
    endif()

    # Add detected GCC include dirs as SYSTEM include dirs so they
    # appear in compile_commands (and clangd picks them up)
    if(GCC_SYSTEM_INCLUDE_PATHS)
        target_compile_options(${TARGET_NAME} PRIVATE -nostdinc++)
        foreach(dir IN LISTS GCC_SYSTEM_INCLUDE_PATHS)
            target_compile_options(${TARGET_NAME} PRIVATE "-isystem${dir}")
        endforeach()
    endif()

    # ----- Linker options ----- #
    target_link_options(${TARGET_NAME} PRIVATE
        # Sanitizer linking for Sanitize builds
        $<$<CONFIG:Sanitize>:-fsanitize=address,undefined>
    )

    message(STATUS "Added problem: ${TARGET_NAME}")
endfunction()

# =========================================================================== #
# -------------------- Automatic Problem Detection -------------------------- #
# =========================================================================== #

# Find all C++ source files in the current directory.
# NOTE: You must re-run CMake (e.g., via 'cppnew' or 'cppconf') when you
# add or remove source files for them to be detected.
file(GLOB PROBLEM_SOURCES LIST_DIRECTORIES false "*.cpp" "*.cc" "*.cxx")

# Loop through each found source file and create an executable target for it.
foreach(source_file ${PROBLEM_SOURCES})
    # Get the base name of the file (without extension) to use as the target name.
    get_filename_component(exec_name ${source_file} NAME_WE)
    cp_add_problem(${exec_name} ${source_file})
endforeach()

# Set a default startup project for IDEs if 'main.cpp' exists.
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/main.cpp")
    set_property(DIRECTORY PROPERTY VS_STARTUP_PROJECT main)
endif()

# =========================================================================== #
# ----------------------------- Utility Targets ----------------------------- #
# =========================================================================== #

# Custom target to create a symlink to compile_commands.json in the root directory.
# This makes it easy for clangd to find it without extra configuration.
add_custom_target(symlink_clangd
    COMMAND ${CMAKE_COMMAND} -E create_symlink 
            "${CMAKE_BINARY_DIR}/compile_commands.json"
            "${CMAKE_SOURCE_DIR}/compile_commands.json"
    COMMENT "Creating symlink in root for compile_commands.json"
    VERBATIM
)

# Automatically create the symlink after configuration
add_custom_command(TARGET symlink_clangd POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E create_symlink 
            "${CMAKE_BINARY_DIR}/compile_commands.json"
            "${CMAKE_SOURCE_DIR}/compile_commands.json"
    COMMENT "Auto-creating compile_commands.json symlink"
    VERBATIM
)

# ============================================================================ #
# --------------------------- Configuration Summary -------------------------- #
# ============================================================================ #

# Define Sanitize as a known configuration type for IDEs.
set(CMAKE_CONFIGURATION_TYPES "Debug;Release;Sanitize" CACHE STRING "Supported build types" FORCE)

message(STATUS "") # Add a blank line for spacing
message(STATUS "${ANSI_COLOR_BLUE}/===----------------- Competitive Programming Setup Summary ----------------===/${ANSI_COLOR_RESET}")
message(STATUS "|")
message(STATUS "| ${ANSI_COLOR_CYAN}Compiler${ANSI_COLOR_RESET}            : ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}")
message(STATUS "| ${ANSI_COLOR_CYAN}Compiler Path${ANSI_COLOR_RESET}       : ${CMAKE_CXX_COMPILER}")
message(STATUS "| ${ANSI_COLOR_CYAN}Build Type${ANSI_COLOR_RESET}          : ${ANSI_COLOR_YELLOW}${CMAKE_BUILD_TYPE}${ANSI_COLOR_RESET}")
message(STATUS "| ${ANSI_COLOR_CYAN}Available Types${ANSI_COLOR_RESET}     : ${CMAKE_CONFIGURATION_TYPES}")
message(STATUS "|")
# ----- Dynamic check for Clangd-related include paths ----- #
if(GCC_SYSTEM_INCLUDE_PATHS)
    list(LENGTH GCC_SYSTEM_INCLUDE_PATHS INCLUDE_COUNT)
    message(STATUS "| ${ANSI_COLOR_CYAN}Clangd Assist${ANSI_COLOR_RESET}       : ${ANSI_COLOR_GREEN}OK (${INCLUDE_COUNT} GCC include paths detected)${ANSI_COLOR_RESET}")
else()
    message(WARNING "| ${ANSI_COLOR_CYAN}Clangd Assist${ANSI_COLOR_RESET}       : ${ANSI_COLOR_RED}WARNING - No GCC include paths found. Clangd may have issues.${ANSI_COLOR_RESET}")
endif()

# ----- Dynamic check for found source files ----- #
if(PROBLEM_SOURCES)
    list(LENGTH PROBLEM_SOURCES PROBLEM_COUNT)
    message(STATUS "| ${ANSI_COLOR_CYAN}Problems Found${ANSI_COLOR_RESET}      : ${PROBLEM_COUNT} C++ source files")

    if(PROBLEM_COUNT GREATER 10)
        list(SUBLIST PROBLEM_SOURCES 0 10 SHOWN_SOURCES)
        string(REPLACE ";" "\n|   " PROBLEM_SOURCES_NL "${SHOWN_SOURCES}")
        math(EXPR REMAINING "${PROBLEM_COUNT} - 10")
        message(STATUS "|   ${PROBLEM_SOURCES_NL}")
        message(STATUS "|   ... and ${REMAINING} more.")
    else()
        string(REPLACE ";" "\n   |   " PROBLEM_SOURCES_NL "${PROBLEM_SOURCES}")
        message(STATUS "|   ${PROBLEM_SOURCES_NL}")
    endif()
else()
    message(STATUS "| ${ANSI_COLOR_CYAN}Problems Found${ANSI_COLOR_RESET}      : No C++ source files detected in this directory.")
endif()
message(STATUS "|")
message(STATUS "${ANSI_COLOR_BLUE}/===------------------------------------------------------------------------===/${ANSI_COLOR_RESET}")
