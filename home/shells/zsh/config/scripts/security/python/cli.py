#!/usr/bin/env python3

# ============================================================================ #
"""
Security Scan - Command-Line Interface:
Reusable file/folder security scanner combining three independent layers:

    1. Structural checks (always on, stdlib + optional pikepdf):
       signature/extension mismatch, embedded PE/ELF executables, PDF
       auto-run vectors (/Launch, /JavaScript, /OpenAction, embedded files),
       dangerous file types bundled inside EPUB/ZIP archives.
    2. YARA (optional, if `yara` CLI is installed): pattern matching against
       the bundled `yara/document-threats.yar` ruleset, or any ruleset you
       point it at.
    3. ClamAV (optional, if `clamscan`/`clamdscan` is installed): full
       signature-based antivirus scan.

Each layer is skipped (not failed) when its tool is unavailable, and the
summary reports exactly what ran vs. what was skipped, so results are never
silently incomplete.

Usage:
    python3 cli.py scan <path> [<path> ...] [options]

Exit codes (mirrors `clamscan`'s convention):
    0   scan completed, nothing suspicious found
    1   scan completed, at least one finding was reported
    2   the scan itself could not run (bad arguments, unreadable path, ...)

Author: Claude (Anthropic)
Version: 1.0.0
"""
# ============================================================================ #

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import external_scanners
import structural_checks
from report import (
    FileReport,
    ScanSummary,
    build_json_report,
    print_file_report,
    print_progress,
    print_status,
    print_summary,
    sha256_file,
    write_json_report,
)

DEFAULT_YARA_RULES = Path(__file__).resolve().parent.parent / "yara" / "document-threats.yar"


# +++++++++++++++++++++++++++++ Path Collection ++++++++++++++++++++++++++++++ #

def collect_files(paths: list[Path], *, recursive: bool) -> list[Path]:
    """Expand a mix of files and directories into a flat, de-duplicated file list."""
    seen: set[Path] = set()
    files: list[Path] = []

    for raw in paths:
        resolved = raw.expanduser()
        if resolved.is_file():
            if resolved not in seen:
                seen.add(resolved)
                files.append(resolved)
            continue
        if resolved.is_dir():
            iterator = resolved.rglob("*") if recursive else resolved.glob("*")
            for candidate in sorted(iterator):
                if candidate.is_file() and candidate not in seen:
                    seen.add(candidate)
                    files.append(candidate)
            continue
        print_status("warn", f"Skipping path (not found): {resolved}", stream=sys.stderr)

    return files


# +++++++++++++++++++++++++++++++++ Scanning +++++++++++++++++++++++++++++++++ #

def scan_one_file(
    path: Path,
    *,
    run_structural: bool,
    run_yara: bool,
    yara_rules: Path,
    compute_hash: bool,
) -> FileReport:
    """Run every enabled check layer against a single file."""
    try:
        size_bytes = path.stat().st_size
    except OSError as exc:
        report = FileReport(path=path, size_bytes=0, sha256=None)
        report.errors.append(f"Could not stat file: {exc}")
        return report

    report = FileReport(
        path=path,
        size_bytes=size_bytes,
        sha256=sha256_file(path) if compute_hash else None,
    )

    if run_structural:
        report.checks_run.append("structural")
        try:
            report.findings.extend(structural_checks.run(path))
        except Exception as exc:  # defensive: never let one bad file kill the run
            report.errors.append(f"Structural check failed: {exc}")

    if run_yara:
        report.checks_run.append("yara")
        report.findings.extend(external_scanners.run_yara(yara_rules, path))

    return report


def run_scan(
    files: list[Path],
    *,
    run_structural: bool,
    run_yara: bool,
    yara_rules: Path,
    run_clamav: bool,
    compute_hash: bool,
) -> tuple[list[FileReport], ScanSummary]:
    """Scan every file, applying batch-friendly layers (ClamAV) once at the end."""
    reports: dict[Path, FileReport] = {}
    total = len(files)
    show_progress = run_structural or run_yara

    for index, path in enumerate(files, start=1):
        reports[path] = scan_one_file(
            path,
            run_structural=run_structural,
            run_yara=run_yara,
            yara_rules=yara_rules,
            compute_hash=compute_hash,
        )
        if show_progress:
            print_progress(index, total, "Structural/YARA")

    if run_clamav and files:
        print_status("info", f"Running ClamAV on {len(files)} file(s) — this can take a while...")
        clamav_hits = external_scanners.run_clamav(files)
        for hit_path, findings in clamav_hits.items():
            # ClamAV may report an absolute path formatted slightly differently
            # (e.g. resolved symlinks); match on resolved path as a fallback.
            target = reports.get(hit_path)
            if target is None:
                for candidate_path, candidate_report in reports.items():
                    if candidate_path.resolve() == hit_path.resolve():
                        target = candidate_report
                        break
            if target is not None:
                if "clamav" not in target.checks_run:
                    target.checks_run.append("clamav")
                target.findings.extend(findings)
        for report in reports.values():
            if "clamav" not in report.checks_run:
                report.checks_run.append("clamav")

    ordered_reports = [reports[p] for p in files]
    summary = ScanSummary()
    for report in ordered_reports:
        summary.register(report)
    return ordered_reports, summary


# +++++++++++++++++++++++++++++++++++ CLI ++++++++++++++++++++++++++++++++++++ #

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="security_scan",
        description="Scan files or folders for structural red flags, YARA matches, and ClamAV hits.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    scan_parser = subparsers.add_parser("scan", help="Scan one or more files/folders.")
    scan_parser.add_argument("paths", nargs="+", type=Path, help="Files and/or directories to scan.")
    scan_parser.add_argument(
        "--recursive", dest="recursive", action="store_true", default=True,
        help="Recurse into subdirectories (default: on).",
    )
    scan_parser.add_argument(
        "--no-recursive", dest="recursive", action="store_false",
        help="Do not recurse into subdirectories.",
    )
    scan_parser.add_argument(
        "--no-structural", dest="structural", action="store_false", default=True,
        help="Disable the built-in structural checks.",
    )
    scan_parser.add_argument(
        "--no-yara", dest="yara", action="store_false", default=True,
        help="Disable YARA even if the `yara` CLI is installed.",
    )
    scan_parser.add_argument(
        "--no-clamav", dest="clamav", action="store_false", default=True,
        help="Disable ClamAV even if `clamscan`/`clamdscan` is installed.",
    )
    scan_parser.add_argument(
        "--yara-rules", type=Path, default=DEFAULT_YARA_RULES,
        help=f"Path to a YARA rules file (default: bundled {DEFAULT_YARA_RULES.name}).",
    )
    scan_parser.add_argument(
        "--hash", dest="compute_hash", action="store_true", default=False,
        help="Compute and report a SHA-256 hash for every scanned file.",
    )
    scan_parser.add_argument(
        "--report", dest="report_path", type=Path, default=None,
        help="Write a detailed JSON report to this path.",
    )
    scan_parser.add_argument(
        "--verbose", action="store_true", default=False,
        help="Also print clean files, not just flagged ones.",
    )
    scan_parser.add_argument(
        "--quiet", action="store_true", default=False,
        help="Only print the final summary box, no per-file detail.",
    )
    return parser


def cmd_scan(args: argparse.Namespace) -> int:
    files = collect_files(args.paths, recursive=args.recursive)
    if not files:
        print_status("error", "No files found to scan.", stream=sys.stderr)
        return 2

    checks_enabled: list[str] = []
    checks_skipped: list[str] = []

    run_structural = bool(args.structural)
    if run_structural:
        checks_enabled.append("structural")

    run_yara = bool(args.yara) and external_scanners.yara_available()
    if args.yara and not external_scanners.yara_available():
        checks_skipped.append("yara (not installed — `brew install yara`)")
    elif run_yara:
        checks_enabled.append("yara")

    run_clamav = bool(args.clamav) and external_scanners.clamav_available()
    if args.clamav and not external_scanners.clamav_available():
        checks_skipped.append("clamav (not installed — `brew install clamav && freshclam`)")
    elif run_clamav:
        checks_enabled.append("clamav")

    print_status("info", f"Scanning {len(files)} file(s) — checks: {', '.join(checks_enabled) or 'none'}")
    if checks_skipped:
        for skipped in checks_skipped:
            print_status("warn", f"Skipped layer: {skipped}")

    reports, summary = run_scan(
        files,
        run_structural=run_structural,
        run_yara=run_yara,
        yara_rules=args.yara_rules,
        run_clamav=run_clamav,
        compute_hash=args.compute_hash,
    )
    summary.checks_enabled = checks_enabled
    summary.checks_skipped = checks_skipped

    if not args.quiet:
        for report in reports:
            print_file_report(report, verbose=args.verbose)
        print()

    print_summary(summary)

    if args.report_path is not None:
        payload = build_json_report(reports, summary)
        write_json_report(args.report_path, payload)
        print_status("ok", f"Report written to: {args.report_path}")

    if summary.files_with_critical or summary.files_with_warnings:
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    # Force line buffering even when stdout is redirected/piped (e.g. `tee`
    # or `> log.txt`). Without this, Python fully buffers non-tty stdout and
    # every status line — including per-file findings — only appears once
    # the entire scan finishes, which looks like the tool has hung.
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except (AttributeError, ValueError):
        pass

    parser = build_parser()
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])

    try:
        if args.command == "scan":
            return cmd_scan(args)
        parser.print_help(sys.stderr)
        return 2
    except KeyboardInterrupt:
        print_status("error", "Interrupted.", stream=sys.stderr)
        return 2
    except Exception as exc:  # last-resort guard, never crash without a message
        print_status("error", f"Unexpected failure: {exc}", stream=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

# ============================================================================ #
# End of script.
