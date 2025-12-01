#!/usr/bin/env python3

# ============================================================================ #
"""
Hash Generator and Updater:
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

HASH_FILE = ".file_hashes"


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
        for line in f:
            file_path, file_hash = line.strip().split("\t")
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
    with open(hash_file, "w", encoding="utf-8") as f:
        for file_path, file_hash in hashes.items():
            f.write(f"{file_path}\t{file_hash}\n")


def update_hashes(directory):
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
    existing_hashes = load_existing_hashes(HASH_FILE)
    current_hashes = {}

    for root, _, files in os.walk(directory):
        for file in files:
            if file.endswith(".md"):
                file_path = os.path.join(root, file)
                current_hash = calculate_hash(file_path)
                current_hashes[file_path] = current_hash

    # Remove hashes of files that are no longer present.
    updated_hashes = {**existing_hashes, **current_hashes}
    for file_path in list(updated_hashes.keys()):
        if file_path not in current_hashes:
            del updated_hashes[file_path]

    # Save updated hashes.
    save_hashes(HASH_FILE, updated_hashes)
    return updated_hashes


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: update_hashes.py <directory>", file=sys.stderr)
        sys.exit(1)

    directory = sys.argv[1]
    if not os.path.isdir(directory):
        print(f"Error: {directory} is not a valid directory.", file=sys.stderr)
        sys.exit(1)

    updated_hashes = update_hashes(directory)
    print(f"Updated hashes for {len(updated_hashes)} files.")

# ============================================================================ #
# End of generate_hashes.py
