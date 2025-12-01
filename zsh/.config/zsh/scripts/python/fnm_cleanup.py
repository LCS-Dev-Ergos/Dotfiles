#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# ============================================================================ #
"""
FNM Symlink Cleanup Utility:
Removes stale symbolic links from the FNM (Fast Node Manager) multishells
directory. A link is considered stale if both the link itself and its target
have been inactive for more than 24 hours. Designed for periodic execution
via cron or systemd timer.

Author: XtremeXSPC
Version: 1.0.0
"""
# ============================================================================ #

import pathlib
import sys
import time

def main():
    """
    Finds and removes stale FNM (Fast Node Manager) symbolic links.
    A link is considered stale if it has not been touched in the last 24 hours.
    This script is intended to be run periodically by a cron job.
    """

    # Define the path to the FNM multishells directory.
    fnm_multishells_dir = pathlib.Path.home() / ".local/state/fnm_multishells"

    if not fnm_multishells_dir.is_dir():
        return

    # Calculate the timestamp for 24 hours ago.
    # time.time() returns seconds since the Epoch.
    stale_threshold_seconds = 24 * 60 * 60
    current_time = time.time()

    # Iterate over all items in the directory.
    for path_item in fnm_multishells_dir.iterdir():
        # We only care about symbolic links.
        if not path_item.is_symlink():
            continue

        try:
            link_stat = path_item.lstat()  # stats of the symlink itself
            # If the target is missing, the link is stale by definition.
            if not path_item.exists():
                path_item.unlink()
                continue

            target_stat = path_item.stat()  # follows symlink

            link_age = current_time - link_stat.st_mtime
            target_inactive = current_time - target_stat.st_atime

            # If both the link itself and its target have been idle long enough, drop it.
            if link_age > stale_threshold_seconds and target_inactive > stale_threshold_seconds:
                # print(f"Removing stale FNM link: {path_item}") # Uncomment for debugging
                path_item.unlink()

        except FileNotFoundError:
            # The link might be broken or was deleted by another process.
            # In this case, it's safe to just continue.
            continue
        except OSError as e:
            # Catch other potential filesystem errors.
            print(f"fnm_cleanup: error processing {path_item}: {e}", file=sys.stderr)

if __name__ == "__main__":
    main()

# ============================================================================ #
# End of fnm_cleanup.py
