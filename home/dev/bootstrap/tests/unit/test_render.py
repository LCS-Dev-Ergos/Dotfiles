"""The text report: golden renderings, width and plain-output guarantees.

Golden files hold the exact output, with ESC written as \\e so color changes
show in a diff. After an intended change, rewrite them with
DEV_BOOTSTRAP_TEST_UPDATE_GOLDEN=1 and review the diff.
"""

import contextlib
import io
import os
import re
import unittest
from pathlib import Path
from unittest.mock import patch

from core import cli, ui
from core.adapters import ADAPTERS
from core.render import render

GOLDEN = Path(__file__).resolve().parent / "golden"
HOME = "/home/user"
STORE = "/nix/store/0123456789abcdefghijklmnopqrstuv-python3-3.14.8"


def runtime(language, version, state, path, owner, **extra):
    return dict(
        language=language,
        version=version,
        path=path,
        owner=owner,
        state=state,
        **extra,
    )


def catalog(*selected):
    entries = []
    for name in ("node", "python", "haskell", "ruby", "conda"):
        adapter = ADAPTERS[name]
        entry = {
            "language": name,
            "title": adapter.title,
            "selected": name in selected,
        }
        if adapter.component_titles:
            entry["componentTitles"] = dict(adapter.component_titles)
        entries.append(entry)
    return entries


CASES = {
    "plan": {
        "action": "plan",
        "platform": "aarch64-darwin",
        "backend": "native",
        "catalog": catalog("node", "python", "haskell"),
        "selection": {"source": "default"},
        "runtimes": [
            runtime(
                "node",
                "24.21.0",
                "present",
                f"{HOME}/.local/share/fnm/node-versions/v24.21.0"
                "/installation/bin/node",
                "fnm",
            ),
            runtime(
                "node",
                "26.11.1",
                "missing",
                f"{HOME}/.local/share/fnm/node-versions/v26.11.1"
                "/installation/bin/node",
                "fnm",
                interrupted=True,
                reason="An interrupted apply left this installation "
                "incomplete; apply removes it and installs it again",
            ),
            runtime(
                "python",
                "3.14.8",
                "missing",
                f"{HOME}/.pyenv/versions/3.14.8/bin/python",
                "pyenv",
            ),
            runtime(
                "haskell",
                "9.14.1",
                "present",
                f"{HOME}/.ghcup/ghc/9.14.1/bin/ghc",
                "ghcup",
                component="ghc",
            ),
            runtime(
                "haskell",
                "3.16.1.0",
                "conflict",
                f"{HOME}/.ghcup/bin/cabal-3.16.1.0",
                "ghcup",
                component="cabal",
                reason="Existing incomplete runtime; manual inspection "
                "required",
            ),
        ],
        "setup": {
            "nativeManagers": [
                {
                    "language": "node",
                    "state": "present",
                    "path": "/opt/homebrew/bin/fnm",
                },
                {
                    "language": "haskell",
                    "state": "missing",
                    "path": f"{HOME}/.ghcup/bin/ghcup",
                },
            ]
        },
    },
    "verify": {
        "action": "verify",
        "platform": "x86_64-linux",
        "backend": "native",
        "catalog": catalog("python", "ruby"),
        "selection": {"source": "only"},
        "runtimes": [
            runtime(
                "python",
                "3.14.8",
                "conflict",
                f"{HOME}/.pyenv/versions/3.14.8/bin/python",
                "pyenv",
                reason="The canary could not import ssl: libssl.so.3: cannot "
                "open shared object file",
                remediation="pyenv install --force 3.14.8",
            ),
            runtime(
                "ruby",
                "4.0.7",
                "ok",
                f"{HOME}/.rbenv/versions/4.0.7/bin/ruby",
                "rbenv",
            ),
        ],
    },
    "health": {
        "action": "verify",
        "verification": "health",
        "platform": "aarch64-darwin",
        "backend": "native",
        "catalog": catalog("python", "ruby", "haskell"),
        "selection": {"source": "file", "path": f"{HOME}/.config/x.json"},
        "runtimes": [
            runtime(
                "python",
                "3.14.8",
                "ok",
                f"{HOME}/.pyenv/versions/3.14.8/bin/python",
                "pyenv",
                actualVersion="3.14.8",
            ),
            runtime(
                "haskell",
                "9.14.1",
                "ok",
                f"{HOME}/.ghcup/ghc/9.12.2/bin/ghc-9.12.2",
                "ghcup",
                component="ghc",
                actualVersion="9.12.2",
            ),
            runtime(
                "ruby",
                "4.0.7",
                "external",
                "",
                "rbenv",
                reason="Global selection delegates to the host system runtime",
            ),
        ],
    },
    "apply": {
        "action": "apply",
        "platform": "aarch64-darwin",
        "backend": "native",
        "catalog": catalog("python"),
        "selection": {"source": "all"},
        "runtimes": [
            runtime(
                "python",
                "3.14.8",
                "ok",
                f"{HOME}/.pyenv/versions/3.14.8/bin/python",
                "pyenv",
            ),
        ],
        "selections": [
            runtime(
                "python",
                "3.14.8",
                "conflict",
                f"{STORE}/bin/python3",
                "pyenv",
                reason="The selected interpreter lies in the Nix store",
            ),
        ],
    },
    "prune": {
        "action": "prune",
        "platform": "aarch64-darwin",
        "backend": "native",
        "catalog": catalog("node", "python"),
        "selection": {"source": "default"},
        "retired": [
            {
                "language": "node",
                "version": "26.10.0",
                "path": f"{HOME}/.local/share/fnm/node-versions/v26.10.0",
                "owner": "fnm",
                "successor": "26.11.1",
                "state": "retire",
                "steps": [
                    "select 26.11.1 globally",
                    "install global packages into 26.11.1: npm-check, pnpm",
                    "remove it",
                ],
            },
            {
                "language": "python",
                "version": "3.14.7",
                "path": f"{HOME}/.pyenv/versions/3.14.7",
                "owner": "pyenv",
                "successor": "3.14.8",
                "state": "blocked",
                "steps": [],
                "reason": "3.14.8 is not installed; apply first",
                "notes": [
                    "environments elsewhere, such as a project's .venv, are "
                    "not checked"
                ],
            },
        ],
    },
}
WIDTHS = (40, 65, 80)


def lines_of(case, style):
    with patch.dict(os.environ, {"HOME": HOME}):
        return render(CASES[case], style)


def escaped(lines):
    return "".join(f"{line}\n".replace("\033", "\\e") for line in lines)


class GoldenTests(unittest.TestCase):
    def check(self, name, lines):
        path = GOLDEN / f"{name}.txt"
        text = escaped(lines)
        if os.environ.get("DEV_BOOTSTRAP_TEST_UPDATE_GOLDEN") == "1":
            path.parent.mkdir(exist_ok=True)
            path.write_text(text)
        self.assertEqual(text, path.read_text(), f"golden {path.name}")

    def test_styled_reports_at_each_width(self):
        for case in CASES:
            for width in WIDTHS:
                with self.subTest(case=case, width=width):
                    self.check(
                        f"{case}-{width}",
                        lines_of(case, ui.Style(True, width)),
                    )

    def test_plain_reports(self):
        for case in CASES:
            with self.subTest(case=case):
                self.check(f"{case}-plain", lines_of(case, ui.Style(False)))

    def test_prune_without_retired_releases(self):
        result = dict(CASES["prune"], retired=[])
        lines = render(result, ui.Style(False))
        self.assertEqual(lines[-1], "No retired release is installed.")


class GuaranteeTests(unittest.TestCase):
    def test_styled_lines_fit_every_width(self):
        for case in CASES:
            for width in range(ui.MIN_WIDTH, ui.MAX_WIDTH + 1):
                for line in lines_of(case, ui.Style(True, width)):
                    with self.subTest(case=case, width=width, line=line):
                        self.assertLessEqual(ui.text_width(line), width)

    def test_plain_output_keeps_every_path_and_reason(self):
        for case, result in CASES.items():
            text = "\n".join(lines_of(case, ui.Style(False)))
            self.assertNotIn("\033", text)
            self.assertNotIn("…", text)
            rows = result.get("runtimes", []) + result.get("retired", [])
            rows += result.get("selections", [])
            for row in rows:
                with self.subTest(case=case, row=row["version"]):
                    if row["path"]:
                        self.assertIn(row["path"], text)
                    if row.get("reason"):
                        self.assertIn(row["reason"], text)
                    if row.get("remediation"):
                        self.assertIn(row["remediation"], text)

    def test_failure_reasons_are_never_cut(self):
        # A reason that does not fit the row continues on wrapped lines.
        reason = CASES["verify"]["runtimes"][0]["reason"]
        for width in WIDTHS:
            lines = lines_of("verify", ui.Style(True, width))
            words = " ".join(_plain_text(lines).split())
            with self.subTest(width=width):
                self.assertIn(" ".join(reason.split()), words)
                self.assertIn("fix pyenv install --force 3.14.8", words)

    def test_control_characters_reach_the_terminal_escaped(self):
        result = dict(CASES["verify"])
        row = dict(result["runtimes"][0], reason="bad\033]0;title\007 name")
        result["runtimes"] = [row]
        for style in (ui.Style(True, 80), ui.Style(False)):
            text = "\n".join(render(result, style))
            with self.subTest(styled=style.styled):
                self.assertIn("bad\\x1b]0;title\\x07 name", text)
                self.assertNotIn("\007", text)

    def test_a_health_row_shows_the_release_that_runs(self):
        # A selection on another compiler is healthy, but not the default.
        lines = lines_of("health", ui.Style(False))
        self.assertIn(
            "Haskell GHC  9.12.2   ghcup    ok        "
            f"{HOME}/.ghcup/ghc/9.12.2/bin/ghc-9.12.2",
            lines,
        )
        self.assertIn("  the declared default is 9.14.1", lines)
        self.assertEqual(
            sum("the declared default" in line for line in lines), 1
        )

    def test_rows_are_named_by_the_catalog_titles(self):
        lines = lines_of("plan", ui.Style(False))
        self.assertTrue(any(line.startswith("Node ") for line in lines))
        self.assertTrue(
            any(line.startswith("Haskell Cabal ") for line in lines)
        )
        # Without titles, a report still names each row by its key.
        bare = dict(CASES["plan"], catalog=[])
        lines = render(bare, ui.Style(False))
        self.assertTrue(
            any(line.startswith("haskell cabal ") for line in lines)
        )

    def test_styled_paths_are_shortened_and_plain_paths_are_not(self):
        styled = "\n".join(lines_of("apply", ui.Style(True, 120)))
        self.assertIn("/nix/store/0123456…-python3-3.14.8/bin/python3", styled)
        self.assertIn("~/.pyenv/versions/3.14.8/bin/python", styled)
        plain = "\n".join(lines_of("apply", ui.Style(False)))
        self.assertIn(f"{STORE}/bin/python3", plain)
        path = f"{HOME}/{STORE}"
        self.assertEqual(ui.short_path(path, ui.Style(False), HOME), path)


def _plain_text(lines):
    return "\n".join(ui.strip(line) for line in lines)


class StyleTests(unittest.TestCase):
    class Terminal(io.StringIO):
        def isatty(self):
            return True

    def test_only_a_color_terminal_is_styled(self):
        terminal = self.Terminal()
        cases = (
            (terminal, {"TERM": "xterm-256color"}, True),
            (terminal, {"TERM": "xterm-256color", "NO_COLOR": "1"}, False),
            (terminal, {"TERM": "dumb"}, False),
            (terminal, {}, False),
            (io.StringIO(), {"TERM": "xterm-256color"}, False),
        )
        for stream, environ, styled in cases:
            with self.subTest(environ=environ, tty=stream is terminal):
                self.assertIs(ui.Style.detect(stream, environ).styled, styled)

    def test_width_follows_columns_within_bounds(self):
        for columns, width in (("30", 40), ("65", 65), ("300", 120)):
            with (
                self.subTest(columns=columns),
                patch.dict(os.environ, {"COLUMNS": columns}),
            ):
                self.assertEqual(
                    ui.Style.detect(io.StringIO(), {}).width, width
                )

    def test_text_width_counts_cells(self):
        self.assertEqual(ui.text_width("\033[1;32m●\033[0m ok"), 4)
        self.assertEqual(ui.text_width("界"), 2)
        self.assertEqual(ui.truncate("界界界", 5), "界界…")

    def test_paths_lose_whole_middle_components(self):
        path = "/home/user/.pyenv/versions/3.14.8/bin/python"
        self.assertEqual(ui.truncate(path, 20), "/home/…/bin/python")
        self.assertEqual(ui.truncate(path, 28), "/home/…/3.14.8/bin/python")
        self.assertEqual(ui.truncate("~/a/b/c/d/file", 10), "~/…/d/file")
        self.assertEqual(
            ui.truncate("no slashes here at all", 10), "no slashe…"
        )


def _shell_style():
    """The Zsh style module, from the package's shell configuration or the
    repository layout."""
    configured = os.environ.get("DEV_BOOTSTRAP_SHELL_CONFIG")
    candidates = [Path(configured)] if configured else []
    candidates.append(
        Path(__file__).resolve().parents[4] / "shells" / "zsh" / "config"
    )
    for config in candidates:
        path = config / "scripts" / "_ui.zsh"
        if path.is_file():
            return path.read_text(encoding="utf-8")
    return None


def _shell_table(text, name):
    block = re.search(rf"typeset -gA {name}=\(\n(.*?)\n\)", text, re.S)
    return dict(re.findall(r"^\s+(\w+)\s+'([^']*)'\s*$", block[1], re.M))


class SharedStyleTests(unittest.TestCase):
    """One look across languages: these tokens are defined in _ui.zsh."""

    def setUp(self):
        self.shell = _shell_style()
        if self.shell is None:
            self.skipTest("the Zsh style module is not available here")

    def test_tokens_match_the_shell_style_module(self):
        self.assertEqual(_shell_table(self.shell, "_ZSH_UI_SGR"), ui.SGR)
        self.assertEqual(_shell_table(self.shell, "_ZSH_UI_GLYPH"), ui.GLYPH)
        for name, value in (("GUTTER", ui.GUTTER), ("INDENT", ui.INDENT)):
            shell = re.search(rf"typeset -gi _ZSH_UI_{name}=(\d+)", self.shell)
            self.assertEqual(int(shell[1]), value, name)


class CommandLineTests(unittest.TestCase):
    def parse(self, *arguments):
        return cli.command_line().parse_args(["--manifest", "m", *arguments])

    def test_json_is_an_alias_of_format_json(self):
        self.assertEqual(self.parse().format, "text")
        self.assertEqual(self.parse("--json").format, "json")
        self.assertEqual(self.parse("--format", "json").format, "json")
        with (
            contextlib.redirect_stderr(io.StringIO()),
            self.assertRaises(SystemExit),
        ):
            self.parse("--format", "text", "--json")
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            cli.report(CASES["verify"], "json")
        self.assertEqual(printed.getvalue()[0], "{")

    def test_text_goes_through_the_renderer(self):
        printed = io.StringIO()
        with (
            contextlib.redirect_stdout(printed),
            patch.dict(os.environ, {"HOME": HOME}),
        ):
            cli.report(CASES["verify"], "text")
        self.assertEqual(
            printed.getvalue().splitlines(),
            lines_of("verify", ui.Style(False)),
        )


if __name__ == "__main__":
    unittest.main()
