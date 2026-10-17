"""What a run would change, worked out from a read-only snapshot.

Stable's desktop edition provides the builds; a consumer shares them:
Insiders, or VS Code Server for Stable or Insiders clients. Sharing follows
the consumer's own lists: an extension is shared only where one of its
profiles already has it. Each entry is matched with the build Stable uses
for it, taken from the Stable profile of the same name and otherwise from
the newest build any Stable profile uses. Stable must still list the folder
and not have marked it for deletion, and for a server the build must run on
the newest server installed (``Side.server``). Only Insiders shares user
files.

- The same build: Insiders' folder becomes a link to Stable's.
- A newer build in Stable: the entry follows it, and the link is made.
- A newer build in Insiders' own folder: Insiders keeps it.
- Extensions in ``EXCLUDED``: Insiders keeps its own copies; a link to
  Stable's is replaced by a copy.
- A link to a folder Stable no longer lists becomes Insiders' own copy.
- An entry whose folder is missing is repaired: it moves to another build
  Insiders has, or the build is downloaded again (``installs``) and adopted
  from ``Downloads``.

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
from .inventory import Folder, Kind, Server, inspect, scan, servers
from .jsondata import as_object
from .manifest import (
    DEFAULT_SCOPE,
    Manifest,
    Obsolete,
    Reference,
    encode,
    location_payload,
    read_manifest,
    read_manifests,
    read_obsolete,
)
from .versions import Version, engine_allows, parse_version

EXCLUDED = ("anthropic.claude-code", "github.copilot")
"""Extensions each edition keeps its own copy of, with their families.

Copilot's builds follow the editor's engine version, which differs between
Stable and Insiders; Claude Code ships a native binary with each build. A
family member such as ``github.copilot-chat`` is excluded with its root.
"""

ITEMS = ("settings.json", "keybindings.json", "snippets", "mcp.json")
"""The user files Insiders shares with Stable through links."""


def is_excluded(extension_id: str) -> bool:
    """Whether an extension stays native to each edition."""
    return any(
        extension_id == root or extension_id.startswith(f"{root}-")
        for root in EXCLUDED
    )


_FOLLOWED_METADATA = ("targetPlatform", "isPreReleaseVersion")
_EXTENSION_FOLDER = re.compile(r"[^.]+\.[^.].*-\d+(\.\d+)*(-.+)?")

# Snapshot ---------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Side:
    """One edition as it was read: its folders, manifests and deletions.

    ``roots`` is the extensions directory as written and as resolved;
    ``server`` the newest installed build of a server edition.
    """

    edition: Edition
    root: Path
    roots: tuple[Path, ...]
    user_dir: Path
    folders: Mapping[str, Folder]
    manifests: tuple[Manifest, ...]
    obsolete: Obsolete
    server: Server | None = None

    @property
    def installed(self) -> bool:
        """Whether the edition has run here: it has either directory."""
        return self.root.is_dir() or self.user_dir.is_dir()

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
    consumer: Side
    items: tuple[Item, ...]
    interrupted: tuple[Path, ...] = ()

    @property
    def label(self) -> str:
        """The consumer's name, for reports."""
        return self.consumer.edition.label


def take_snapshot(
    host: Host, consumer: Edition = Edition.INSIDERS
) -> Snapshot:
    """Read Stable, one consumer and the state directory.

    Raises:
        SyncError: If a manifest, profile list or ``.obsolete`` file
            cannot be parsed.
    """
    stable = read_side(host, Edition.STABLE)
    side = read_side(host, consumer)
    items: tuple[Item, ...] = ()
    if consumer is Edition.INSIDERS:
        items = tuple(_item(stable, side, name) for name in ITEMS)
    return Snapshot(stable, side, items, interrupted_runs(host))


def interrupted_runs(host: Host) -> tuple[Path, ...]:
    """The run workspaces an interruption left behind."""
    try:
        return tuple(sorted((host.state_dir() / "runs").iterdir()))
    except FileNotFoundError:
        return ()


def read_side(host: Host, edition: Edition) -> Side:
    """Read one edition.

    Raises:
        SyncError: If a manifest, profile list or ``.obsolete`` file
            cannot be parsed.
    """
    root = host.extensions_dir(edition)
    resolved = Path(os.path.realpath(root))
    builds = servers(host.server_builds(edition)) if edition.is_server else []
    return Side(
        edition,
        root,
        (root,) if resolved == root else (root, resolved),
        host.user_dir(edition),
        scan(root),
        read_manifests(host, edition),
        read_obsolete(root),
        builds[0] if builds else None,
    )


def _item(stable: Side, consumer: Side, name: str) -> Item:
    """Classify one user file."""
    source = stable.user_dir / name
    target = consumer.user_dir / name
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
    INSTALL = "install"


ACTION_TONES = {
    Action.SHARED: "ok",
    Action.LINK: "pending",
    Action.REBIND: "pending",
    Action.RELOCATE: "pending",
    Action.RESTORE: "pending",
    Action.NATIVE: "muted",
    Action.FOREIGN: "warn",
    Action.INSTALL: "pending",
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
    """Make ``path``, a folder link or nothing, a copy of ``source``."""

    name: str
    path: Path
    source: Path


@dataclass(frozen=True, slots=True)
class UnlinkFolder:
    """Remove a folder link nobody lists any more."""

    name: str
    path: Path


@dataclass(frozen=True, slots=True)
class AdoptFolder:
    """Move a downloaded build into Insiders' extensions directory."""

    name: str
    path: Path
    source: Path


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


@dataclass(frozen=True, slots=True)
class Install:
    """Download a build for entries whose folder is missing.

    ``version`` is the build the entries named; ``pre_release`` whether it
    was a pre-release, so that a fallback to the latest build keeps to the
    same channel.
    """

    extension_id: str
    version: str | None
    pre_release: bool = False


Operation = (
    LinkFolder
    | RestoreFolder
    | UnlinkFolder
    | AdoptFolder
    | LinkItem
    | RestoreItem
    | UnlinkItem
    | WriteFile
    | Quarantine
)


@dataclass(frozen=True, slots=True)
class Plan:
    """The operations of a run, and what was found while planning them.

    ``installs`` are downloads a run makes before its operations; the
    builds they bring are adopted by planning again with ``Downloads``.
    """

    command: str
    operations: tuple[Operation, ...] = ()
    installs: tuple[Install, ...] = ()
    decisions: tuple[Decision, ...] = ()
    findings: tuple[Finding, ...] = ()
    items: tuple[Item, ...] = ()
    consumer: Edition | None = None

    @property
    def changed(self) -> bool:
        """Whether the run would change anything."""
        return bool(self.operations or self.installs)

    @property
    def size(self) -> int:
        """How many changes the run would make."""
        return len(self.operations) + len(self.installs)

    @property
    def problems(self) -> int:
        """Findings and decisions that need a person."""
        tones = [finding.tone for finding in self.findings]
        tones += [ACTION_TONES[decision.action] for decision in self.decisions]
        return sum(tone == "error" for tone in tones)


# Setup ------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class _Build:
    """A build an Insiders entry can name.

    ``reference`` is an entry listing it, whose version and build metadata
    the Insiders entry takes over.
    """

    folder: str
    version: Version | None
    reference: Reference
    engine: object = None


@dataclass(frozen=True, slots=True)
class Downloads:
    """Builds downloaded for entries whose folder is missing, by extension."""

    root: Path
    builds: Mapping[str, _Build] = field(default_factory=dict[str, _Build])


def read_downloads(root: Path) -> Downloads:
    """The builds VS Code's command line installed into ``root``.

    Only a build whose folder holds the extension its entry names counts.

    Raises:
        SyncError: If the manifest there cannot be parsed.
    """
    manifest = read_manifest(root / "extensions.json", "downloads")
    builds: dict[str, _Build] = {}
    for reference in manifest.references if manifest else ():
        folder = inspect(root, reference.folder)
        package = folder.package
        if folder.kind is Kind.DIRECTORY and package is not None:
            if package.extension_id == reference.extension_id:
                build = _Build(reference.folder, package.version, reference)
                builds[reference.extension_id] = build
    return Downloads(root, builds)


@dataclass(slots=True)
class _Setup:
    """The working state of a plan that decides Insiders' entries.

    ``local`` are Insiders' own builds an entry with a missing folder can
    move to; ``dangling`` are this tool's links whose Stable folder is gone.
    """

    snapshot: Snapshot
    downloads: Downloads | None = None
    local: Mapping[str, list[_Build]] = field(
        default_factory=dict[str, list[_Build]]
    )
    blocked: set[str] = field(default_factory=set[str])
    decisions: list[Decision] = field(default_factory=list[Decision])
    findings: list[Finding] = field(default_factory=list[Finding])
    shared: set[str] = field(default_factory=set[str])
    restored: dict[str, Path] = field(default_factory=dict[str, Path])
    dangling: set[str] = field(default_factory=set[str])
    adopted: dict[str, Path] = field(default_factory=dict[str, Path])
    installs: dict[str, Install] = field(default_factory=dict[str, Install])

    def operations(self, listed: set[str]) -> list[Operation]:
        """Copies, removed dangling links and adoptions, in that order."""
        consumer = self.snapshot.consumer
        operations: list[Operation] = [
            RestoreFolder(name, consumer.root / name, source)
            for name, source in sorted(self.restored.items())
        ]
        operations += [
            UnlinkFolder(name, consumer.root / name)
            for name in sorted(self.dangling & listed)
        ]
        operations += [
            AdoptFolder(name, consumer.root / name, source)
            for name, source in sorted(self.adopted.items())
        ]
        return operations

    def kept(self) -> set[str]:
        """The folders the plan relies on, kept off the deletion list."""
        return self.shared | set(self.restored) | set(self.adopted)


def plan_setup(snapshot: Snapshot, downloads: Downloads | None = None) -> Plan:
    """The operations that make a consumer share what it can with Stable."""
    absent = unusable(snapshot)
    if absent is not None:
        return Plan(
            "setup",
            findings=(absent, *_interrupted(snapshot)),
            consumer=snapshot.consumer.edition,
        )
    stable, consumer = snapshot.stable, snapshot.consumer
    state = _Setup(snapshot, downloads, _live_builds(consumer))
    builds = _runnable(state, _live_builds(stable))
    operations: list[Operation] = []
    listed: set[str] = set()
    for manifest in consumer.manifests:
        entries = list(manifest.entries)
        for reference in manifest.references:
            entry = _decide(state, builds, manifest.scope, reference)
            target = reference.folder
            if entry is not None:
                if entry != reference.entry:
                    entries[reference.index] = entry
                target = _entry_folder(entry, reference.folder)
            listed.add(target)
        listed |= _unusable_folders(manifest, entries)
        operations += _rewrite(manifest, entries)
    for name in sorted(state.shared):
        folder = consumer.folder(name)
        if not _shares(folder, stable, name):
            operations.append(
                LinkFolder(name, folder.path, stable.root / name)
            )
    operations += state.operations(listed)
    for name, folder in consumer.folders.items():
        if not folder.links_into(*stable.roots) or name in listed:
            continue
        if _EXTENSION_FOLDER.fullmatch(name):
            operations.append(UnlinkFolder(name, folder.path))
        else:
            state.findings.append(
                Finding(
                    "muted",
                    name,
                    "A shared folder that is no extension; left as it is",
                )
            )
    operations += _unmark(consumer.obsolete, state.kept())
    item_operations, item_findings = _setup_items(snapshot)
    return Plan(
        "setup",
        tuple(item_operations + operations),
        tuple(state.installs.values()),
        tuple(state.decisions),
        tuple(item_findings + state.findings + _interrupted(snapshot)),
        snapshot.items,
        consumer.edition,
    )


def unusable(snapshot: Snapshot) -> Finding | None:
    """Why the consumer cannot share at all, if it cannot.

    A server whose builds were all removed cannot tell which extensions
    would run on it, nor download any, so nothing is decided for it.
    """
    side = snapshot.consumer
    subject = f"VS Code {side.edition.label}"
    if not side.installed:
        return Finding(
            "muted", subject, "Not installed here; nothing to share"
        )
    if side.edition.is_server and side.server is None:
        return Finding(
            "muted",
            subject,
            "No server build is installed; a remote client installs one",
        )
    return None


def _runnable(
    state: _Setup, builds: dict[str, list[_Build]]
) -> dict[str, list[_Build]]:
    """The builds the consumer can run; the others are noted as blocked."""
    server = state.snapshot.consumer.server
    if server is None:
        return builds
    runnable: dict[str, list[_Build]] = {}
    for ident, candidates in builds.items():
        kept = [
            b for b in candidates if engine_allows(b.engine, server.version)
        ]
        if kept:
            runnable[ident] = kept
        else:
            state.blocked.add(ident)
    return runnable


def _live_builds(side: Side) -> dict[str, list[_Build]]:
    """An edition's builds an Insiders entry may name, by extension.

    A build is live when a profile of the edition lists it, its folder is a
    real directory and VS Code has not marked it for deletion.
    """
    builds: dict[str, list[_Build]] = {}
    seen: set[str] = set()
    for manifest in side.manifests:
        for reference in manifest.references:
            name = reference.folder
            if name in seen or name in side.obsolete.names:
                continue
            folder = side.folder(name)
            if folder.kind is not Kind.DIRECTORY:
                continue
            seen.add(name)
            version = (
                folder.package.version
                if folder.package
                else parse_version(reference.version)
            )
            engine = folder.package.engine if folder.package else None
            build = _Build(name, version, reference, engine)
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
    newest = _newest(candidates)
    if newest is not None:
        return newest
    return candidates[0] if len(candidates) == 1 else None


def _decide(
    state: _Setup,
    builds: Mapping[str, list[_Build]],
    scope: str,
    reference: Reference,
) -> dict[str, object] | None:
    """Decide one Insiders entry; the entry it should become, if any."""
    stable, consumer = state.snapshot.stable, state.snapshot.consumer
    name = reference.folder
    folder = consumer.folder(name)
    ours = folder.links_into(*stable.roots)

    def note(action: Action, target: str = name, detail: str = "") -> None:
        """Record the decision for this entry."""
        state.decisions.append(
            Decision(
                scope, reference.extension_id, name, target, action, detail
            )
        )

    gone = folder.kind is Kind.MISSING or (ours and not folder.target_exists())
    if is_excluded(reference.extension_id):
        if gone:
            return _repair(state, scope, reference)
        if ours and folder.target is not None:
            state.restored[name] = folder.target
            note(Action.RESTORE, detail="Kept as its own copy")
        else:
            note(Action.NATIVE, detail="Keeps its own copy")
        return _relocated(reference, consumer)
    build = _choose(stable, builds, scope, reference.extension_id)
    if build is None:
        if gone:
            return _repair(state, scope, reference)
        server = state.snapshot.consumer.server
        too_new = (
            f"Stable's build needs a newer VS Code than {server.version}"
            if server is not None and reference.extension_id in state.blocked
            else None
        )
        if ours and folder.target is not None:
            state.restored[name] = folder.target
            why = too_new or "Stable no longer lists it"
            note(Action.RESTORE, detail=f"{why}; a copy is kept")
        else:
            note(Action.NATIVE, detail=too_new or "Stable does not have it")
        return _relocated(reference, consumer)
    if folder.kind is Kind.LINK and not ours:
        note(Action.FOREIGN, detail=f"Links to {folder.link}")
        return _relocated(reference, consumer)
    if name != build.folder and folder.kind is Kind.DIRECTORY:
        current = folder.package.version if folder.package else None
        if current is None or build.version is None:
            note(Action.NATIVE, detail="Versions cannot be compared")
            return _relocated(reference, consumer)
        if current > build.version:
            note(Action.NATIVE, detail=f"Newer than Stable's {build.version}")
            return _relocated(reference, consumer)
    entry = _shared_entry(reference, build, consumer.root)
    state.shared.add(build.folder)
    linked = _shares(consumer.folder(build.folder), stable, build.folder)
    if name != build.folder:
        note(Action.REBIND, build.folder, f"Stable uses {build.version}")
    elif not linked:
        note(Action.LINK, detail="Shares Stable's folder")
    elif entry != reference.entry:
        note(Action.RELOCATE, detail=_relocation(reference, stable))
    else:
        note(Action.SHARED)
    return entry


def _repair(
    state: _Setup,
    scope: str,
    reference: Reference,
    stable_builds: Mapping[str, list[_Build]] | None = None,
) -> dict[str, object] | None:
    """Repair an entry whose folder is missing; the entry it becomes.

    In order: a build downloaded for it, a copy of Stable's build (only
    when ``stable_builds`` is given, for an extension Stable may share),
    the newest build Insiders has of its own, or a download. This tool's
    link whose Stable folder is gone is removed first.
    """
    consumer = state.snapshot.consumer
    name, ident = reference.folder, reference.extension_id
    if consumer.folder(name).kind is Kind.LINK:
        state.dangling.add(name)

    def note(action: Action, target: str, detail: str) -> None:
        """Record the decision for this entry."""
        state.decisions.append(
            Decision(scope, ident, name, target, action, detail)
        )

    downloaded = state.downloads.builds.get(ident) if state.downloads else None
    if downloaded is not None and state.downloads is not None:
        state.adopted[downloaded.folder] = (
            state.downloads.root / downloaded.folder
        )
        note(Action.INSTALL, downloaded.folder, "Downloaded again")
        return _shared_entry(reference, downloaded, consumer.root)
    if stable_builds is not None and not is_excluded(ident):
        stable = state.snapshot.stable
        build = _newest(stable_builds.get(ident, []))
        present = consumer.folder(build.folder) if build else None
        if build is not None and present is not None:
            if present.kind is Kind.MISSING or present.links_into(
                *stable.roots
            ):
                state.restored[build.folder] = stable.root / build.folder
                note(Action.RESTORE, build.folder, "Copied from Stable")
                return _shared_entry(reference, build, consumer.root)
            if present.kind is Kind.DIRECTORY:
                note(Action.REBIND, build.folder, "Its own folder is there")
                return _shared_entry(reference, build, consumer.root)
    local = _newest(state.local.get(ident, []))
    if local is not None:
        note(
            Action.REBIND,
            local.folder,
            f"Its folder is missing; uses {local.version}",
        )
        return _shared_entry(reference, local, consumer.root)
    metadata = as_object(reference.entry.get("metadata")) or {}
    state.installs.setdefault(
        ident,
        Install(
            ident,
            reference.version,
            metadata.get("isPreReleaseVersion") is True,
        ),
    )
    note(Action.INSTALL, name, "Its folder is missing; downloads it again")
    return None


def _newest(builds: list[_Build]) -> _Build | None:
    """The newest build whose version can be read."""
    versioned = [build for build in builds if build.version is not None]
    if not versioned:
        return None
    return max(versioned, key=lambda build: (build.version, build.folder))


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
        return "Entry points into Stable's directory"
    return "Entry names another location"


def _relocated(
    reference: Reference, consumer: Side
) -> dict[str, object] | None:
    """The entry with its location inside Insiders' directory, if it is not.

    Only an entry whose folder exists there is moved; other entries are
    left as they are.
    """
    path = consumer.root / reference.folder
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
    if not snapshot.items:
        return operations, findings
    if not snapshot.consumer.user_dir.is_dir():
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
            operations.append(UnlinkItem(item.name, item.target))
        elif item.status is ItemStatus.FOREIGN:
            findings.append(
                Finding("warn", item.name, f"Links to {item.link}; left alone")
            )
    return operations, findings


def _interrupted(snapshot: Snapshot) -> list[Finding]:
    """A finding for each workspace an interrupted run left behind."""
    return list(_interrupted_in(snapshot.interrupted))


def _interrupted_in(paths: Iterable[Path]) -> tuple[Finding, ...]:
    """A finding for each of the workspaces ``paths``."""
    return tuple(
        Finding(
            "pending",
            "interrupted run",
            f"The next change undoes it, from {path}",
        )
        for path in paths
    )


# Remove -----------------------------------------------------------------------


def plan_remove(
    snapshot: Snapshot, downloads: Downloads | None = None
) -> Plan:
    """The operations that give Insiders its own copy of everything shared.

    An entry whose folder is a link to a Stable folder that is gone is
    repaired like in setup, with a copy of Stable's build first.
    """
    stable, consumer = snapshot.stable, snapshot.consumer
    state = _Setup(snapshot, downloads, _live_builds(consumer))
    builds = _runnable(state, _live_builds(stable))
    operations: list[Operation] = []
    listed: set[str] = set()
    for manifest in consumer.manifests:
        entries = list(manifest.entries)
        for reference in manifest.references:
            folder = consumer.folder(reference.folder)
            if folder.links_into(*stable.roots) and not folder.target_exists():
                entry = _repair(state, manifest.scope, reference, builds)
            else:
                entry = _relocated(reference, consumer)
            target = reference.folder
            if entry is not None:
                entries[reference.index] = entry
                target = _entry_folder(entry, reference.folder)
            listed.add(target)
        listed |= _unusable_folders(manifest, entries)
        operations += _rewrite(manifest, entries)
    for name in sorted(listed - set(state.restored) - state.dangling):
        folder = consumer.folder(name)
        if folder.links_into(*stable.roots) and folder.target is not None:
            state.restored[name] = folder.target
    operations += state.operations(listed)
    for name, folder in consumer.folders.items():
        if not folder.links_into(*stable.roots) or name in listed:
            continue
        if not _EXTENSION_FOLDER.fullmatch(name) and folder.target_exists():
            assert folder.target is not None
            operations.append(RestoreFolder(name, folder.path, folder.target))
        else:
            operations.append(UnlinkFolder(name, folder.path))
    operations += _unmark(consumer.obsolete, state.kept())
    for item in snapshot.items:
        if item.status is ItemStatus.LINKED:
            operations.append(RestoreItem(item.name, item.target, item.source))
        elif item.status is ItemStatus.BROKEN:
            operations.append(UnlinkItem(item.name, item.target))
    return Plan(
        "remove",
        tuple(operations),
        tuple(state.installs.values()),
        tuple(state.decisions),
        tuple(_interrupted(snapshot)),
        snapshot.items,
        consumer.edition,
    )


# Clean ------------------------------------------------------------------------


def plan_clean(
    sides: Mapping[Edition, Side],
    editions: Iterable[Edition],
    interrupted: tuple[Path, ...] = (),
) -> Plan:
    """Quarantine duplicate builds no profile uses.

    In each group of folders holding builds of one extension for one
    platform, the newest build stays, and so does every folder a profile
    lists. For Stable that includes the folders any consumer links to.
    """
    operations: list[Operation] = []
    for edition in editions:
        side = sides[edition]
        protected = side.referenced()
        if edition is Edition.STABLE:
            for other in sides.values():
                for folder in other.folders.values():
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
        "clean", tuple(operations), findings=_interrupted_in(interrupted)
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
