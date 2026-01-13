#! /bin/bash

# Source directory from which to copy configurations
SOURCE_DIR="$HOME/.config"

# Current directory where to create Stow packages
TARGET_DIR=$(pwd)

# List of directories to exclude
EXCLUDE=(
    ".andorid" ".vscode" "crossnote" "emacs" "fzf-fit" "gh" "github-copilot"
    "gtk-2.0" "jgit" "Microsoft" "raycast" "thefuck" "wireshark" "xbuild" "zsh"
)

# Check that the source directory exists
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Error: the directory $SOURCE_DIR does not exist."
    exit 1
fi

# Iterate over all directories in ~/.config
for dir in "$SOURCE_DIR"/*; do
    # Check that it is a directory
    if [[ -d "$dir" ]]; then
        # Package name (basename of the directory)
        package_name=$(basename "$dir")
        
        # Check if the directory is in the exclusion list
        if [[ " ${EXCLUDE[@]} " =~ " $package_name " ]]; then
            echo "Skipped excluded directory: $package_name"
            continue
        fi

        # Path of the package directory
        package_path="$TARGET_DIR/$package_name/.config/$package_name"

        # Check if the package directory exists
        if [[ -d "$TARGET_DIR/$package_name" || -L "$TARGET_DIR/$package_name" ]]; then
            # If it is a symlink, warn the user
            if [[ -L "$TARGET_DIR/$package_name" ]]; then
                echo "Warning: the package '$package_name' exists as a symlink."
            else
                echo "Warning: the package '$package_name' exists as a directory."
            fi
            # Ask for confirmation to overwrite
            read -p "Do you want to overwrite it? (y/N): " response
            if [[ "$response" != "y" && "$response" != "Y" ]]; then
                echo "Skipped package: $package_name"
                continue
            else
                echo "Overwriting package: $package_name"
                rm -rf "$TARGET_DIR/$package_name"
            fi
        fi

        # Create the necessary structure
        mkdir -p "$package_path"
        
        # Copy files from source to package
        cp -r "$dir/"* "$package_path/"
        
        echo "Created Stow package: $package_name"
    fi
done

echo "Operation completed."