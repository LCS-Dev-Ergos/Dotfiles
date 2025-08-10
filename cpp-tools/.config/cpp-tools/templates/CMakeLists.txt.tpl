# =========================================================================== #
# ------------ Project Configuration for Competitive Programming ------------ #
# =========================================================================== #
cmake_minimum_required(VERSION 3.22)
project(competitive_programming LANGUAGES CXX)

# Set C++23 as standard and export compile commands for clangd
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Set output directories
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/bin)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/lib)

# =========================================================================== #
# -------------------- Helper Function to Add a Problem --------------------- #
# =========================================================================== #

# Function to add a new problem executable with all configurations
# Usage: cp_add_problem(problem_name)
function(cp_add_problem TARGET_NAME SOURCE_FILE)
    add_executable(${TARGET_NAME} ${SOURCE_FILE})
    message(STATUS "Added executable: ${TARGET_NAME}")

    # ----- Target-specific compiler definitions ----- #
    target_compile_definitions(${TARGET_NAME} PRIVATE
        $<$<CONFIG:Debug,Sanitize>:LOCAL>
        $<$<CONFIG:Release>:NDEBUG>
    )

    # ----- Target-specific compiler options ----- #
    target_compile_options(${TARGET_NAME} PRIVATE
        # Warning Flags
        -Wall -Wextra -pedantic -Wshadow -Wconversion
        
        # Debug Flags
        $<$<CONFIG:Debug>:-g -O0>
        
        # Release Flags
        $<$<CONFIG:Release>:-O2 -march=native>
        
        # Sanitize Flags
        $<$<CONFIG:Sanitize>:-g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer>
    )

    # ----- Target-specific include directories ----- #
    # Add a shared 'algorithms' or 'includes' directory if it exists
    if(IS_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/algorithms)
        target_include_directories(${TARGET_NAME} PRIVATE 
            ${CMAKE_CURRENT_SOURCE_DIR}/algorithms
        )
        message(STATUS "Added include path 'algorithms' for target ${TARGET_NAME}")
    endif()

endfunction()

# =========================================================================== #
# ------------------------ Executable Configuration ------------------------- #
# =========================================================================== #

# Find all source files in the current directory and add them as problems.
# NOTE: You need to re-run CMake when adding/deleting source files.
file(GLOB PROBLEM_SOURCES LIST_DIRECTORIES false "*.cpp" "*.cc" "*.cxx")

# Loop through each source file and create a target for it
foreach(source_file ${PROBLEM_SOURCES})
    # Get the base name of the file to use as the target name
    get_filename_component(exec_name ${source_file} NAME_WE)
    
    # Call the helper function, passing both the target name and the full source file
    cp_add_problem(${exec_name} ${source_file})
endforeach()

# Set default startup project for IDEs if main exists
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/main.cpp")
    set_property(DIRECTORY PROPERTY VS_STARTUP_PROJECT main)
endif()

# =========================================================================== #
# ----------------------------- Utility Targets ----------------------------- #
# =========================================================================== #

# Custom target for contest builds (release mode)
add_custom_target(contest
    COMMAND ${CMAKE_COMMAND} --build . --config Release
    COMMENT "Building all targets in optimized Release mode"
)

# Create a symbolic link for compile_commands.json in the source directory
# This is cleaner than copying on every build.
add_custom_target(symlink_clangd
    COMMAND ${CMAKE_COMMAND} -E create_symlink 
            ${CMAKE_BINARY_DIR}/compile_commands.json 
            ${CMAKE_SOURCE_DIR}/compile_commands.json
    COMMENT "Creating symlink for compile_commands.json for clangd"
)

# ============================================================================ #
# --------------------------- Configuration Summary -------------------------- #
# ============================================================================ #

# Define Sanitize as a known configuration
set(CMAKE_CONFIGURATION_TYPES "Debug;Release;Sanitize" CACHE STRING "Supported build types" FORCE)

# Print a summary
message(STATUS "=== Competitive Programming Setup Summary ===")
message(STATUS "Configured with compiler: ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}")
message(STATUS "To build a specific problem: cmake --build . --target <problem_name>")
message(STATUS "Default build type: ${CMAKE_BUILD_TYPE}")
message(STATUS "Available build types: ${CMAKE_CONFIGURATION_TYPES}")
message(STATUS "==============================================")