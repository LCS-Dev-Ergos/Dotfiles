#!/usr/bin/env python3

import os
import shutil
import argparse
import sys
from pathlib import Path

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

def find_payload_root(package_dir: Path) -> Path:
    """
    Traverses down the Stow package structure to find the real root
    of configuration files.
    Example: from 'alacritty/' -> goes down to 'alacritty/.config/alacritty/'.
    """
    current_path = package_dir
    while True:
        try:
            children = [child for child in current_path.iterdir() if not child.name.startswith('.')]
            if len(children) == 1 and children[0].is_dir():
                current_path = children[0]
            else:
                # Stops if there are multiple files/folders or if the only element is a file
                return current_path
        except FileNotFoundError:
            return current_path # Returns the last valid path
        except Exception:
            # Returns the current path in case of other errors (e.g. permissions)
            return current_path


def main():
    """Main function that orchestrates the transformation."""
    parser = argparse.ArgumentParser(
        description="Transform a dotfiles structure from GNU Stow format to a flat structure, ideal for Ansible.",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('source', help="The source directory containing dotfiles in Stow format (e.g. ~/Dotfiles).")
    parser.add_argument('destination', help="The destination directory where to create the flat structure.")
    parser.add_argument('--force', action='store_true', help="Overwrites the destination folder if it already exists.")
    parser.add_argument('--dry-run', action='store_true', help="Runs the script without copying files, showing only what would be done.")
    args = parser.parse_args()

    source_dir = Path(args.source).expanduser().resolve()
    dest_dir = Path(args.destination).expanduser().resolve()

    if not source_dir.is_dir():
        print(f"{styles.FAIL}ERROR: The source directory '{source_dir}' does not exist.{styles.ENDC}")
        sys.exit(1)

    print(f"{styles.HEADER}🟢 Starting transformation from Stow to Ansible-ready structure...{styles.ENDC}")
    print(f" Source: {styles.CYAN}{source_dir}{styles.ENDC}")
    print(f" Destination: {styles.CYAN}{dest_dir}{styles.ENDC}")
    if args.dry_run:
        print(f"{styles.WARNING}--- RUNNING IN DRY-RUN MODE ---{styles.ENDC}")
    
    # Create the main destination directory
    if not args.dry_run:
        dest_dir.mkdir(parents=True, exist_ok=True)
    
    stow_packages = [p for p in source_dir.iterdir() if p.is_dir() and not p.name.startswith('.')]

    for package_dir in stow_packages:
        program_name = package_dir.name
        final_dest_path = dest_dir / program_name

        print(f"\n{styles.BOLD}▶️  Processing '{program_name}'...{styles.ENDC}")

        # Check if the destination for this program already exists
        if final_dest_path.exists():
            if args.force:
                print(f"  {styles.WARNING}FORCE: The destination folder '{final_dest_path}' exists and will be overwritten.{styles.ENDC}")
                if not args.dry_run:
                    shutil.rmtree(final_dest_path)
            else:
                print(f"  {styles.FAIL}FAIL: The destination folder '{final_dest_path}' already exists. Use --force to overwrite.{styles.ENDC}")
                continue
        
        # Find the real root of configuration files
        payload_root = find_payload_root(package_dir)
        
        # Copy the content of the found root
        payload_items = list(payload_root.iterdir())
        
        if not payload_items:
            print(f"  {styles.WARNING}WARN: No files found in '{payload_root}', skipped.{styles.ENDC}")
            continue

        print(f"  {styles.BLUE}Found content in: {styles.CYAN}{payload_root.relative_to(source_dir)}{styles.ENDC}")
        print(f"  {styles.BLUE}Copying to: {styles.CYAN}{final_dest_path}{styles.ENDC}")

        if args.dry_run:
            continue

        try:
            # Create the destination folder for the program
            final_dest_path.mkdir(exist_ok=True)
            # Copy each file/folder from the payload root to the destination
            for item in payload_items:
                dest_item_path = final_dest_path / item.name
                if item.is_dir():
                    shutil.copytree(item, dest_item_path)
                else:
                    shutil.copy2(item, dest_item_path)
        except Exception as e:
            print(f"  {styles.FAIL}ERROR during copy of '{program_name}': {e}{styles.ENDC}")

    print(f"\n{styles.GREEN}✅ Operation completed!{styles.ENDC}")
    print(f"Your dotfiles are now ready for Ansible in: {styles.CYAN}{dest_dir}{styles.ENDC}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\n❌ Operation interrupted by user.")
        sys.exit(1)