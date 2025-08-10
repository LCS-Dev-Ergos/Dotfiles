# CMake-based C++ Environment for Competitive Programming

This repository contains a set of scripts and templates to create a robust, fast, and IDE-friendly C++ development environment for competitive programming, especially on macOS. It leverages CMake for a solid build system and a collection of shell functions for an efficient workflow.

The primary goal is to solve common frustrations like compiler issues (`GCC` vs. `Clang`), IDE integration (`clangd`), and project management during contests.

## Key Features

- **Forced GCC on macOS**: Guarantees the use of a modern GCC compiler (for `<bits/stdc++.h>`, PBDS, etc.), bypassing macOS's default AppleClang.
- **Automatic Problem Detection**: Automatically finds all `.cpp`, `.cc`, and `.cxx` files in a project directory and creates a separate executable for each.
- **Full `clangd` Integration**: Generates and maintains a `compile_commands.json` file, providing perfect autocompletion and error checking in IDEs like VS Code.
- **Flexible Build Types**: Pre-configured for `Debug`, `Release`, and `Sanitize` builds.
- **Powerful Shell Utilities**: A suite of `cpp*` commands to initialize projects, create new problem files from templates, build, run, and test solutions with a single command.
- **Modular and Clean**: Each contest is an isolated CMake project, keeping the setup fast and organized.

## Prerequisites

Before you begin, ensure you have the following installed on your system (specifically for macOS):

1. **Homebrew**: The missing package manager for macOS.
2. **GCC**: For modern C++ features, `<bits/stdc++.h>`, and PBDS.

    ```bash
    brew install gcc
    ```

3. **CMake**: The build system generator.

    ```bash
    brew install cmake
    ```

## Installation

1. **Clone or Download the `cpp-tools` Directory:**
    Place the `cpp-tools` directory (containing `competitive.sh` and the `templates/` folder) in a safe, persistent location. The recommended location is `~/.config/`.

    ```bash
    # Example:
    # git clone <your-repo-url> ~/.config/cpp-tools
    # Or simply:
    mkdir -p ~/.config/cpp-tools
    # ...and move the files there.
    ```

2. **Source the Script in Your Shell Configuration:**
    Add the following line to the end of your `~/.zshrc` (for Zsh) or `~/.bashrc` (for Bash) file to load the utilities automatically with every new terminal session.

    ```bash
    # Load competitive programming utilities
    if [ -f ~/.config/cpp-tools/competitive.sh ]; then
        source ~/.config/cpp-tools/competitive.sh
    fi
    ```

3. **Reload Your Shell:**
    Apply the changes by running `source ~/.zshrc` or by opening a new terminal window. You should see the message "✅ Competitive Programming utilities loaded."

### Workflow

The workflow is designed to be fast and intuitive.

#### 1. Start a New Contest

Navigate to your main competitive programming directory (e.g., `~/cp`) and use the `cppcontest` command to create a dedicated, isolated project for the new contest.

```bash
# This creates the directory structure and navigates into it
cd ~/cp
cppcontest Codeforces/Round_1037_Div_3
```

This command automatically runs `cppinit`, which sets up the `CMakeLists.txt`, `.gitignore`, and the `build` directory.

#### 2. Create a Problem File

Inside the contest directory, use `cppnew` to create a source file for a specific problem.

```bash
# Creates problem_A.cpp from the default template
cppnew problem_A

# Creates problem_G.cpp using the Policy-Based Data Structures template
cppnew problem_G pbds
```

This command generates the file from a template and automatically re-runs CMake to add the new problem as a build target.

#### 3. Write, Build, and Run

Write your solution in the generated file. When you're ready to test it, use the all-in-one `cppgo` command.

```bash
# Build and run the executable for problem_A
# It will automatically find the file, even if it's problem_A.cc
cppgo problem_A

# Build and run problem_C, redirecting input.txt to stdin
# (Assumes a file named 'input.txt' exists)
cppgo problem_C

# Build and run problem_D, using a specific input file
cppgo problem_D problem_D.in
```

#### 4. Test Against Sample Cases

If you have multiple sample cases named like `problem_A.1.in`, `problem_A.1.out`, `problem_A.2.in`, etc., you can test them all automatically with `cppjudge`.

```bash
cppjudge problem_A
```

The script will run your code against each `.in` file and `diff` the output with the corresponding `.out` file, reporting ✅ **PASSED** or ❌ **FAILED**.

#### 5. Develop with Auto-Rebuild

For a fast development loop, use `cppwatch` to monitor a source file for changes and automatically rebuild it.

```bash
# Watches problem_E.cpp and rebuilds it on every save
cppwatch problem_E
```

## Command Reference

| Command                     | Description                                                              |
| --------------------------- | ------------------------------------------------------------------------ |
| `cppcontest <dir_name>`     | Creates, navigates into, and initializes a new contest directory.        |
| `cppinit`                   | (Internal) Initializes a new CMake project in the current directory.     |
| `cppnew <name> [type]`      | Creates a new problem file from a template (`default`, `pbds`).          |
| `cppconf [type]`            | (Re)configures the CMake project (e.g., `Debug`, `Release`, `Sanitize`). |
| `cppbuild [name]`           | Builds a specific target (defaults to the most recently modified file).  |
| `cpprun [name]`             | Runs a specific target's executable.                                     |
| `cppgo [name] [input_file]` | All-in-one: builds and runs a target, with optional input redirection.   |
| `cppjudge [name]`           | Tests a solution against all corresponding `.in`/`.out` sample files.    |
| `cppwatch [name]`           | Watches a source file and automatically rebuilds it on change.           |
| `cppclean`                  | Cleans the project by removing the `build` directory.                    |
| `cpphelp`                   | Displays a help message with all available commands.                     |

## Project Directory Structure

A typical contest directory created and managed by these scripts will look like this:

```path
ROUND_1037_DIV_3/
├── CMakeLists.txt          # Project build script, auto-generated
├── .gitignore              # Standard git ignore file
├── algorithms/             # For shared headers like debug.h
├── build/                  # Build directory, where CMake works its magic
│   ├── ...
│   └── compile_commands.json # For clangd
├── bin/                    # Where executables are placed
│   ├── problem_A
│   └── problem_B
├── problem_A.cc            # Your source files
├── problem_B.cpp
└── compile_commands.json   # Symlink to the file in build/ for easy IDE access
```
