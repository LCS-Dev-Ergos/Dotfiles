#!/usr/bin/env python3

# ============================================================================ #
"""
GPT Fix Math Syntax (Single File):
CLI utility that converts LaTeX-like math syntax in one Markdown document into
KaTeX-compatible Markdown delimiters.

Typical usage:
  ./GPT_fix_math_syntax.py notes.md --dry-run
  ./GPT_fix_math_syntax.py notes.md --backup

Author: Codex (GPT-5)
Version: 1.0.0
"""
# ============================================================================ #

from __future__ import annotations

import argparse
from pathlib import Path
import sys

from GPT_math_syntax_converter import (
    MarkdownMathConverter,
    backup_file,
    convert_markdown_file,
    write_text_atomic,
)


def build_parser() -> argparse.ArgumentParser:
    """Build and return CLI arguments for single-file conversion."""
    parser = argparse.ArgumentParser(
        description="Convert LaTeX-like math syntax into KaTeX-compatible Markdown"
    )
    parser.add_argument("markdown_file", help="Path to the Markdown file to process")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show conversion stats without modifying the file",
    )
    parser.add_argument(
        "--backup",
        action="store_true",
        help="Create a .bak copy before writing changes",
    )
    parser.add_argument(
        "--no-operator-subscripts",
        action="store_true",
        help="Do not convert operator subscripts such as min_i",
    )
    return parser


def print_summary(file_path: Path, changed: bool, stats) -> None:
    """Print a compact conversion summary for one file."""
    print("=" * 64)
    print(f"File: {file_path}")
    print(f"Changed: {'yes' if changed else 'no'}")
    print(f"Total conversions: {stats.total}")
    print("-" * 64)
    print(f"  escaped display  \\\\[...\\\\] : {stats.escaped_display}")
    print(f"  escaped inline   \\\\(...\\\\) : {stats.escaped_inline}")
    print(f"  bare [math] lines          : {stats.bare_bracket_lines}")
    print(f"  parenthesized LaTeX (...)  : {stats.parenthesized_latex}")
    print(f"  operator subscripts        : {stats.operator_subscripts}")
    print("=" * 64)


def main() -> int:
    """Run CLI flow: parse args, convert file, optionally write output."""
    args = build_parser().parse_args()
    file_path = Path(args.markdown_file).expanduser().resolve()

    if not file_path.exists():
        print(f"Error: file not found: {file_path}", file=sys.stderr)
        return 2
    if not file_path.is_file():
        print(f"Error: not a file: {file_path}", file=sys.stderr)
        return 2

    converter = MarkdownMathConverter(
        convert_operator_subscripts=not args.no_operator_subscripts
    )

    try:
        _, converted, stats, changed = convert_markdown_file(file_path, converter)
    except OSError as exc:
        print(f"Error reading file {file_path}: {exc}", file=sys.stderr)
        return 2

    print_summary(file_path, changed, stats)
    if not changed:
        print("No changes needed.")
        return 0

    if args.dry_run:
        print("[DRY-RUN] No file was modified.")
        return 0

    if args.backup:
        backup_path = Path(f"{file_path}.bak")
        try:
            backup_file(file_path, backup_path)
            print(f"Backup written to: {backup_path}")
        except OSError as exc:
            print(f"Error creating backup {backup_path}: {exc}", file=sys.stderr)
            return 2

    try:
        write_text_atomic(file_path, converted)
    except OSError as exc:
        print(f"Error writing file {file_path}: {exc}", file=sys.stderr)
        return 2

    print(f"Updated: {file_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# ============================================================================ #
# End of GPT_fix_math_syntax.py
