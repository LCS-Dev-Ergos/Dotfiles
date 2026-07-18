#!/usr/bin/env python3

# ============================================================================ #
"""
Hash Generator and Updater (canonical blog backend):
This script calculates and updates SHA-256 hash values for all markdown (.md)
files in a specified directory. It maintains a record of these hashes in a
hash file, allowing for easy detection of changes to the files over time.

Author: XtremeXSPC
Version: 1.0.0
"""
# ============================================================================ #

import sys
import os
import hashlib
import tempfile

DEFAULT_HASH_FILE = ".file_hashes"


def calculate_hash(file_path):
    """
    Calculate the SHA-256 hash of a file.
    Args:
        file_path (str): The path to the file for which the hash is to be calculated.
    Returns:
        str: The SHA-256 hash of the file in hexadecimal format.
    """
    sha256 = hashlib.sha256()
    with open(file_path, "rb") as f:
        for block in iter(lambda: f.read(65536), b""):
            sha256.update(block)
    return sha256.hexdigest()


def load_existing_hashes(hash_file):
    """
    Load existing file hashes from a given file.
    This function reads a file containing file paths and their corresponding
    hashes, separated by a tab character, and returns a dictionary where the
    keys are file paths and the values are their respective hashes.
    Args:
        hash_file (str): The path to the file containing the hashes.
    Returns:
        dict: A dictionary with file paths as keys and their hashes as values.
              If the file does not exist, an empty dictionary is returned.
    """
    if not os.path.exists(hash_file):
        return {}
    hashes = {}
    with open(hash_file, "r", encoding="utf-8") as f:
        for line_number, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line:
                continue
            file_path, separator, file_hash = line.rpartition("\t")
            if not separator or not file_path or not file_hash:
                print(
                    f"Warning: skipping malformed line {line_number} in {hash_file}",
                    file=sys.stderr,
                )
                continue
            hashes[file_path] = file_hash
    return hashes


def save_hashes(hash_file, hashes):
    """
    Save file paths and their corresponding hashes to a file.
    Args:
        hash_file (str): The path to the file where the hashes will be saved.
        hashes (dict): A dictionary where keys are file paths and values are their
        corresponding hashes.
    """
    hash_dir = os.path.dirname(os.path.abspath(hash_file)) or "."
    fd, temp_path = tempfile.mkstemp(
        prefix=".file_hashes.", suffix=".tmp", dir=hash_dir
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            for file_path, file_hash in hashes.items():
                f.write(f"{file_path}\t{file_hash}\n")
        os.replace(temp_path, hash_file)
    except Exception:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        raise


def update_hashes(directory, hash_file=DEFAULT_HASH_FILE):
    """
    Updates the hash values of markdown files in the specified directory.
    This function walks through the given directory, calculates the hash values
    of all markdown (.md) files, and updates the existing hash values stored in
    a hash file. It also removes the hash values of files that are no longer present
    in the directory.
    Args:
        directory (str): The path to the directory containing markdown files.
    Returns:
        dict: A dictionary containing the updated hash values of the markdown files.
    """
    current_hashes = {}

    for root, _, files in os.walk(directory):
        for file in files:
            if not file.endswith(".md"):
                continue
            file_path = os.path.join(root, file)
            try:
                current_hashes[file_path] = calculate_hash(file_path)
            except OSError as exc:
                print(f"Warning: could not hash {file_path}: {exc}", file=sys.stderr)

    # The current scan is the complete record: entries for deleted files
    # disappear simply by not being re-added.
    save_hashes(hash_file, current_hashes)
    return current_hashes


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: generate_hashes.py <directory> [hash_file]", file=sys.stderr)
        sys.exit(1)

    directory = sys.argv[1]
    if not os.path.isdir(directory):
        print(f"Error: {directory} is not a valid directory.", file=sys.stderr)
        sys.exit(1)

    hash_file = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_HASH_FILE
    hash_parent = os.path.dirname(os.path.abspath(hash_file))
    os.makedirs(hash_parent, mode=0o700, exist_ok=True)
    updated_hashes = update_hashes(directory, hash_file)
    print(f"Updated hashes for {len(updated_hashes)} files.")

# ============================================================================ #
# End of generate_hashes.py
