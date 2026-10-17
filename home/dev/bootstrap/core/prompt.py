"""What a guided run asks a person.

The guided flow (core.guided) asks through a Prompter only, so tests replace
it with a scripted one. On a color terminal Gum asks, pinned by the package
and themed with the shared tokens; NO_COLOR, a pipe or a dumb terminal get
line prompts. Without a terminal on stdin nothing is asked: a question fails
and names the flag that answers it, so a script never chooses for a person.
"""

import os
import shutil
import sys

import terminal_style as ui

from . import process
from .errors import BootstrapError

# Gum's exit statuses: a declined confirmation or Esc, and Ctrl-C.
GUM_NO = 1
GUM_ABORTED = 130
# Separates an option's label from its key in what Gum reads: sanitized
# labels hold no control character.
LABEL_KEY = "\t"


class Cancelled(Exception):
    """The person left the flow at a question: Esc, Ctrl-C or end of input."""


class Prompter:
    """Asks nothing, since nobody is at the terminal.

    Each question names the flag that answers it without a person; the
    subclasses ask at the terminal instead.
    """

    # Whether a person can answer: the flow asks only then.
    attended = False

    def __init__(self, style, *, stream=None):
        self.style = style
        # Flushed before each question, so a report never trails a prompt.
        self.stream = sys.stdout if stream is None else stream

    def confirm(self, question, *, default=False, flag):
        """Yes or no; Cancelled when the person leaves instead."""
        raise self.unattended(question, flag)

    def choose(self, header, options, *, default=None, flag):
        """One key of options, a list of (key, label) pairs."""
        raise self.unattended(header, flag)

    def choose_many(self, header, options, *, selected=(), flag):
        """The chosen keys, in the order of options; possibly none."""
        raise self.unattended(header, flag)

    @staticmethod
    def unattended(question, flag):
        return BootstrapError(
            f"{question.rstrip('?:')}: nobody can answer here, since stdin "
            f"is not a terminal; {flag}"
        )


class LinePrompter(Prompter):
    """Questions as lines on stderr, answers read from stdin."""

    attended = True

    def __init__(self, style, *, stream=None, terminal=None):
        super().__init__(style, stream=stream)
        self.terminal = sys.stderr if terminal is None else terminal

    def ask(self, text, choices):
        self.stream.flush()
        self.terminal.write(
            f"{self.style.paint(ui.ACCENT, '?')} {ui.sanitize(text)} "
            f"{self.style.paint(ui.MUTED, choices)} "
        )
        self.terminal.flush()
        try:
            answer = sys.stdin.readline()
        except KeyboardInterrupt:
            self.terminal.write("\n")
            raise Cancelled from None
        if not answer:
            # End of input: the person closed it rather than answer.
            self.terminal.write("\n")
            raise Cancelled
        return answer.strip()

    def confirm(self, question, *, default=False, flag):
        answer = self.ask(question, "[Y/n]" if default else "[y/N]").lower()
        if not answer:
            return default
        return answer in ("y", "yes")

    def listing(self, header, options, marked=None):
        self.terminal.write(ui.sanitize(header) + "\n")
        width = len(str(len(options)))
        for number, (key, label) in enumerate(options, 1):
            mark = ""
            if marked is not None:
                mark = "[x] " if key in marked else "[ ] "
            self.terminal.write(
                f"  {self.style.paint(ui.MUTED, f'{number:>{width}})')} "
                f"{mark}{ui.sanitize(label)}\n"
            )

    def choose(self, header, options, *, default=None, flag):
        self.listing(header, options)
        keys = [key for key, _ in options]
        hint = f"[1-{len(options)}]"
        if default in keys:
            hint = f"[1-{len(options)}, Enter {keys.index(default) + 1}]"
        while True:
            answer = self.ask("Choose", hint)
            if not answer and default in keys:
                return default
            if answer.isdigit() and 1 <= int(answer) <= len(options):
                return keys[int(answer) - 1]

    def choose_many(self, header, options, *, selected=(), flag):
        self.listing(header, options, marked=set(selected))
        keys = [key for key, _ in options]
        while True:
            answer = self.ask(
                "Numbers to select",
                "[space-separated; Enter keeps the marked; none]",
            )
            if not answer:
                return [key for key in keys if key in selected]
            if answer.lower() == "none":
                return []
            numbers = answer.replace(",", " ").split()
            if all(
                number.isdigit() and 1 <= int(number) <= len(options)
                for number in numbers
            ):
                chosen = {keys[int(number) - 1] for number in numbers}
                return [key for key in keys if key in chosen]


class GumPrompter(Prompter):
    """Gum's widgets at the terminal, in the shared theme."""

    attended = True

    def __init__(self, style, *, gum, stream=None):
        super().__init__(style, stream=stream)
        self.gum = gum

    def run(self, arguments):
        self.stream.flush()
        try:
            return process.interact(
                [self.gum, *arguments], env=dict(os.environ, **ui.GUM_THEME)
            )
        except KeyboardInterrupt:
            # Gum saw the same Ctrl-C and has left the terminal as it was.
            raise Cancelled from None

    def confirm(self, question, *, default=False, flag):
        code, _ = self.run(
            [
                "confirm",
                f"--default={'true' if default else 'false'}",
                "--",
                ui.sanitize(question),
            ]
        )
        if code == 0:
            return True
        if code == GUM_NO:
            return False
        if code == GUM_ABORTED:
            raise Cancelled
        raise BootstrapError(f"gum confirm exited {code}")

    def options(self, options):
        """Gum's label-key lines: it shows the label and prints the key."""
        labels = {}
        lines = []
        for key, label in options:
            # A comma would split --selected; a tab, the label from its key.
            label = ui.sanitize(label).replace(",", " ")
            if label in labels:
                raise BootstrapError(f"Two options read {label!r}")
            labels[label] = key
            lines.append(f"{label}{LABEL_KEY}{key}")
        return labels, lines

    def pick(self, header, options, extra):
        labels, lines = self.options(options)
        rows = shutil.get_terminal_size((80, 24)).lines
        code, output = self.run(
            [
                "choose",
                f"--header={ui.sanitize(header)}",
                f"--label-delimiter={LABEL_KEY}",
                f"--height={max(min(len(lines), rows - 4), 3)}",
                *extra(labels),
                "--",
                *lines,
            ]
        )
        if code in (GUM_NO, GUM_ABORTED):
            raise Cancelled
        if code != 0:
            raise BootstrapError(f"gum choose exited {code}")
        keys = {key for key, _ in options}
        chosen = [line for line in output.split("\n") if line]
        if not set(chosen) <= keys:
            raise BootstrapError("gum choose printed an unknown option")
        return chosen

    def choose(self, header, options, *, default=None, flag):
        def selected(labels):
            return [
                f"--selected={label}"
                for label, key in labels.items()
                if key == default
            ]

        chosen = self.pick(header, options, selected)
        if len(chosen) != 1:
            raise Cancelled
        return chosen[0]

    def choose_many(self, header, options, *, selected=(), flag):
        def marked(labels):
            chosen = [
                label for label, key in labels.items() if key in selected
            ]
            return ["--no-limit"] + (
                [f"--selected={','.join(chosen)}"] if chosen else []
            )

        chosen = set(self.pick(header, options, marked))
        return [key for key, _ in options if key in chosen]


def prompter(frontend, style, *, attended):
    """The prompter for this terminal.

    frontend holds the pinned `gum` path the package declares; a source
    checkout without it asks with lines.
    """
    if not attended:
        return Prompter(style)
    if style.styled and frontend.get("gum"):
        return GumPrompter(style, gum=frontend["gum"])
    return LinePrompter(style)
