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

# -------------------------- Compiler Verification -------------------------- #
# This block ensures that the project is being configured with GCC, as
# intended by the toolchain file. If another compiler (like Clang) is
# detected, it means CMake is using a stale cache. We stop the process with
# a helpful error message, guiding the user to the correct fix.
if(NOT CMAKE_CXX_COMPILER_ID MATCHES "GNU")
    message(FATAL_ERROR "Incorrect compiler detected: ${CMAKE_CXX_COMPILER_ID}. "
            "This project requires GCC. The build cache is likely stale.\n"
            "Please run 'cppclean' or manually delete the 'build' directory, "
            "then re-run the configuration using the 'cppconf' command.")
endif()

# ------------ GCC System Include Path Auto-Detection for Clangd ------------ #
# This block is crucial for clangd integration. It finds the system include
# directories for the active GCC compiler and adds them to the compile commands.
# This allows clangd to find headers like <bits/stdc++.h> and the standard library.

# We use the CXX compiler path determined by the toolchain file.
set(GCC_EXECUTABLE ${CMAKE_CXX_COMPILER})

# On macOS, we can reliably find paths using Homebrew's layout.
if(APPLE AND EXISTS "/opt/homebrew/bin/brew")
    message(STATUS "macOS Homebrew detected. Finding GCC system includes...")

    # Get GCC version (e.g., "13.2.0")
    execute_process(
        COMMAND ${GCC_EXECUTABLE} -dumpversion
        OUTPUT_VARIABLE GCC_VERSION
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    # Get machine architecture (e.g., "aarch64-apple-darwin23")
    execute_process(
        COMMAND ${GCC_EXECUTABLE} -dumpmachine
        OUTPUT_VARIABLE GCC_MACHINE
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )

    set(BREW_PREFIX "/opt/homebrew")
    
    # Construct the standard paths where Homebrew installs GCC headers.
    set(GCC_INCLUDE_PATHS
        "${BREW_PREFIX}/include/c++/${GCC_VERSION}"
        "${BREW_PREFIX}/include/c++/${GCC_VERSION}/${GCC_MACHINE}"
        "${BREW_PREFIX}/include/c++/${GCC_VERSION}/backward"
        "${BREW_PREFIX}/lib/gcc/${GCC_VERSION}/include"
        "${BREW_PREFIX}/lib/gcc/${GCC_VERSION}/include-fixed"
    )

    # Convert the list of paths to "-isystem" flags for the compiler.
    set(GCC_ISYSTEM_FLAGS "")
    foreach(path IN LISTS GCC_INCLUDE_PATHS)
        if(IS_DIRECTORY "${path}")
            list(APPEND GCC_ISYSTEM_FLAGS "-isystem" "${path}")
        endif()
    endforeach()

    if(GCC_ISYSTEM_FLAGS)
        message(STATUS "Found GCC include flags for clangd: ${GCC_ISYSTEM_FLAGS}")
    else()
        message(WARNING "Could not find GCC system paths in Homebrew layout.")
    endif()
else()
    message(STATUS "Non-Homebrew system. Relying on compiler's default include paths.")
endif()

# ----------------------------- Project Settings ---------------------------- #
# Set the C++ standard and export compile commands for IDEs like VS Code (clangd).
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Set output directories for executables and libraries.
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/bin)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/lib)

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
    target_compile_options(${TARGET_NAME} PRIVATE
        # Common warning flags for catching potential errors.
        -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wsign-conversion
        
        # Debug flags: full debug info, no optimization.
        $<$<CONFIG:Debug>:-g2 -O0>
        
        # Release flags: optimized for speed, using native CPU instructions.
        $<$<CONFIG:Release>:-O2 -march=native>
        
        # Sanitize flags: enable Address and Undefined Behavior sanitizers.
        $<$<CONFIG:Sanitize>:-g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer>
    )

    # ----- Target-specific include directories ----- #
    # Add the shared 'algorithms' directory if it exists.
    if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/algorithms)
        target_include_directories(${TARGET_NAME} PRIVATE 
            ${CMAKE_CURRENT_SOURCE_DIR}/algorithms
        )
    endif()

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
)

# ============================================================================ #
# --------------------------- Configuration Summary -------------------------- #
# ============================================================================ #

# Define Sanitize as a known configuration type for IDEs.
set(CMAKE_CONFIGURATION_TYPES "Debug;Release;Sanitize" CACHE STRING "Supported build types" FORCE)

# Print a summary
message(STATUS "/===--------- Competitive Programming Setup Summary ---------===/")
message(STATUS "Configured with compiler: ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}")
message(STATUS "Build Type: ${CMAKE_BUILD_TYPE}")
message(STATUS "Default build type: ${CMAKE_BUILD_TYPE}")
message(STATUS "Available build types: ${CMAKE_CONFIGURATION_TYPES}")
message(STATUS "Found Problems: ${PROBLEM_SOURCES}")
message(STATUS "/===---------------------------------------------------------===/")