"""Applying a plan, with the means to undo every step.

A transaction works in a workspace below the state directory. Whatever an
operation replaces is moved there first, never deleted, and each step adds
the step that undoes it; ``journal.txt`` lists what was done, for a person
recovering by hand. ``commit`` keeps the replaced user files that differed
from Stable's and removes the workspace; ``rollback`` undoes every step in
reverse and removes the workspace only when all of them succeeded.

``quarantine`` is no transaction: each folder it moves is safe where it
lands, so a failure stops nothing else.
"""

import os
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from .errors import SyncError
from .host import Edition
from .plan import (
    LinkFolder,
    LinkItem,
    Operation,
    Quarantine,
    RestoreFolder,
    RestoreItem,
    UnlinkFolder,
    UnlinkItem,
    WriteFile,
)
from .storage import (
    QUARANTINE_RUNS,
    copy,
    move,
    private_dir,
    prune,
    reason,
    remove_tree,
    same_content,
    sibling,
    stamp,
    sync_directory,
    write_atomically,
)


@dataclass(slots=True)
class Transaction:
    """The steps applied so far, and how to undo them.

    ``workspace`` is the run's directory below ``runs/``; ``kept`` is where
    differing user files go when the run succeeds.
    """

    workspace: Path
    kept: Path
    _undo: list[tuple[str, Callable[[], None]]] = field(
        default_factory=list[tuple[str, Callable[[], None]]]
    )
    _items: list[tuple[Path, Path]] = field(
        default_factory=list[tuple[Path, Path]]
    )
    _count: int = 0

    def apply(self, operation: Operation) -> None:
        """Apply one operation.

        Raises:
            SyncError: If it fails; whatever it had done is undone first.
        """
        try:
            if isinstance(operation, LinkFolder | LinkItem):
                self._link(operation.path, operation.target, operation)
            elif isinstance(operation, RestoreFolder | RestoreItem):
                self._restore(operation.path, operation.source)
            elif isinstance(operation, UnlinkFolder | UnlinkItem):
                self._unlink(operation.path)
            elif isinstance(operation, WriteFile):
                self._write(operation)
            else:
                raise SyncError(f"{operation} is not part of a transaction")
        except OSError as error:
            raise SyncError(
                f"{describe(operation)} failed: {reason(error)}"
            ) from None

    def rollback(self) -> list[str]:
        """Undo every applied step, newest first.

        Returns:
            What could not be undone. When this is empty the workspace is
            removed; otherwise it stays, with the originals in it.
        """
        failures: list[str] = []
        for what, undo in reversed(self._undo):
            try:
                undo()
            except (OSError, SyncError) as error:
                failures.append(f"{what}: {reason(error)}")
        self._undo.clear()
        if not failures:
            failures += self._discard()
        return failures

    def commit(self) -> tuple[list[Path], list[str]]:
        """Keep differing user files and remove the workspace.

        Returns:
            The kept copies, and warnings for what could not be cleaned up.
        """
        kept: list[Path] = []
        warnings: list[str] = []
        for source, aside in self._items:
            try:
                if source.exists() and not same_content(aside, source):
                    destination = private_dir(self.kept) / aside.name
                    move(aside, destination)
                    kept.append(destination)
            except (OSError, SyncError) as error:
                warnings.append(f"cannot keep {aside}: {reason(error)}")
        self._undo.clear()
        if warnings:
            return kept, warnings
        return kept, self._discard()

    def _journal(self, line: str) -> None:
        """Record a completed step in ``journal.txt``."""
        with (self.workspace / "journal.txt").open("a") as journal:
            journal.write(f"{line}\n")
            journal.flush()
            os.fsync(journal.fileno())

    def _aside(self, path: Path) -> Path:
        """Move ``path`` into the workspace; where it went."""
        self._count += 1
        destination = (
            self.workspace / "aside" / f"{self._count:04d}-{path.name}"
        )
        move(path, destination)
        return destination

    def _link(self, path: Path, target: Path, operation: Operation) -> None:
        """Make ``path`` a symlink to ``target``, moving any original aside."""
        aside = self._aside(path) if os.path.lexists(path) else None
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(target, path)
        except OSError:
            if aside is not None:
                move(aside, path)
            raise
        sync_directory(path.parent)

        def undo() -> None:
            """Remove the link and put the original back."""
            if path.is_symlink():
                path.unlink()
            if aside is not None:
                move(aside, path)

        self._undo.append((f"undo linking {path}", undo))
        if aside is not None and isinstance(operation, LinkItem):
            self._items.append((target, aside))
        moved = f" (original in {aside})" if aside else ""
        self._journal(f"linked {path} -> {target}{moved}")

    def _restore(self, path: Path, source: Path) -> None:
        """Replace the symlink ``path`` with a copy of ``source``."""
        link = os.readlink(path)
        staging = sibling(path, "restore")
        try:
            copy(source, staging)
        except OSError:
            if os.path.lexists(staging):
                remove_tree(staging)
            raise
        path.unlink()
        try:
            os.rename(staging, path)
        except OSError:
            os.symlink(link, path)
            remove_tree(staging)
            raise
        sync_directory(path.parent)

        def undo() -> None:
            """Remove the copy and put the link back."""
            remove_tree(path)
            os.symlink(link, path)

        self._undo.append((f"undo copying {source} to {path}", undo))
        self._journal(f"replaced the link {path} -> {link} with a copy")

    def _unlink(self, path: Path) -> None:
        """Remove the symlink ``path``."""
        link = os.readlink(path)
        path.unlink()
        sync_directory(path.parent)

        def undo() -> None:
            """Put the link back."""
            os.symlink(link, path)

        self._undo.append((f"undo removing {path}", undo))
        self._journal(f"removed the link {path} -> {link}")

    def _write(self, operation: WriteFile) -> None:
        """Replace a file, keeping its previous bytes in the workspace."""
        if operation.expected is not None:
            self._count += 1
            name = f"{self._count:04d}-{operation.path.name}"
            (self.workspace / "files").mkdir(exist_ok=True)
            (self.workspace / "files" / name).write_bytes(operation.expected)
        write_atomically(operation.path, operation.expected, operation.data)

        def undo() -> None:
            """Put the previous content back, or remove a new file."""
            if operation.expected is None:
                Path(os.path.realpath(operation.path)).unlink()
            else:
                write_atomically(
                    operation.path, operation.data, operation.expected
                )

        self._undo.append((f"undo writing {operation.path}", undo))
        self._journal(f"wrote {operation.path}")

    def _discard(self) -> list[str]:
        """Remove the workspace."""
        try:
            remove_tree(self.workspace)
        except OSError as error:
            return [f"cannot remove {self.workspace}: {reason(error)}"]
        return []


@dataclass(frozen=True, slots=True)
class QuarantineResult:
    """Where ``clean`` put the folders it moved, and what it could not move."""

    directory: Path | None
    moved: tuple[Path, ...]
    failed: tuple[str, ...]
    warnings: tuple[str, ...]


def quarantine(
    operations: list[Quarantine], roots: dict[Edition, Path], state_dir: Path
) -> QuarantineResult:
    """Move each folder into a fresh directory below ``quarantine/``.

    A folder is moved only if it is still a real directory directly inside
    its edition's extensions directory; one that changed since planning is
    reported instead.
    """
    if not operations:
        return QuarantineResult(None, (), (), ())
    directory = private_dir(state_dir / "quarantine") / stamp("clean")
    moved: list[Path] = []
    failed: list[str] = []
    for operation in operations:
        path = operation.path
        if path.parent != roots[operation.edition]:
            failed.append(f"{path}: not inside the extensions directory")
            continue
        if path.is_symlink() or not path.is_dir():
            failed.append(f"{path}: no longer a folder")
            continue
        destination = directory / operation.edition.value / operation.name
        try:
            move(path, destination)
        except OSError as error:
            failed.append(f"{path}: {reason(error)}")
            continue
        moved.append(destination)
    if not moved and directory.exists():
        remove_tree(directory)
    warnings = prune(state_dir / "quarantine", QUARANTINE_RUNS)
    return QuarantineResult(
        directory if moved else None,
        tuple(moved),
        tuple(failed),
        tuple(warnings),
    )


def describe(operation: Operation) -> str:
    """A short description of an operation, for messages."""
    if isinstance(operation, LinkFolder):
        return f"linking {operation.name} to Stable's folder"
    if isinstance(operation, RestoreFolder):
        return f"copying {operation.name} from Stable"
    if isinstance(operation, UnlinkFolder):
        return f"removing the link {operation.name}"
    if isinstance(operation, LinkItem):
        return f"linking {operation.name} to Stable's"
    if isinstance(operation, RestoreItem):
        return f"copying {operation.name} from Stable"
    if isinstance(operation, UnlinkItem):
        return f"removing the link {operation.name}"
    if isinstance(operation, WriteFile):
        return f"writing the {operation.label}"
    return f"quarantining {operation.name}"
