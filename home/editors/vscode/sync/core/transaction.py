"""Applying a plan, with the means to undo every step, even after a crash.

A transaction works in a workspace below the state directory. Before each
step it appends a record to ``journal.jsonl`` and flushes it to disk; the
record holds everything needed to undo the step, and whatever the step
replaces is moved into the workspace, never deleted. Undoing reads the
records newest first and checks the filesystem before touching it, so it is
correct whether the step completed, stopped half way or never began.

``rollback`` undoes the steps of the running transaction; ``recover`` does
the same for a workspace an interrupted run left behind, so the next run
repairs it without help. Both remove the workspace when every step was
undone. ``commit`` keeps the changes and removes the workspace.

``quarantine`` is no transaction: each folder it moves is safe where it
lands, so a failure stops nothing else.
"""

import hashlib
import json
import os
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field
from pathlib import Path

from .errors import SyncError
from .host import Edition
from .jsondata import as_object
from .plan import (
    AdoptFolder,
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
    ensure_unchanged,
    move,
    private_dir,
    prune,
    reason,
    remove_tree,
    sibling,
    stamp,
    sync_directory,
    write_atomically,
)

JOURNAL = "journal.jsonl"
"""The workspace file that lists the steps of a run, one JSON object each."""

Record = Mapping[str, str | None]


@dataclass(frozen=True, slots=True)
class Undone:
    """The outcome of undoing a run.

    ``failures`` are steps that could not be undone; the workspace is kept
    while there are any. ``notes`` describe what was left as it was, because
    something else changed it since, and where displaced originals went.
    """

    steps: int
    failures: tuple[str, ...] = ()
    notes: tuple[str, ...] = ()


@dataclass(slots=True)
class Transaction:
    """The steps applied so far, recorded in ``workspace``."""

    workspace: Path
    _records: list[Record] = field(default_factory=list[Record])

    def apply(self, operation: Operation) -> None:
        """Apply one operation.

        Raises:
            SyncError: If it fails; the step stays recorded, so a rollback
                undoes whatever part of it was done.
        """
        try:
            if isinstance(operation, LinkFolder | LinkItem):
                self._link(operation.path, operation.target)
            elif isinstance(operation, RestoreFolder | RestoreItem):
                self._restore(operation.path, operation.source)
            elif isinstance(operation, UnlinkFolder | UnlinkItem):
                self._unlink(operation.path)
            elif isinstance(operation, AdoptFolder):
                self._adopt(operation.path, operation.source)
            elif isinstance(operation, WriteFile):
                self._write(operation)
            else:
                raise SyncError(f"{operation} is not part of a transaction")
        except OSError as error:
            raise SyncError(
                f"{describe(operation)} failed: {reason(error)}"
            ) from None

    def rollback(self) -> Undone:
        """Undo every step, newest first, and remove the workspace if done."""
        undone = _undo_all(self._records, self.workspace)
        self._records.clear()
        return undone

    def commit(self) -> list[str]:
        """Keep the changes and remove the workspace.

        Returns:
            Warnings for what could not be cleaned up.
        """
        self._records.clear()
        return _discard(self.workspace)

    def _record(self, **fields: str | None) -> None:
        """Append a step to the journal and flush it before the step runs."""
        line = json.dumps(fields, separators=(",", ":"))
        with (self.workspace / JOURNAL).open("a") as journal:
            journal.write(f"{line}\n")
            journal.flush()
            os.fsync(journal.fileno())
        self._records.append(fields)

    def _aside(self) -> Path:
        """An unused name in the workspace for an original moved aside."""
        return self.workspace / "aside" / f"{len(self._records):04d}"

    def _link(self, path: Path, target: Path) -> None:
        """Make ``path`` a symlink to ``target``, moving any original aside."""
        aside = self._aside() if os.path.lexists(path) else None
        self._record(
            op="link",
            path=str(path),
            target=str(target),
            aside=str(aside) if aside else None,
        )
        if aside is not None:
            move(path, aside)
        path.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(target, path)
        sync_directory(path.parent)

    def _restore(self, path: Path, source: Path) -> None:
        """Make ``path``, a symlink or nothing, a copy of ``source``."""
        link = os.readlink(path) if path.is_symlink() else None
        staging = sibling(path, "restore")
        self._record(
            op="restore",
            path=str(path),
            source=str(source),
            link=link,
            staging=str(staging),
        )
        copy(source, staging)
        if link is not None:
            path.unlink()
        os.rename(staging, path)
        sync_directory(path.parent)

    def _unlink(self, path: Path) -> None:
        """Remove the symlink ``path``."""
        self._record(op="unlink", path=str(path), link=os.readlink(path))
        path.unlink()
        sync_directory(path.parent)

    def _adopt(self, path: Path, source: Path) -> None:
        """Move a downloaded folder to ``path``, which must be free."""
        self._record(op="adopt", path=str(path), source=str(source))
        move(source, path)
        sync_directory(path.parent)

    def _write(self, operation: WriteFile) -> None:
        """Replace a file, keeping its previous bytes in the workspace."""
        ensure_unchanged(operation.path, operation.expected)
        before = None
        if operation.expected is not None:
            before = self.workspace / "files" / f"{len(self._records):04d}"
            before.parent.mkdir(exist_ok=True)
            with before.open("wb") as handle:
                handle.write(operation.expected)
                handle.flush()
                os.fsync(handle.fileno())
        self._record(
            op="write",
            path=str(operation.path),
            before=str(before) if before else None,
            after=_digest(operation.data),
        )
        write_atomically(operation.path, operation.expected, operation.data)


def recover(workspace: Path) -> Undone:
    """Undo the run whose workspace an interruption left behind.

    A journal line cut off by the interruption belongs to a step that never
    began, and is ignored.
    """
    records: list[Record] = []
    try:
        lines = (workspace / JOURNAL).read_text().splitlines()
    except FileNotFoundError:
        lines = []
    except OSError as error:
        return Undone(0, (f"cannot read {workspace}: {reason(error)}",))
    for line in lines:
        try:
            record = as_object(json.loads(line))
        except json.JSONDecodeError:
            continue
        if record is not None:
            records.append(_as_record(record))
    return _undo_all(records, workspace)


def _as_record(value: Mapping[str, object]) -> Record:
    """A journal line, with only text and null values kept."""
    return {
        key: item
        for key, item in value.items()
        if item is None or isinstance(item, str)
    }


def _undo_all(records: Iterable[Record], workspace: Path) -> Undone:
    """Undo ``records`` newest first; remove the workspace if all succeed."""
    steps = list(records)
    failures: list[str] = []
    notes: list[str] = []
    for record in reversed(steps):
        try:
            note = _undo(record, workspace)
        except (OSError, SyncError, KeyError) as error:
            failures.append(f"{record.get('path')}: {reason(error)}")
            continue
        if note:
            notes.append(note)
    if not failures:
        failures += _discard(workspace)
    return Undone(len(steps), tuple(failures), tuple(notes))


def _undo(record: Record, workspace: Path) -> str | None:
    """Undo one step, whatever part of it was done; a note, if any."""
    kind = record["op"]
    path = Path(_text(record, "path"))
    if kind == "link":
        target = _text(record, "target")
        if path.is_symlink() and os.readlink(path) == target:
            path.unlink()
        aside = record.get("aside")
        if aside and os.path.lexists(aside):
            if os.path.lexists(path):
                return _rescue(Path(aside), path, workspace)
            move(Path(aside), path)
    elif kind == "restore":
        staging = Path(_text(record, "staging"))
        if os.path.lexists(staging):
            remove_tree(staging)
        link = record.get("link")
        if path.is_symlink() and link is not None:
            return None
        if os.path.lexists(path):
            remove_tree(path)
        if link is not None:
            os.symlink(link, path)
    elif kind == "unlink":
        if not os.path.lexists(path):
            os.symlink(_text(record, "link"), path)
    elif kind == "adopt":
        if os.path.lexists(path) and not path.is_symlink():
            remove_tree(path)
    elif kind == "write":
        return _undo_write(record, path)
    else:
        raise SyncError(f"unknown step {kind!r}")
    sync_directory(path.parent)
    return None


def _undo_write(record: Record, path: Path) -> str | None:
    """Put a file's previous bytes back, if it still holds what was written."""
    real = Path(os.path.realpath(path))
    before_path = record.get("before")
    before = Path(before_path).read_bytes() if before_path else None
    try:
        current: bytes | None = real.read_bytes()
    except FileNotFoundError:
        current = None
    if current == before:
        return None
    if current is None or _digest(current) != record.get("after"):
        return f"{real} changed since the run; left as it is"
    if before is None:
        real.unlink()
    else:
        write_atomically(path, current, before)
    return None


def _rescue(aside: Path, path: Path, workspace: Path) -> str:
    """Keep an original whose place is taken, in the quarantine."""
    state_dir = workspace.parent.parent
    directory = private_dir(state_dir / "quarantine") / stamp("recovered")
    destination = directory / path.name
    move(aside, destination)
    return f"{path} was taken since the run; its original is in {destination}"


def _text(record: Record, key: str) -> str:
    """A field a step always has.

    Raises:
        KeyError: If the journal line lacks it.
    """
    value = record.get(key)
    if value is None:
        raise KeyError(key)
    return value


def _digest(data: bytes) -> str:
    """The SHA-256 of a file's content, to recognize it later."""
    return hashlib.sha256(data).hexdigest()


def _discard(workspace: Path) -> list[str]:
    """Remove a workspace."""
    try:
        remove_tree(workspace)
    except FileNotFoundError:
        return []
    except OSError as error:
        return [f"cannot remove {workspace}: {reason(error)}"]
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
    if isinstance(operation, AdoptFolder):
        return f"adopting the downloaded {operation.name}"
    if isinstance(operation, LinkItem):
        return f"linking {operation.name} to Stable's"
    if isinstance(operation, RestoreItem):
        return f"copying {operation.name} from Stable"
    if isinstance(operation, UnlinkItem):
        return f"removing the link {operation.name}"
    if isinstance(operation, WriteFile):
        return f"writing the {operation.label}"
    return f"quarantining {operation.name}"
