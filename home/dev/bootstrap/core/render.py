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
    "report": "Run history",
}
# How a run that stopped before its report reads, by command and outcome.
STOPPED = {
    ("apply", "failed"): "Apply failed",
    ("apply", "interrupted"): "Apply interrupted",
    ("prune --yes", "failed"): "Prune failed",
    ("prune --yes", "interrupted"): "Prune interrupted",
}
RUN_TONES = {
    "ok": "ok",
    "failed": "error",
    "interrupted": "warn",
    "incomplete": "muted",
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
# A run is named as --run takes it; its length is the first thing to go.
RUN_COLUMNS = [
    Column("Run", limit=20),
    Column("Command", priority=50),
    Column("State", priority=60, fold=NOT_HEALTHY),
    Column("Duration", priority=40),
]


def render(result, style, *, applied=False):
    """The report's lines, for a styled terminal or for plain output."""
    if result["action"] == "report":
        return _history(result, style)
    if result["action"] == "prune":
        return _prune(result, style, applied)
    return _runtimes(result, style)


def duration(seconds):
    """A run's length as a person reads it: 42 s, 7 min 6 s, 1 h 3 min."""
    seconds = round(seconds or 0)
    if seconds < 60:
        return f"{seconds} s"
    minutes, seconds = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes} min {seconds} s" if seconds else f"{minutes} min"
    hours, minutes = divmod(minutes, 60)
    return f"{hours} h {minutes} min" if minutes else f"{hours} h"


def plural(count, noun):
    return f"{count} {noun}{'' if count == 1 else 's'}"


def namer(result):
    """How a row's ecosystem and component read: the catalog's titles.

    A report without them, or an ecosystem the catalog does not list, falls
    back to the keys `--only` takes. A runtime row without a component is
    the ecosystem's primary one (a global selection); a row about the whole
    ecosystem (a manager, its packages) passes ecosystem=True.
    """
    titles, components, primary = {}, {}, {}
    for entry in result.get("catalog", []):
        titles[entry["language"]] = entry.get("title") or entry["language"]
        components[entry["language"]] = entry.get("componentTitles", {})
        primary[entry["language"]] = entry.get("primaryComponent")

    def name(row, *, ecosystem=False):
        language = row["language"]
        component = row.get("component") or primary.get(language)
        title = titles.get(language, language)
        if ecosystem or not component:
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
    if action in ("plan", "stopped") and state == "present":
        return "ok"
    if action in ("plan", "stopped") and state == "missing":
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
    run = result.get("run", {})
    health = result.get("verification") == "health"
    title = TITLES["health" if health else result["action"]]
    # A run that stopped kept the plan of what it left: its rows read as a
    # plan's, and the title, the run and the hint say that it stopped.
    action = "stopped" if run.get("error") else result["action"]
    runtimes = result.get("runtimes", [])
    name = namer(result)
    ecosystems = len({row["language"] for row in runtimes})
    noun = "selection" if health else "runtime"
    lines = _header(
        result,
        style,
        _title(run, title),
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
        if action == "plan" and tone == "pending" and row["language"] in costs:
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
                        name(row, ecosystem=True),
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
    # apply initializes a default only where none is selected; a selection
    # left on another release is the person's, or prune's once retired.
    elsewhere = sum(
        row["state"] == "ok"
        and row.get("actualVersion", row["version"]) != row["version"]
        for row in result.get("selections", [])
    )
    healthy = all(
        _runtime_tone(row["state"], action) != "error" for row in runtimes
    )
    if action == "apply" and elsewhere and healthy and not hint:
        hint = (
            f"{plural(elsewhere, 'global selection')} "
            f"{'stays' if elsewhere == 1 else 'stay'} on another release; "
            "verify --health lists them"
        )

    lines += _run(run, style)
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
        _stopped_hint(run) or hint or _runtime_hint(action, health, counts),
        RUN_TONES[run["outcome"]] if run.get("error") else "ok",
    )
    return lines


def _title(run, title):
    """A report's title, or how its run stopped before it could finish."""
    if run.get("error"):
        return STOPPED.get((run["command"], run["outcome"]), title)
    return title


def _stopped_hint(run):
    if not run.get("error"):
        return ""
    if run["outcome"] == "interrupted":
        return f"{run['command']} again to finish"
    return f"{run['command']} again after resolving it"


def _run(run, style):
    """Where a recorded run keeps its logs and, when it stopped, why."""
    if not run:
        return []
    fields = []
    error = run.get("error")
    if error:
        fields.append(("error", Cell(error["message"], ui.TONES["error"])))
        if error.get("log"):
            fields.append(("log", Cell(error["log"], ui.MUTED, path=True)))
    fields.append(("logs", Cell(run["path"], ui.MUTED, path=True)))
    return [""] + ui.card(style, "Run", fields, duration(run.get("duration")))


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
                    f"{name(entry, ecosystem=True)} packages",
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
                        f"{name(entry, ecosystem=True)} {version}",
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
    run = result.get("run", {})
    lines = _header(
        result,
        style,
        _title(run, TITLES["prune --yes" if applied else "prune"]),
        f"{plural(len(retired), 'retired release')} installed",
    )
    if run.get("error"):
        # It stopped before it could list what it removed.
        lines += _run(run, style)[1:] + [""]
        return lines + ui.summary(
            style, [], _stopped_hint(run), RUN_TONES[run["outcome"]]
        )
    if not retired:
        message = "No retired release is installed."
        if style.styled:
            message = f"{' ' * ui.GUTTER}{style.marker('ok')} {message}"
        return lines + [message] + _run(run, style)

    rows = []
    name = namer(result)
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

    lines += _run(run, style)
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


def _history(result, style):
    """`report`: the kept runs, newest first."""
    runs = result.get("runs", [])
    lines = ui.header(
        style,
        "dev-bootstrap",
        TITLES["report"],
        f"{plural(len(runs), 'run')} kept",
        "",
        "the last ten",
    ) + [""]
    if not runs:
        message = "No run is recorded yet; apply records one."
        if style.styled:
            message = f"{' ' * ui.GUTTER}{style.marker('muted')} {message}"
        return lines + [message]
    rows = []
    for run in runs:
        tone = RUN_TONES.get(run["state"], "muted")
        rows.append(
            Row(
                [
                    run["id"],
                    Cell(run.get("command", "—"), ui.MUTED),
                    _state(run["state"], tone),
                    Cell(
                        duration(run["duration"])
                        if "duration" in run
                        else "—",
                        ui.MUTED,
                    ),
                ],
                tone,
            )
        )
    # Every run lives in the same directory, so it is said once.
    directory = result.get("directory", "")
    if style.styled:
        directory = ui.short_path(directory, style)
    lines += ui.section(style, "Runs", directory)
    lines += ui.table(style, RUN_COLUMNS, rows)
    counts = {}
    for run in runs:
        counts[run["state"]] = counts.get(run["state"], 0) + 1
    lines.append("")
    return lines + ui.summary(
        style,
        [
            (RUN_TONES[state], counts.get(state, 0), state)
            for state in RUN_TONES
        ],
        "report --last shows the newest again",
    )
