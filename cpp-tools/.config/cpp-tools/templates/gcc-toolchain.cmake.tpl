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
# Features:
#   - Intelligent GCC version detection and validation
#   - Cross-platform support (macOS, Linux, BSD)
#   - Automatic fallback to best available GCC version
#   - Comprehensive error messages with installation instructions
#   - Caching for faster reconfiguration
#
# =========================================================================== #

# Prevent duplicate execution of this toolchain file
if(DEFINED _GCC_TOOLCHAIN_LOADED)
    return()
endif()
set(_GCC_TOOLCHAIN_LOADED TRUE)

message(STATUS "Using GCC Toolchain File to find and set a GCC compiler.")

# Check if we have a cached GCC path from a previous run
if(DEFINED CACHE{CACHED_GCC_EXECUTABLE} AND EXISTS "${CACHED_GCC_EXECUTABLE}")
    set(GCC_EXECUTABLE "${CACHED_GCC_EXECUTABLE}")
    message(STATUS "Using cached GCC compiler: ${GCC_EXECUTABLE}")
else()
    # Platform detection for appropriate compiler search strategy
    if(APPLE)
        set(PLATFORM_NAME "macOS")
    elseif(CMAKE_SYSTEM_NAME MATCHES "Linux")
        set(PLATFORM_NAME "Linux")
    elseif(CMAKE_SYSTEM_NAME MATCHES "BSD")
        set(PLATFORM_NAME "BSD")
    else()
        set(PLATFORM_NAME "Unix")
    endif()

    message(STATUS "Detected platform: ${PLATFORM_NAME}")

    # Platform-specific compiler search paths and version preferences
    # Prefer newer versions for better C++23 support and optimizations
    if(APPLE)
        # macOS with Homebrew - prioritize newer versions and Homebrew paths
        set(COMPILER_SEARCH_NAMES 
            g++-15 g++-14 g++-13 g++-12 g++-11 g++-10 g++
        )
        set(COMPILER_SEARCH_PATHS 
            /opt/homebrew/bin           # Apple Silicon Homebrew
            /usr/local/bin              # Intel Mac Homebrew
            /opt/local/bin              # MacPorts
            /sw/bin                     # Fink
            /usr/bin                    # System (usually old/clang)
        )
    elseif(CMAKE_SYSTEM_NAME MATCHES "Linux")
        # Linux - check both versioned and unversioned, prefer newer versions
        set(COMPILER_SEARCH_NAMES 
            g++-15 g++-14 g++-13 g++-12 g++-11 g++-10 g++-9 g++
        )
        
        # Detect Linux distribution for better path handling
        if(EXISTS "/etc/os-release")
            file(READ "/etc/os-release" OS_RELEASE)
            if(OS_RELEASE MATCHES "ID=ubuntu" OR OS_RELEASE MATCHES "ID=debian")
                set(DISTRO "Debian-based")
            elseif(OS_RELEASE MATCHES "ID=fedora" OR OS_RELEASE MATCHES "ID=rhel" OR OS_RELEASE MATCHES "ID=centos")
                set(DISTRO "RedHat-based")
            elseif(OS_RELEASE MATCHES "ID=arch" OR OS_RELEASE MATCHES "ID=manjaro")
                set(DISTRO "Arch-based")
            else()
                set(DISTRO "Generic Linux")
            endif()
        else()
            set(DISTRO "Unknown Linux")
        endif()
        
        set(COMPILER_SEARCH_PATHS 
            /usr/bin
            /usr/local/bin
            /opt/gcc/bin                # Custom installations
            /opt/rh/devtoolset-*/root/usr/bin  # Red Hat Developer Toolset
            /snap/bin                   # Snap packages
            $ENV{HOME}/.local/bin       # User installations
        )
    else()
        # BSD and other Unix systems
        set(COMPILER_SEARCH_NAMES 
            g++15 g++14 g++13 g++12 g++11 g++10 g++9 g++
        )
        set(COMPILER_SEARCH_PATHS 
            /usr/local/bin
            /usr/bin
            /opt/local/bin
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

    # Cache the found compiler for future runs
    if(GCC_EXECUTABLE)
        set(CACHED_GCC_EXECUTABLE "${GCC_EXECUTABLE}" CACHE INTERNAL "Cached GCC executable path")
    endif()
endif()

# If no g++ is found, terminate with a helpful platform-specific error message.
if(NOT GCC_EXECUTABLE)
    message(FATAL_ERROR 
        "\n"
        "//===----------------------------------------------------------------------===//\n"
        "                            GCC COMPILER NOT FOUND!                             \n"
        "//===----------------------------------------------------------------------===//\n"
        "\n"
        "This project requires GCC for competitive programming features:\n"
        "  - <bits/stdc++.h> header\n"
        "  - Policy-Based Data Structures (PBDS)\n"
        "  - Full C++23 support\n"
        "\n"
        "Installation instructions for ${PLATFORM_NAME}:\n"
        "\n")
    
    if(APPLE)
        message(FATAL_ERROR
            "  macOS (Homebrew):\n"
            "    brew install gcc\n"
            "\n"
            "  macOS (MacPorts):\n"
            "    sudo port install gcc13 +universal\n"
            "\n"
            "After installation, re-run 'cppconf' to configure the project.\n"
            "//===----------------------------------------------------------------------===//\n")
    elseif(CMAKE_SYSTEM_NAME MATCHES "Linux")
        if(DISTRO MATCHES "Debian")
            set(INSTALL_CMD "sudo apt update && sudo apt install g++")
        elseif(DISTRO MATCHES "RedHat")
            set(INSTALL_CMD "sudo dnf install gcc-c++  # or: sudo yum install gcc-c++")
        elseif(DISTRO MATCHES "Arch")
            set(INSTALL_CMD "sudo pacman -S gcc")
        else()
            set(INSTALL_CMD "Use your distribution's package manager to install g++")
        endif()
        
        message(FATAL_ERROR
            "  ${DISTRO}:\n"
            "    ${INSTALL_CMD}\n"
            "\n"
            "  For newer GCC versions, you may need to add a PPA or use a toolchain:\n"
            "    Ubuntu: sudo add-apt-repository ppa:ubuntu-toolchain-r/test\n"
            "    RHEL/CentOS: sudo yum install devtoolset-11\n"
            "\n"
            "After installation, re-run 'cppconf' to configure the project.\n"
            "//===----------------------------------------------------------------------===//\n")
    else()
        message(FATAL_ERROR
            "  Please install GCC using your system's package manager.\n"
            "\n"
            "  Common commands:\n"
            "    pkg install gcc      # FreeBSD\n"
            "    pkg_add gcc          # OpenBSD\n"
            "    pkgin install gcc    # NetBSD\n"
            "\n"
            "After installation, re-run 'cppconf' to configure the project.\n"
            "//===----------------------------------------------------------------------===//\n")
    endif()
endif()

# Verify the found compiler is actually GCC and get version info
execute_process(
    COMMAND ${GCC_EXECUTABLE} --version
    OUTPUT_VARIABLE GCC_VERSION_OUTPUT
    ERROR_VARIABLE GCC_VERSION_ERROR
    RESULT_VARIABLE GCC_VERSION_RESULT
    OUTPUT_STRIP_TRAILING_WHITESPACE
    TIMEOUT 5
)

if(NOT GCC_VERSION_RESULT EQUAL 0)
    message(FATAL_ERROR 
        "Failed to execute ${GCC_EXECUTABLE} --version.\n"
        "The found executable may not be a valid GCC compiler.\n"
        "Error: ${GCC_VERSION_ERROR}")
endif()

# Robust version extraction with multiple patterns
string(REGEX MATCH "gcc.*([0-9]+\\.[0-9]+\\.[0-9]+)" GCC_VERSION_MATCH "${GCC_VERSION_OUTPUT}")
if(GCC_VERSION_MATCH)
    string(REGEX MATCH "([0-9]+\\.[0-9]+\\.[0-9]+)" GCC_VERSION "${GCC_VERSION_MATCH}")
    string(REGEX MATCH "^([0-9]+)" GCC_MAJOR_VERSION "${GCC_VERSION}")
else()
    # Try alternative patterns
    string(REGEX MATCH "\\(GCC\\) ([0-9]+\\.[0-9]+)" GCC_VERSION_MATCH "${GCC_VERSION_OUTPUT}")
    if(GCC_VERSION_MATCH)
        string(REGEX MATCH "([0-9]+\\.[0-9]+)" GCC_VERSION "${GCC_VERSION_MATCH}")
        string(REGEX MATCH "^([0-9]+)" GCC_MAJOR_VERSION "${GCC_VERSION}")
    else()
        # Final fallback using dumpversion
        execute_process(
            COMMAND ${GCC_EXECUTABLE} -dumpversion
            OUTPUT_VARIABLE GCC_VERSION
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
        )
        string(REGEX MATCH "^([0-9]+)" GCC_MAJOR_VERSION "${GCC_VERSION}")
    endif()
endif()

# Verify it's actually GCC and not a disguised Clang
if(GCC_VERSION_OUTPUT MATCHES "clang" OR GCC_VERSION_OUTPUT MATCHES "Apple")
    message(WARNING 
        "\n"
        "//===----------------------------------------------------------------------===//\n"
        "                         WARNING: CLANG DETECTED AS G++                         \n"
        "//===----------------------------------------------------------------------===//\n"
        "\n"
        "The 'g++' command at ${GCC_EXECUTABLE} is actually Clang, not GCC.\n"
        "This is common on macOS where 'g++' is aliased to Clang.\n"
        "\n"
        "Searching for real GCC installation...\n")
    
    # Try to find real GCC by excluding the fake one
    list(REMOVE_ITEM COMPILER_SEARCH_PATHS "/usr/bin")
    
    find_program(REAL_GCC_EXECUTABLE
        NAMES ${COMPILER_SEARCH_NAMES}
        PATHS ${COMPILER_SEARCH_PATHS}
        DOC "Path to the real g++ executable"
        NO_DEFAULT_PATH
    )
    
    if(REAL_GCC_EXECUTABLE)
        set(GCC_EXECUTABLE ${REAL_GCC_EXECUTABLE})
        set(CACHED_GCC_EXECUTABLE "${GCC_EXECUTABLE}" CACHE INTERNAL "Cached GCC executable path" FORCE)
        message(STATUS "Found real GCC at: ${GCC_EXECUTABLE}")
        
        # Re-verify version
        execute_process(
            COMMAND ${GCC_EXECUTABLE} -dumpversion
            OUTPUT_VARIABLE GCC_VERSION
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
        )
        string(REGEX MATCH "^([0-9]+)" GCC_MAJOR_VERSION "${GCC_VERSION}")
    else()
        message(FATAL_ERROR 
            "Could not find real GCC. Please install it using the instructions above.\n"
            "//===----------------------------------------------------------------------===//\n")
    endif()
endif()

# Verify GCC version meets minimum requirements for competitive programming
if(GCC_MAJOR_VERSION)
    if(GCC_MAJOR_VERSION LESS 9)
        message(WARNING 
            "Found GCC version ${GCC_VERSION} is quite old (< 9.0).\n"
            "Some modern C++ features may not be available:\n"
            "  - C++20/23 features may be incomplete\n"
            "  - Newer optimization flags may not work\n"
            "  - Some PBDS features might be missing\n"
            "Consider upgrading to GCC 11 or newer for best results.")
    elseif(GCC_MAJOR_VERSION LESS 11)
        message(STATUS "GCC ${GCC_VERSION} detected. C++20 support may be incomplete.")
    else()
        message(STATUS "GCC ${GCC_VERSION} detected. Full C++20/23 support available!")
    endif()
endif()

# Find the corresponding C compiler (gcc) based on the g++ path.
get_filename_component(GCC_DIR ${GCC_EXECUTABLE} DIRECTORY)
get_filename_component(GCC_NAME ${GCC_EXECUTABLE} NAME)

# Create C compiler name by replacing g++ with gcc
string(REPLACE "g++" "gcc" C_COMPILER_NAME ${GCC_NAME})
string(REPLACE "c++" "cc" CPP_COMPILER_NAME ${GCC_NAME})

# Try to find gcc in the same directory as g++
find_program(C_COMPILER_PATH
    NAMES ${C_COMPILER_NAME} ${CPP_COMPILER_NAME}
    HINTS ${GCC_DIR}
    NO_DEFAULT_PATH
)

# If not found, try broader search
if(NOT C_COMPILER_PATH)
    # Create list of C compiler candidates
    set(C_COMPILER_CANDIDATES)
    foreach(cpp_name IN LISTS COMPILER_SEARCH_NAMES)
        string(REPLACE "g++" "gcc" c_name ${cpp_name})
        string(REPLACE "++" "" c_name2 ${cpp_name})
        list(APPEND C_COMPILER_CANDIDATES ${c_name} ${c_name2})
    endforeach()
    list(REMOVE_DUPLICATES C_COMPILER_CANDIDATES)
    
    find_program(C_COMPILER_PATH
        NAMES ${C_COMPILER_CANDIDATES}
        PATHS ${COMPILER_SEARCH_PATHS}
        DOC "Path to the gcc executable"
    )
endif()

# Verify we found a matching C compiler
if(NOT C_COMPILER_PATH)
    message(WARNING 
        "Could not find matching GCC C compiler for ${GCC_EXECUTABLE}.\n"
        "Using ${GCC_EXECUTABLE} for both C and C++.\n"
        "This may cause issues with C files.")
    set(C_COMPILER_PATH ${GCC_EXECUTABLE})
else()
    # Verify version compatibility
    execute_process(
        COMMAND ${C_COMPILER_PATH} -dumpversion
        OUTPUT_VARIABLE C_COMPILER_VERSION
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    
    string(REGEX MATCH "^([0-9]+)" C_MAJOR_VERSION "${C_COMPILER_VERSION}")
    
    if(C_MAJOR_VERSION AND GCC_MAJOR_VERSION AND 
       NOT C_MAJOR_VERSION STREQUAL GCC_MAJOR_VERSION)
        message(WARNING 
            "C compiler version (${C_COMPILER_VERSION}) differs from "
            "C++ compiler version (${GCC_VERSION}).\n"
            "This may cause linking issues.")
    endif()
endif()

# Force CMake to use the found compilers for both C and C++.
set(CMAKE_C_COMPILER   ${C_COMPILER_PATH} CACHE PATH "C compiler"   FORCE)
set(CMAKE_CXX_COMPILER ${GCC_EXECUTABLE}  CACHE PATH "C++ compiler" FORCE)

# Set compiler-specific flags that may be needed for toolchain setup
set(CMAKE_C_COMPILER_ID "GNU" CACHE STRING "C compiler ID" FORCE)
set(CMAKE_CXX_COMPILER_ID "GNU" CACHE STRING "C++ compiler ID" FORCE)

# Ensure the compilers support the required standards
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Set C++23 standard
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++23" CACHE STRING "" FORCE)

# Enable compiler-specific features
if(GCC_MAJOR_VERSION AND GCC_MAJOR_VERSION GREATER_EQUAL 10)
    # Enable coroutines for GCC 10+
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fcoroutines" CACHE STRING "" FORCE)
endif()

# Success message with summary
message(STATUS "")
message(STATUS "//===----------------------------------------------------------------------===//")
message(STATUS "                     GCC Toolchain Successfully Configured                      ")
message(STATUS "//===----------------------------------------------------------------------===//")
message(STATUS "  C++ compiler : ${CMAKE_CXX_COMPILER}")
if(GCC_VERSION)
    message(STATUS "  GCC version  : ${GCC_VERSION}")
    if(GCC_MAJOR_VERSION GREATER_EQUAL 13)
        message(STATUS "  C++ Support  : Full C++23 support available!")
    elseif(GCC_MAJOR_VERSION GREATER_EQUAL 11)
        message(STATUS "  C++ Support  : Full C++20 support, partial C++23")
    else()
        message(STATUS "  C++ Support  : C++17 full, C++20 partial")
    endif()
endif()
message(STATUS "  C compiler   : ${CMAKE_C_COMPILER}")
if(C_COMPILER_VERSION AND NOT C_COMPILER_VERSION STREQUAL GCC_VERSION)
    message(STATUS "  C version    : ${C_COMPILER_VERSION}")
endif()

# Set the build type to Debug by default if not specified by the user.
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Debug CACHE STRING "Default build type" FORCE)
    message(STATUS "  Build type   : ${CMAKE_BUILD_TYPE} (default)")
else()
    message(STATUS "  Build type   : ${CMAKE_BUILD_TYPE}")
endif()

message(STATUS "//===----------------------------------------------------------------------===//")
message(STATUS "")

# ============================================================================ #
# End of GCC Toolchain File