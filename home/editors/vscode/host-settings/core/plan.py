"""Work out the edits a run makes, and prove they change only what they should.

Planning has four parts, each returning a ``Fragment``: the top-level keys,
the nested strings, the Settings Sync exclusion list, and the placement of
new text. The merged edits are applied to the source in memory and the result
is verified against the original; nothing here writes a file.
"""

from collections import Counter
from collections.abc import Collection, Mapping
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

from . import PROG
from .errors import SettingsError
from .host import Host
from .jsonc import (
    ArrayNode,
    Document,
    JsonNode,
    Member,
    NodePath,
    ObjectNode,
    Span,
    StringNode,
    describe_path,
    diff_paths,
    parse,
)
from .manifest import (
    HOST_BOUND,
    IGNORED_KEY,
    LEAVES,
    NESTED,
    Key,
    ObjectWith,
    Step,
    StringWithPrefix,
)
from .text import Edit, Layout, apply_edits, json_string, line_start

BLOCK_BEGIN_PREFIX = f"// >>> {PROG}"
BLOCK_END_PREFIX = f"// <<< {PROG}"
BLOCK_BEGIN = (
    f"{BLOCK_BEGIN_PREFIX}: generated for this host, "
    f"refresh with `{PROG} apply` >>>"
)
BLOCK_END = f"{BLOCK_END_PREFIX} <<<"


class ChangeAction(Enum):
    """What a change does to its subject."""

    ADD = "add"
    UPDATE = "update"


@dataclass(frozen=True, slots=True)
class Change:
    """One value a run writes; ``old`` is None for a new one."""

    subject: str
    action: ChangeAction
    old: str | None
    new: str


class FindingKind(Enum):
    """What a finding reports.

    ``UNRESOLVED``: a managed value whose target is not on this machine.
    ``ABSENT``: a nested target that is not in the file.
    ``NOTICE``: a managed value deliberately left alone.
    ``UNMANAGED``: a host-bound value the manifest does not cover.
    """

    UNRESOLVED = "unresolved"
    ABSENT = "absent"
    NOTICE = "notice"
    UNMANAGED = "unmanaged"


@dataclass(frozen=True, slots=True)
class Finding:
    """Something a run reports without changing it."""

    kind: FindingKind
    subject: str
    detail: str = ""


@dataclass(frozen=True, slots=True)
class Plan:
    """What a run would do to one settings file."""

    path: Path
    old_text: str
    new_text: str
    changes: tuple[Change, ...]
    findings: tuple[Finding, ...]

    @property
    def changed(self) -> bool:
        """Whether applying the plan alters the file."""
        return self.old_text != self.new_text

    def of_kind(self, kind: FindingKind) -> tuple[Finding, ...]:
        """The findings of one kind, in the order they were made."""
        return tuple(f for f in self.findings if f.kind is kind)


@dataclass(frozen=True, slots=True)
class Fragment:
    """What one part of the planning contributes.

    ``touched`` are the paths whose value may change, ``inserted`` the
    top-level keys that may appear or disappear, and ``managed`` the paths
    the scan for unmanaged host-bound values skips.
    """

    edits: tuple[Edit, ...] = ()
    changes: tuple[Change, ...] = ()
    findings: tuple[Finding, ...] = ()
    touched: frozenset[NodePath] = frozenset()
    inserted: frozenset[str] = frozenset()
    managed: frozenset[NodePath] = frozenset()

    def __add__(self, other: "Fragment") -> "Fragment":
        return Fragment(
            self.edits + other.edits,
            self.changes + other.changes,
            self.findings + other.findings,
            self.touched | other.touched,
            self.inserted | other.inserted,
            self.managed | other.managed,
        )


@dataclass(frozen=True, slots=True)
class GeneratedBlock:
    """The marked block the tool owns, markers included, and its values."""

    start: int
    end: int
    values: Mapping[str, str]

    @classmethod
    def find(
        cls, doc: Document, managed: Collection[str]
    ) -> "GeneratedBlock | None":
        """Locate the block, if there is one.

        Raises:
            SettingsError: If the markers are damaged, split a setting, or
                enclose a key that is not managed or not a string.
        """
        span = _block_span(doc)
        if span is None:
            return None
        start, end = span
        values: dict[str, str] = {}
        for member in doc.root.members:
            first = line_start(doc.text, member.start)
            inside = start <= first and member.end <= end
            if not inside and not (member.end <= start or first >= end):
                raise SettingsError(
                    "the generated block markers split a setting in two"
                )
            if not inside:
                continue
            if member.key not in managed:
                raise SettingsError(
                    f"the generated block holds {member.key!r}, which is not "
                    "managed; refusing to drop it"
                )
            values[member.key] = _require_string(member).value
        return cls(start, end, values)


def _block_span(doc: Document) -> Span | None:
    """The whole lines from the begin marker through the end marker.

    A marker counts only as a line comment on a line of its own.

    Raises:
        SettingsError: Unless there is no marker at all or exactly one begin
            marker followed by exactly one end marker.
    """
    text = doc.text
    begins: list[int] = []
    ends: list[int] = []
    for comment in doc.comments:
        first = line_start(text, comment.start)
        if text[first : comment.start].strip():
            continue
        body = text[comment.start : comment.end]
        if body.startswith(BLOCK_BEGIN_PREFIX):
            begins.append(first)
        elif body.startswith(BLOCK_END_PREFIX):
            newline = text.find("\n", comment.end)
            ends.append(len(text) if newline < 0 else newline + 1)
    if not begins and not ends:
        return None
    if len(begins) != 1 or len(ends) != 1 or begins[0] >= ends[0]:
        raise SettingsError(
            "the generated block markers are damaged: expected exactly "
            "one begin and one end marker, in that order. Fix or remove "
            "them by hand."
        )
    return Span(begins[0], ends[0])


def build_plan(path: Path, text: str, host: Host) -> Plan:
    """Work out the edits a run would make to ``text`` without writing.

    Args:
        path: The file the text came from, for the report.
        text: The settings text without a byte order mark.
        host: The machine whose values are resolved.

    Raises:
        SettingsError: If the file cannot be edited safely or the result
            fails verification against the original.
    """
    doc = parse(text)
    layout = Layout.detect(doc)
    block = GeneratedBlock.find(doc, {leaf.key for leaf in LEAVES})
    leaves, entries = _plan_leaves(doc, block, host)
    ignore_list, ignore_member = _plan_ignore_list(doc, layout)
    fragment = (
        leaves
        + _plan_nested(doc, host)
        + ignore_list
        + _plan_placement(doc, layout, block, entries, ignore_member)
    )
    new_text = apply_edits(text, fragment.edits)
    if new_text != text:
        _verify(doc, new_text, fragment)
    unmanaged = _scan_host_bound(parse(new_text), fragment.managed)
    return Plan(
        path, text, new_text, fragment.changes, fragment.findings + unmanaged
    )


# Planning ---------------------------------------------------------------------


def _plan_leaves(
    doc: Document, block: GeneratedBlock | None, host: Host
) -> tuple[Fragment, dict[str, str]]:
    """Plan the top-level keys.

    A key that exists outside the block is updated in place. A key the block
    holds, or one that is missing, is returned as an entry for the rewritten
    block; a block entry that no longer resolves is stale and dropped.

    Returns:
        The fragment and the block entries, in manifest order.
    """
    edits: list[Edit] = []
    changes: list[Change] = []
    findings: list[Finding] = []
    touched: set[NodePath] = set()
    inserted: set[str] = set()
    entries: dict[str, str] = {}
    held: Mapping[str, str] = block.values if block is not None else {}
    for leaf in LEAVES:
        member = _single(doc, leaf.key)
        resolved = leaf.resolver.resolve(host)
        hint = leaf.resolver.hint
        if leaf.key in held:
            inserted.add(leaf.key)
            old = held[leaf.key]
            if resolved is None:
                detail = f"{hint}; removed from the generated block"
                findings.append(
                    Finding(FindingKind.UNRESOLVED, leaf.key, detail)
                )
                continue
            entries[leaf.key] = resolved
            if resolved != old:
                touched.add((leaf.key,))
                changes.append(
                    Change(leaf.key, ChangeAction.UPDATE, old, resolved)
                )
        elif member is not None:
            node = _require_string(member)
            if resolved is None:
                findings.append(
                    Finding(FindingKind.UNRESOLVED, leaf.key, hint)
                )
            elif resolved != node.value:
                edits.append(Edit(node.start, node.end, json_string(resolved)))
                touched.add((leaf.key,))
                changes.append(
                    Change(leaf.key, ChangeAction.UPDATE, node.value, resolved)
                )
        elif resolved is not None:
            entries[leaf.key] = resolved
            inserted.add(leaf.key)
            changes.append(Change(leaf.key, ChangeAction.ADD, None, resolved))
        else:
            findings.append(Finding(FindingKind.UNRESOLVED, leaf.key, hint))
    fragment = Fragment(
        tuple(edits),
        tuple(changes),
        tuple(findings),
        frozenset(touched),
        frozenset(inserted),
        frozenset((leaf.key,) for leaf in LEAVES),
    )
    return fragment, entries


def _plan_nested(doc: Document, host: Host) -> Fragment:
    """Plan the nested strings; a target that is ambiguous is left alone."""
    edits: list[Edit] = []
    changes: list[Change] = []
    findings: list[Finding] = []
    touched: set[NodePath] = set()
    managed: set[NodePath] = set()
    for nested in NESTED:
        matches = _locate(doc.root, nested.steps)
        if not matches:
            findings.append(Finding(FindingKind.ABSENT, nested.label))
            continue
        if len(matches) > 1:
            detail = f"{len(matches)} matches, left alone"
            findings.append(Finding(FindingKind.NOTICE, nested.label, detail))
            continue
        node, path = matches[0]
        managed.add(path)
        if not isinstance(node, StringNode):
            detail = "not a string, left alone"
            findings.append(Finding(FindingKind.NOTICE, nested.label, detail))
            continue
        subject = describe_path(path)
        resolved = nested.resolver.resolve(host)
        if resolved is None:
            findings.append(
                Finding(FindingKind.UNRESOLVED, subject, nested.resolver.hint)
            )
        elif resolved != node.value:
            edits.append(Edit(node.start, node.end, json_string(resolved)))
            touched.add(path)
            changes.append(
                Change(subject, ChangeAction.UPDATE, node.value, resolved)
            )
    return Fragment(
        tuple(edits),
        tuple(changes),
        tuple(findings),
        frozenset(touched),
        managed=frozenset(managed),
    )


def _plan_ignore_list(doc: Document, layout: Layout) -> tuple[Fragment, str]:
    """Plan the Settings Sync exclusion of every managed top-level key.

    A key the list names with a leading ``-`` is synced on purpose and
    stays synced.

    Returns:
        The fragment and, when the list does not exist yet, the text of the
        member that creates it.
    """
    wanted = [leaf.key for leaf in LEAVES]
    member = _single(doc, IGNORED_KEY)
    if member is None:
        indent, newline = layout.indent, layout.newline
        lines = "".join(
            f"{indent}{indent}{json_string(key)},{newline}" for key in wanted
        )
        text = (
            f"{indent}{json_string(IGNORED_KEY)}: [{newline}"
            f"{lines}{indent}],{newline}"
        )
        change = Change(IGNORED_KEY, ChangeAction.ADD, None, ", ".join(wanted))
        created = Fragment(
            changes=(change,), inserted=frozenset({IGNORED_KEY})
        )
        return created, text
    array = member.value
    present = _string_items(array) if isinstance(array, ArrayNode) else None
    if not isinstance(array, ArrayNode) or present is None:
        raise SettingsError(
            f"{IGNORED_KEY} is not a list of strings, refusing to edit it"
        )
    findings: list[Finding] = []
    missing: list[str] = []
    for key in wanted:
        if f"-{key}" in present:
            detail = (
                f"listed as '-{key}' in {IGNORED_KEY}, so it stays synced; "
                "remove that entry to keep it per machine"
            )
            findings.append(Finding(FindingKind.NOTICE, key, detail))
        elif key not in present:
            missing.append(key)
    if not missing:
        return Fragment(findings=tuple(findings)), ""
    edit = _append_to_array(doc.text, array, missing, layout)
    change = Change(IGNORED_KEY, ChangeAction.ADD, None, ", ".join(missing))
    fragment = Fragment(
        (edit,),
        (change,),
        tuple(findings),
        touched=frozenset({(IGNORED_KEY,)}),
    )
    return fragment, ""


def _plan_placement(
    doc: Document,
    layout: Layout,
    block: GeneratedBlock | None,
    entries: Mapping[str, str],
    ignore_member: str,
) -> Fragment:
    """Plan where new text goes.

    The block is rewritten as a whole, or appended at the end of the root
    object when there is none yet. A new exclusion list goes before the
    block, never inside it.
    """
    text = doc.text
    block_text = _render_block(entries, layout)
    edits: list[Edit] = []
    if block is not None:
        if ignore_member:
            edits += _comma_before(doc, block.start)
            edits.append(Edit(block.start, block.start, ignore_member))
        if block_text != text[block.start : block.end]:
            edits.append(Edit(block.start, block.end, block_text))
    elif block_text or ignore_member:
        edits += _insert_at_end(doc, ignore_member + block_text, layout)
    return Fragment(tuple(edits))


# Text placement ---------------------------------------------------------------


def _render_block(entries: Mapping[str, str], layout: Layout) -> str:
    """The generated block holding ``entries``, or nothing for none."""
    if not entries:
        return ""
    indent, newline = layout.indent, layout.newline
    body = "".join(
        f"{indent}{json_string(key)}: {json_string(value)},{newline}"
        for key, value in entries.items()
    )
    return f"{indent}{BLOCK_BEGIN}{newline}{body}{indent}{BLOCK_END}{newline}"


def _append_to_array(
    text: str, array: ArrayNode, keys: list[str], layout: Layout
) -> Edit:
    """Append string items to an existing array, matching its layout."""
    if not array.items:
        joined = ", ".join(json_string(key) for key in keys)
        return Edit(array.start + 1, array.start + 1, joined)
    last = array.items[-1]
    if "\n" in text[array.start : array.items[0].start]:
        pad = text[line_start(text, last.start) : last.start]
        if pad.strip():
            pad = layout.indent * 2
        extra = "".join(
            f",{layout.newline}{pad}{json_string(key)}" for key in keys
        )
    else:
        extra = "".join(f", {json_string(key)}" for key in keys)
    return Edit(last.end, last.end, extra)


def _comma_before(doc: Document, offset: int) -> list[Edit]:
    """Make sure the top-level member before ``offset`` ends in a comma."""
    before = [member for member in doc.root.members if member.end <= offset]
    if not before:
        return []
    last = before[-1]
    if last.comma is None or last.comma >= offset:
        return [Edit(last.end, last.end, ",")]
    return []


def _insert_at_end(doc: Document, addition: str, layout: Layout) -> list[Edit]:
    """Insert whole lines before the root's closing brace.

    Raises:
        SettingsError: If the closing brace shares its line with a setting.
    """
    text, root = doc.text, doc.root
    first = line_start(text, root.close)
    if not text[first : root.close].strip():
        return [*_comma_before(doc, first), Edit(first, first, addition)]
    if not root.members and not text[root.start + 1 : root.close].strip():
        return [Edit(root.start + 1, root.close, layout.newline + addition)]
    raise SettingsError(
        "cannot append to the settings: the closing brace shares a line "
        "with a setting"
    )


# Lookup -----------------------------------------------------------------------


def _single(doc: Document, key: str) -> Member | None:
    """The one top-level member called ``key``, if there is one.

    Raises:
        SettingsError: If the key appears more than once.
    """
    found = doc.root.named(key)
    if len(found) > 1:
        raise SettingsError(
            f"{key!r} appears {len(found)} times; refusing to guess"
        )
    return found[0] if found else None


def _require_string(member: Member) -> StringNode:
    """The value of ``member``, which must be a string."""
    if not isinstance(member.value, StringNode):
        raise SettingsError(
            f"{member.key} is not a string, refusing to replace it"
        )
    return member.value


def _string_items(array: ArrayNode) -> set[str] | None:
    """The items of ``array``, or None unless every one is a string."""
    strings = [item for item in array.items if isinstance(item, StringNode)]
    if len(strings) != len(array.items):
        return None
    return {item.value for item in strings}


def _locate(
    root: ObjectNode, steps: tuple[Step, ...]
) -> list[tuple[JsonNode, NodePath]]:
    """Follow ``steps`` from the root; every matching node with its path."""
    frontier: list[tuple[JsonNode, NodePath]] = [(root, ())]
    for step in steps:
        frontier = [
            found
            for node, path in frontier
            for found in _follow(node, path, step)
        ]
    return frontier


def _follow(
    node: JsonNode, path: NodePath, step: Step
) -> list[tuple[JsonNode, NodePath]]:
    """The children of ``node`` that ``step`` selects."""
    match step, node:
        case Key(name), ObjectNode() as parent:
            return [(m.value, (*path, m.key)) for m in parent.named(name)]
        case ObjectWith(key, value), ArrayNode() as parent:
            return [
                (item, (*path, index))
                for index, item in enumerate(parent.items)
                if isinstance(item, ObjectNode)
                and any(
                    isinstance(m.value, StringNode) and m.value.value == value
                    for m in item.named(key)
                )
            ]
        case StringWithPrefix(prefix), ArrayNode() as parent:
            return [
                (item, (*path, index))
                for index, item in enumerate(parent.items)
                if isinstance(item, StringNode)
                and item.value.startswith(prefix)
            ]
        case _:
            return []


# Verification -----------------------------------------------------------------


def _verify(before: Document, new_text: str, fragment: Fragment) -> None:
    """Prove the edited text differs from the original only where planned.

    Only the keys the fragment inserts may appear or disappear, the other
    keys keep their order, values change only at touched paths, and the
    exclusion list only grows at its end.

    Raises:
        SettingsError: On any other difference, which is a planning bug.
    """
    try:
        after = parse(new_text)
    except SettingsError as error:
        raise SettingsError(
            f"internal error, the edited text does not parse: {error}"
        ) from None
    old_members = before.root.members
    new_members = after.root.members
    old_count = Counter(member.key for member in old_members)
    new_count = Counter(member.key for member in new_members)
    added = new_count - old_count
    removed = old_count - new_count
    unexpected = (set(added) | set(removed)) - fragment.inserted
    if unexpected:
        raise SettingsError(
            f"internal error, unexpected keys changed: {sorted(unexpected)}"
        )
    kept_old = [m for m in old_members if m.key not in removed]
    kept_new = [m for m in new_members if m.key not in added]
    if [m.key for m in kept_old] != [m.key for m in kept_new]:
        raise SettingsError("internal error, settings were reordered")
    for old, new in zip(kept_old, kept_new, strict=True):
        stray = diff_paths(old.value, new.value, (old.key,)) - fragment.touched
        if stray:
            where = describe_path(min(stray, key=describe_path))
            raise SettingsError(
                f"internal error, unintended change at {where}"
            )
    old_list = before.root.named(IGNORED_KEY)
    new_list = after.root.named(IGNORED_KEY)
    if old_list and new_list:
        old_value, new_value = old_list[0].value, new_list[0].value
        if isinstance(old_value, ArrayNode) and not _extends(
            old_value, new_value
        ):
            raise SettingsError(f"internal error, {IGNORED_KEY} lost entries")


def _extends(before: ArrayNode, after: JsonNode) -> bool:
    """Whether ``after`` is ``before`` with items appended."""
    if not isinstance(after, ArrayNode) or len(after.items) < len(
        before.items
    ):
        return False
    return not any(
        diff_paths(old, new)
        for old, new in zip(before.items, after.items, strict=False)
    )


def _scan_host_bound(
    doc: Document, managed: frozenset[NodePath]
) -> tuple[Finding, ...]:
    """Strings outside ``managed`` that still name a home or profile path."""
    found: list[Finding] = []

    def walk(node: JsonNode, path: NodePath) -> None:
        """Collect the matching strings at or below ``node``."""
        match node:
            case ObjectNode(members=members):
                for member in members:
                    walk(member.value, (*path, member.key))
            case ArrayNode(items=items):
                for index, item in enumerate(items):
                    walk(item, (*path, index))
            case StringNode(value=value):
                if HOST_BOUND.search(value) and path not in managed:
                    found.append(
                        Finding(
                            FindingKind.UNMANAGED, describe_path(path), value
                        )
                    )
            case _:
                pass

    walk(doc.root, ())
    return tuple(found)
