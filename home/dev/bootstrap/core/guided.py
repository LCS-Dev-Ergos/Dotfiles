"""The guided setup: detect, summarize and review, for a person.

The executor decides and this module displays. Each step reads the report
`plan --preflight` prints, first for every ecosystem available here, then
for the selection, and never re-derives what apply would do. Every screen is
drawn like any report (core.ui); questions go through a core.prompt
prompter. Nothing changes before the person accepts the review: then the
selection is saved, and apply runs in-process like `dev-bootstrap apply`.
"""

import shlex
import sys
from pathlib import Path
from urllib.parse import urlsplit

from . import process, ui
from .adapters import ADAPTERS
from .engine import select
from .errors import BootstrapError
from .prompt import Cancelled
from .runs import recorded_runs, stored_report
from .selection import save_selection
from .render import (
    NOT_HEALTHY,
    RUNTIME_STATES,
    cost_text,
    namer,
    plural,
    render,
)
from .ui import Cell, Column, Note, Row

# An ecosystem reads as its least settled runtime.
STATES = ("conflict", "blocked", "missing", "present", "ok", "external")
STATE_TONES = {
    "conflict": "error",
    "blocked": "error",
    "missing": "pending",
    "present": "ok",
    "ok": "ok",
    "external": "muted",
}
# The cost is what the summary is for, so it outlasts the manager; the
# versions are the first to go.
ECOSYSTEM_COLUMNS = [
    Column("Ecosystem", limit=16),
    Column("Manager", priority=40),
    Column("State", priority=60, fold=NOT_HEALTHY),
    Column("Cost", priority=50),
    Column("Runtimes", priority=30, shrink=12),
]
# What stops apply: the item stays, its problem continues under it.
BLOCKER_COLUMNS = [
    Column("Item", limit=28),
    Column("Problem", priority=50, fold=("error",)),
]
MANAGER_COLUMNS = [
    Column("Manager", limit=16),
    Column("For", priority=40, fold=("pending",)),
    Column("From", priority=60, fold=("pending",)),
]
INSTALL_COLUMNS = [
    Column("Runtime", limit=16),
    Column("Version", limit=12),
    Column("Cost", priority=40),
]
DEFAULT_COLUMNS = [
    Column("Runtime", limit=16),
    Column("Default", limit=12),
]
SELECTIONS = {
    "chosen": "chosen here",
    "only": "--only",
    "all": "every default ecosystem (--all)",
    "default": "every default ecosystem",
    "file": "saved selection",
}


def available(manifest):
    """Every ecosystem declared and supported here, in registry order."""
    return [
        language
        for language, adapter in ADAPTERS.items()
        if adapter.describe(manifest)["available"]
    ]


class Guide:
    """One guided setup, from detection to the applied selection.

    planner(only) returns the report of `plan --preflight` for that
    selection; executor(selection, accepted) runs apply, printing its report,
    and returns its exit status, where selection holds the `only` and `all`
    options; prompter is a core.prompt.Prompter; selection_file is the
    saved selection's path.
    """

    def __init__(
        self,
        manifest,
        planner,
        prompter,
        style,
        *,
        executor=None,
        selection_file=None,
        stream=None,
    ):
        self.manifest = manifest
        self.planner = planner
        self.executor = executor
        self.prompter = prompter
        self.style = style
        self.selection_file = selection_file
        self.stream = sys.stdout if stream is None else stream

    def print(self, lines):
        for line in lines:
            print(line, file=self.stream)
        self.stream.flush()

    def run(self, only, origin, accepted=(), *, yes=False):
        """The whole flow; its exit status.

        0 once apply succeeds, when nothing is selected, or when the person
        takes the privileged command to run it themselves; 1 when a blocker
        stops it before apply; apply's own status otherwise. Leaving at a
        question raises core.prompt.Cancelled before any change.
        """
        detected = self.planner(available(self.manifest))
        chosen = select(self.manifest, only)
        self.print(self.summary(detected, chosen))
        chosen, origin = self.choose(detected, chosen, origin)
        if not chosen:
            self.print(
                [""]
                + message(
                    self.style,
                    "muted",
                    "Nothing selected; setup changes nothing.",
                )
            )
            return 0
        reviewed = self.planner(chosen)
        self.print(review(reviewed, origin, self.style, accepted))
        self.print([""] + self.closing(reviewed))
        if blockers(reviewed):
            return 1
        accepted = self.consent(reviewed, accepted)
        decision = "apply" if yes else self.decide(reviewed)
        selection = self.remember(chosen, origin)
        if decision == "manual":
            self.print(
                [""]
                + message(
                    self.style,
                    "pending",
                    "Install the native packages with this command, then run "
                    "setup again:",
                )
                + command_lines(self.style, reviewed["preflight"]["command"])
            )
            return 0
        if decision == "authenticate":
            self.authenticate(reviewed["preflight"]["command"])
        return self.execute(selection, accepted)

    def choose(self, detected, chosen, origin):
        """The ecosystems to set up, asked when no option chose them.

        --only and --all answer the question, and so does a selection file
        declared elsewhere (a link), which setup cannot change; without a
        terminal the saved or default selection stands. A requirement left
        out is added and the question asked again, never silently.
        """
        if (
            origin["source"] in ("only", "all")
            or not self.prompter.attended
            or (self.selection_file and self.selection_file.is_symlink())
        ):
            return chosen, origin
        name = namer(detected)
        states = {}
        for row in detected["runtimes"]:
            state = states.get(row["language"], "ok")
            states[row["language"]] = min(
                (state, row["state"]), key=STATES.index
            )
        options = [
            (
                entry["language"],
                f"{name(entry, ecosystem=True)}  "
                f"{states.get(entry['language'], 'missing')} · "
                f"{cost_text(entry.get('cost', {}))}",
            )
            for entry in detected["catalog"]
            if entry["language"] in states
        ]
        selected = list(chosen)
        while True:
            picked = self.prompter.choose_many(
                "Ecosystems to set up",
                options,
                selected=selected,
                flag="choose them with --only, or --all",
            )
            needed = [
                requirement
                for language in picked
                for requirement in ADAPTERS[language].requires
                if requirement not in picked
            ]
            if not needed:
                break
            needed = list(dict.fromkeys(needed))
            dependents = [
                language
                for language in picked
                if set(ADAPTERS[language].requires) & set(needed)
            ]
            self.print(
                message(
                    self.style,
                    "warn",
                    f"{listed(name({'language': d}, ecosystem=True) for d in dependents)} "
                    f"{'needs' if len(dependents) == 1 else 'need'} "
                    f"{listed(name({'language': n}, ecosystem=True) for n in needed)}, "
                    "now selected as well: confirm or change.",
                )
            )
            selected = picked + needed
        picked = [language for language in ADAPTERS if language in picked]
        if picked == list(chosen):
            return chosen, origin
        return picked, {"source": "chosen"}

    def consent(self, result, accepted):
        """Terms the selection requires, accepted here or by --accept."""
        accepted = list(accepted)
        for entry in result["catalog"]:
            if not entry.get("selected"):
                continue
            for term in entry.get("consents", []):
                if term in accepted:
                    continue
                if not self.prompter.confirm(
                    f"Accept {term}, which {entry.get('title') or entry['language']} requires?",
                    flag=f"accept it with --accept {term}",
                ):
                    raise Cancelled
                accepted.append(term)
        return accepted

    def decide(self, result):
        """Apply, authenticate first, or take the privileged command away."""
        preflight = result["preflight"]
        if (
            preflight["privileged"]
            and preflight["command"]
            and self.prompter.attended
        ):
            choice = self.prompter.choose(
                "Installing the native packages needs administrator rights",
                [
                    ("authenticate", "Authenticate now, then apply"),
                    ("manual", "Show the command and stop: run it yourself"),
                    ("cancel", "Cancel: change nothing"),
                ],
                default="authenticate",
                flag="accept the review with --yes",
            )
            if choice == "cancel":
                raise Cancelled
            return choice
        if not self.prompter.confirm(
            "Apply this review?",
            default=True,
            flag="accept the review with --yes",
        ):
            raise Cancelled
        return "apply"

    def remember(self, chosen, origin):
        """Save a selection chosen here; the options apply runs with.

        A selection the options made is passed on as they made it; one made
        here, or the saved one, is read back from the selection file.
        """
        if origin["source"] == "only":
            return {"only": list(chosen), "all": False}
        if origin["source"] == "all":
            return {"only": None, "all": True}
        if origin["source"] == "chosen":
            save_selection(self.selection_file, chosen)
            self.print(
                message(
                    self.style,
                    "muted",
                    f"Selection saved in {self.selection_file}; later runs "
                    "use it.",
                )
            )
        return {"only": None, "all": False}

    def authenticate(self, command):
        """Ask for administrator rights now, before apply starts working."""
        login = self.manifest["setup"].get("authenticate")
        if not login:
            return
        process.announce(
            "installing the missing native packages needs administrator "
            f"rights; this runs\n  {shlex.join(command)}"
        )
        process.attend(login)

    def execute(self, selection, accepted):
        """Apply, then what to do next, or what stopped it.

        apply prints its own report. A run that fails or is interrupted
        keeps one too, which is shown here; only a run this apply recorded
        counts, never an older one.
        """
        before = {run["id"] for run in recorded_runs()}

        def recorded():
            runs = [run for run in recorded_runs() if run["id"] not in before]
            return runs[0] if runs else None

        self.print([""])
        try:
            code = self.executor(selection, accepted)
        except KeyboardInterrupt:
            self.stopped(recorded())
            raise
        run = recorded()
        if code == 0:
            # apply's report already names the logs and the new shell.
            fields = [
                ("check", "dev-bootstrap verify --health"),
                ("again", "dev-bootstrap report --last"),
            ]
            self.print([""] + ui.card(self.style, "Next", fields))
        elif code == 2:
            self.stopped(run)
        return code

    def stopped(self, run):
        """The report a stopped run kept: the plan it left and its error."""
        if run is None:
            return
        try:
            result = stored_report(run["id"])
        except BootstrapError:
            # Stopped before it could write one; stderr said why.
            return
        self.print([""] + render(result, self.style))

    def summary(self, result, chosen):
        """The masthead and one row per available ecosystem."""
        name = namer(result)
        catalog = {entry["language"]: entry for entry in result["catalog"]}
        rows = {}
        for row in result["runtimes"]:
            rows.setdefault(row["language"], []).append(row)
        managers = {
            row["language"]: row
            for row in result.get("setup", {}).get("nativeManagers", [])
        }
        context = " · ".join((result["platform"], result["backend"]))
        lines = ui.header(
            self.style,
            "dev-bootstrap",
            "Guided setup",
            f"{plural(len(rows), 'ecosystem')} available",
            context,
            f"{len(chosen)} selected",
        ) + [""]
        foundation = result["preflight"]["packageManager"]
        if foundation["state"] != "present":
            lines += ui.callout(
                self.style,
                "error",
                f"{foundation['path']} is missing",
                [
                    "Apply installs native packages through it; the entry's "
                    "--install-foundation installs it."
                ],
            ) + [""]
        lines += ui.section(
            self.style, "Ecosystems", Path(foundation["path"]).name
        )
        table = []
        for language, runtimes in rows.items():
            table.append(
                self.ecosystem(
                    catalog[language],
                    runtimes,
                    managers.get(language),
                    language in chosen,
                    name,
                )
            )
        return lines + ui.table(self.style, ECOSYSTEM_COLUMNS, table)

    def ecosystem(self, entry, runtimes, manager, selected, name):
        state = min((row["state"] for row in runtimes), key=STATES.index)
        tone = STATE_TONES[state]
        notes = []
        # Why an ecosystem nobody chose waits is noise until it is chosen.
        noted = runtimes if selected else []
        for reason in dict.fromkeys(
            row["reason"] for row in noted if row.get("reason")
        ):
            notes.append(Note(reason, "" if tone == "error" else ui.MUTED))
        waiting = [row for row in runtimes if row["state"] == "missing"]
        if waiting and len(waiting) < len(runtimes):
            notes.append(
                Note(
                    "missing "
                    + ", ".join(
                        f"{name(row)} {row['version']}" for row in waiting
                    )
                )
            )
        if not selected:
            notes.append(Note("not selected"))
        cost = entry.get("cost", {})
        costly = cost.get("build") == "source" or cost.get("size") == "large"
        absent = manager and manager["state"] != "present"
        return Row(
            [
                entry.get("title") or entry["language"],
                Cell(
                    entry.get("manager", ""),
                    ui.TONES["pending"] if absent else ui.MUTED,
                ),
                Cell(state, ui.MUTED if tone == "ok" else ui.TONES[tone]),
                Cell(cost_text(cost), "" if costly else ui.MUTED),
                Cell(", ".join(row["version"] for row in runtimes), ui.MUTED),
            ],
            tone,
            notes,
        )

    def closing(self, result):
        """The counts of the selection's runtimes and the next step."""
        counts = {}
        for row in result["runtimes"]:
            counts[row["state"]] = counts.get(row["state"], 0) + 1
        blocked = blockers(result)
        if blocked:
            hint, tone = "resolve the review's blockers before apply", "error"
        elif work(result):
            hint, tone = "apply carries out this review", "pending"
        else:
            hint, tone = "nothing to install", "ok"
        return ui.summary(
            self.style,
            [
                (STATE_TONES[state], counts[state], state)
                for state in RUNTIME_STATES
                if state in counts
            ],
            hint,
            tone,
        )


def message(style, tone, text):
    """A sentence in a section, led by its tone's marker when styled."""
    text = ui.sanitize(text)
    if not style.styled:
        return [text]
    indent = ui.GUTTER + ui.INDENT
    lines = ui.wrap(text, style.width - indent - 2 - ui.GUTTER)
    return [f"{' ' * indent}{style.marker(tone)} {lines[0]}"] + [
        f"{' ' * (indent + 2)}{line}" for line in lines[1:]
    ]


def command_lines(style, argv):
    """A command to copy, shell-quoted, in the accent color.

    Styled, the words continue on lines ending in a backslash, so it still
    pastes; plain output keeps it on one line.
    """
    words = [ui.sanitize(shlex.quote(word)) for word in argv]
    if not style.styled:
        return [" ".join(words)]
    indent = ui.GUTTER + ui.INDENT
    room = style.width - indent - ui.GUTTER
    lines = [words[0]]
    for word in words[1:]:
        # Room for the word and, should another follow, " \\".
        if ui.text_width(f"{lines[-1]} {word}") + 2 > room:
            lines[-1] += " \\"
            lines.append(f"  {word}")
        else:
            lines[-1] += f" {word}"
    return [f"{' ' * indent}{style.paint(ui.ACCENT, line)}" for line in lines]


def blockers(result):
    """What stops apply before it changes anything: (item, problem, fix)."""
    preflight = result["preflight"]
    found = []
    foundation = preflight["packageManager"]
    if foundation["state"] != "present":
        found.append(
            (
                Path(foundation["path"]).name,
                f"{foundation['path']} is missing; nothing can be installed",
                "the entry's --install-foundation installs it",
            )
        )
    if preflight.get("sdk") == "missing":
        found.append(
            (
                "Apple SDK",
                "missing",
                "install the Apple developer tools and accept their license",
            )
        )
    name = namer(result)
    managers = {
        entry["language"]: entry.get("manager") or "its manager"
        for entry in result["catalog"]
    }
    for entry in preflight["ecosystems"]:
        manager = managers[entry["language"]]
        for version in entry.get("unbuildable", []):
            found.append(
                (
                    f"{name(entry, ecosystem=True)} {version}",
                    f"{manager} cannot build it",
                    f"upgrade {manager}, then run setup again",
                )
            )
    for row in result["runtimes"]:
        if row["state"] in ("conflict", "blocked"):
            found.append(
                (
                    f"{name(row)} {row['version']}",
                    row.get("reason", row["state"]),
                    row.get("remediation", ""),
                )
            )
    return found


def work(result):
    """Whether apply would install or set anything for this selection."""
    return bool(
        result["preflight"]["missing"]
        or result["setup"]["initialDefaults"]
        or any(row["state"] == "missing" for row in result["runtimes"])
    )


def command(result, origin, accepted):
    """The apply argv that does what this review shows, without the guide."""
    argv = ["dev-bootstrap", "apply"]
    if origin["source"] in ("only", "chosen"):
        for entry in result["catalog"]:
            if entry.get("selected"):
                argv += ["--only", entry["language"]]
    elif origin["source"] == "all":
        argv.append("--all")
    for consent in accepted:
        argv += ["--accept", consent]
    return argv


def listed(items):
    """Items as a sentence lists them: "a", "a and b", "a, b and c"."""
    items = list(items)
    if len(items) < 2:
        return "".join(items)
    return f"{', '.join(items[:-1])} and {items[-1]}"


def review(result, origin, style, accepted=()):
    """What apply would do for the selection, section by section."""
    name = namer(result)
    catalog = {entry["language"]: entry for entry in result["catalog"]}
    selected = [entry for entry in catalog.values() if entry.get("selected")]
    fields = [
        (
            "ecosystems",
            ", ".join(
                entry.get("title") or entry["language"] for entry in selected
            ),
        )
    ]
    if origin["source"] == "file":
        fields.append(("saved in", Cell(origin["path"], ui.MUTED, path=True)))
    lines = [""] + ui.card(
        style,
        "Selection",
        fields,
        SELECTIONS.get(origin["source"], origin["source"]),
    )

    found = blockers(result)
    if found:
        rows = [
            Row(
                [item, Cell(problem, ui.TONES["error"])],
                "error",
                [Note(fix, ui.ACCENT, label="fix")] if fix else [],
            )
            for item, problem, fix in found
        ]
        lines += [""] + ui.section(style, "Blockers", "apply stops on these")
        lines += ui.table(style, BLOCKER_COLUMNS, rows)

    managers = {}
    for row in result["setup"]["nativeManagers"]:
        if row["state"] != "present":
            # Ecosystems sharing a manager (SDKMAN) get it once; the first
            # one with a source installs it.
            manager = catalog[row["language"]].get("manager", row["language"])
            managers.setdefault(manager, []).append(row)
    if managers:
        package_manager = Path(
            result["preflight"]["packageManager"]["path"]
        ).name
        rows = []
        for manager, entries in managers.items():
            provider = next(
                (
                    entry
                    for entry in entries
                    if entry.get("installer") or entry.get("package")
                ),
                {},
            )
            source = ""
            if provider.get("installer"):
                host = urlsplit(provider["installer"]).hostname
                source = f"installer {host}"
            elif provider.get("package"):
                source = f"{package_manager} {provider['package']}"
            rows.append(
                Row(
                    [
                        manager,
                        Cell(
                            ", ".join(
                                name(entry, ecosystem=True)
                                for entry in entries
                            ),
                            ui.MUTED,
                        ),
                        Cell(source, ui.MUTED),
                    ],
                    "pending",
                )
            )
        lines += [""] + ui.section(
            style, "Managers to install", "installers are hash-checked"
        )
        lines += ui.table(style, MANAGER_COLUMNS, rows)

    waiting = [row for row in result["runtimes"] if row["state"] == "missing"]
    lines += [""] + ui.section(style, "Runtimes to install")
    if waiting:
        costs = {entry["language"]: entry.get("cost") for entry in selected}
        rows = []
        for row in waiting:
            # The cost belongs to the ecosystem: it reads once.
            cost = costs.pop(row["language"], None)
            rows.append(
                Row(
                    [
                        name(row),
                        row["version"],
                        Cell(cost_text(cost) if cost else "", ui.MUTED),
                    ],
                    "pending",
                )
            )
        lines += ui.table(style, INSTALL_COLUMNS, rows)
    else:
        lines += message(
            style, "ok", "Every runtime of the selection is installed."
        )

    defaults = result["setup"]["initialDefaults"]
    lines += [""] + ui.section(style, "Defaults", "where none is selected")
    if defaults:
        rows = [
            Row(
                [name({"language": language}), result["defaults"][language]],
                "pending",
            )
            for language in defaults
        ]
        lines += ui.table(style, DEFAULT_COLUMNS, rows)
    else:
        lines += message(
            style, "ok", "Every manager keeps its global selection."
        )
    lines += message(
        style,
        "muted",
        "Apply then recreates missing shims and shell hooks, and checks that "
        "a fresh shell runs the selected runtimes.",
    )

    preflight = result["preflight"]
    lines += [""] + ui.section(
        style,
        "Native packages",
        Path(preflight["packageManager"]["path"]).name,
    )
    if preflight["missing"] and preflight["command"]:
        asks = (
            ", asking once for administrator rights"
            if preflight["privileged"]
            else ""
        )
        lines += message(
            style,
            "pending",
            f"Apply installs {listed(preflight['missing'])}{asks}. It runs:",
        )
        lines += command_lines(style, preflight["command"])
    elif preflight["missing"]:
        lines += message(
            style,
            "error",
            f"The selection needs {listed(preflight['missing'])}, which "
            "nothing can install yet.",
        )
    else:
        required = {
            package
            for entry in preflight["ecosystems"]
            for package in entry["packages"]
        }
        lines += message(
            style,
            "ok",
            f"All {plural(len(required), 'package')} the selection needs are "
            "installed."
            if required
            else "The selection needs none.",
        )

    consents = sorted(
        {
            consent
            for entry in selected
            for consent in entry.get("consents", [])
        }
        - set(accepted)
    )
    if consents:
        lines += [""] + ui.section(style, "Terms")
        lines += message(
            style,
            "warn",
            f"The selection requires accepting {listed(consents)}: apply "
            "refuses to start until each is named with "
            + listed(f"--accept {consent}" for consent in consents)
            + ".",
        )

    lines += [""] + ui.section(style, "Without the guide")
    lines += command_lines(style, command(result, origin, accepted))
    return lines
