"""Command line: resolve every selected pin, report, and apply on request."""

import argparse
import os
import shutil
import sys

from . import declarations
from .declarations import ROOT, apply_edits, evaluate
from .model import MANUAL_LINES, Finding, Kind, SourceError
from .report import render_markdown, render_text
from .resolvers import ECOSYSTEMS, NEEDS_YAML, RESOLVERS, installers
from .upstream import Source, Upstream

PROGRAM = "update-runtime-baseline"
ENTRY = ROOT / "scripts/updates/update-runtime-baseline.py"
SHELLS = ROOT / "scripts/bootstrap/development-bootstrap.nix"
# Set inside the locked shell, so a second re-execution cannot loop.
SHELL_MARKER = "UPDATE_RUNTIME_BASELINE_SHELL"


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog=PROGRAM,
        description="Report or advance the runtime baseline's upstream pins.",
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--accept-installer", metavar="NAME", action="append")
    parser.add_argument(
        "--line",
        choices=ECOSYSTEMS,
        action="append",
        default=[],
        help="Also move this ecosystem to its newest line (with --apply)",
    )
    parser.add_argument(
        "--markdown", action="store_true", help="Report as Markdown"
    )
    parser.add_argument(
        "ecosystems",
        nargs="*",
        metavar="ECOSYSTEM",
        help=f"Limit to these: {', '.join(ECOSYSTEMS)}",
    )
    args = parser.parse_args(argv)
    unknown = sorted(set(args.ecosystems) - set(ECOSYSTEMS))
    if unknown:
        parser.error(f"unknown ecosystems: {', '.join(unknown)}")
    if args.line and not args.apply:
        parser.error("--line requires --apply")
    for name in args.line:
        if name in MANUAL_LINES:
            parser.error(f"--line {name}: {MANUAL_LINES[name]}")
    return args


def needs_yaml(selected: list[str]) -> bool:
    if NEEDS_YAML.isdisjoint(selected):
        return False
    try:
        import yaml  # noqa: F401
    except ImportError:
        return True
    return False


def reexecute(argv: list[str]) -> None:
    """Run again in the locked shell that provides PyYAML for GHCup's data."""
    expression = f'import {SHELLS} {{ target = "freshness"; }}'
    if os.environ.get(SHELL_MARKER) or not shutil.which("nix"):
        raise SourceError(
            "GHCup's metadata needs PyYAML; run inside: nix develop "
            f"--impure --expr '{expression}'"
        )
    os.execvpe(
        "nix",
        [
            "nix",
            "develop",
            "--impure",
            "--expr",
            expression,
            "--command",
            "python3",
            str(ENTRY),
            *argv,
        ],
        os.environ | {SHELL_MARKER: "1"},
    )


def resolve(
    selected: list[str], upstream: Source, baseline: dict, managers: dict
) -> tuple[list[Finding], list[tuple[str, str]]]:
    findings, errors = [], []
    for name in selected:
        try:
            findings += RESOLVERS[name](upstream, baseline, managers)
        except (SourceError, KeyError, TypeError, ValueError) as error:
            errors.append((name, f"{type(error).__name__}: {error}"))
    return findings, errors


def fail(error: SourceError) -> int:
    print(f"{PROGRAM}: {error}", file=sys.stderr)
    return 2


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    args = parse_arguments(argv)
    selected = args.ecosystems or list(ECOSYSTEMS)
    upstream = Upstream(os.environ.get("GITHUB_TOKEN"))
    try:
        managers = evaluate(declarations.MANAGERS)
        if args.accept_installer:
            installers.accept(args.accept_installer, upstream, managers)
            return 0
        if needs_yaml(selected):
            reexecute(argv)
        baseline = evaluate(declarations.BASELINE)
        findings, errors = resolve(selected, upstream, baseline, managers)
    except SourceError as error:
        return fail(error)
    render = render_markdown if args.markdown else render_text
    print(render(findings, errors))
    if errors:
        return 2
    if args.check:
        return 1 if any(f.actionable for f in findings) else 0
    chosen = [
        f
        for f in findings
        if f.edits
        and (
            f.kind == Kind.UPDATE
            or (f.kind == Kind.LINE and f.ecosystem in args.line)
        )
    ]
    if not chosen:
        print("Nothing to apply.")
        return 0
    try:
        # Build every rewrite, downloads included, before writing anything.
        edits = [edit for f in chosen for edit in f.edits()]
        apply_edits(edits)
    except SourceError as error:
        return fail(error)
    print()
    for f in chosen:
        print(f"applied  {f.name}: {f.pinned} -> {f.available}")
    print(
        "Next: build, run the native CI adapters for these ecosystems, then "
        "apply on each host (see home/dev/README.md)."
    )
    return 0
