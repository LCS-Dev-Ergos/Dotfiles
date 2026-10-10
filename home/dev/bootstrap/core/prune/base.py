"""Retirements: installed releases the baseline retired, and their removal.

Prune never decides what is obsolete. The baseline's `retired` mirror names
the releases, and only those still installed are considered. A release the
global selection names moves to its successor first, and dependents that can
follow it safely move with it; anything else blocks that release, which then
stays installed. Planning reads the filesystem only.
"""

import os
import re
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from ..errors import BootstrapError


def numeric(release):
    return tuple(int(part) for part in re.findall(r"[0-9]+", release))


@dataclass
class Step:
    """One change made before the removal, described for the report."""

    description: str
    run: Callable[[], object]


@dataclass
class Retirement:
    """A retired release found installed, and what removing it takes."""

    retirer: "Retirer" = field(repr=False)
    release: str
    prefix: Path
    successor: str
    component: str | None = None
    steps: list[Step] = field(default_factory=list)
    blockers: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    state: str = "retire"
    reason: str = ""

    def report(self):
        row = {
            "language": self.retirer.adapter.language,
            "version": self.release,
            "path": str(self.prefix),
            "owner": self.retirer.adapter.manager_name,
            "successor": self.successor,
            "state": self.state,
            "steps": [step.description for step in self.steps],
        }
        if self.component:
            row["component"] = self.component
        if self.reason:
            row["reason"] = self.reason
        if self.notes:
            row["notes"] = list(self.notes)
        return row


class Retirer:
    """How one adapter's retired releases are found, freed and removed.

    `depth` is how many leading components name a line: the successor is
    the newest declared release in the same line, or the declared default.
    """

    depth = 0

    def __init__(self, adapter):
        self.adapter = adapter
        self.context = adapter.context

    # What prune considers -----------------------------------------------------

    @staticmethod
    def lookup(data, path):
        for key in path.split("."):
            data = data.get(key) if isinstance(data, dict) else None
        return data

    def paths(self):
        """Each component's dotted declaration path; None names the only one.

        The `retired` mirror repeats these paths.
        """
        raise NotImplementedError

    def releases(self):
        """(component, release) pairs the baseline retired."""
        retired = self.context.data.get("retired", {})
        for component, path in self.paths().items():
            for release in self.lookup(retired, path) or []:
                yield component, release

    def declared(self, component):
        value = self.lookup(self.context.data, self.paths()[component])
        return value if isinstance(value, list) else [value]

    def successor(self, release, component):
        declared = self.declared(component)
        line = numeric(release)[: self.depth]
        same = [r for r in declared if numeric(r)[: self.depth] == line]
        if same:
            return max(same, key=numeric)
        default = self.context.data["defaults"].get(self.adapter.language)
        return default if default in declared else max(declared, key=numeric)

    def prefix(self, release, component):
        """Where the release is installed; its presence means installed."""
        raise NotImplementedError

    def plan(self):
        retirements = []
        for component, release in self.releases():
            prefix = self.prefix(release, component)
            if prefix is None or not os.path.lexists(prefix):
                continue
            retirement = Retirement(
                self,
                release,
                prefix,
                self.successor(release, component),
                component,
            )
            self.locate(retirement)
            if not retirement.blockers:
                self.inspect(retirement)
            if not retirement.blockers and self.selects(retirement):
                self.plan_reselection(retirement)
            if not retirement.blockers:
                retirement.steps.append(
                    Step("remove it", lambda r=retirement: self.remove(r))
                )
            if retirement.blockers:
                retirement.state = "blocked"
                retirement.reason = "; ".join(retirement.blockers)
            retirements.append(retirement)
        return retirements

    def locate(self, retirement):
        """Only a real directory or file strictly inside the root is removed."""
        prefix = retirement.prefix
        root = self.adapter.root.resolve()
        resolved = prefix.parent.resolve() / prefix.name
        if prefix.is_symlink():
            retirement.blockers.append(f"{prefix} is a symlink")
        elif resolved == root or not resolved.is_relative_to(root):
            retirement.blockers.append(f"{prefix} lies outside {root}")

    def inspect(self, retirement):
        """Add the steps that free the release, or the blockers that keep it."""

    def installed(self, release, component):
        prefix = self.prefix(release, component)
        return prefix is not None and os.path.lexists(prefix)

    # Global selection ---------------------------------------------------------

    def selects(self, retirement):
        """Whether a global selection resolves into the release."""
        prefix = retirement.prefix.resolve()
        for row in self.adapter.selected():
            if row.get("state") == "present" and row.get("path"):
                if Path(row["path"]).resolve().is_relative_to(prefix):
                    return True
        return False

    def plan_reselection(self, retirement):
        successor = retirement.successor
        if not successor or not self.installed(
            successor, retirement.component
        ):
            retirement.blockers.append(
                f"the global selection names it and its successor "
                f"{successor} is not installed; apply first"
            )
            return
        retirement.steps.append(
            Step(
                f"select {successor} globally",
                lambda: self.move_selection(retirement),
            )
        )

    def move_selection(self, retirement):
        self.reselect(retirement)
        if self.selects(retirement):
            raise BootstrapError(
                f"the global selection still names {retirement.release}"
            )

    def reselect(self, retirement):
        """Point the global selection at the successor."""
        raise NotImplementedError

    # Removal ------------------------------------------------------------------

    def remove(self, retirement):
        self.uninstall(retirement)
        if os.path.lexists(retirement.prefix):
            raise BootstrapError(
                f"{retirement.prefix} is still present after uninstalling"
            )

    def uninstall(self, retirement):
        """Remove the release through its manager."""
        raise NotImplementedError

    def execute(self, retirement):
        for step in retirement.steps:
            step.run()
