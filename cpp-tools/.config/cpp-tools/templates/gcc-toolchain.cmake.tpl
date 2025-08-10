# ---------------------------------------------------------------------- #
# File: gcc-toolchain.cmake
#
# Description:
#   CMake toolchain file to force the use of a modern GCC compiler.
#   This is the standard way to ensure headers like <bits/stdc++.h>
#   and PBDS are found and used correctly by CMake.
#
# Usage:
#   cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=../gcc-toolchain.cmake
# ---------------------------------------------------------------------- #

message(STATUS "Using GCC Toolchain File")

# Find the latest available GCC executable
find_program(GCC_EXECUTABLE 
    NAMES g++-15 g++-14 g++-13 g++-12 g++
    PATHS /opt/homebrew/bin /usr/local/bin
    NO_DEFAULT_PATH
    DOC "Path to the g++ executable"
)

# If not found in priority paths, search in default locations
if(NOT GCC_EXECUTABLE)
    message(STATUS "GCC not found in Homebrew path, checking default system paths...")
    find_program(GCC_EXECUTABLE 
        NAMES g++-14 g++-13 g++-12 g++-11 g++
    )
endif()

# If still not found, raise an error
if(NOT GCC_EXECUTABLE)
    message(FATAL_ERROR "GCC not found! This toolchain requires GCC. \
            Install with 'brew install gcc' or 'sudo apt install g++'.")
endif()

# Set the C and C++ compilers
set(CMAKE_C_COMPILER   ${GCC_EXECUTABLE} CACHE PATH "C compiler"   FORCE)
set(CMAKE_CXX_COMPILER ${GCC_EXECUTABLE} CACHE PATH "C++ compiler" FORCE)

message(STATUS "Forcing compiler to: ${GCC_EXECUTABLE}")

# Set the build type to Debug by default if not specified
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Debug)
endif()