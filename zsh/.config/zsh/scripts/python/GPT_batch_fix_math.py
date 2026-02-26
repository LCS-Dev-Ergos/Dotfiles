#!/usr/bin/env python3

# ============================================================================ #
"""
GPT Batch Fix Math:
Batch CLI utility for converting LaTeX-like math syntax across multiple
Markdown files in a directory tree.

Typical usage:
  ./GPT_batch_fix_math.py /path/to/docs --dry-run
  ./GPT_batch_fix_math.py /path/to/docs --pattern '*.md' --backup-dir /tmp/backup

Author: Codex (GPT-5)
Version: 1.0.0
"""
# ============================================================================ #

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import sys

from GPT_math_syntax_converter import (
    ConversionStats,
    MarkdownMathConverter,
    backup_file,
    convert_markdown_file,
    write_text_atomic,
)


@dataclass
class FileResult:
    file: Path
    status: str
    changes: int = 0
    error: str | None = None


def build_parser() -> argparse.ArgumentParser:
    """Build and return CLI arguments for batch conversion."""
    parser = argparse.ArgumentParser(
        description="Batch convert LaTeX-like math syntax in Markdown files"
    )
    parser.add_argument("directory", help="Root directory containing Markdown files")
    parser.add_argument(
        "--no-recursive",
        "-nr",
        action="store_true",
        help="Only process files in the top-level directory",
    )
    parser.add_argument(
        "--pattern",
        "-p",
        default="*.md",
        help="Glob pattern for target files (default: *.md)",
    )
    parser.add_argument(
        "--dry-run",
        "-d",
        action="store_true",
        help="Show what would change without writing files",
    )
    parser.add_argument(
        "--backup-dir",
        help="Directory where original files are copied before write",
    )
    parser.add_argument(
        "--no-operator-subscripts",
        action="store_true",
        help="Do not convert operator subscripts such as min_i",
    )
    return parser


def iter_target_files(directory: Path, pattern: str, recursive: bool) -> list[Path]:
    """Collect and sort matching files under the target directory."""
    iterator = directory.rglob(pattern) if recursive else directory.glob(pattern)
    files = [path for path in iterator if path.is_file()]
    files.sort()
    return files


def print_report(
    directory: Path,
    dry_run: bool,
    results: list[FileResult],
    aggregate: ConversionStats,
) -> None:
    """Print aggregate stats and per-file outcomes for the batch run."""
    total_files = len(results)
    modified = [r for r in results if r.status in {"modified", "would-modify"}]
    unchanged = [r for r in results if r.status == "unchanged"]
    errors = [r for r in results if r.status == "error"]

    print("=" * 72)
    print("BATCH MATH CONVERSION REPORT")
    print("=" * 72)
    print(f"Directory:   {directory}")
    print(f"Mode:        {'dry-run' if dry_run else 'write'}")
    print(f"Files seen:  {total_files}")
    print(f"Modified:    {len(modified)}")
    print(f"Unchanged:   {len(unchanged)}")
    print(f"Errors:      {len(errors)}")
    print("-" * 72)
    print(f"Total conversions: {aggregate.total}")
    print(f"  escaped display  \\\\[...\\\\] : {aggregate.escaped_display}")
    print(f"  escaped inline   \\\\(...\\\\) : {aggregate.escaped_inline}")
    print(f"  bare [math] lines          : {aggregate.bare_bracket_lines}")
    print(f"  parenthesized LaTeX (...)  : {aggregate.parenthesized_latex}")
    print(f"  operator subscripts        : {aggregate.operator_subscripts}")
    print("=" * 72)

    if modified:
        print("\nChanged files:")
        for result in modified:
            marker = "would modify" if result.status == "would-modify" else "modified"
            print(f"  - {result.file} ({result.changes} conversions, {marker})")

    if errors:
        print("\nErrors:")
        for result in errors:
            print(f"  - {result.file}: {result.error}")


def main() -> int:
    """Run CLI flow for directory processing and report final status."""
    args = build_parser().parse_args()
    directory = Path(args.directory).expanduser().resolve()

    if not directory.exists():
        print(f"Error: directory not found: {directory}", file=sys.stderr)
        return 2
    if not directory.is_dir():
        print(f"Error: not a directory: {directory}", file=sys.stderr)
        return 2

    backup_root = None
    if args.backup_dir:
        backup_root = Path(args.backup_dir).expanduser().resolve()

    files = iter_target_files(
        directory=directory,
        pattern=args.pattern,
        recursive=not args.no_recursive,
    )

    converter = MarkdownMathConverter(
        convert_operator_subscripts=not args.no_operator_subscripts
    )

    results: list[FileResult] = []
    aggregate = ConversionStats()

    for file_path in files:
        try:
            _, converted, stats, changed = convert_markdown_file(file_path, converter)
            aggregate.merge(stats)

            if not changed:
                results.append(FileResult(file=file_path, status="unchanged", changes=0))
                continue

            if args.dry_run:
                results.append(
                    FileResult(
                        file=file_path,
                        status="would-modify",
                        changes=stats.total,
                    )
                )
                continue

            if backup_root is not None:
                relative = file_path.relative_to(directory)
                backup_path = backup_root / relative
                backup_file(file_path, backup_path)

            write_text_atomic(file_path, converted)
            results.append(
                FileResult(file=file_path, status="modified", changes=stats.total)
            )
        except OSError as exc:
            results.append(
                FileResult(file=file_path, status="error", changes=0, error=str(exc))
            )

    print_report(directory, args.dry_run, results, aggregate)
    return 0 if not any(r.status == "error" for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())

# ============================================================================ #
# End of GPT_batch_fix_math.py
