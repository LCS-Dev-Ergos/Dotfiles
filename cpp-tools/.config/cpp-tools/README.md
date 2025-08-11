# Robust C++ Environment for Competitive Programming

This repository provides a set of scripts and templates to create a robust, fast, and IDE-friendly C++ development environment for competitive programming, especially on macOS. It leverages CMake for a solid build system and a collection of shell functions for an efficient workflow.

The primary goal is to solve common frustrations like compiler conflicts (`GCC` vs. `Clang`), IDE integration (`clangd` in VS Code), and project management during contests.

## Key Features

- **Forced GCC on All Platforms**: Guarantees the use of a modern GCC compiler (for `<bits/stdc++.h>`, PBDS, etc.) by using a CMake toolchain file, which is the standard and most reliable method.
- **Seamless `clangd` Integration**: The setup automatically finds GCC's system headers and adds them to the build flags. This generates a perfect `compile_commands.json` file, giving `clangd` flawless autocompletion and diagnostics out-of-the-box.
- **Automatic IDE Configuration**: Creates a project-specific `.clangd` file to suppress common warnings (like `unused-const-variable`) that are just noise in a competitive programming context, keeping your editor clean.
- **Automatic Problem Detection**: Automatically finds all `.cpp`, `.cc`, and `.cxx` files in a project directory and creates a separate executable for each.
- **Flexible Build Types**: Pre-configured for `Debug`, `Release`, and `Sanitize` builds (with Address and Undefined Behavior sanitizers).
- **Powerful Shell Utilities**: A suite of `cpp*` commands to initialize projects, create new files from templates, build, run, test, and diagnose your environment with a single command.
- **Idempotent and Modular**: Each contest is an isolated CMake project. The initialization scripts are idempotent, meaning they can be run multiple times without causing issues, ensuring the configuration is always correct.

## Prerequisites

Before you begin, ensure you have the following installed on your system:

1. **GCC**: For modern C++ features, `<bits/stdc++.h>`, and PBDS.
    - **macOS**: `brew install gcc`
    - **Debian/Ubuntu**: `sudo apt install build-essential g++`
2. **CMake**: The build system generator.
    - **macOS**: `brew install cmake`
    - **Debian/Ubuntu**: `sudo apt install cmake`
3. **(Optional, for `cppwatch`) `fswatch`**:
    - **macOS**: `brew install fswatch`

## Installation

1. **Clone or Download the Tools Directory:**
    Place the directory containing `competitive.sh` and the `templates/` folder in a safe, persistent location. The recommended location is `~/.config/cpp-tools`.

    ```bash
    # Example:
    mkdir -p ~/.config/cpp-tools
    # ...and move the script and templates folder there.
    ```

2. **Source the Script in Your Shell Configuration:**
    Add the following line to the end of your `~/.zshrc` (for Zsh) or `~/.bashrc` (for Bash) file to load the utilities automatically.

    ```bash
    # Load competitive programming utilities
    if [ -f ~/.config/cpp-tools/competitive.sh ]; then
        source ~/.config/cpp-tools/competitive.sh
    fi
    ```

3. **Reload Your Shell:**
    Apply the changes by running `source ~/.zshrc` (or `source ~/.bashrc`) or by opening a new terminal window.

## Workflow

### 1. Start a New Contest

Navigate to your main competitive programming directory (e.g., `~/cp`) and use `cppcontest` to create a dedicated, isolated project for the new contest.

```bash
cd ~/cp
cppcontest Codeforces/Round_999_Div_2
```

This command creates the directory structure, navigates into it, and automatically runs `cppinit` to set up CMake, `.gitignore`, `.clangd`, etc.

### 2\. Create a Problem File

Inside the contest directory, use `cppnew` to create a source file.

```bash
# Creates A.cpp from the default template
cppnew A

# Creates C_pbds.cpp using the Policy-Based Data Structures template
cppnew C_pbds pbds
```

This command generates the file, creates a corresponding empty input file in `input_cases/`, and re-runs CMake to add the new problem as a build target.

### 3\. Write, Build, and Run

Write your solution in the generated file. When you're ready to test it, use the all-in-one `cppgo` command.

```bash
# Build and run the target A
# Input will be read from 'input_cases/A.in' by default
cppgo A

# Build and run target B, using a specific input file
cppgo B custom_input.in
```

### 4\. Test Against Sample Cases

If you have multiple sample cases named like `A.1.in`, `A.1.out`, `A.2.in`, etc., in the `input_cases/` folder, you can test them all automatically with `cppjudge`.

```bash
cppjudge A
```

The script will run your code against each `.in` file and `diff` the output with the corresponding `.out` file, reporting ✅ **PASSED** or ❌ **FAILED**.

## Command Reference

| Command                | Description                                                                    |
| :--------------------- | :----------------------------------------------------------------------------- |
| `cppcontest <dir>`     | Creates, navigates into, and initializes a new contest directory.              |
| `cppinit`              | Initializes or verifies a CMake project in the current directory (idempotent). |
| `cppnew <name> [tpl]`  | Creates a new source file from a template (`default`, `pbds`).                 |
| `cppconf [type]`       | (Re)configures the CMake project (`Debug`, `Release`, `Sanitize`).             |
| `cppbuild [name]`      | Builds a specific target (defaults to the most recently modified file).        |
| `cpprun [name]`        | Runs a target's executable.                                                    |
| `cppgo [name] [input]` | Builds and runs. Uses `input_cases/<name>.in` by default.                      |
| `cppjudge [name]`      | Tests the solution against all corresponding `.in`/`.out` sample files.        |
| `cppwatch [name]`      | Automatically rebuilds a target when its source file changes.                  |
| `cppclean`             | Removes the `build` directory and other artifacts.                             |
| `cppdiag`              | Displays detailed diagnostic information about the toolchain and environment.  |
| `cpphelp`              | Displays this help message.                                                    |

## Project Directory Structure

```dir
CONTEST_NAME/
├── .clangd                   # IDE configuration to suppress warnings (auto-generated)
├── .gitignore                # Standard gitignore file (auto-generated)
├── CMakeLists.txt            # Project build script (auto-generated)
├── gcc-toolchain.cmake       # File that forces GCC usage (auto-generated)
├── algorithms/               # For shared headers like debug.h
│   └── debug.h               # (symlink or local file)
├── input_cases/              # For all input files
│   ├── A.in
│   ├── A.1.in
│   └── A.1.out
├── build/                    # Build directory (managed by CMake)
│   └── compile_commands.json # For clangd
├── bin/                      # Where executables are placed
│   └── A
├── A.cpp                     # Your source files
└── compile_commands.json     # Symlink to the file in build/ for easy IDE access
```
