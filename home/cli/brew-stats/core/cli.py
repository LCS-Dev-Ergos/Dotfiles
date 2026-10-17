"""The ``brew-stats`` command line and report.

Exit status: 0 for a complete report, 1 when Homebrew, the inventory or a
measurement fails, or some linked artifacts could not be measured (the
report is still printed and names them), 2 for a usage error.
"""

import argparse
import os
import shutil
import sys
from collections.abc import Mapping, Sequence
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import terminal_style as ui
from terminal_style import Cell, Column, Row

from . import PROG, __version__
from .homebrew import BrewError, Homebrew, Inventory, Package, human

_DESCRIPTION = (
    "Report the number and on-disk size of installed Homebrew packages. "
    "Formula sizes include every installed Cellar version; cask sizes "
    "include the Caskroom entry and the artifacts it links to inside its "
    "recorded install roots. Files a .pkg installer placed cannot be "
    "attributed and are not included."
)


def build_parser() -> argparse.ArgumentParser:
    """The options."""
    parser = argparse.ArgumentParser(prog=PROG, description=_DESCRIPTION)
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument(
        "-f", "--formula", action="store_true", help="show only formulae"
    )
    scope.add_argument(
        "-c", "--cask", action="store_true", help="show only casks"
    )
    parser.add_argument(
        "--top",
        type=_positive,
        metavar="N",
        help="list only the N largest (or first) packages",
    )
    parser.add_argument(
        "--sort",
        choices=("size", "name"),
        default="size",
        help="order by size, largest first (default), or by name",
    )
    parser.add_argument(
        "-q",
        "--quiet",
        action="store_true",
        help="print only the table, without the summary",
    )
    parser.add_argument(
        "--version", action="version", version=f"{PROG} {__version__}"
    )
    return parser


def _positive(text: str) -> int:
    """A positive integer option value."""
    if not text.isdigit() or int(text) < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return int(text)


def main(
    argv: Sequence[str] | None = None,
    environ: Mapping[str, str] | None = None,
    style: ui.Style | None = None,
) -> int:
    """Run the command line; the exit status."""
    args = build_parser().parse_args(argv)
    env = dict(environ if environ is not None else _environment())
    brew = shutil.which("brew", path=env.get("PATH", ""))
    if brew is None:
        print(f"{PROG}: Homebrew is not installed", file=sys.stderr)
        return 1
    try:
        return _report(args, Homebrew(brew, env), style or ui.Style.detect())
    except BrewError as error:
        print(f"{PROG}: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print(f"{PROG}: Interrupted", file=sys.stderr)
        return 130


def _environment() -> dict[str, str]:
    """The process environment."""
    return dict(os.environ)


def _report(
    args: argparse.Namespace, homebrew: Homebrew, style: ui.Style
) -> int:
    """Read, measure, check the inventory again, then draw."""
    kinds = ["formula"] if args.formula else ["cask"] if args.cask else []
    kinds = kinds or ["formula", "cask"]
    with ThreadPoolExecutor(max_workers=2) as pool:
        inventories = list(pool.map(homebrew.inventory, kinds))
    if not any(inventory.directories for inventory in inventories):
        if args.quiet:
            print(f"{PROG}: No installed packages found", file=sys.stderr)
        else:
            print("No installed Homebrew packages found.")
        return 0
    packages: list[Package] = []
    totals: dict[str, int] = {}
    for inventory in inventories:
        measured = _measure(homebrew, inventory)
        packages += measured
        totals[inventory.kind] = sum(package.kb for package in measured)
    for inventory in inventories:
        homebrew.recheck(inventory)

    ordered = sorted(packages, key=lambda p: (p.name.casefold(), p.kind))
    if args.sort == "size":
        ordered.sort(key=lambda package: -package.kb)
    shown = ordered[: args.top] if args.top else ordered
    if args.quiet:
        print("\n".join(_table(ui.Style(False), shown)))
    else:
        cache, cache_kb = homebrew.cache()
        lines = _table(style, shown)
        lines += ["", *_summary(style, inventories, totals, cache, cache_kb)]
        print("\n".join(lines))
    incomplete = [package for package in packages if package.unmeasured]
    for package in incomplete:
        for reason in package.unmeasured:
            print(
                f"{PROG}: {package.name}: not measured: {reason}",
                file=sys.stderr,
            )
    return 1 if incomplete else 0


def _measure(homebrew: Homebrew, inventory: Inventory) -> list[Package]:
    """The packages of one inventory, measured."""
    if not inventory.directories:
        return []
    if inventory.kind == "formula":
        return homebrew.formulae(inventory)
    return homebrew.casks(inventory)


def _table(style: ui.Style, packages: Sequence[Package]) -> list[str]:
    """Package, type and size; sizes aligned on the right."""
    sizes = [human(package.kb) for package in packages]
    width = max((len(size) for size in sizes), default=0)
    rows = [
        Row(
            [
                package.name,
                package.kind.capitalize(),
                Cell(size.rjust(width)),
            ],
            "warn" if package.unmeasured and style.styled else "",
        )
        for package, size in zip(packages, sizes, strict=True)
    ]
    columns = [Column("Package", shrink=16), Column("Type"), Column("Size")]
    return ui.table(style, columns, rows)


def _summary(
    style: ui.Style,
    inventories: Sequence[Inventory],
    totals: Mapping[str, int],
    cache: Path,
    cache_kb: int,
) -> list[str]:
    """The counts and sizes of each kind, the total and the cache."""
    counts = {inv.kind: len(inv.directories) for inv in inventories}
    fields: list[tuple[str, Cell | str]] = []
    for kind, title in (("formula", "Formulae"), ("cask", "Casks")):
        if kind in counts:
            fields.append((title, f"{counts[kind]} · {human(totals[kind])}"))
    total = sum(counts.values())
    fields.append(
        ("Total", f"{total} packages · {human(sum(totals.values()))}")
    )
    fields.append(("Cache", Cell(f"{human(cache_kb)} · {cache}", path=True)))
    return ui.card(style, "Homebrew disk usage", fields)
