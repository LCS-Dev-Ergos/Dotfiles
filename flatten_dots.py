#!/usr/bin/env python3

import os
import shutil
import argparse
import sys
from pathlib import Path

# --- STYLES FOR CONSOLE OUTPUT ---
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
    """Main function to orchestrate the transformation."""
    parser = argparse.ArgumentParser(
        description="Transforms a GNU Stow directory structure into a flat, Ansible-ready format.",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('source', help="The source directory containing the Stow-formatted dotfiles (e.g., ~/Dotfiles).")
    parser.add_argument('destination', help="The destination directory where the flat structure will be created.")
    parser.add_argument('--force', action='store_true', help="Overwrite the destination directory if it already exists.")
    parser.add_argument('--dry-run', action='store_true', help="Run the script without copying any files, only showing what would be done.")
    args = parser.parse_args()

    source_dir = Path(args.source).expanduser().resolve()
    dest_dir = Path(args.destination).expanduser().resolve()

    if not source_dir.is_dir():
        print(f"{styles.FAIL}ERROR: Source directory '{source_dir}' does not exist.{styles.ENDC}")
        sys.exit(1)

    print(f"{styles.HEADER}🟢 Starting transformation from Stow to Ansible-ready structure...{styles.ENDC}")
    print(f" Source:      {styles.CYAN}{source_dir}{styles.ENDC}")
    print(f" Destination: {styles.CYAN}{dest_dir}{styles.ENDC}")
    if args.dry_run:
        print(f"{styles.WARNING}--- RUNNING IN DRY-RUN MODE ---{styles.ENDC}")
    
    # Create the main destination directory
    if not args.dry_run:
        dest_dir.mkdir(parents=True, exist_ok=True)
    
    # Get a list of packages to process (e.g., alacritty, fastfetch, etc.)
    stow_packages = [p for p in source_dir.iterdir() if p.is_dir() and not p.name.startswith('.')]

    for package_dir in sorted(stow_packages):
        program_name = package_dir.name
        final_dest_path = dest_dir / program_name

        print(f"\n{styles.BOLD}▶️  Processing '{program_name}'...{styles.ENDC}")

        # ----- CONFLICT MANAGEMENT: Check if the destination already exists ----- #
        if final_dest_path.exists():
            if args.force:
                print(f"  {styles.WARNING}FORCE: Destination '{final_dest_path.name}' exists and will be overwritten.{styles.ENDC}")
                if not args.dry_run:
                    shutil.rmtree(final_dest_path)
            else:
                print(f"  {styles.FAIL}FAIL: Destination '{final_dest_path.name}' already exists. Use --force to overwrite.{styles.ENDC}")
                continue
        
        # ----- Intelligently find the real configuration root ----- #
        # Recursively search for subdirectories that match the program's name.
        # This handles structures like `fastfetch/.config/fastfetch`.
        payload_candidates = list(package_dir.rglob(program_name))
        
        # We choose the deepest matching directory as the most likely source.
        # If no subdirectory matches, we use the top-level package directory itself.
        if payload_candidates:
            payload_root = max(payload_candidates, key=lambda p: len(str(p)))
        else:
            payload_root = package_dir

        print(f"  {styles.BLUE}Found configuration content in: {styles.CYAN}{payload_root.relative_to(source_dir.parent)}{styles.ENDC}")
        print(f"  {styles.BLUE}Copying contents to:            {styles.CYAN}{final_dest_path}{styles.ENDC}")

        if args.dry_run:
            continue

        # ----- COPY LOGIC ----- #
        try:
            # Copy the *contents* of the payload_root, not the directory itself.
            shutil.copytree(payload_root, final_dest_path, symlinks=True, dirs_exist_ok=True)
        except Exception as e:
            print(f"  {styles.FAIL}ERROR while copying '{program_name}': {e}{styles.ENDC}")

    print(f"\n{styles.GREEN}✅ Operation completed!{styles.ENDC}")
    print(f"Your dotfiles are now ready for Ansible in: {styles.CYAN}{dest_dir}{styles.ENDC}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\n❌ Operation interrupted by user.")
        sys.exit(1)