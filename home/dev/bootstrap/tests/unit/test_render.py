"""The text report: golden renderings, width and plain-output guarantees.

Golden files hold the exact output, with ESC written as \\e so color changes
show in a diff. After an intended change, rewrite them with
DEV_BOOTSTRAP_TEST_UPDATE_GOLDEN=1 and review the diff.
"""

import contextlib
import copy
import io
import os
import unittest
from pathlib import Path
from unittest.mock import patch

import terminal_style as ui

from core import cli
from core.adapters import ADAPTERS
from core.render import render

GOLDEN = Path(__file__).resolve().parent / "golden"
HOME = "/home/user"
STORE = "/nix/store/0123456789abcdefghijklmnopqrstuv-python3-3.14.8"
RUNS = f"{HOME}/.local/state/dev-bootstrap/runs"


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
            "manager": adapter.manager_name,
            "selected": name in selected,
            "cost": adapter.cost_class(),
        }
        if adapter.component_titles:
            entry["componentTitles"] = dict(adapter.component_titles)
        if adapter.primary_component:
            entry["primaryComponent"] = adapter.primary_component
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
    "preflight": {
        "action": "plan",
        "platform": "x86_64-linux",
        "backend": "native",
        "catalog": catalog("node", "python"),
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
                "python",
                "3.14.9",
                "missing",
                f"{HOME}/.pyenv/versions/3.14.9/bin/python",
                "pyenv",
            ),
        ],
        "setup": {"nativeManagers": []},
        "preflight": {
            "packageManager": {"path": "/usr/bin/pacman", "state": "present"},
            "missing": ["sqlite", "tk"],
            "privileged": True,
            "command": [
                "sudo",
                "/usr/bin/pacman",
                "-S",
                "--needed",
                "--noconfirm",
                "sqlite",
                "tk",
            ],
            "ecosystems": [
                {
                    "language": "node",
                    "manager": "present",
                    "packages": [],
                    "missing": [],
                },
                {
                    "language": "python",
                    "manager": "present",
                    "packages": ["sqlite", "tk", "xz"],
                    "missing": ["sqlite", "tk"],
                    "unbuildable": ["3.14.9"],
                },
            ],
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
                # A global selection carries no component: it is GHC's.
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
        "run": {
            "id": "20261011T101500Z",
            "command": "apply",
            "path": RUNS + "/20261011T101500Z",
            "started": "2026-10-11T10:15:00Z",
            "duration": 426.2,
            "exit": 0,
            "outcome": "ok",
            "logs": {"python": RUNS + "/20261011T101500Z/python.log"},
        },
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
CASES["stopped"] = {
    "action": "apply",
    "platform": "x86_64-linux",
    "backend": "native",
    "catalog": catalog("node", "python"),
    "selection": {"source": "file", "path": f"{HOME}/.config/sel.json"},
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
            "python",
            "3.14.9",
            "missing",
            f"{HOME}/.pyenv/versions/3.14.9/bin/python",
            "pyenv",
        ),
    ],
    "run": {
        "id": "20261011T101500Z",
        "command": "apply",
        "path": RUNS + "/20261011T101500Z",
        "started": "2026-10-11T10:15:00Z",
        "duration": 83.4,
        "exit": 2,
        "outcome": "failed",
        "logs": {"python": RUNS + "/20261011T101500Z/python.log"},
        "error": {
            "stage": "runtimes",
            "message": "runtimes: pyenv exited 1: BUILD FAILED (Arch Linux "
            "using python-build 2.8.8). Retry apply after resolving this "
            "stage; plan reports any incomplete installation.",
            "log": RUNS + "/20261011T101500Z/python.log",
        },
    },
}
CASES["history"] = {
    "schema": 1,
    "action": "report",
    "directory": RUNS,
    "runs": [
        {
            "id": "20261011T101500Z",
            "path": RUNS + "/20261011T101500Z",
            "state": "failed",
            "command": "apply",
            "started": "2026-10-11T10:15:00Z",
            "duration": 83.4,
            "exit": 2,
        },
        {
            "id": "20261010T090000Z",
            "path": RUNS + "/20261010T090000Z",
            "state": "ok",
            "command": "prune --yes",
            "started": "2026-10-10T09:00:00Z",
            "duration": 12.0,
            "exit": 0,
        },
        {
            "id": "20261009T080000Z",
            "path": RUNS + "/20261009T080000Z",
            "state": "incomplete",
        },
    ],
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

    def test_apply_names_selections_left_on_another_release(self):
        # apply never moves an existing default: the hint says so.
        result = copy.deepcopy(CASES["apply"])
        result["selections"] = [
            runtime(
                "python",
                "3.14.8",
                "ok",
                f"{HOME}/.pyenv/versions/3.14.7/bin/python",
                "pyenv",
                actualVersion="3.14.7",
            )
        ]
        lines = list(render(result, ui.Style(False)))
        self.assertEqual(
            lines[-1],
            "[OK]    1 ok. 1 global selection stays on another release; "
            "verify --health lists them.",
        )

    def test_a_preflight_that_stops_apply_says_so(self):
        result = copy.deepcopy(CASES["preflight"])
        preflight = result["preflight"]
        preflight["packageManager"]["state"] = "missing"
        preflight["command"] = []
        preflight["ecosystems"][1].pop("unbuildable")
        text = "\n".join(render(result, ui.Style(False)))
        self.assertIn("Package manager  missing", text)
        self.assertIn("apply cannot install native packages", text)
        self.assertNotIn("runs:", text)
        self.assertTrue(
            text.endswith(". Resolve the preflight before apply."), text
        )
        # Nothing missing and nothing stopping: the usual next step.
        result = copy.deepcopy(CASES["preflight"])
        result["preflight"].update(missing=[], command=[], privileged=False)
        for entry in result["preflight"]["ecosystems"]:
            entry.update(missing=[])
            entry.pop("unbuildable", None)
        text = "\n".join(render(result, ui.Style(False)))
        self.assertIn("Native packages  all 3 packages installed", text)
        self.assertTrue(text.endswith(". apply installs 1 runtime."), text)

    def test_a_preflight_with_packages_to_install_says_so(self):
        result = copy.deepcopy(CASES["preflight"])
        for entry in result["preflight"]["ecosystems"]:
            entry.pop("unbuildable", None)
        packages = len(result["preflight"]["missing"])
        lines = list(render(result, ui.Style(False)))
        self.assertTrue(
            lines[-1].endswith(
                f". apply installs {packages} native packages and 1 runtime."
            ),
            lines[-1],
        )
        # Every runtime installed, a prerequisite gone: still work to do.
        for row in result["runtimes"]:
            row["state"] = "present"
        lines = list(render(result, ui.Style(False)))
        self.assertTrue(lines[-1].startswith("[INFO]"), lines[-1])
        self.assertTrue(
            lines[-1].endswith(
                f". apply installs {packages} native packages."
            ),
            lines[-1],
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

    def test_a_plan_states_each_installing_ecosystems_cost_once(self):
        result = copy.deepcopy(CASES["plan"])
        result["runtimes"].append(
            runtime(
                "node",
                "22.30.0",
                "missing",
                f"{HOME}/.local/share/fnm/node-versions/v22.30.0"
                "/installation/bin/node",
                "fnm",
            )
        )
        lines = render(result, ui.Style(False))
        self.assertEqual(lines.count("  cost: download · small"), 1)
        self.assertEqual(lines.count("  cost: source build · medium"), 1)
        # Only what apply would install has a cost; the result of an
        # apply reports none.
        applied = dict(result, action="apply")
        self.assertFalse(
            any("cost:" in line for line in render(applied, ui.Style(False)))
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
