# =========================================================================== #
# ----- CMake Toolchain File to Enforce GCC for Competitive Programming ----- #
# =========================================================================== #
#
# Description:
#   This file forces CMake to use a modern GCC compiler, which is crucial
#   for competitive programming features like <bits/stdc++.h> and PBDS.
#   It ensures that both the build process and the generated compile_commands.json
#   for clangd are based on GCC, solving compiler-IDE conflicts.
#
# Usage:
#   This file is used automatically by the 'cppconf' shell function via:
#   cmake -DCMAKE_TOOLCHAIN_FILE=gcc-toolchain.cmake
#
# ============================================================================ #

message(STATUS "Using GCC Toolchain File to find and set a GCC compiler.")

# Set the CMAKE_SYSTEM_NAME to avoid CMake misconfigurations on macOS
set(CMAKE_SYSTEM_NAME Generic)

# Find the latest available GCC/G++ executable from a list of common names.
# We prioritize Homebrew's path on macOS but also check standard system paths.
find_program(GCC_EXECUTABLE
    NAMES g++-15 g++-14 g++-13 g++-12 g++
    PATHS /opt/homebrew/bin /usr/local/bin /usr/bin
    DOC "Path to the g++ executable"
)

# If no g++ is found, terminate with a helpful error message.
if(NOT GCC_EXECUTABLE)
    message(FATAL_ERROR "GCC (g++) not found! This toolchain requires GCC. "
                        "Please install it (e.g., 'brew install gcc' on macOS "
                        "or 'sudo apt install g++' on Debian/Ubuntu).")
endif()

# Find the corresponding C compiler (gcc) based on the g++ path.
get_filename_component(GCC_DIR ${GCC_EXECUTABLE} DIRECTORY)
get_filename_component(GCC_NAME ${GCC_EXECUTABLE} NAME)
string(REPLACE "g++" "gcc" C_COMPILER_NAME ${GCC_NAME})
find_program(C_COMPILER_PATH
    NAMES ${C_COMPILER_NAME}
    HINTS ${GCC_DIR}
)

# Force CMake to use the found compilers for both C and C++.
# The CACHE PATH and FORCE options ensure these settings override any defaults.
set(CMAKE_C_COMPILER   ${C_COMPILER_PATH} CACHE PATH "C compiler"   FORCE)
set(CMAKE_CXX_COMPILER ${GCC_EXECUTABLE}  CACHE PATH "C++ compiler" FORCE)

message(STATUS "Toolchain forcing CXX compiler to: ${CMAKE_CXX_COMPILER}")
message(STATUS "Toolchain forcing C compiler to:   ${CMAKE_C_COMPILER}")

# Set the build type to Debug by default if not specified by the user.
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Debug CACHE STRING "Default build type" FORCE)
endif()

# ============================================================================ #
