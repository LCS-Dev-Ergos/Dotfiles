#!/usr/bin/env python3

# ============================================================================ #
"""
Directory Size Analyzer:
Interactive tool for analyzing and displaying directory sizes with pagination
support. Features batch size calculation using du, human-readable formatting,
and optional Nushell integration for enhanced table rendering. Can include
files with the --all flag.

Author: XtremeXSPC
Version: 1.0.0
"""
# ============================================================================ #

import os
import sys
import argparse
import subprocess
import shutil
from pathlib import Path

# ANSI color codes
C_CYAN = "\033[0;36m"
C_YELLOW = "\033[0;33m"
C_GREEN = "\033[0;32m"
C_RED = "\033[0;31m"
C_RESET = "\033[0m"

def format_size(size_k):
    """Convert size in KB to human readable string."""
    size_bytes = size_k * 1024
    for unit in ['B', 'K', 'M', 'G', 'T', 'P']:
        if size_bytes < 1024:
            return f"{size_bytes:.1f}{unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f}E"

def get_sizes_batched(paths, batch_size=500):
    """
    Calculate sizes of multiple paths using du -sk in batches.
    Returns a dictionary {path_str: size_k_int}.
    """
    results = {}

    # Process in chunks
    for i in range(0, len(paths), batch_size):
        chunk = paths[i:i + batch_size]
        # Convert Path objects to strings
        chunk_strs = [str(p) for p in chunk]

        try:
            # Run du -sk on the chunk
            # We use check=False because du might return non-zero if some files are unreadable,
            # but it still prints output for readable ones.
            proc = subprocess.run(
                ["du", "-sk"] + chunk_strs,
                capture_output=True,
                text=True,
                check=False
            )

            # Parse output: "size_k\tpath"
            for line in proc.stdout.splitlines():
                parts = line.split('\t', 1)
                if len(parts) == 2:
                    try:
                        size_k = int(parts[0])
                        path_str = parts[1]
                        results[path_str] = size_k
                    except ValueError:
                        continue

        except Exception as e:
            print(f"{C_RED}Error processing batch: {e}{C_RESET}", file=sys.stderr)

    return results

def main():
    parser = argparse.ArgumentParser(description="Directory Size Analyzer")
    parser.add_argument("directory", nargs="?", default=".", help="Target directory")
    parser.add_argument("-n", "--limit", type=int, default=25, help="Results per page")
    parser.add_argument("-a", "--all", action="store_true", help="Include files")
    args = parser.parse_args()

    # Resolve target directory (handle symlinks).
    target_dir = Path(args.directory).resolve()

    if not target_dir.exists() or not target_dir.is_dir():
        print(f"{C_RED}Error: Directory '{target_dir}' not found.{C_RESET}", file=sys.stderr)
        sys.exit(1)

    print(f"{C_CYAN}Analyzing: {target_dir}{C_RESET}")
    print(f"{C_YELLOW}Calculating sizes...{C_RESET}")

    items_to_process = []

    try:
        # Collect items first.
        with os.scandir(target_dir) as it:
            for entry in it:
                if not args.all and not entry.is_dir():
                    continue

                if not (entry.is_dir() or entry.is_file()):
                     continue

                items_to_process.append(Path(entry.path))

    except PermissionError:
        print(f"{C_RED}Error: Permission denied accessing '{target_dir}'{C_RESET}", file=sys.stderr)
        sys.exit(1)

    if not items_to_process:
        print(f"{C_YELLOW}No items found in directory.{C_RESET}")
        return

    # Calculate sizes in batches.
    size_map = get_sizes_batched(items_to_process)

    # Build final items list.
    items = []
    for path in items_to_process:
        path_str = str(path)
        if path_str in size_map:
            size_val = size_map[path_str]
            size_str = format_size(size_val)
            item_type = "dir" if path.is_dir() else "file"

            items.append({
                "size_str": size_str,
                "size_val": size_val,
                "type": item_type,
                "name": path.name
            })

    # Sort by size descending.
    items.sort(key=lambda x: x["size_val"], reverse=True)

    total_items = len(items)
    print(f"{C_GREEN}Found {total_items} items{C_RESET}\n")

    # Check for Nushell.
    has_nu = shutil.which("nu") is not None
    import json

    # Pagination.
    offset = 0
    limit = args.limit

    while offset < total_items:
        chunk = items[offset:offset + limit]

        if has_nu:
            # Prepare data for Nushell.
            nu_data = []
            for item in chunk:
                nu_data.append({
                    "size": item['size_str'],
                    "type": item['type'],
                    "name": item['name']
                })

            json_str = json.dumps(nu_data)

            # Pass data via environment variable to avoid pipe issues.
            env = os.environ.copy()
            env["DIRSIZE_DATA"] = json_str

            try:
                subprocess.run(
                    ["nu", "-c", "$env.DIRSIZE_DATA | from json | table --width 100"],
                    env=env,
                    check=True
                )
            except subprocess.CalledProcessError:
                # Fallback if nu fails.
                print(f"{C_RED}Error rendering with Nushell, falling back to text.{C_RESET}")
                has_nu = False # Disable nu for subsequent pages.
                continue # Retry this chunk with text.
        else:
            # Print header
            print(f"{C_CYAN}{'Size':<10} {'Type':<6} {'Name'}{C_RESET}")
            print(f"{C_CYAN}{'─'*50}{C_RESET}")

            for item in chunk:
                print(f"{item['size_str']:<10} {item['type']:<6} {item['name']}")

        offset += len(chunk)

        if offset < total_items:
            print()
            try:
                response = input(f"{C_YELLOW}Show next {limit}? [y/N] {C_RESET}")
                if response.lower() != 'y':
                    print(f"\n{C_CYAN}Stopped at {offset}/{total_items} items.{C_RESET}")
                    break
            except (KeyboardInterrupt, EOFError):
                 print(f"\n{C_CYAN}Stopped.{C_RESET}")
                 break
            print()

    print(f"\n{C_GREEN}Total items displayed: {offset}/{total_items}{C_RESET}")

if __name__ == "__main__":
    main()

# ============================================================================ #
# End of dirsize.py
