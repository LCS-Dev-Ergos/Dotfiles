#!/usr/bin/env python3

# ============================================================================ #
"""
Directory Size Analyzer:
Interactive tool for analyzing and displaying directory sizes with pagination
support. Features batch size calculation using du, human-readable formatting,
and optional Gum table rendering with a native text fallback. Can include files
with the --all flag.

Author: XtremeXSPC
Version: 2.0.0

Changes in 2.0.0:
- Null-terminated du output parsing (handles filenames with newlines).
- Parallel batch processing with ThreadPoolExecutor.
- Improved error handling and user feedback.
- Signal handling during long operations.
- Better encoding handling.
"""
# ============================================================================ #

import os
import sys
import argparse
import subprocess
import shutil
import csv
import io
import signal
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Dict, List, Tuple

# ++++++++++++++++++++++++++++++++ Constants +++++++++++++++++++++++++++++++++ #

BATCH_SIZE = 128
MAX_WORKERS = 4
MAX_WORKER_LIMIT = 32

# ANSI color codes
C_CYAN = "\033[0;36m"
C_YELLOW = "\033[0;33m"
C_GREEN = "\033[0;32m"
C_RED = "\033[0;31m"
C_DIM = "\033[2m"
C_RESET = "\033[0m"

# Global flag for graceful interruption
_interrupted = False


def positive_int(value: str) -> int:
    """Parse an argparse integer that must be greater than zero."""
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def worker_count(value: str) -> int:
    """Parse a bounded worker count to avoid accidental resource exhaustion."""
    parsed = positive_int(value)
    if parsed > MAX_WORKER_LIMIT:
        raise argparse.ArgumentTypeError(f"must not exceed {MAX_WORKER_LIMIT}")
    return parsed


# +++++++++++++++++++++++++++++ Signal Handling ++++++++++++++++++++++++++++++ #


def _signal_handler(signum, frame):
    """Handle interrupt signals gracefully."""
    global _interrupted
    _interrupted = True
    print(
        f"\n{C_YELLOW}Interrupt requested; finishing current batch...{C_RESET}",
        file=sys.stderr,
    )


def setup_signal_handlers():
    """Install signal handlers for graceful shutdown."""
    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)


# +++++++++++++++++++++++++++++ Size Formatting ++++++++++++++++++++++++++++++ #


def format_size(size_k: int) -> str:
    """
    Convert size in KB to human readable string.

    Args:
        size_k: Size in kilobytes.

    Returns:
        Human-readable size string (e.g., "1.5G").
    """
    size_bytes = size_k * 1024
    for unit in ["B", "K", "M", "G", "T", "P"]:
        if size_bytes < 1024:
            return f"{size_bytes:.1f}{unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f}E"


# +++++++++++++++++++++++++++++ Size Calculation +++++++++++++++++++++++++++++ #


def process_single_batch(paths: List[str]) -> Tuple[Dict[str, int], List[str]]:
    """
    Process a single batch of paths with du -sk0.

    Args:
        paths: List of path strings to process.

    Returns:
        Tuple of (results dict, errors list).
    """
    results = {}
    errors = []

    if not paths:
        return results, errors

    # macOS/BSD du does not support NUL-delimited output. Run it once per path
    # there so a newline in a filename cannot corrupt record boundaries.
    try:
        if sys.platform == "darwin":
            for path in paths:
                if _interrupted:
                    break
                proc = subprocess.run(
                    ["du", "-sk", path],
                    capture_output=True,
                    check=False,
                    timeout=300,
                )
                if proc.stdout:
                    try:
                        size_text = proc.stdout.split(b"\t", 1)[0].strip()
                        results[path] = int(size_text)
                    except ValueError as exc:
                        errors.append(f"Parse error for {path!r}: {exc}")
                if proc.stderr:
                    stderr_text = proc.stderr.decode("utf-8", errors="replace").strip()
                    if stderr_text:
                        errors.extend(
                            line for line in stderr_text.splitlines() if line.strip()
                        )
            return results, errors

        # Run du command with null-terminated output.
        cmd = ["du", "-sk0", "--"]
        proc = subprocess.run(
            cmd + paths, capture_output=True, check=False, timeout=300
        )

        # Format: "size_k\tpath\0size_k\tpath\0..."
        entries = proc.stdout.split(b"\0")

        for entry in entries:
            if not entry:
                continue

            try:
                decoded = entry.decode("utf-8", errors="surrogateescape")
                parts = decoded.split("\t", 1)

                if len(parts) == 2:
                    size_k = int(parts[0])
                    path_str = parts[1]
                    results[path_str] = size_k

            except (ValueError, UnicodeDecodeError) as e:
                errors.append(f"Parse error: {e}")

        # Capture stderr warnings
        if proc.stderr:
            stderr_text = proc.stderr.decode("utf-8", errors="replace").strip()
            if stderr_text:
                for line in stderr_text.splitlines():
                    if line.strip():
                        errors.append(line)

    except subprocess.TimeoutExpired:
        errors.append("Batch timeout expired (300s)")
    except FileNotFoundError:
        errors.append("'du' command not found")
    except Exception as e:
        errors.append(f"Batch processing error: {e}")

    return results, errors


def get_sizes_batched(
    paths: List[str],
    batch_size: int = BATCH_SIZE,
    parallel: bool = True,
    max_workers: int = MAX_WORKERS,
) -> Tuple[Dict[str, int], List[str]]:
    """
    Calculate sizes of multiple paths using du -sk0 in batches.

    Args:
        paths: List of path strings to measure.
        batch_size: Number of paths per batch.
        parallel: Enable parallel batch processing.
        max_workers: Maximum concurrent workers.

    Returns:
        Tuple of (results dict {path: size_k}, all_errors list).
    """
    global _interrupted

    results = {}
    all_errors = []

    # Split into batches
    batches = [paths[i : i + batch_size] for i in range(0, len(paths), batch_size)]

    if not batches:
        return results, all_errors

    if parallel and len(batches) > 1:
        # Parallel processing
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = {
                executor.submit(process_single_batch, batch): i
                for i, batch in enumerate(batches)
            }

            for future in as_completed(futures):
                if _interrupted:
                    executor.shutdown(wait=False, cancel_futures=True)
                    break

                try:
                    batch_results, batch_errors = future.result()
                    results.update(batch_results)
                    all_errors.extend(batch_errors)
                except Exception as e:
                    all_errors.append(f"Future error: {e}")
    else:
        # Sequential processing
        for batch in batches:
            if _interrupted:
                break

            batch_results, batch_errors = process_single_batch(batch)
            results.update(batch_results)
            all_errors.extend(batch_errors)

    return results, all_errors


# ++++++++++++++++++++++++++++ Directory Scanning ++++++++++++++++++++++++++++ #


def scan_directory(
    target_dir: Path, include_files: bool = False
) -> Tuple[List[str], Dict[str, str], List[str]]:
    """
    Scan directory and collect items to process.

    Args:
        target_dir: Directory to scan.
        include_files: Include files (not just directories).

    Returns:
        Tuple of (path_strings, type_map {path: type}, warnings).
    """
    paths = []
    type_map = {}  # path_str -> "dir" | "file" | "link"
    warnings = []

    try:
        with os.scandir(target_dir) as it:
            for entry in it:
                try:
                    is_dir = entry.is_dir(follow_symlinks=False)
                    is_file = entry.is_file(follow_symlinks=False)
                    is_link = entry.is_symlink()
                    target_is_dir = False
                    target_is_file = False
                    if is_link:
                        target_is_dir = entry.is_dir(follow_symlinks=True)
                        target_is_file = entry.is_file(follow_symlinks=True)

                    # Default mode includes real directories and links to
                    # directories. --all additionally includes files and
                    # broken links, but still excludes special files.
                    if not include_files and not (is_dir or target_is_dir):
                        continue

                    # Skip special files (sockets, devices, etc.)
                    if not (is_dir or is_file or is_link):
                        continue

                    path_str = entry.path
                    paths.append(path_str)

                    # Determine type with symlink annotation
                    if is_link:
                        # Check if symlink target exists
                        try:
                            target_exists = os.path.exists(path_str)
                            if target_is_dir:
                                base_type = "dir"
                            elif target_is_file:
                                base_type = "file"
                            else:
                                base_type = "link"
                            type_map[path_str] = (
                                f"{base_type}@" if target_exists else "link!"
                            )
                            if not target_exists:
                                warnings.append(f"Broken symlink: {entry.name}")
                        except (OSError, RuntimeError):
                            type_map[path_str] = "link!"
                            warnings.append(f"Unresolvable symlink: {entry.name}")
                    else:
                        type_map[path_str] = "dir" if is_dir else "file"

                except OSError as e:
                    warnings.append(f"Cannot access '{entry.name}': {e.strerror}")

    except PermissionError:
        raise
    except OSError as e:
        raise RuntimeError(f"Failed to scan directory: {e.strerror}")

    return paths, type_map, warnings


# +++++++++++++++++++++++++++++ Output Rendering +++++++++++++++++++++++++++++ #


def resolve_ui_mode() -> str:
    """Resolve the shared auto/plain/ansi/gum presentation policy."""
    requested = os.environ.get("ZSH_UI_STYLE", "auto").lower()
    if os.environ.get("NO_COLOR"):
        return "plain"
    if requested not in {"auto", "plain", "ansi", "gum"}:
        raise ValueError(f"invalid ZSH_UI_STYLE: {requested}")
    if requested == "auto":
        if not sys.stdout.isatty() or os.environ.get("TERM", "dumb") == "dumb":
            return "plain"
        return "gum" if shutil.which("gum") else "ansi"
    if requested == "gum" and not shutil.which("gum"):
        return "ansi" if sys.stdout.isatty() else "plain"
    return requested


def configure_colors(mode: str) -> None:
    """Disable ANSI constants when plain output was requested."""
    if mode != "plain":
        return
    global C_CYAN, C_YELLOW, C_GREEN, C_RED, C_DIM, C_RESET
    C_CYAN = C_YELLOW = C_GREEN = C_RED = C_DIM = C_RESET = ""


def sanitize_display_text(value: str) -> str:
    """Escape terminal control characters while preserving normal Unicode."""
    escaped = []
    for character in value:
        codepoint = ord(character)
        if character == "\n":
            escaped.append(r"\n")
        elif character == "\r":
            escaped.append(r"\r")
        elif character == "\t":
            escaped.append(r"\t")
        elif codepoint < 32 or codepoint == 127 or 128 <= codepoint <= 159:
            escaped.append(f"\\x{codepoint:02x}")
        else:
            escaped.append(character)
    return "".join(escaped)


def render_with_gum(items: List[dict]) -> bool:
    """
    Render items using one static Gum table.

    Args:
        items: List of item dicts with 'size', 'type', 'name' keys.

    Returns:
        True if successful, False otherwise.
    """
    data = io.StringIO(newline="")
    writer = csv.writer(data)
    writer.writerows((item["size_str"], item["type"], item["name"]) for item in items)

    try:
        # The child writes directly to the terminal; flush Python's buffered
        # progress lines first so redirected and captured output stays ordered.
        sys.stdout.flush()
        subprocess.run(
            [
                "gum",
                "table",
                "--print",
                "--separator",
                ",",
                "--columns",
                "Size,Type,Name",
                "--border",
                "rounded",
                "--border.foreground",
                "212",
                "--header.foreground",
                "75",
            ],
            input=data.getvalue(),
            text=True,
            check=True,
            timeout=30,
        )
        return True
    except (
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
        FileNotFoundError,
        OSError,
    ):
        return False


def confirm_next_page(prompt: str, ui_mode: str) -> bool:
    """Request pagination confirmation, with a native fallback for Gum errors."""
    if ui_mode == "gum":
        try:
            return (
                subprocess.run(
                    ["gum", "confirm", "--default=false", prompt],
                    check=False,
                    timeout=30,
                ).returncode
                == 0
            )
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            pass

    response = input(f"{C_YELLOW}{prompt} [y/N] {C_RESET}")
    return response.lower() in {"y", "yes"}


def render_text_table(items: List[dict]):
    """
    Render items as plain text table.

    Args:
        items: List of item dicts with 'size_str', 'type', 'name' keys.
    """
    print(f"{C_CYAN}{'Size':<10} {'Type':<7} {'Name'}{C_RESET}")
    print(f"{C_CYAN}{'-' * 60}{C_RESET}")

    for item in items:
        type_str = item["type"]
        # Color broken links
        if type_str == "link!":
            type_colored = f"{C_RED}{type_str:<7}{C_RESET}"
        elif type_str.endswith("@"):
            type_colored = f"{C_DIM}{type_str:<7}{C_RESET}"
        else:
            type_colored = f"{type_str:<7}"

        print(f"{item['size_str']:<10} {type_colored} {item['name']}")


# +++++++++++++++++++++++++++++++++++ Main +++++++++++++++++++++++++++++++++++ #


def main():
    global _interrupted

    parser = argparse.ArgumentParser(
        description="Directory Size Analyzer",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n"
        "  %(prog)s                      # Analyze current directory\n"
        "  %(prog)s /var/log -a          # Include files, analyze /var/log\n"
        "  %(prog)s -n 50 --no-parallel  # 50 items per page, "
        "sequential processing",
    )
    parser.add_argument(
        "directory",
        nargs="?",
        default=".",
        help="Target directory to analyze (default: current)",
    )
    parser.add_argument(
        "-n",
        "--limit",
        type=positive_int,
        default=25,
        metavar="N",
        help="Number of results per page (default: 25)",
    )
    parser.add_argument(
        "-a",
        "--all",
        action="store_true",
        help="Include files in analysis (not just directories)",
    )
    parser.add_argument(
        "--no-parallel", action="store_true", help="Disable parallel batch processing"
    )
    parser.add_argument(
        "-w",
        "--workers",
        type=worker_count,
        default=MAX_WORKERS,
        metavar="N",
        help=f"Max parallel workers (default: {MAX_WORKERS})",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Show detailed warnings and errors"
    )
    args = parser.parse_args()

    try:
        ui_mode = resolve_ui_mode()
    except ValueError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(2)
    configure_colors(ui_mode)

    # Setup signal handlers
    setup_signal_handlers()

    # Resolve target directory
    try:
        target_dir = Path(args.directory).resolve()
    except OSError as exc:
        print(f"{C_RED}Error: Cannot resolve path: {exc}{C_RESET}", file=sys.stderr)
        sys.exit(1)

    if not target_dir.exists():
        print(
            f"{C_RED}Error: Path '{args.directory}' does not exist.{C_RESET}",
            file=sys.stderr,
        )
        sys.exit(1)

    if not target_dir.is_dir():
        print(
            f"{C_RED}Error: '{args.directory}' is not a directory.{C_RESET}",
            file=sys.stderr,
        )
        sys.exit(1)

    display_target = sanitize_display_text(str(target_dir))
    print(f"{C_CYAN}Analyzing: {display_target}{C_RESET}")

    # Scan directory
    try:
        print(f"{C_YELLOW}Scanning directory...{C_RESET}")
        paths, type_map, scan_warnings = scan_directory(target_dir, args.all)
    except PermissionError:
        print(
            f"{C_RED}Error: Permission denied accessing '{target_dir}'{C_RESET}",
            file=sys.stderr,
        )
        sys.exit(1)
    except RuntimeError as e:
        print(f"{C_RED}Error: {e}{C_RESET}", file=sys.stderr)
        sys.exit(1)

    if args.verbose and scan_warnings:
        print(f"{C_DIM}Scan warnings:{C_RESET}")
        for w in scan_warnings[:10]:  # Limit output
            print(f"{C_DIM}  - {sanitize_display_text(w)}{C_RESET}")
        if len(scan_warnings) > 10:
            print(f"{C_DIM}  ... and {len(scan_warnings) - 10} more{C_RESET}")

    if not paths:
        print(f"{C_YELLOW}No items found in directory.{C_RESET}")
        return

    # Calculate sizes
    parallel = not args.no_parallel
    mode = "parallel" if parallel else "sequential"
    print(f"{C_YELLOW}Calculating sizes ({mode})...{C_RESET}")

    size_map, calc_errors = get_sizes_batched(
        paths, parallel=parallel, max_workers=args.workers
    )

    if _interrupted:
        print(f"{C_YELLOW}Operation interrupted.{C_RESET}")
        sys.exit(130)

    if args.verbose and calc_errors:
        print(f"{C_DIM}Calculation errors:{C_RESET}")
        for e in calc_errors[:10]:
            print(f"{C_DIM}  - {sanitize_display_text(e)}{C_RESET}")
        if len(calc_errors) > 10:
            print(f"{C_DIM}  ... and {len(calc_errors) - 10} more{C_RESET}")

    # Build items list
    items = []
    missing_count = 0

    for path_str in paths:
        if path_str in size_map:
            size_val = size_map[path_str]
            size_str = format_size(size_val)
            item_type = type_map.get(path_str, "?")
            name = sanitize_display_text(Path(path_str).name)

            items.append(
                {
                    "size_str": size_str,
                    "size_val": size_val,
                    "type": item_type,
                    "name": name,
                }
            )
        else:
            missing_count += 1

    if missing_count > 0 and args.verbose:
        print(
            f"{C_DIM}Note: {missing_count} items could not be measured "
            f"(possibly deleted){C_RESET}"
        )

    # Sort by size descending
    items.sort(key=lambda x: x["size_val"], reverse=True)

    total_items = len(items)
    print(f"{C_GREEN}Found {total_items} items{C_RESET}\n")

    # Pagination
    offset = 0
    limit = args.limit

    while offset < total_items:
        if _interrupted:
            break

        chunk = items[offset : offset + limit]

        if ui_mode == "gum":
            if not render_with_gum(chunk):
                print(f"{C_YELLOW}Gum rendering failed; using native output.{C_RESET}")
                ui_mode = "ansi" if sys.stdout.isatty() else "plain"
                configure_colors(ui_mode)
                render_text_table(chunk)
        else:
            render_text_table(chunk)

        offset += len(chunk)

        if offset < total_items:
            print()
            try:
                remaining = total_items - offset
                prompt_count = min(limit, remaining)
                confirmed = confirm_next_page(f"Show next {prompt_count}?", ui_mode)
                if not confirmed:
                    print(
                        f"\n{C_CYAN}Stopped at {offset}/{total_items} items.{C_RESET}"
                    )
                    break
            except (KeyboardInterrupt, EOFError):
                print(f"\n{C_CYAN}Stopped.{C_RESET}")
                break
            print()

    # Summary
    total_size = sum(it["size_val"] for it in items)
    print(f"\n{C_GREEN}Displayed: {min(offset, total_items)}/{total_items} items")
    print(f"Total size: {format_size(total_size)}{C_RESET}")


if __name__ == "__main__":
    main()

# ============================================================================ #
# End of dirsize.py
