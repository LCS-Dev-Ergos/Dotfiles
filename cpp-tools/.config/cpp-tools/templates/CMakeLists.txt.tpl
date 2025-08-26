# =========================================================================== #
# ------------ Project Configuration for Competitive Programming ------------ #
# =========================================================================== #
# This CMake file is designed to be simple and robust. The complexity of
# compiler selection is handled by the toolchain files, which ensures the
# correct compiler is used. This allows clangd to work correctly out-of-the-box
# by reading the compiler-generated compile commands.
#
# Special handling for macOS: Uses Clang for Sanitize builds due to missing
# GCC sanitizer libraries on macOS.
# --------------------------------------------------------------------------- #
cmake_minimum_required(VERSION 3.20)
project(competitive_programming LANGUAGES CXX)

# ----------------------------- ANSI Color Codes ---------------------------- #
# Define variables for ANSI color codes to make message() output more readable.
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

# ---------------------- macOS RPATH Handling Cleanup ----------------------- #
if(APPLE)
    # Modern RPATH handling for macOS
    set(CMAKE_MACOSX_RPATH ON)
    set(CMAKE_SKIP_BUILD_RPATH FALSE)
    set(CMAKE_BUILD_WITH_INSTALL_RPATH FALSE)
    set(CMAKE_INSTALL_RPATH_USE_LINK_PATH TRUE)
    
    # Disable automatic RPATH generation to avoid duplicates
    set(CMAKE_SKIP_RPATH FALSE)
    set(CMAKE_SKIP_INSTALL_RPATH TRUE)
    
    # Get the LLVM/Clang library path if using Homebrew LLVM
    if(CMAKE_CXX_COMPILER MATCHES "llvm")
        get_filename_component(LLVM_BIN_DIR ${CMAKE_CXX_COMPILER} DIRECTORY)
        get_filename_component(LLVM_ROOT_DIR ${LLVM_BIN_DIR} DIRECTORY)
        set(LLVM_LIB_DIR "${LLVM_ROOT_DIR}/lib")
        
        if(EXISTS "${LLVM_LIB_DIR}")
            # Set a clean, single RPATH for LLVM
            set(CMAKE_INSTALL_RPATH "${LLVM_LIB_DIR}")
            message(STATUS "RPATH Fix: Set single LLVM RPATH: ${LLVM_LIB_DIR}")
        endif()
    endif()
endif()

# ------------------------ Compilation Timing Setup ------------------------- #
# Enable per-config compilation timing without affecting Release by default.
option(CP_ENABLE_TIMING "Enable detailed GCC/Clang compilation timing reports" OFF)
set(CP_TIMING_CONFIGS "Debug;Sanitize" CACHE STRING "Configs that receive timing flags")

if(CP_ENABLE_TIMING)
  message(STATUS "${ANSI_COLOR_CYAN}Compilation timing enabled.${ANSI_COLOR_RESET}")

  include(CheckCXXCompilerFlag)
  set(TIMING_FLAGS "")

  if(CMAKE_CXX_COMPILER_ID MATCHES "GNU")
    check_cxx_compiler_flag("-ftime-report" HAS_FTIME_REPORT)
    if(HAS_FTIME_REPORT)
      list(APPEND TIMING_FLAGS "-ftime-report")
    endif()
    string(REPLACE ";" "; " TIMING_FLAGS_DISPLAY "${TIMING_FLAGS}")
    message(STATUS "${ANSI_COLOR_CYAN}GCC timing flags detected: ${TIMING_FLAGS_DISPLAY}${ANSI_COLOR_RESET}")

  elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang|AppleClang")
    check_cxx_compiler_flag("-ftime-trace" HAS_FTIME_TRACE)
    if(HAS_FTIME_TRACE)
      list(APPEND TIMING_FLAGS "-ftime-trace")
      check_cxx_compiler_flag("-ftime-trace-granularity=1" HAS_FTIME_TRACE_GRAN)
      if(HAS_FTIME_TRACE_GRAN)
        list(APPEND TIMING_FLAGS "-ftime-trace-granularity=1")
      endif()
    endif()
    check_cxx_compiler_flag("-ftime-report" HAS_CLANG_FTIME_REPORT)
    if(HAS_CLANG_FTIME_REPORT)
      list(APPEND TIMING_FLAGS "-ftime-report")
    endif()
    string(REPLACE ";" "; " TIMING_FLAGS_DISPLAY "${TIMING_FLAGS}")
    message(STATUS "${ANSI_COLOR_CYAN}Clang timing flags detected: ${TIMING_FLAGS_DISPLAY}${ANSI_COLOR_RESET}")
  endif()

  if(TIMING_FLAGS)
    foreach(cfg ${CP_TIMING_CONFIGS})
      foreach(f ${TIMING_FLAGS})
        add_compile_options("$<$<AND:$<COMPILE_LANGUAGE:CXX>,$<CONFIG:${cfg}>>:${f}>")
      endforeach()
    endforeach()
    string(REPLACE ";" "; " TIMING_CONFIGS_DISPLAY "${CP_TIMING_CONFIGS}")
    message(STATUS "${ANSI_COLOR_CYAN}Timing applied to configs: ${TIMING_CONFIGS_DISPLAY}${ANSI_COLOR_RESET}")
  else()
    message(WARNING "${ANSI_COLOR_YELLOW}Timing requested, but no supported flags were found for this compiler.${ANSI_COLOR_RESET}")
  endif()
endif()

# ---------------------------- LTO Configuration ---------------------------- #
option(CP_ENABLE_LTO "Enable Link Time Optimization (if supported)" OFF)

if(CP_ENABLE_LTO AND CMAKE_BUILD_TYPE STREQUAL "Release")
    include(CheckIPOSupported)
    check_ipo_supported(RESULT ipo_supported OUTPUT ipo_output)
    
    if(ipo_supported)
        message(STATUS "${ANSI_COLOR_GREEN}Link Time Optimization (LTO) enabled${ANSI_COLOR_RESET}")
        set(CMAKE_INTERPROCEDURAL_OPTIMIZATION TRUE)
    else()
        message(WARNING "${ANSI_COLOR_YELLOW}LTO not supported: ${ipo_output}${ANSI_COLOR_RESET}")
    endif()
endif()

# ------------------ Compiler Include Path Auto-Detection ------------------- #
# Different logic for GCC vs Clang

function(detect_compiler_system_includes OUTPUT_VARIABLE)
    # Check cache first
    if(DEFINED CACHE{COMPILER_SYSTEM_INCLUDES_CACHED})
        set(${OUTPUT_VARIABLE} "${COMPILER_SYSTEM_INCLUDES_CACHED}" PARENT_SCOPE)
        message(STATUS "Clangd Assist: Using cached compiler include paths")
        return()
    endif()

    set(DETECTED_PATHS "")

    if(CMAKE_CXX_COMPILER_ID MATCHES "GNU")
        # GCC-specific path detection (existing logic)
        if(APPLE)
            message(STATUS "Clangd Assist: Using selective path detection for GCC on macOS.")
            
            # Try to get exact brew prefix first, fallback to common locations.
            execute_process(
                COMMAND brew --prefix
                OUTPUT_VARIABLE BREW_PREFIX
                OUTPUT_STRIP_TRAILING_WHITESPACE
                ERROR_QUIET
                RESULT_VARIABLE BREW_RESULT
            )
            if(NOT BREW_RESULT EQUAL 0 OR NOT BREW_PREFIX)
                foreach(prefix "/opt/homebrew" "/usr/local")
                    if(IS_DIRECTORY "${prefix}")
                        set(BREW_PREFIX "${prefix}")
                        break()
                    endif()
                endforeach()
            endif()

            if(BREW_PREFIX)
                # Get GCC full version, fall back if needed
                execute_process(
                    COMMAND ${CMAKE_CXX_COMPILER} -dumpfullversion
                    OUTPUT_VARIABLE GCC_FULL_VERSION
                    OUTPUT_STRIP_TRAILING_WHITESPACE
                    ERROR_QUIET
                )
                
                # Derive major version number (e.g. "15")
                string(REGEX MATCH "^[0-9]+" GCC_VERSION "${GCC_FULL_VERSION}")
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
                )

                foreach(p IN LISTS GCC_INCLUDE_PATHS)
                    if(IS_DIRECTORY "${p}")
                        list(APPEND DETECTED_PATHS "${p}")
                    endif()
                endforeach()
            endif()
        else()
            # Generic GCC path detection for Linux
            execute_process(
                COMMAND ${CMAKE_CXX_COMPILER} -E -x c++ -v /dev/null
                OUTPUT_VARIABLE GCC_VERBOSE_OUTPUT
                ERROR_VARIABLE GCC_VERBOSE_OUTPUT
                RESULT_VARIABLE EXIT_CODE
                TIMEOUT 5
            )

            if(EXIT_CODE EQUAL 0)
                string(REPLACE "\n" ";" OUTPUT_LINES "${GCC_VERBOSE_OUTPUT}")
                set(IS_PARSING_INCLUDES FALSE)
                
                foreach(line ${OUTPUT_LINES})
                    if(line MATCHES "^#include <...> search starts here:")
                        set(IS_PARSING_INCLUDES TRUE)
                    elseif(line MATCHES "^End of search list.")
                        break()
                    elseif(IS_PARSING_INCLUDES)
                        string(STRIP "${line}" path)
                        if(IS_DIRECTORY "${path}")
                            list(APPEND DETECTED_PATHS "${path}")
                        endif()
                    endif()
                endforeach()
            endif()
        endif()
        
    elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang|AppleClang")
        # Clang-specific path detection
        message(STATUS "Clangd Assist: Detecting Clang system includes.")
        
        # For Clang, we don't need to add as many custom paths since it handles its own includes well
        # But we might want to add some for compatibility
        execute_process(
            COMMAND ${CMAKE_CXX_COMPILER} -E -x c++ -v /dev/null
            OUTPUT_VARIABLE CLANG_VERBOSE_OUTPUT
            ERROR_VARIABLE CLANG_VERBOSE_OUTPUT
            RESULT_VARIABLE EXIT_CODE
            TIMEOUT 5
        )
        
        if(EXIT_CODE EQUAL 0)
            string(REPLACE "\n" ";" OUTPUT_LINES "${CLANG_VERBOSE_OUTPUT}")
            set(IS_PARSING_INCLUDES FALSE)
            
            foreach(line ${OUTPUT_LINES})
                if(line MATCHES "^#include.*search starts here:")
                    set(IS_PARSING_INCLUDES TRUE)
                elseif(line MATCHES "^End of search list.")
                    break()
                elseif(IS_PARSING_INCLUDES)
                    string(STRIP "${line}" path)
                    # Exclude framework paths on macOS
                    if(IS_DIRECTORY "${path}" AND NOT path MATCHES "\\(framework directory\\)")
                        list(APPEND DETECTED_PATHS "${path}")
                    endif()
                endif()
            endforeach()
        endif()
    endif()

    # Keep only directories that actually exist
    if(DETECTED_PATHS)
        list(REMOVE_DUPLICATES DETECTED_PATHS)
        set(COMPILER_SYSTEM_INCLUDES_CACHED "${DETECTED_PATHS}" CACHE INTERNAL "Cached compiler include paths")
        set(${OUTPUT_VARIABLE} "${DETECTED_PATHS}" PARENT_SCOPE)
        string(REPLACE ";" "\n   " PATHS_NL "${DETECTED_PATHS}")
        message(STATUS "Clangd Assist: Found compiler include paths:\n   ${PATHS_NL}")
    else()
        message(WARNING "Clangd Assist: Could not auto-detect compiler system include paths.")
        set(${OUTPUT_VARIABLE} "" PARENT_SCOPE)
    endif()
endfunction()

detect_compiler_system_includes(COMPILER_SYSTEM_INCLUDE_PATHS)

# -------------------------- Compiler Verification -------------------------- #
# Special case: Allow Clang for Sanitize builds on macOS
set(USING_CLANG_FOR_SANITIZERS FALSE)

if(CMAKE_BUILD_TYPE STREQUAL "Sanitize" AND APPLE)
    # On macOS, we prefer Clang for sanitizers due to better library support
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|AppleClang")
        set(USING_CLANG_FOR_SANITIZERS TRUE)
        message(STATUS "${ANSI_COLOR_CYAN}Using Clang for Sanitize build on macOS (better sanitizer support)${ANSI_COLOR_RESET}")
    elseif(CMAKE_CXX_COMPILER_ID MATCHES "GNU")
        # Check if GCC has sanitizer support on this system
        include(CheckCXXCompilerFlag)
        set(CMAKE_REQUIRED_FLAGS "-fsanitize=address")
        check_cxx_compiler_flag("-fsanitize=address" HAS_ASAN)
        unset(CMAKE_REQUIRED_FLAGS)
        
        if(NOT HAS_ASAN)
            message(WARNING 
                "${ANSI_COLOR_YELLOW}GCC on this macOS system lacks sanitizer support.\n"
                "Consider using 'cppconf Sanitize clang' to use Clang for sanitizers.${ANSI_COLOR_RESET}")
        endif()
    endif()
elseif(NOT CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang|AppleClang")
    message(FATAL_ERROR "This project requires GCC or Clang. Found: ${CMAKE_CXX_COMPILER_ID}")
elseif(CMAKE_BUILD_TYPE STREQUAL "Sanitize" AND CMAKE_CXX_COMPILER_ID MATCHES "Clang|AppleClang")
    set(USING_CLANG_FOR_SANITIZERS TRUE)
    message(STATUS "${ANSI_COLOR_CYAN}Using Clang for Sanitize build${ANSI_COLOR_RESET}")
elseif(NOT CMAKE_BUILD_TYPE STREQUAL "Sanitize" AND NOT CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND NOT APPLE)
    # Only show warning for non-Apple systems when using non-GCC for non-Sanitize builds
    message(WARNING 
        "${ANSI_COLOR_YELLOW}Non-GCC compiler detected for non-Sanitize build.\n"
        "Detected compiler: ${CMAKE_CXX_COMPILER_ID}\n"
        "Some features like <bits/stdc++.h> may not be available.${ANSI_COLOR_RESET}")
endif()

# ----------------------------- Project Settings ---------------------------- #
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(CMAKE_COLOR_MAKEFILE ON)
set(CMAKE_VERBOSE_MAKEFILE OFF)

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/bin)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/lib)

file(MAKE_DIRECTORY ${CMAKE_RUNTIME_OUTPUT_DIRECTORY})
file(MAKE_DIRECTORY ${CMAKE_ARCHIVE_OUTPUT_DIRECTORY})

# Enable ccache if available
find_program(CCACHE_PROGRAM ccache)
if(CCACHE_PROGRAM)
    set(CMAKE_CXX_COMPILER_LAUNCHER ${CCACHE_PROGRAM})
    message(STATUS "Found ccache: ${CCACHE_PROGRAM} - builds will be faster!")
endif()

# =========================================================================== #
# -------------------- Helper Function to Add a Problem --------------------- #
# =========================================================================== #

function(cp_add_problem TARGET_NAME SOURCE_FILE)
    add_executable(${TARGET_NAME} ${SOURCE_FILE})
    
    # Set C++23 standard for the target
    set_target_properties(${TARGET_NAME} PROPERTIES
        CXX_STANDARD 23
        CXX_STANDARD_REQUIRED ON
        CXX_EXTENSIONS OFF
    )

    # Determine if we should use PCH.h instead of bits/stdc++.h
    set(USE_PCH FALSE)
    if(USING_CLANG_FOR_SANITIZERS)
        set(USE_PCH TRUE)
    elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang|AppleClang" AND NOT CMAKE_BUILD_TYPE STREQUAL "Sanitize")
        # Also use PCH for regular Clang builds
        set(USE_PCH TRUE)
    endif()

    # ----- Target-specific compiler definitions ----- #
    target_compile_definitions(${TARGET_NAME} PRIVATE
      # Define LOCAL for debug builds
      $<$<CONFIG:Debug,Sanitize>:LOCAL>
      # Define NDEBUG for release builds
      $<$<CONFIG:Release>:NDEBUG>
      # Add _GLIBCXX_DEBUG for better STL debugging in debug mode (GCC only)
      $<$<AND:$<CONFIG:Debug>,$<CXX_COMPILER_ID:GNU>>:_GLIBCXX_DEBUG>
      # Use PCH instead of bits/stdc++.h when needed
      $<$<BOOL:${USE_PCH}>:USE_CLANG_SANITIZE>
      # Enable C++23 specific features
      $<$<CXX_COMPILER_ID:GNU>:_GLIBCXX_ASSERTIONS>
      $<$<AND:$<CXX_COMPILER_ID:GNU>,$<VERSION_GREATER_EQUAL:${CMAKE_CXX_COMPILER_VERSION},13>>:_GLIBCXX_USE_CXX23_ABI>
      # Use modern libc++ hardening mode for Clang/AppleClang
      $<$<CXX_COMPILER_ID:Clang,AppleClang>:_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE>
    )

    # ----- Compiler-specific flags ----- #
    if(CMAKE_CXX_COMPILER_ID MATCHES "GNU")
        # GCC flags
        set(COMMON_FLAGS -Wall -Wextra -Wpedantic -Wshadow)
        set(DEBUG_FLAGS -g2 -O0 -fstack-protector-strong)
        set(RELEASE_FLAGS -O2 -funroll-loops -ftree-vectorize -ffast-math)
        
        if(CMAKE_SYSTEM_PROCESSOR MATCHES "(x86_64|AMD64)")
            list(APPEND RELEASE_FLAGS -march=native)
        endif()
        
        # GCC sanitizer flags (might not work on macOS)
        set(SANITIZE_FLAGS -g -O1 -fsanitize=address,undefined,leak
            -fsanitize-address-use-after-scope
            -fno-omit-frame-pointer
            -fno-sanitize-recover=all)
            
    elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang|AppleClang")
        # Clang flags
        set(COMMON_FLAGS -Wall -Wextra -Wpedantic -Wshadow)
        set(DEBUG_FLAGS -g2 -O0 -fstack-protector-strong)
        set(RELEASE_FLAGS -O2 -funroll-loops -fvectorize)
        
        # Clang sanitizer flags (work well on all platforms)
        set(SANITIZE_FLAGS -g -O1 
            -fsanitize=address,undefined
            -fsanitize-address-use-after-scope
            -fno-omit-frame-pointer
            -fno-sanitize-recover=all)
            
        # Add integer and nullability sanitizers on newer Clang
        if(CMAKE_CXX_COMPILER_VERSION VERSION_GREATER_EQUAL "10.0")
            list(APPEND SANITIZE_FLAGS -fsanitize=integer,nullability)
        endif()
    endif()

    # Apply compiler flags
    target_compile_options(${TARGET_NAME} PRIVATE
        # Use C++23 standard
        -std=c++23
        ${COMMON_FLAGS}
        # Suppress common warnings
        -Wno-unused-const-variable
        -Wno-sign-conversion
        -Wno-unused-parameter
        -Wno-unused-variable
        
        $<$<CONFIG:Debug>:${DEBUG_FLAGS}>
        $<$<CONFIG:Release>:${RELEASE_FLAGS}>
        $<$<CONFIG:Sanitize>:${SANITIZE_FLAGS}>
    )

    # ----- Include directories ----- #
    if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/algorithms)
        target_include_directories(${TARGET_NAME} PRIVATE 
            ${CMAKE_CURRENT_SOURCE_DIR}/algorithms
        )
    endif()

    # ----- Platform and compiler specific adjustments ----- #
    if(APPLE AND CMAKE_CXX_COMPILER_ID MATCHES "GNU")
        # Use libstdc++ for GCC on macOS
        target_compile_options(${TARGET_NAME} PRIVATE -stdlib=libstdc++)
        target_link_options(${TARGET_NAME} PRIVATE -stdlib=libstdc++)
    elseif(APPLE AND CMAKE_CXX_COMPILER_ID MATCHES "Clang|AppleClang")
        # Use libc++ for Clang on macOS (default)
        # No need to specify, it's the default
    endif()

    # Add system include paths for better clangd support
    if(COMPILER_SYSTEM_INCLUDE_PATHS)
        if(CMAKE_CXX_COMPILER_ID MATCHES "GNU")
            # For GCC, use nostdinc++ and add paths manually
            target_compile_options(${TARGET_NAME} PRIVATE -nostdinc++)
            foreach(dir IN LISTS COMPILER_SYSTEM_INCLUDE_PATHS)
                target_compile_options(${TARGET_NAME} PRIVATE "-isystem${dir}")
            endforeach()
        elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang|AppleClang")
            # For Clang, just add as system includes without nostdinc++
            foreach(dir IN LISTS COMPILER_SYSTEM_INCLUDE_PATHS)
                target_include_directories(${TARGET_NAME} SYSTEM PRIVATE ${dir})
            endforeach()
            # RPATH fix for this specific target
            if(LLVM_LIB_DIR AND EXISTS "${LLVM_LIB_DIR}")
                set_target_properties(${TARGET_NAME} PROPERTIES
                    INSTALL_RPATH "${LLVM_LIB_DIR}"
                    BUILD_WITH_INSTALL_RPATH TRUE
                    SKIP_BUILD_RPATH FALSE
                )
            endif()
        endif()
    endif()

    # ----- Linker options ----- #
    target_link_options(${TARGET_NAME} PRIVATE
        # Sanitizer linking
        $<$<CONFIG:Sanitize>:${SANITIZE_FLAGS}>
        # Strip symbols in release
        $<$<CONFIG:Release>:-s>
    )
    
    if(USE_PCH)
        set(PCH_STATUS "Yes")
    else()
        set(PCH_STATUS "No")
    endif()
    
    message(STATUS "Added problem: ${TARGET_NAME} "
                   "(Compiler: ${CMAKE_CXX_COMPILER_ID}, "
                   "PCH: ${PCH_STATUS})")
endfunction()

# =========================================================================== #
# ----------------------- Automatic Problem Detection ----------------------- #
# =========================================================================== #

file(GLOB PROBLEM_SOURCES LIST_DIRECTORIES false "*.cpp" "*.cc" "*.cxx")
list(SORT PROBLEM_SOURCES)
list(FILTER PROBLEM_SOURCES EXCLUDE REGEX ".*template.*")

foreach(source_file ${PROBLEM_SOURCES})
    get_filename_component(exec_name ${source_file} NAME_WE)
    cp_add_problem(${exec_name} ${source_file})
endforeach()

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/main.cpp")
    set_property(DIRECTORY PROPERTY VS_STARTUP_PROJECT main)
endif()

# =========================================================================== #
# ----------------------------- Utility Targets ----------------------------- #
# =========================================================================== #

add_custom_target(symlink_clangd
    COMMAND ${CMAKE_COMMAND} -E create_symlink 
            "${CMAKE_BINARY_DIR}/compile_commands.json"
            "${CMAKE_SOURCE_DIR}/.ide-config/compile_commands.json"
    COMMAND ${CMAKE_COMMAND} -E create_symlink 
            "${CMAKE_BINARY_DIR}/compile_commands.json"
            "${CMAKE_SOURCE_DIR}/compile_commands.json"
    COMMENT "Creating symlinks for compile_commands.json"
    VERBATIM
)

add_custom_target(all_problems)
foreach(source_file ${PROBLEM_SOURCES})
    get_filename_component(exec_name ${source_file} NAME_WE)
    add_dependencies(all_problems ${exec_name})
endforeach()

add_custom_target(rebuild
    COMMAND ${CMAKE_COMMAND} --build . --target clean
    COMMAND ${CMAKE_COMMAND} --build . -j
    COMMENT "Clean rebuild of all targets"
    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
)

# ============================================================================ #
# --------------------------- Configuration Summary -------------------------- #
# ============================================================================ #

set(CMAKE_CONFIGURATION_TYPES "Debug;Release;Sanitize" CACHE STRING "Supported build types" FORCE)

message(STATUS "")
message(STATUS "${ANSI_COLOR_BLUE}/===----------------- Competitive Programming Setup Summary ----------------===/${ANSI_COLOR_RESET}")
message(STATUS "|")
message(STATUS "| ${ANSI_COLOR_CYAN}Compiler${ANSI_COLOR_RESET}            : ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}")
message(STATUS "| ${ANSI_COLOR_CYAN}Compiler Path${ANSI_COLOR_RESET}       : ${CMAKE_CXX_COMPILER}")
message(STATUS "| ${ANSI_COLOR_CYAN}Build Type${ANSI_COLOR_RESET}          : ${ANSI_COLOR_YELLOW}${CMAKE_BUILD_TYPE}${ANSI_COLOR_RESET}")
message(STATUS "| ${ANSI_COLOR_CYAN}C++ Standard${ANSI_COLOR_RESET}        : C++${CMAKE_CXX_STANDARD}")

# Special note for Sanitize builds
if(CMAKE_BUILD_TYPE STREQUAL "Sanitize")
    if(USING_CLANG_FOR_SANITIZERS)
        message(STATUS "| ${ANSI_COLOR_CYAN}Sanitizer Mode${ANSI_COLOR_RESET}      : ${ANSI_COLOR_GREEN}Using Clang with PCH.h${ANSI_COLOR_RESET}")
    else()
        message(STATUS "| ${ANSI_COLOR_CYAN}Sanitizer Mode${ANSI_COLOR_RESET}      : ${ANSI_COLOR_YELLOW}Using GCC (check sanitizer availability)${ANSI_COLOR_RESET}")
    endif()
endif()

if(CCACHE_PROGRAM)
    message(STATUS "| ${ANSI_COLOR_CYAN}Build Cache${ANSI_COLOR_RESET}         : ${ANSI_COLOR_GREEN}ccache enabled${ANSI_COLOR_RESET}")
else()
    message(STATUS "| ${ANSI_COLOR_CYAN}Build Cache${ANSI_COLOR_RESET}         : ${ANSI_COLOR_YELLOW}ccache not found${ANSI_COLOR_RESET}")
endif()

message(STATUS "|")

if(COMPILER_SYSTEM_INCLUDE_PATHS)
    list(LENGTH COMPILER_SYSTEM_INCLUDE_PATHS INCLUDE_COUNT)
    message(STATUS "| ${ANSI_COLOR_CYAN}Clangd Assist${ANSI_COLOR_RESET}       : ${ANSI_COLOR_GREEN}OK (${INCLUDE_COUNT} include paths detected)${ANSI_COLOR_RESET}")
else()
    message(STATUS "| ${ANSI_COLOR_CYAN}Clangd Assist${ANSI_COLOR_RESET}       : ${ANSI_COLOR_YELLOW}WARNING - No include paths found${ANSI_COLOR_RESET}")
endif()

if(PROBLEM_SOURCES)
    list(LENGTH PROBLEM_SOURCES PROBLEM_COUNT)
    message(STATUS "| ${ANSI_COLOR_CYAN}Problems Found${ANSI_COLOR_RESET}      : ${PROBLEM_COUNT} C++ source files")
    
    if(PROBLEM_COUNT GREATER 10)
        list(SUBLIST PROBLEM_SOURCES 0 10 SHOWN_SOURCES)
        foreach(source ${SHOWN_SOURCES})
            get_filename_component(name ${source} NAME)
            message(STATUS "|   - ${name}")
        endforeach()
        math(EXPR REMAINING "${PROBLEM_COUNT} - 10")
        message(STATUS "|   ... and ${REMAINING} more.")
    else()
        foreach(source ${PROBLEM_SOURCES})
            get_filename_component(name ${source} NAME)
            message(STATUS "|   - ${name}")
        endforeach()
    endif()
else()
    message(STATUS "| ${ANSI_COLOR_CYAN}Problems Found${ANSI_COLOR_RESET}      : No C++ source files detected.")
endif()

message(STATUS "|")

# Build type specific tips
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    message(STATUS "| ${ANSI_COLOR_YELLOW}Tip: Use 'cppconf Release' for maximum performance.${ANSI_COLOR_RESET}")
elseif(CMAKE_BUILD_TYPE STREQUAL "Release")
    message(STATUS "| ${ANSI_COLOR_GREEN}Performance mode active - optimizations enabled.${ANSI_COLOR_RESET}")
elseif(CMAKE_BUILD_TYPE STREQUAL "Sanitize")
    if(USING_CLANG_FOR_SANITIZERS)
        message(STATUS "| ${ANSI_COLOR_CYAN}Using PCH.h as replacement for bits/stdc++.h${ANSI_COLOR_RESET}")
    endif()
    message(STATUS "| ${ANSI_COLOR_CYAN}Sanitizers active - great for finding bugs!${ANSI_COLOR_RESET}")
endif()

message(STATUS "${ANSI_COLOR_BLUE}/===------------------------------------------------------------------------===/${ANSI_COLOR_RESET}")

# ============================================================================ #
