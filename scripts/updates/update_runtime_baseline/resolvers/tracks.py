"""Declarative tracking: one pinned declaration, one upstream listing.

Most ecosystems differ only in where their pin lives, where releases are
listed, how deep a line is and what makes a release installable. A `Track`
holds exactly those parameters; resolving it is the same for all of them.
"""

import functools
from collections.abc import Callable
from dataclasses import dataclass

from ..declarations import baseline_edit, lookup
from ..model import Edit, Finding, classify
from ..upstream import Source
from ..versions import line, numeric, stable
from .sources import Listing, Probe

Resolver = Callable[[Source, dict, dict], list[Finding]]


@dataclass(frozen=True, kw_only=True)
class Track:
    """How one declaration follows its upstream.

    `declaration` is the dotted path of a pinned release, or of a list of
    releases, one per maintained line; each then reports under its line and
    only the newest reports newer lines. `default` means the declared
    default moves with the pin.
    """

    ecosystem: str
    declaration: str
    releases: Listing
    depth: int
    installable: Probe | None = None
    label: str = ""
    default: bool = True
    # Whether --line may rewrite a newer line; MANUAL_LINES never can.
    movable_lines: bool = True

    def __call__(
        self, upstream: Source, baseline: dict, managers: dict
    ) -> list[Finding]:
        declared = lookup(baseline, self.declaration)
        pins = declared if isinstance(declared, list) else [declared]
        available = {v for v in self.releases(upstream) if stable(v)}
        check = self.installable(upstream) if self.installable else None
        newest = max(pins, key=numeric)
        found = []
        for pinned in pins:
            edits = functools.partial(self.edits, pinned)
            found += classify(
                self.ecosystem,
                self.name(pinned, lines=len(pins) > 1),
                pinned,
                available,
                self.depth,
                check,
                edits=edits,
                line_edits=edits if self.movable_lines else None,
                lines=pinned == newest,
                retires=((self.declaration, pinned),),
            )
        return found

    def name(self, pinned: str, *, lines: bool) -> str:
        if self.label:
            return self.label
        if lines:
            return f"{self.ecosystem} {line(pinned, self.depth)}"
        return self.ecosystem

    def edits(self, pinned: str, version: str) -> list[Edit]:
        scopes = [self.declaration]
        if self.default:
            scopes.append(f"defaults.{self.ecosystem}")
        return [baseline_edit(pinned, version, *scopes)]


def combine(*resolvers: Resolver) -> Resolver:
    """One ecosystem resolved through several declarations, in order."""

    def resolve(upstream: Source, baseline: dict, managers: dict) -> list:
        return [
            finding
            for resolver in resolvers
            for finding in resolver(upstream, baseline, managers)
        ]

    return resolve
