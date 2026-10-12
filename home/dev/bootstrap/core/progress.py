"""Live progress of apply and prune --yes, as text on stderr.

The run's events (core.runs) drive it, so a person sees the stages and
ecosystems a frontend reading --events sees. Lines are only ever appended:
nothing hides a prompt or the report, and captured stderr reads in order. On
a terminal a step's line ends when the step does, with its outcome and
duration; elsewhere the start and the end are separate lines.
"""

import sys

from . import ui
from .render import duration, namer

STAGES = {
    "prerequisites": "Prerequisites",
    "readiness": "Readiness",
    "runtimes": "Runtimes",
    "defaults": "Defaults",
    "shell": "Shell",
}
OUTCOMES = {"ok": "ok", "failed": "error", "interrupted": "warn"}
# Steps nest under a stage; prune's removals have no stage around them.
STEPS = ("packages", "ecosystem", "removal")


class Progress:
    """An event listener for core.runs.Recorder."""

    def __init__(self, catalog, style, stream=None):
        self.stream = sys.stderr if stream is None else stream
        self.style = style
        self.name = namer({"catalog": catalog})
        # Stage titles and steps sit where a report puts its titles and rows.
        self.titles = " " * (ui.GUTTER if style.styled else 0)
        self.rows = self.titles + " " * ui.INDENT
        # Each step's text, kept from its start: a finish event repeats the
        # identity, not the runtimes or packages.
        self.steps = {}
        self.open = None

    def __call__(self, record):
        event = record["event"]
        if event == "run-start":
            path = ui.short_path(record["directory"], self.style)
            self.line(self.titles + self.style.paint(ui.MUTED, f"logs {path}"))
            return
        kind, _, phase = event.rpartition("-")
        if kind == "stage":
            self.stage(record, phase)
        elif kind in STEPS:
            self.step(kind, record, phase)

    def stage(self, record, phase):
        title = STAGES.get(record["stage"], record["stage"])
        if phase == "start":
            self.line(self.titles + self.style.paint(ui.HEADING, title))
        elif record["outcome"] != "ok":
            # A failing step has ended its own line; this one says where a
            # failure outside any step stopped.
            self.line(f"{self.titles}{title}: {self.outcome(record)}")

    def step(self, kind, record, phase):
        if phase == "start":
            text = ui.sanitize(self.describe(kind, record))
            self.steps[kind] = text
            if self.style.styled:
                self.close()
                self.stream.write(f"{self.rows}{text} … ")
                self.stream.flush()
                self.open = text
            else:
                self.line(f"{self.rows}{text} …")
            return
        text = self.steps.pop(kind, kind)
        if self.open == text:
            self.open = None
            self.stream.write(self.outcome(record) + "\n")
            self.stream.flush()
        else:
            self.line(f"{self.rows}{text}: {self.outcome(record)}")

    def describe(self, kind, record):
        if kind == "packages":
            return "Native packages " + " ".join(record.get("packages", ()))
        if kind == "removal":
            return f"Remove {self.name(record)} {record.get('version', '')}"
        language = record["language"]
        runtimes = record.get("runtimes", ())
        if any(runtime.get("component") for runtime in runtimes):
            return ", ".join(
                f"{self.name({**runtime, 'language': language})} "
                f"{runtime['version']}"
                for runtime in runtimes
            )
        versions = ", ".join(runtime["version"] for runtime in runtimes)
        title = self.name({"language": language}, ecosystem=True)
        return f"{title} {versions}".rstrip()

    def outcome(self, record):
        tone = OUTCOMES.get(record["outcome"], "warn")
        took = duration(record["duration"])
        if not self.style.styled:
            return f"{record['outcome']} after {took}"
        word = self.style.paint(ui.TONES[tone], record["outcome"])
        return f"{self.style.marker(tone)} {word} · {took}"

    def line(self, text):
        self.close()
        self.stream.write(text + "\n")
        self.stream.flush()

    def close(self):
        """End a styled step line that something else interrupts."""
        if self.open is not None:
            self.open = None
            self.stream.write("\n")
