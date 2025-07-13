#!/usr/bin/env python3

import os
import shutil
import argparse
import sys
from pathlib import Path

# ----- CONFIGURATION ----- #
# List of directories to exclude. We use a set for more efficient searches.
EXCLUDE_DIRS = {
    ".android", ".vscode", "crossnote", "emacs", "fzf-git", "gh", "github-copilot",
    "gtk-2.0", "jgit", "Microsoft", "raycast", "thefuck", "wireshark", "xbuild", "zsh"
}

# ----- STYLES FOR CONSOLE OUTPUT ----- #
class styles:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    GREEN = '\033[92m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'

def main():
    """Main function that orchestrates the creation of Stow packages."""
    parser = argparse.ArgumentParser(
        description="Create GNU Stow compatible packages by copying configurations from a source directory.",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('--source', default=Path.home() / '.config', type=Path,
                        help="The source directory to copy configurations from (default: ~/.config).")
    parser.add_argument('--target', default=Path.cwd(), type=Path,
                        help="The target directory where Stow packages will be created (default: current folder).")
    parser.add_argument('--dry-run', action='store_true', help="Run the script without creating or copying files, only showing what would be done.")

    args = parser.parse_args()

    source_dir = args.source.expanduser().resolve()
    target_dir = args.target.expanduser().resolve()

    if not source_dir.is_dir():
        print(f"{styles.FAIL}ERROR: The source directory '{source_dir}' does not exist.{styles.ENDC}")
        sys.exit(1)

    print(f"{styles.HEADER}🟢 Starting Stow package creation...{styles.ENDC}")
    print(f" Source: {styles.CYAN}{source_dir}{styles.ENDC}")
    print(f" Target: {styles.CYAN}{target_dir}{styles.ENDC}")
    if args.dry_run:
        print(f"{styles.WARNING}--- RUNNING IN DRY-RUN MODE ---{styles.ENDC}")

    # Iterate through all items in the source directory
    for config_source in sorted(source_dir.iterdir()):
        if not config_source.is_dir():
            continue

        package_name = config_source.name
        
        # Check if the directory is in the exclusion list
        if package_name in EXCLUDE_DIRS:
            print(f"\n{styles.WARNING}⏭️  Skipped (excluded): {package_name}{styles.ENDC}")
            continue
            
        print(f"\n{styles.BOLD}▶️  Processing '{package_name}'...{styles.ENDC}")

        # Build paths safely with pathlib
        target_package_dir = target_dir / package_name
        final_stow_path = target_package_dir / '.config' / package_name

        # ----- CONFLICT HANDLING ----- #
        if target_package_dir.exists() or target_package_dir.is_symlink():
            print(f"  {styles.WARNING}WARNING: The target '{target_package_dir.name}' already exists.{styles.ENDC}")
            
            if args.dry_run:
                print(f"  {styles.CYAN}DRY-RUN: Would ask for overwrite confirmation.{styles.ENDC}")
                continue

            try:
                response = input(f"  {styles.BOLD}Do you want to overwrite it? (y/N): {styles.ENDC}")
                if response.lower() not in ['y', 'yes', 's', 'si']:
                    print("  Skipped by user.")
                    continue
                else:
                    print("  Removing old version...")
                    if target_package_dir.is_dir() and not target_package_dir.is_symlink():
                        shutil.rmtree(target_package_dir)
                    else:
                        target_package_dir.unlink() # For files or symlinks
            except KeyboardInterrupt:
                print("\n\n❌ Operation interrupted by user.")
                sys.exit(1)

        # ----- CREATION AND COPY ----- #
        print(f"  {styles.BLUE}Creating structure in: {styles.CYAN}{final_stow_path.relative_to(target_dir)}{styles.ENDC}")
        if not args.dry_run:
            try:
                # Create the necessary structure
                final_stow_path.mkdir(parents=True, exist_ok=True)
                
                # Copy content robustly
                shutil.copytree(config_source, final_stow_path, dirs_exist_ok=True)
                
                print(f"  {styles.GREEN}✅ Created Stow package: {package_name}{styles.ENDC}")
            except Exception as e:
                print(f"  {styles.FAIL}ERROR during creation of '{package_name}': {e}{styles.ENDC}")

    print(f"\n{styles.GREEN}Operation completed.{styles.ENDC}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\n❌ Operation interrupted by user.")
        sys.exit(1)