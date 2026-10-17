"""What a run would change, worked out from a read-only snapshot.

Sharing follows Insiders' own lists: an extension is shared only where an
Insiders profile already has it. Each Insiders entry is matched with the
build Stable uses for it, taken from the Stable profile of the same name and
otherwise from the newest build any Stable profile uses. Stable must still
list the folder and not have marked it for deletion.

- The same build: Insiders' folder becomes a link to Stable's.
- A newer build in Stable: the entry follows it, and the link is made.
- A newer build in Insiders' own folder: Insiders keeps it.
- Extensions in ``EXCLUDED``: Insiders keeps its own copies; a link to
  Stable's is replaced by a copy.

A link counts as this tool's when it points at a folder directly inside
Stable's extensions directory. Links nobody lists any more are removed;
every other link is left alone. Entries always name their folder inside
Insiders' directory, even when the folder is a link, so VS Code never
deletes a Stable folder through an Insiders entry.
"""

import os
import re
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field, replace
from enum import Enum
from pathlib import Path

from .host import Edition, Host
from .inventory import Folder, Kind, inspect, scan
from .jsondata import as_object
from .manifest import (
    DEFAULT_SCOPE,
    Manifest,
    Obsolete,
    Reference,
    encode,
    location_payload,
    read_manifests,
    read_obsolete,
)
from .versions import Version, parse_version

EXCLUDED = frozenset(
    {"anthropic.claude-code", "github.copilot", "github.copilot-chat"}
)
"""Extensions each edition keeps its own copy of.

Copilot's builds follow the editor's engine version, which differs between
Stable and Insiders; Claude Code ships a native binary with each build.
"""

ITEMS = ("settings.json", "keybindings.json", "snippets", "mcp.json")
"""The user files Insiders shares with Stable through links."""

_FOLLOWED_METADATA = ("targetPlatform", "isPreReleaseVersion")
_EXTENSION_FOLDER = re.compile(r"[^.]+\.[^.].*-\d+(\.\d+)*(-.+)?")

# Snapshot ---------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Side:
    """One edition as it was read: its folders, manifests and deletions."""

    edition: Edition
    root: Path
    user_dir: Path
    folders: Mapping[str, Folder]
    manifests: tuple[Manifest, ...]
    obsolete: Obsolete

    @property
    def roots(self) -> tuple[Path, ...]:
        """The extensions directory as written and as resolved."""
        resolved = Path(os.path.realpath(self.root))
        return (self.root,) if resolved == self.root else (self.root, resolved)

    def folder(self, name: str) -> Folder:
        """The folder ``name``, also when the scan left it out."""
        return self.folders.get(name) or inspect(self.root, name)

    def referenced(self) -> set[str]:
        """Every folder some profile of this edition lists."""
        names: set[str] = set()
        for manifest in self.manifests:
            names |= manifest.folders()
        return names


class ItemStatus(Enum):
    """How an Insiders user file relates to Stable's."""

    LINKED = "linked"
    INDEPENDENT = "independent"
    MISSING = "missing"
    BROKEN = "broken"
    FOREIGN = "foreign"
    NO_SOURCE = "no source"


@dataclass(frozen=True, slots=True)
class Item:
    """A shared user file: Stable's ``source`` and Insiders' ``target``."""

    name: str
    source: Path
    target: Path
    status: ItemStatus
    link: str | None = None


@dataclass(frozen=True, slots=True)
class Snapshot:
    """Everything a plan is made from, read once.

    ``interrupted`` lists run workspaces a previous run left behind.
    """

    stable: Side
    insiders: Side
    items: tuple[Item, ...]
    interrupted: tuple[Path, ...] = ()

    def side(self, edition: Edition) -> Side:
        """The side of an edition."""
        return self.insiders if edition is Edition.INSIDERS else self.stable


def take_snapshot(host: Host) -> Snapshot:
    """Read both editions and the state directory.

    Raises:
        SyncError: If a manifest, profile list or ``.obsolete`` file
            cannot be parsed.
    """
    stable = _side(host, Edition.STABLE)
    insiders = _side(host, Edition.INSIDERS)
    items = tuple(_item(stable, insiders, name) for name in ITEMS)
    runs = host.state_dir() / "runs"
    try:
        interrupted = tuple(sorted(path for path in runs.iterdir()))
    except FileNotFoundError:
        interrupted = ()
    return Snapshot(stable, insiders, items, interrupted)


def _side(host: Host, edition: Edition) -> Side:
    """Read one edition."""
    root = host.extensions_dir(edition)
    return Side(
        edition,
        root,
        host.user_dir(edition),
        scan(root),
        read_manifests(host, edition),
        read_obsolete(root),
    )


def _item(stable: Side, insiders: Side, name: str) -> Item:
    """Classify one user file."""
    source = stable.user_dir / name
    target = insiders.user_dir / name
    has_source = os.path.lexists(source)
    try:
        link = os.readlink(target)
    except FileNotFoundError:
        status = ItemStatus.MISSING if has_source else ItemStatus.NO_SOURCE
        return Item(name, source, target, status)
    except OSError:
        if not os.path.lexists(target):
            status = ItemStatus.MISSING if has_source else ItemStatus.NO_SOURCE
            return Item(name, source, target, status)
        status = ItemStatus.INDEPENDENT if has_source else ItemStatus.NO_SOURCE
        return Item(name, source, target, status)
    pointed = Path(os.path.normpath(os.path.join(target.parent, link)))
    accepted = {source, Path(os.path.realpath(source))}
    if pointed not in accepted:
        return Item(name, source, target, ItemStatus.FOREIGN, link)
    status = ItemStatus.LINKED if source.exists() else ItemStatus.BROKEN
    return Item(name, source, target, status, link)


# Plan -------------------------------------------------------------------------


class Action(Enum):
    """What happens to one Insiders entry."""

    SHARED = "shared"
    LINK = "link"
    REBIND = "rebind"
    RELOCATE = "relocate"
    RESTORE = "restore"
    NATIVE = "native"
    FOREIGN = "foreign"
    ORPHANED = "orphaned"
    MISSING = "missing"


ACTION_TONES = {
    Action.SHARED: "ok",
    Action.LINK: "pending",
    Action.REBIND: "pending",
    Action.RELOCATE: "pending",
    Action.RESTORE: "pending",
    Action.NATIVE: "muted",
    Action.FOREIGN: "warn",
    Action.ORPHANED: "warn",
    Action.MISSING: "error",
}
"""How each action reads: work due, information or a problem."""


@dataclass(frozen=True, slots=True)
class Decision:
    """The outcome for one Insiders entry.

    ``folder`` is the folder the entry names now and ``target`` the one it
    names afterwards.
    """

    scope: str
    extension_id: str
    folder: str
    target: str
    action: Action
    detail: str = ""


@dataclass(frozen=True, slots=True)
class Finding:
    """Something worth reporting that is not a change: a tone and a text."""

    tone: str
    subject: str
    text: str


@dataclass(frozen=True, slots=True)
class LinkFolder:
    """Make Insiders' folder ``name`` a link to Stable's."""

    name: str
    path: Path
    target: Path


@dataclass(frozen=True, slots=True)
class RestoreFolder:
    """Replace a shared folder link with a copy of its target."""

    name: str
    path: Path
    source: Path


@dataclass(frozen=True, slots=True)
class UnlinkFolder:
    """Remove a folder link nobody lists any more."""

    name: str
    path: Path


@dataclass(frozen=True, slots=True)
class LinkItem:
    """Make an Insiders user file a link to Stable's."""

    name: str
    path: Path
    target: Path


@dataclass(frozen=True, slots=True)
class RestoreItem:
    """Replace a user file link with a copy of Stable's file."""

    name: str
    path: Path
    source: Path


@dataclass(frozen=True, slots=True)
class UnlinkItem:
    """Remove a user file link whose Stable file is gone."""

    name: str
    path: Path


@dataclass(frozen=True, slots=True)
class WriteFile:
    """Replace a manifest or ``.obsolete`` file.

    ``expected`` is what the file held when it was read, None if it did not
    exist; the write is refused if that changed.
    """

    label: str
    path: Path
    expected: bytes | None
    data: bytes


@dataclass(frozen=True, slots=True)
class Quarantine:
    """Move an unused duplicate folder out of an extensions directory."""

    edition: Edition
    name: str
    path: Path


Operation = (
    LinkFolder
    | RestoreFolder
    | UnlinkFolder
    | LinkItem
    | RestoreItem
    | UnlinkItem
    | WriteFile
    | Quarantine
)


@dataclass(frozen=True, slots=True)
class Plan:
    """The operations of a run, and what was found while planning them."""

    command: str
    operations: tuple[Operation, ...] = ()
    decisions: tuple[Decision, ...] = ()
    findings: tuple[Finding, ...] = ()
    items: tuple[Item, ...] = ()

    @property
    def changed(self) -> bool:
        """Whether the run would change anything."""
        return bool(self.operations)

    @property
    def problems(self) -> int:
        """Findings and decisions that need a person."""
        tones = [finding.tone for finding in self.findings]
        tones += [ACTION_TONES[decision.action] for decision in self.decisions]
        return sum(tone == "error" for tone in tones)


# Setup ------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class _Build:
    """A Stable build an Insiders entry can share.

    ``reference`` is a Stable entry listing it, whose version and build
    metadata the Insiders entry takes over.
    """

    folder: str
    version: Version | None
    reference: Reference


@dataclass(slots=True)
class _Setup:
    """The working state of ``plan_setup``."""

    snapshot: Snapshot
    decisions: list[Decision] = field(default_factory=list[Decision])
    findings: list[Finding] = field(default_factory=list[Finding])
    shared: set[str] = field(default_factory=set[str])
    restored: dict[str, Path] = field(default_factory=dict[str, Path])


def plan_setup(snapshot: Snapshot) -> Plan:
    """The operations that make Insiders share what it can with Stable."""
    state = _Setup(snapshot)
    stable, insiders = snapshot.stable, snapshot.insiders
    builds = _live_builds(stable)
    operations: list[Operation] = []
    listed: set[str] = set()
    for manifest in insiders.manifests:
        entries = list(manifest.entries)
        for reference in manifest.references:
            entry = _decide(state, builds, manifest.scope, reference)
            target = reference.folder
            if entry is not None:
                if encode(entry) != encode(reference.entry):
                    entries[reference.index] = entry
                target = _entry_folder(entry, reference.folder)
            listed.add(target)
        listed |= _unusable_folders(manifest, entries)
        operations += _rewrite(manifest, entries)
    for name in sorted(state.shared):
        folder = insiders.folder(name)
        if not _shares(folder, stable, name):
            operations.append(
                LinkFolder(name, folder.path, stable.root / name)
            )
    for name, source in sorted(state.restored.items()):
        operations.append(RestoreFolder(name, insiders.root / name, source))
    for name, folder in insiders.folders.items():
        if not folder.links_into(*stable.roots) or name in listed:
            continue
        if _EXTENSION_FOLDER.fullmatch(name):
            operations.append(UnlinkFolder(name, folder.path))
        else:
            state.findings.append(
                Finding(
                    "muted",
                    name,
                    "a shared folder that is no extension; left as it is",
                )
            )
    keep = state.shared | set(state.restored)
    operations += _unmark(insiders.obsolete, keep)
    item_operations, item_findings = _setup_items(snapshot)
    return Plan(
        "setup",
        tuple(item_operations + operations),
        tuple(state.decisions),
        tuple(item_findings + state.findings + _interrupted(snapshot)),
        snapshot.items,
    )


def _live_builds(stable: Side) -> dict[str, list[_Build]]:
    """The Stable builds Insiders may share, by extension.

    A build is live when Stable lists it, its folder is a real directory and
    VS Code has not marked it for deletion.
    """
    builds: dict[str, list[_Build]] = {}
    seen: set[str] = set()
    for manifest in stable.manifests:
        for reference in manifest.references:
            name = reference.folder
            if name in seen or name in stable.obsolete.names:
                continue
            folder = stable.folder(name)
            if folder.kind is not Kind.DIRECTORY:
                continue
            seen.add(name)
            version = (
                folder.package.version
                if folder.package
                else parse_version(reference.version)
            )
            build = _Build(name, version, reference)
            builds.setdefault(reference.extension_id, []).append(build)
    return builds


def _choose(
    stable: Side, builds: Mapping[str, list[_Build]], scope: str, ident: str
) -> _Build | None:
    """The Stable build an Insiders entry of ``scope`` should share.

    The Stable profile of the same name decides; without one, the newest
    live build. Builds whose version cannot be read are only chosen when
    they are the only one.
    """
    candidates = builds.get(ident, [])
    for manifest in stable.manifests:
        reference = manifest.find(ident) if manifest.scope == scope else None
        if reference is None:
            continue
        for build in candidates:
            if build.folder == reference.folder:
                return build
    versioned = [build for build in candidates if build.version is not None]
    if versioned:
        return max(versioned, key=lambda build: (build.version, build.folder))
    return candidates[0] if len(candidates) == 1 else None


def _decide(
    state: _Setup,
    builds: Mapping[str, list[_Build]],
    scope: str,
    reference: Reference,
) -> dict[str, object] | None:
    """Decide one Insiders entry; the entry it should become, if any."""
    stable, insiders = state.snapshot.stable, state.snapshot.insiders
    name = reference.folder
    folder = insiders.folder(name)
    ours = folder.links_into(*stable.roots)

    def note(action: Action, target: str = name, detail: str = "") -> None:
        """Record the decision for this entry."""
        state.decisions.append(
            Decision(
                scope, reference.extension_id, name, target, action, detail
            )
        )

    if reference.extension_id in EXCLUDED:
        if ours and folder.target is not None and folder.target_exists():
            state.restored[name] = folder.target
            note(Action.RESTORE, detail="kept as Insiders' own copy")
        elif ours:
            note(Action.MISSING, detail="link to a missing Stable folder")
        elif folder.kind is Kind.MISSING:
            note(Action.MISSING, detail="its folder is missing")
        else:
            note(Action.NATIVE, detail="Insiders keeps its own copy")
        return _relocated(reference, insiders)
    build = _choose(stable, builds, scope, reference.extension_id)
    if build is None:
        if ours and folder.target_exists():
            note(Action.ORPHANED, detail="Stable no longer lists this folder")
        elif folder.kind is Kind.MISSING or (
            ours and not folder.target_exists()
        ):
            note(Action.MISSING, detail="no folder, and none in Stable")
        else:
            note(Action.NATIVE, detail="Stable does not have it")
        return _relocated(reference, insiders)
    if folder.kind is Kind.LINK and not ours:
        note(Action.FOREIGN, detail=f"links to {folder.link}")
        return _relocated(reference, insiders)
    if name != build.folder and folder.kind is Kind.DIRECTORY:
        current = folder.package.version if folder.package else None
        if current is None or build.version is None:
            note(Action.NATIVE, detail="versions cannot be compared")
            return _relocated(reference, insiders)
        if current > build.version:
            note(Action.NATIVE, detail=f"newer than Stable's {build.version}")
            return _relocated(reference, insiders)
    entry = _shared_entry(reference, build, insiders.root)
    state.shared.add(build.folder)
    linked = _shares(insiders.folder(build.folder), stable, build.folder)
    if name != build.folder:
        note(Action.REBIND, build.folder, f"Stable uses {build.version}")
    elif not linked:
        note(Action.LINK, detail="shares Stable's folder")
    elif encode(entry) != encode(reference.entry):
        note(Action.RELOCATE, detail=_relocation(reference, stable))
    else:
        note(Action.SHARED)
    return entry


def _shared_entry(
    reference: Reference, build: _Build, root: Path
) -> dict[str, object]:
    """The Insiders entry for a shared build.

    It names the folder inside Insiders' own directory. When it moves to
    another build, it takes over that build's version and its own metadata
    (its platform, whether it is a pre-release) from Stable's entry; the
    rest, and everything about a build it already names, stays Insiders'.
    """
    entry = dict(reference.entry)
    entry["relativeLocation"] = build.folder
    entry["location"] = location_payload(
        entry.get("location"), root / build.folder
    )
    if reference.folder == build.folder:
        return entry
    source = dict(build.reference.entry)
    version = source.get("version")
    if isinstance(version, str):
        entry["version"] = version
    metadata = as_object(source.get("metadata")) or {}
    followed = {
        key: value
        for key, value in metadata.items()
        if key in _FOLLOWED_METADATA
    }
    if followed:
        current = as_object(entry.get("metadata")) or {}
        entry["metadata"] = {**current, **followed}
    return entry


def _shares(folder: Folder, stable: Side, name: str) -> bool:
    """Whether ``folder`` already links to Stable's folder ``name``."""
    return (
        folder.links_into(*stable.roots)
        and folder.target is not None
        and folder.target.name == name
    )


def _relocation(reference: Reference, stable: Side) -> str:
    """Why an entry's location is rewritten."""
    location = Path(reference.location or "")
    if location.parent in stable.roots:
        return "entry points into Stable's directory"
    return "entry names another location"


def _relocated(
    reference: Reference, insiders: Side
) -> dict[str, object] | None:
    """The entry with its location inside Insiders' directory, if it is not.

    Only an entry whose folder exists there is moved; other entries are
    left as they are.
    """
    path = insiders.root / reference.folder
    if reference.location in (None, str(path)):
        return None
    if not os.path.lexists(path):
        return None
    entry = dict(reference.entry)
    entry["location"] = location_payload(entry.get("location"), path)
    return entry


def _entry_folder(entry: Mapping[str, object], fallback: str) -> str:
    """The folder an entry names."""
    relative = entry.get("relativeLocation")
    return relative if isinstance(relative, str) else fallback


def _unusable_folders(
    manifest: Manifest, entries: Iterable[object]
) -> set[str]:
    """Folder names of entries the manifest model skipped.

    They are never acted on, but a link they might name is not stale.
    """
    used = {reference.index for reference in manifest.references}
    names: set[str] = set()
    for index, entry in enumerate(entries):
        fields = as_object(entry)
        if index in used or fields is None:
            continue
        relative = fields.get("relativeLocation")
        if isinstance(relative, str) and relative:
            names.add(relative.strip("/"))
    return names


def _rewrite(manifest: Manifest, entries: list[object]) -> list[Operation]:
    """A write of ``manifest`` with ``entries``, if they changed."""
    if entries == list(manifest.entries):
        return []
    label = f"{manifest.scope} extension list"
    return [WriteFile(label, manifest.path, manifest.raw, encode(entries))]


def _unmark(obsolete: Obsolete, names: set[str]) -> list[Operation]:
    """Take folders the plan relies on off VS Code's deletion list."""
    data = obsolete.without(names)
    if data is None:
        return []
    return [WriteFile("deletion list", obsolete.path, obsolete.raw, data)]


def _setup_items(snapshot: Snapshot) -> tuple[list[Operation], list[Finding]]:
    """Link the user files Insiders does not share yet."""
    operations: list[Operation] = []
    findings: list[Finding] = []
    if not snapshot.insiders.user_dir.is_dir():
        findings.append(
            Finding(
                "muted",
                "user files",
                "Insiders has no user directory yet; start it once",
            )
        )
        return operations, findings
    for item in snapshot.items:
        if item.status in (ItemStatus.INDEPENDENT, ItemStatus.MISSING):
            operations.append(LinkItem(item.name, item.target, item.source))
        elif item.status is ItemStatus.BROKEN:
            findings.append(
                Finding("error", item.name, "links to Stable, which has none")
            )
        elif item.status is ItemStatus.FOREIGN:
            findings.append(
                Finding("warn", item.name, f"links to {item.link}; left alone")
            )
    return operations, findings


def _interrupted(snapshot: Snapshot) -> list[Finding]:
    """A finding for each workspace an interrupted run left behind."""
    return [
        Finding(
            "error",
            "interrupted run",
            f"its original files are kept in {path}",
        )
        for path in snapshot.interrupted
    ]


# Remove -----------------------------------------------------------------------


def plan_remove(snapshot: Snapshot) -> Plan:
    """The operations that give Insiders its own copy of everything shared."""
    stable, insiders = snapshot.stable, snapshot.insiders
    operations: list[Operation] = []
    findings: list[Finding] = []
    restored: set[str] = set()
    listed = insiders.referenced()
    for manifest in insiders.manifests:
        entries = list(manifest.entries)
        for reference in manifest.references:
            entry = _relocated(reference, insiders)
            if entry is not None:
                entries[reference.index] = entry
        operations += _rewrite(manifest, entries)
    for name in sorted(listed):
        folder = insiders.folder(name)
        if not folder.links_into(*stable.roots) or folder.target is None:
            continue
        if folder.target_exists():
            operations.append(RestoreFolder(name, folder.path, folder.target))
            restored.add(name)
        else:
            findings.append(
                Finding("error", name, "links to a missing Stable folder")
            )
    for name, folder in insiders.folders.items():
        if not folder.links_into(*stable.roots) or name in listed:
            continue
        if not _EXTENSION_FOLDER.fullmatch(name) and folder.target_exists():
            assert folder.target is not None
            operations.append(RestoreFolder(name, folder.path, folder.target))
        else:
            operations.append(UnlinkFolder(name, folder.path))
    operations += _unmark(insiders.obsolete, restored)
    for item in snapshot.items:
        if item.status is ItemStatus.LINKED:
            operations.append(RestoreItem(item.name, item.target, item.source))
        elif item.status is ItemStatus.BROKEN:
            operations.append(UnlinkItem(item.name, item.target))
    return Plan(
        "remove",
        tuple(operations),
        (),
        tuple(findings + _interrupted(snapshot)),
        snapshot.items,
    )


# Clean ------------------------------------------------------------------------


def plan_clean(snapshot: Snapshot, editions: Iterable[Edition]) -> Plan:
    """Quarantine duplicate builds no profile uses.

    In each group of folders holding builds of one extension for one
    platform, the newest build stays, and so does every folder a profile
    lists. For Stable that includes the folders Insiders links to.
    """
    operations: list[Operation] = []
    for edition in editions:
        side = snapshot.side(edition)
        protected = side.referenced()
        if edition is Edition.STABLE:
            for folder in snapshot.insiders.folders.values():
                if folder.links_into(*side.roots) and folder.target:
                    protected.add(folder.target.name)
        groups: dict[tuple[str, str | None], list[Folder]] = {}
        for folder in side.folders.values():
            if folder.kind is Kind.DIRECTORY and folder.package is not None:
                key = (folder.package.extension_id, folder.package.platform)
                groups.setdefault(key, []).append(folder)
        for _, group in sorted(groups.items()):
            if len(group) < 2:
                continue
            newest = max(group, key=_build_order)
            for folder in sorted(group, key=lambda item: item.name):
                if folder is newest or folder.name in protected:
                    continue
                operations.append(
                    Quarantine(edition, folder.name, folder.path)
                )
    return Plan(
        "clean",
        tuple(operations),
        (),
        tuple(_interrupted(snapshot)),
        snapshot.items,
    )


def _build_order(folder: Folder) -> tuple[Version, str]:
    """The order of builds in a group: version, then name."""
    assert folder.package is not None
    return folder.package.version, folder.name


def without_findings(plan: Plan) -> Plan:
    """The plan with only its operations, for comparing two plans."""
    return replace(plan, decisions=(), findings=(), items=())


def scope_order(scope: str) -> tuple[int, str]:
    """Reports list the default profile first, then the others by name."""
    return (0 if scope == DEFAULT_SCOPE else 1, scope.casefold())
