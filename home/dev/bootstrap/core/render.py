"""The text report: what plan, apply, verify and prune found, for a person.

The JSON report stays the interface for programs; this module only renders
it. Each row's state is the executor's; the renderer chooses how it reads
(see `core.ui.TONES`): a missing runtime is work for apply in a plan, but a
failure after apply or verify. Healthy rows stay quiet; a row that needs
attention says why, where and how to fix it.
"""

import shlex
from pathlib import Path

from . import ui
from .ui import Cell, Column, Note, Row

TITLES = {
    "plan": "Runtime plan",
    "apply": "Apply result",
    "verify": "Verification",
    "health": "Health check",
    "prune": "Prune plan",
    "prune --yes": "Prune result",
}
SELECTIONS = {
    "all": "all ecosystems",
    "default": "default selection",
    "file": "saved selection",
}
RUNTIME_STATES = (
    "ok",
    "present",
    "missing",
    "external",
    "conflict",
    "blocked",
)
RETIRED_STATES = ("removed", "retire", "blocked", "failed")
RETIRED_TONES = {
    "removed": "ok",
    "retire": "pending",
    "blocked": "warn",
    "failed": "error",
}
NOT_HEALTHY = ("pending", "warn", "error", "muted")
FAILING = ("warn", "error")

# The name and version always stay; the state folds under the row when it
# must go, and so does the location of a failing row. A location shorter
# than 20 columns says too little, so it goes before the manager does.
RUNTIME_COLUMNS = [
    Column("Runtime", limit=16),
    Column("Version", limit=12),
    Column("Manager", priority=40),
    Column("State", priority=60, fold=NOT_HEALTHY),
    Column("Location", priority=30, shrink=20, fold=FAILING),
]
# What prune removes is the location itself, so it outlasts the manager.
RETIRED_COLUMNS = [
    Column("Runtime", limit=16),
    Column("Release", limit=24),
    Column("Manager", priority=40),
    Column("State", priority=60, fold=NOT_HEALTHY),
    Column("Location", priority=50, shrink=20, fold=("pending", *FAILING)),
]
# A check's name stays whole. Its result is what the row says, so it is
# never shortened: when it does not fit, it continues under the row.
PREFLIGHT_COLUMNS = [
    Column("Check", limit=28),
    Column("Result", priority=50, fold=("ok", *NOT_HEALTHY)),
]
MANAGER_COLUMNS = [
    Column("Ecosystem", limit=16),
    Column("State", priority=60, fold=NOT_HEALTHY),
    Column("Location", priority=30, shrink=20, fold=FAILING),
]


def render(result, style, *, applied=False):
    """The report's lines, for a styled terminal or for plain output."""
    if result["action"] == "prune":
        return _prune(result, style, applied)
    return _runtimes(result, style)


def plural(count, noun):
    return f"{count} {noun}{'' if count == 1 else 's'}"


def _namer(result):
    """How a row's ecosystem and component read: the catalog's titles.

    A report without them, or an ecosystem the catalog does not list, falls
    back to the keys `--only` takes.
    """
    titles, components = {}, {}
    for entry in result.get("catalog", []):
        titles[entry["language"]] = entry.get("title") or entry["language"]
        components[entry["language"]] = entry.get("componentTitles", {})

    def name(row):
        language, component = row["language"], row.get("component")
        title = titles.get(language, language)
        if not component:
            return title
        return (
            f"{title} {components.get(language, {}).get(component, component)}"
        )

    return name


def _header(result, style, title, subtitle):
    selection = result.get("selection", {})
    if selection.get("source") == "only":
        chosen = ", ".join(
            entry["language"]
            for entry in result.get("catalog", [])
            if entry.get("selected")
        )
        note = f"--only {chosen}" if chosen else "--only"
    else:
        note = SELECTIONS.get(selection.get("source"), "")
    context = " · ".join(
        part
        for part in (result.get("platform"), result.get("backend"))
        if part
    )
    return ui.header(
        style, "dev-bootstrap", title, subtitle, context, note
    ) + [""]


def _state(state, tone):
    """The state word: quiet when healthy, in its tone's color otherwise."""
    return Cell(state, ui.MUTED if tone == "ok" else ui.TONES[tone])


def _location(path, tone):
    # A runtime that is not installed yet shows where it will go, faintly.
    color = ui.FAINT if tone == "pending" else ui.MUTED
    return Cell(path, color, path=True) if path else Cell("—", ui.FAINT)


def _reason(text, tone):
    # A failure's reason is the line to read; anything else stays quiet.
    return Note(text, "" if tone in FAILING else ui.MUTED)


def _cost(cost):
    """How a catalog cost reads: "source build · medium", "download"."""
    build = "source build" if cost.get("build") == "source" else "download"
    return " · ".join(part for part in (build, cost.get("size")) if part)


def _runtime_tone(state, action):
    if state == "ok":
        return "ok"
    if state == "external":
        return "muted"
    if action == "plan" and state == "present":
        return "ok"
    if action == "plan" and state == "missing":
        return "pending"
    return "error"


def _runtime_row(row, tone, name, version=None):
    notes = []
    if row.get("reason"):
        notes.append(_reason(row["reason"], tone))
    declared = row["version"]
    version = version or row.get("actualVersion", declared)
    if version not in (declared, "—"):
        # A health row names the declared default; show what actually runs.
        notes.append(Note(f"the declared default is {declared}"))
    if row.get("remediation"):
        notes.append(Note(row["remediation"], ui.ACCENT, label="fix"))
    return Row(
        [
            name(row),
            version,
            Cell(row.get("owner", ""), ui.MUTED),
            _state(row["state"], tone),
            _location(row.get("path", ""), tone),
        ],
        tone,
        notes,
    )


def _runtimes(result, style):
    action = result["action"]
    health = result.get("verification") == "health"
    runtimes = result.get("runtimes", [])
    name = _namer(result)
    ecosystems = len({row["language"] for row in runtimes})
    noun = "selection" if health else "runtime"
    lines = _header(
        result,
        style,
        TITLES["health" if health else action],
        f"{plural(len(runtimes), noun)} in {plural(ecosystems, 'ecosystem')}",
    )
    lines += ui.section(style, "Global selections" if health else "Runtimes")
    costs = {
        entry["language"]: entry["cost"]
        for entry in result.get("catalog", [])
        if entry.get("cost")
    }
    rows = []
    for row in runtimes:
        tone = _runtime_tone(row["state"], action)
        rows.append(_runtime_row(row, tone, name))
        # The cost belongs to the ecosystem: it reads once, under the first
        # runtime apply would install.
        if tone == "pending" and row["language"] in costs:
            cost = costs.pop(row["language"])
            rows[-1].notes.append(Note(_cost(cost), label="cost"))
    lines += ui.table(style, RUNTIME_COLUMNS, rows)

    managers = [
        row
        for row in result.get("setup", {}).get("nativeManagers", [])
        if row["state"] != "present"
    ]
    if managers:
        lines += [""] + ui.section(style, "Managers", "apply installs these")
        rows = []
        for row in managers:
            tone = "pending" if row["state"] == "missing" else "error"
            notes = [_reason(row["reason"], tone)] if row.get("reason") else []
            rows.append(
                Row(
                    [
                        name(row),
                        _state(row["state"], tone),
                        _location(row.get("path", ""), tone),
                    ],
                    tone,
                    notes,
                )
            )
        lines += ui.table(style, MANAGER_COLUMNS, rows)

    selections = [
        row for row in result.get("selections", []) if row["state"] != "ok"
    ]
    if selections:
        # Selections belong to the native managers: reported, never failed.
        lines += [""] + ui.section(
            style, "Global selections", "reported, never failed"
        )
        rows = []
        for row in selections:
            tone = "muted" if row["state"] == "external" else "warn"
            rows.append(
                _runtime_row(row, tone, name, row.get("actualVersion") or "—")
            )
        lines += ui.table(style, RUNTIME_COLUMNS, rows)

    hint = None
    if result.get("preflight"):
        rows, blocked = _preflight(result, name)
        lines += [""] + ui.section(
            style,
            "Preflight",
            Path(result["preflight"]["packageManager"]["path"]).name,
        )
        lines += ui.table(style, PREFLIGHT_COLUMNS, rows)
        if blocked:
            hint = "resolve the preflight before apply"

    counts = dict.fromkeys(RUNTIME_STATES, 0)
    for row in runtimes:
        counts[row["state"]] = counts.get(row["state"], 0) + 1
    lines.append("")
    lines += ui.summary(
        style,
        [
            (_runtime_tone(state, action), count, state)
            for state, count in counts.items()
        ],
        hint or _runtime_hint(action, health, counts),
    )
    return lines


def _preflight(result, name):
    """The rows of plan --preflight, and whether apply would stop on them.

    Missing packages are work apply does; a privileged install is worth a
    look, since apply then asks for administrator rights; a missing package
    manager or SDK, or a release the manager cannot build, stops apply.
    """
    preflight = result["preflight"]
    managers = {
        entry["language"]: entry.get("manager", "")
        for entry in result.get("catalog", [])
    }
    ecosystems = preflight.get("ecosystems", [])
    foundation = preflight["packageManager"]
    present = foundation["state"] == "present"
    rows = []
    blocked = False
    if present:
        rows.append(
            Row(
                [
                    "Package manager",
                    Cell(foundation["path"], ui.MUTED, path=True),
                ],
                "ok",
            )
        )
    else:
        rows.append(
            Row(
                ["Package manager", _state("missing", "error")],
                "error",
                [
                    _reason(
                        f"{foundation['path']} is not installed, so apply "
                        "cannot install native packages",
                        "error",
                    )
                ],
            )
        )

    waiting = [entry for entry in ecosystems if entry.get("missing")]
    for entry in waiting:
        tone = "pending" if present else "error"
        blocked = blocked or not present
        rows.append(
            Row(
                [
                    f"{name(entry)} packages",
                    Cell(" ".join(entry["missing"]), ui.TONES[tone]),
                ],
                tone,
            )
        )
    if not waiting:
        required = {
            package for entry in ecosystems for package in entry["packages"]
        }
        rows.append(
            Row(
                [
                    "Native packages",
                    Cell(
                        f"all {plural(len(required), 'package')} installed"
                        if required
                        else "none needed",
                        ui.MUTED,
                    ),
                ],
                "ok",
            )
        )

    command = preflight.get("command") or []
    if command and present:
        runs = Note(shlex.join(command), ui.ACCENT, label="runs")
        if preflight.get("privileged"):
            rows.append(
                Row(
                    ["Privilege", "apply asks once for administrator rights"],
                    "warn",
                    [runs],
                )
            )
        else:
            rows.append(
                Row(["Privilege", Cell("not needed", ui.MUTED)], "ok", [runs])
            )

    if "sdk" in preflight:
        if preflight["sdk"] == "present":
            rows.append(Row(["Apple SDK", Cell("present", ui.MUTED)], "ok"))
        else:
            blocked = True
            rows.append(
                Row(
                    ["Apple SDK", _state("missing", "error")],
                    "error",
                    [
                        Note(
                            "install the Apple developer tools and accept "
                            "their license",
                            ui.ACCENT,
                            label="fix",
                        )
                    ],
                )
            )

    for entry in ecosystems:
        manager = managers.get(entry["language"]) or "its manager"
        for version in entry.get("unbuildable", []):
            blocked = True
            rows.append(
                Row(
                    [
                        f"{name(entry)} {version}",
                        Cell(f"{manager} cannot build it", ui.TONES["error"]),
                    ],
                    "error",
                    [
                        Note(
                            f"upgrade {manager}, then plan again",
                            ui.ACCENT,
                            label="fix",
                        )
                    ],
                )
            )
    return rows, blocked


def _runtime_hint(action, health, counts):
    unhealthy = sum(
        count
        for state, count in counts.items()
        if _runtime_tone(state, action) == "error"
    )
    if action == "plan":
        if counts["missing"]:
            return f"apply installs {plural(counts['missing'], 'runtime')}"
        return "" if unhealthy else "verify runs each one"
    if unhealthy:
        if action == "apply":
            return "apply again after resolving these"
        return f"{plural(unhealthy, 'runtime')} to look at"
    if action == "apply":
        return "a new shell picks up the defaults"
    return "" if health else "verify --health checks the selections"


def _prune(result, style, applied):
    retired = result.get("retired", [])
    lines = _header(
        result,
        style,
        TITLES["prune --yes" if applied else "prune"],
        f"{plural(len(retired), 'retired release')} installed",
    )
    if not retired:
        message = "No retired release is installed."
        if style.styled:
            message = f"{' ' * ui.GUTTER}{style.marker('ok')} {message}"
        return lines + [message]

    rows = []
    name = _namer(result)
    for row in retired:
        tone = RETIRED_TONES.get(row["state"], "error")
        notes = []
        if row.get("reason"):
            notes.append(_reason(row["reason"], tone))
        if row["state"] in ("retire", "removed") and row.get("steps"):
            label = "steps" if row["state"] == "retire" else "done"
            notes.append(Note(" → ".join(row["steps"]), label=label))
        notes += [Note(note, label="note") for note in row.get("notes", [])]
        rows.append(
            Row(
                [
                    name(row),
                    f"{row['version']} → {row['successor']}",
                    Cell(row.get("owner", ""), ui.MUTED),
                    _state(row["state"], tone),
                    Cell(row.get("path", ""), ui.MUTED, path=True),
                ],
                tone,
                notes,
            )
        )
    lines += ui.section(style, "Retired releases")
    lines += ui.table(style, RETIRED_COLUMNS, rows)

    counts = dict.fromkeys(RETIRED_STATES, 0)
    for row in retired:
        counts[row["state"]] = counts.get(row["state"], 0) + 1
    pending = counts["retire"]
    lines.append("")
    lines += ui.summary(
        style,
        [
            (RETIRED_TONES.get(state, "error"), count, state)
            for state, count in counts.items()
        ],
        f"prune --yes removes {plural(pending, 'release')}" if pending else "",
    )
    return lines
