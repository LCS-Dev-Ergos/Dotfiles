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

# Platform detection for appropriate compiler search strategy
if(APPLE)
    set(PLATFORM_NAME "macOS")
elseif(UNIX AND NOT APPLE)
    set(PLATFORM_NAME "Linux")
else()
    set(PLATFORM_NAME "Other Unix")
endif()

message(STATUS "Detected platform: ${PLATFORM_NAME}")

# Don't set CMAKE_SYSTEM_NAME to Generic unless necessary, as it can cause issues
# with some CMake modules. Only set it if we're cross-compiling or have issues.
# set(CMAKE_SYSTEM_NAME Generic)

# Platform-specific compiler search paths and version preferences
if(APPLE)
    # macOS with Homebrew - prioritize newer versions and Homebrew paths
    set(COMPILER_SEARCH_NAMES g++-15 g++-14 g++-13 g++-12 g++-11 g++)
    set(COMPILER_SEARCH_PATHS 
        /opt/homebrew/bin           # Apple Silicon Homebrew
        /usr/local/bin              # Intel Mac Homebrew
        /opt/local/bin              # MacPorts
        /usr/bin                    # System (usually old)
    )
elseif(UNIX)
    # Linux - check both versioned and unversioned, prefer newer versions
    set(COMPILER_SEARCH_NAMES g++-15 g++-14 g++-13 g++-12 g++-11 g++-10 g++-9 g++)
    set(COMPILER_SEARCH_PATHS 
        /usr/bin
        /usr/local/bin
        /opt/gcc/bin                # Custom installations
        /snap/bin                   # Snap packages
    )
endif()

# Find the latest available GCC/G++ executable
find_program(GCC_EXECUTABLE
    NAMES ${COMPILER_SEARCH_NAMES}
    PATHS ${COMPILER_SEARCH_PATHS}
    DOC "Path to the g++ executable"
    NO_DEFAULT_PATH  # Force using our paths first
)

# Fallback to system PATH if not found in specific locations
if(NOT GCC_EXECUTABLE)
    find_program(GCC_EXECUTABLE
        NAMES ${COMPILER_SEARCH_NAMES}
        DOC "Path to the g++ executable"
    )
endif()

# If no g++ is found, terminate with a helpful platform-specific error message.
if(NOT GCC_EXECUTABLE)
    if(APPLE)
        set(INSTALL_HINT "Please install GCC via Homebrew: 'brew install gcc'")
    elseif(UNIX)
        set(INSTALL_HINT "Please install GCC via your package manager:\n"
                        "  - Debian/Ubuntu: 'sudo apt install g++'\n"
                        "  - RHEL/CentOS/Fedora: 'sudo dnf install gcc-c++' or 'sudo yum install gcc-c++'\n"
                        "  - Arch Linux: 'sudo pacman -S gcc'\n"
                        "  - openSUSE: 'sudo zypper install gcc-c++'")
    else()
        set(INSTALL_HINT "Please install GCC for your system")
    endif()
    
    message(FATAL_ERROR "GCC (g++) not found! This toolchain requires GCC.\n${INSTALL_HINT}")
endif()

# Verify the found compiler is actually GCC and get version info
execute_process(
    COMMAND ${GCC_EXECUTABLE} --version
    OUTPUT_VARIABLE GCC_VERSION_OUTPUT
    ERROR_VARIABLE GCC_VERSION_ERROR
    RESULT_VARIABLE GCC_VERSION_RESULT
    OUTPUT_STRIP_TRAILING_WHITESPACE
)

if(NOT GCC_VERSION_RESULT EQUAL 0)
    message(FATAL_ERROR "Failed to execute ${GCC_EXECUTABLE} --version. "
                        "The found executable may not be a valid GCC compiler.")
endif()

# Extract GCC version from output
string(REGEX MATCH "gcc.*([0-9]+\\.[0-9]+\\.[0-9]+)" GCC_VERSION_MATCH "${GCC_VERSION_OUTPUT}")
if(GCC_VERSION_MATCH)
    string(REGEX MATCH "([0-9]+\\.[0-9]+\\.[0-9]+)" GCC_VERSION "${GCC_VERSION_MATCH}")
    string(REGEX MATCH "^([0-9]+)" GCC_MAJOR_VERSION "${GCC_VERSION}")
else()
    # Fallback version detection
    execute_process(
        COMMAND ${GCC_EXECUTABLE} -dumpversion
        OUTPUT_VARIABLE GCC_VERSION
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    string(REGEX MATCH "^([0-9]+)" GCC_MAJOR_VERSION "${GCC_VERSION}")
endif()

# Verify GCC version meets minimum requirements for competitive programming
if(GCC_MAJOR_VERSION AND GCC_MAJOR_VERSION LESS 9)
    message(WARNING "Found GCC version ${GCC_VERSION} is quite old (< 9.0). "
                   "Some modern C++ features may not be available. "
                   "Consider upgrading to a newer GCC version.")
endif()

# Find the corresponding C compiler (gcc) based on the g++ path.
get_filename_component(GCC_DIR ${GCC_EXECUTABLE} DIRECTORY)
get_filename_component(GCC_NAME ${GCC_EXECUTABLE} NAME)
string(REPLACE "g++" "gcc" C_COMPILER_NAME ${GCC_NAME})

# First try to find gcc in the same directory as g++
find_program(C_COMPILER_PATH
    NAMES ${C_COMPILER_NAME}
    HINTS ${GCC_DIR}
    NO_DEFAULT_PATH
)

# If not found, try broader search with version-specific fallbacks
if(NOT C_COMPILER_PATH)
    # Create list of C compiler candidates based on the C++ compiler name
    string(REPLACE "g++" "gcc" BASE_C_NAME ${GCC_NAME})
    set(C_COMPILER_CANDIDATES ${BASE_C_NAME})
    
    # Add version-specific candidates
    if(GCC_MAJOR_VERSION)
        list(APPEND C_COMPILER_CANDIDATES "gcc-${GCC_MAJOR_VERSION}")
    endif()
    list(APPEND C_COMPILER_CANDIDATES "gcc")
    
    find_program(C_COMPILER_PATH
        NAMES ${C_COMPILER_CANDIDATES}
        PATHS ${COMPILER_SEARCH_PATHS}
        DOC "Path to the gcc executable"
    )
endif()

# Verify we found a matching C compiler
if(NOT C_COMPILER_PATH)
    message(WARNING "Could not find matching GCC C compiler for ${GCC_EXECUTABLE}. "
                   "Using ${GCC_EXECUTABLE} for both C and C++.")
    set(C_COMPILER_PATH ${GCC_EXECUTABLE})
endif()

# Verify the C compiler version matches (or is compatible with) the C++ compiler
if(NOT C_COMPILER_PATH STREQUAL GCC_EXECUTABLE)
    execute_process(
        COMMAND ${C_COMPILER_PATH} -dumpversion
        OUTPUT_VARIABLE C_COMPILER_VERSION
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    
    # Extract major version for comparison
    string(REGEX MATCH "^([0-9]+)" C_MAJOR_VERSION "${C_COMPILER_VERSION}")
    
    if(C_MAJOR_VERSION AND GCC_MAJOR_VERSION AND 
       NOT C_MAJOR_VERSION STREQUAL GCC_MAJOR_VERSION)
        message(WARNING "C compiler version (${C_COMPILER_VERSION}) differs from "
                       "C++ compiler version (${GCC_VERSION}). This may cause issues.")
    endif()
endif()

# Force CMake to use the found compilers for both C and C++.
# The CACHE PATH and FORCE options ensure these settings override any defaults.
set(CMAKE_C_COMPILER   ${C_COMPILER_PATH} CACHE PATH "C compiler"   FORCE)
set(CMAKE_CXX_COMPILER ${GCC_EXECUTABLE}  CACHE PATH "C++ compiler" FORCE)

# Set compiler-specific flags that may be needed for toolchain setup
set(CMAKE_C_COMPILER_ID "GNU" CACHE STRING "C compiler ID" FORCE)
set(CMAKE_CXX_COMPILER_ID "GNU" CACHE STRING "C++ compiler ID" FORCE)

# Ensure the compilers support the required standards
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

message(STATUS "Successfully configured GCC toolchain:")
message(STATUS "  C++ compiler: ${CMAKE_CXX_COMPILER}")
if(GCC_VERSION)
    message(STATUS "  GCC version:  ${GCC_VERSION}")
endif()
message(STATUS "  C compiler:   ${CMAKE_C_COMPILER}")
if(C_COMPILER_VERSION AND NOT C_COMPILER_VERSION STREQUAL GCC_VERSION)
    message(STATUS "  C version:    ${C_COMPILER_VERSION}")
endif()

# Set the build type to Debug by default if not specified by the user.
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Debug CACHE STRING "Default build type" FORCE)
    message(STATUS "  Build type:   ${CMAKE_BUILD_TYPE} (default)")
else()
    message(STATUS "  Build type:   ${CMAKE_BUILD_TYPE}")
endif()

# ============================================================================ #
# End of GCC Toolchain File