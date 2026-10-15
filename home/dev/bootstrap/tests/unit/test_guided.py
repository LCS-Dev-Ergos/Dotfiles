"""The guided setup's screens: the summary, the review and their order.

The planner and the prompter are replaced, so these tests read what the
flow does with given reports. Golden files hold the screens as test_render
holds reports (ESC written as \\e); rewrite them with
DEV_BOOTSTRAP_TEST_UPDATE_GOLDEN=1 and review the diff.
"""

import copy
import io
import os
import shlex
import unittest
from pathlib import Path
from unittest.mock import patch

from core import guided, ui
from core.adapters import ADAPTERS
from core.guided import Guide, blockers, command_lines, review
from tests.prompter import ScriptedPrompter
from tests.unit.test_render import HOME, escaped

GOLDEN = Path(__file__).resolve().parent / "golden"
WIDTHS = (40, 65, 80)


def entry(language, selected=True, **extra):
    adapter = ADAPTERS[language]
    described = {
        "language": language,
        "title": adapter.title or language,
        "manager": adapter.manager_name,
        "consents": [],
        "selected": selected,
        "cost": adapter.cost_class(),
    }
    if adapter.component_titles:
        described["componentTitles"] = dict(adapter.component_titles)
    if adapter.primary_component:
        described["primaryComponent"] = adapter.primary_component
    return dict(described, **extra)


def row(language, version, state, owner, **extra):
    return dict(
        language=language,
        version=version,
        path=f"{HOME}/.local/{language}/{version}/bin/{language}",
        owner=owner,
        state=state,
        **extra,
    )


GHCUP = "https://get-ghcup.haskell.org/0.1.50/bootstrap-haskell"
SDKMAN = "https://get.sdkman.io?rcupdate=false"
RUNTIMES = [
    row("node", "24.21.0", "present", "fnm"),
    row("node", "26.11.1", "missing", "fnm"),
    row("python", "3.14.8", "present", "pyenv"),
    *(
        row(
            "haskell",
            version,
            "missing",
            "ghcup",
            component=component,
            reason="apply installs ghcup first",
        )
        for component, version in (
            ("ghc", "9.14.1"),
            ("cabal", "3.16.1.0"),
            ("hls", "2.14.0.0"),
        )
    ),
    row(
        "jvm",
        "21.0.12.1",
        "conflict",
        "sdkman",
        reason="An incomplete installation is in the way; inspect it",
    ),
    row(
        "kotlin",
        "2.4.21",
        "missing",
        "sdkman",
        reason="apply installs sdkman first",
    ),
]
SELECTION = ["node", "python", "haskell", "jvm", "kotlin"]
PACKAGES = {
    "node": [],
    "python": ["openssl", "zlib"],
    "haskell": ["gmp", "zip"],
    "jvm": ["zip"],
    "kotlin": ["zip"],
}
REVIEWED = {
    "schema": 1,
    "action": "plan",
    "platform": "x86_64-linux",
    "backend": "native",
    "defaults": {
        "node": "26.11.1",
        "python": "3.14.8",
        "haskell": "9.14.1",
        "jvm": "21.0.12.1",
        "kotlin": "2.4.21",
        "conda": "26.7.2",
    },
    "catalog": [
        *(entry(language) for language in SELECTION),
        entry("conda", selected=False),
    ],
    "observed": {"globalSelections": {}, "installed": {}},
    "runtimes": RUNTIMES,
    "setup": {
        "stages": [],
        "nativeManagers": [
            {"language": "node", "state": "present", "path": "/usr/bin/fnm"},
            {
                "language": "python",
                "state": "present",
                "path": f"{HOME}/.pyenv/bin/pyenv",
            },
            {
                "language": "haskell",
                "state": "missing",
                "reason": "Native ghcup is unavailable",
                "installer": GHCUP,
            },
            {
                "language": "jvm",
                "state": "missing",
                "reason": "Native sdkman is unavailable",
                "installer": SDKMAN,
            },
            {
                "language": "kotlin",
                "state": "missing",
                "reason": "Native sdkman is unavailable",
            },
        ],
        "packageManager": "/usr/bin/pacman",
        "privilegedPackages": True,
        "initialDefaults": ["haskell", "jvm", "kotlin"],
    },
    "preflight": {
        "packageManager": {"path": "/usr/bin/pacman", "state": "present"},
        "missing": ["gmp", "zip"],
        "privileged": True,
        "command": [
            "sudo",
            "/usr/bin/pacman",
            "-S",
            "--needed",
            "--noconfirm",
            "gmp",
            "zip",
        ],
        "ecosystems": [
            {
                "language": language,
                "manager": "present"
                if language in ("node", "python")
                else "missing",
                "packages": packages,
                "missing": [p for p in packages if p in ("gmp", "zip")],
            }
            for language, packages in PACKAGES.items()
        ],
    },
    "selection": {"source": "only"},
}


def detected():
    """The same machine, planned for every available ecosystem."""
    result = copy.deepcopy(REVIEWED)
    for described in result["catalog"]:
        described["selected"] = True
    result["runtimes"].append(row("conda", "26.7.2", "present", "conda"))
    result["setup"]["nativeManagers"].append(
        {"language": "conda", "state": "present", "path": "/opt/conda"}
    )
    return result


def settled():
    """A selection with nothing to do: everything installed and selected."""
    result = copy.deepcopy(REVIEWED)
    result["platform"] = "aarch64-darwin"
    for runtime in result["runtimes"]:
        runtime["state"] = "present"
        runtime.pop("reason", None)
    for manager in result["setup"]["nativeManagers"]:
        manager.update(state="present", path="/opt/homebrew/bin/manager")
        manager.pop("installer", None)
        manager.pop("reason", None)
    result["setup"]["initialDefaults"] = []
    result["preflight"].update(
        packageManager={"path": "/opt/homebrew/bin/brew", "state": "present"},
        missing=[],
        privileged=False,
        command=[],
    )
    for ecosystem in result["preflight"]["ecosystems"]:
        ecosystem.update(manager="present", missing=[])
    return result


class GoldenCase(unittest.TestCase):
    def check(self, name, text):
        path = GOLDEN / name
        if os.environ.get("DEV_BOOTSTRAP_TEST_UPDATE_GOLDEN") == "1":
            path.write_text(text)
        self.assertEqual(text, path.read_text(), f"golden {path.name}")


class SummaryTests(GoldenCase):
    def summary(self, style):
        guide = Guide({}, None, None, style)
        with patch.dict(os.environ, {"HOME": HOME}):
            return guide.summary(detected(), SELECTION)

    def test_styled_summary_at_each_width(self):
        for width in WIDTHS:
            with self.subTest(width=width):
                lines = self.summary(ui.Style(True, width))
                self.check(f"guided-summary-{width}.txt", escaped(lines))
                self.assertTrue(
                    all(ui.text_width(line) <= width for line in lines)
                )

    def test_plain_summary_keeps_every_state_in_words(self):
        lines = self.summary(ui.Style(False))
        self.check("guided-summary-plain.txt", escaped(lines))
        text = "\n".join(lines)
        self.assertNotIn("\033", text)
        for word in ("present", "missing", "conflict", "not selected"):
            self.assertIn(word, text)

    def test_a_missing_package_manager_is_called_out(self):
        result = detected()
        result["preflight"]["packageManager"]["state"] = "missing"
        guide = Guide({}, None, None, ui.Style(False))
        lines = guide.summary(result, SELECTION)
        self.assertIn("/usr/bin/pacman is missing", lines)


class ReviewTests(GoldenCase):
    def review(self, result, origin, style, accepted=()):
        with patch.dict(os.environ, {"HOME": HOME}):
            return review(result, origin, style, accepted)

    def test_review_at_each_width_and_plain(self):
        only = {"source": "only"}
        for width in WIDTHS:
            with self.subTest(width=width):
                lines = self.review(REVIEWED, only, ui.Style(True, width))
                self.check(f"guided-review-{width}.txt", escaped(lines))
                self.assertTrue(
                    all(ui.text_width(line) <= width for line in lines)
                )
        self.check(
            "guided-review-plain.txt",
            escaped(self.review(REVIEWED, only, ui.Style(False))),
        )
        saved = {"source": "file", "path": f"{HOME}/.config/selection.json"}
        self.check(
            "guided-settled-80.txt",
            escaped(self.review(settled(), saved, ui.Style(True, 80))),
        )

    def plain(self, result, origin=None, accepted=()):
        return self.review(
            result, origin or {"source": "only"}, ui.Style(False), accepted
        )

    def test_shared_managers_are_listed_once_with_their_source(self):
        lines = self.plain(REVIEWED)
        (sdkman,) = [line for line in lines if line.startswith("sdkman")]
        self.assertEqual(
            sdkman.split(),
            "sdkman JVM, Kotlin installer get.sdkman.io".split(),
        )

    def test_cost_reads_once_per_ecosystem(self):
        lines = self.plain(REVIEWED)
        # The runtimes table comes first; the defaults list GHC again.
        ghc = next(line for line in lines if line.startswith("Haskell GHC "))
        (cabal,) = [line for line in lines if line.startswith("Haskell Cabal")]
        self.assertTrue(ghc.endswith("download · large"))
        self.assertTrue(cabal.rstrip().endswith("-"))

    def test_blockers(self):
        result = copy.deepcopy(REVIEWED)
        result["preflight"]["sdk"] = "missing"
        result["preflight"]["ecosystems"][0]["unbuildable"] = ["26.11.1"]
        result["runtimes"][2].update(
            state="conflict",
            reason="ssl does not load",
            remediation="pyenv install --force 3.14.8",
        )
        found = blockers(result)
        self.assertEqual(
            [item for item, _, _ in found],
            ["Apple SDK", "Node 26.11.1", "Python 3.14.8", "JVM 21.0.12.1"],
        )
        self.assertEqual(
            found[1][1:],
            ("fnm cannot build it", "upgrade fnm, then run setup again"),
        )
        self.assertEqual(found[2][2], "pyenv install --force 3.14.8")
        result["preflight"]["packageManager"]["state"] = "missing"
        self.assertIn("nothing can be installed", blockers(result)[0][1])

    def test_terms_name_their_flags(self):
        result = copy.deepcopy(REVIEWED)
        result["catalog"][0]["consents"] = ["node-terms"]
        text = "\n".join(self.plain(result))
        self.assertIn("named with --accept node-terms.", text)
        text = "\n".join(self.plain(result, accepted=["node-terms"]))
        self.assertNotIn("Terms", text)
        self.assertIn("--accept node-terms", text.splitlines()[-1])

    def test_without_the_guide_matches_the_selection_source(self):
        for origin, expected in (
            ({"source": "only"}, "dev-bootstrap apply --only node --only "),
            ({"source": "all"}, "dev-bootstrap apply --all"),
            ({"source": "default"}, "dev-bootstrap apply"),
            ({"source": "file", "path": "/s.json"}, "dev-bootstrap apply"),
        ):
            with self.subTest(origin=origin):
                last = self.plain(REVIEWED, origin)[-1]
                self.assertTrue(last.startswith(expected), last)


class CommandTests(unittest.TestCase):
    def test_commands_wrap_into_lines_that_still_paste(self):
        argv = ["dev-bootstrap", "apply"] + ["--only", "haskell"] * 6
        lines = [
            ui.strip(line) for line in command_lines(ui.Style(True, 50), argv)
        ]
        self.assertGreater(len(lines), 1)
        self.assertTrue(all(len(line) <= 50 - ui.GUTTER for line in lines))
        self.assertTrue(all(line.endswith(" \\") for line in lines[:-1]))
        self.assertEqual(
            shlex.split(" ".join(line.rstrip("\\") for line in lines)), argv
        )
        self.assertEqual(
            command_lines(ui.Style(False), argv), [shlex.join(argv)]
        )
        # Untrusted words are quoted and cannot drive the terminal.
        self.assertEqual(
            command_lines(ui.Style(False), ["say", "a b\a"]),
            ["say 'a b\\x07'"],
        )


class FlowTests(unittest.TestCase):
    def test_detect_summarize_and_review_ask_nothing(self):
        calls = []

        def planner(only):
            calls.append(list(only))
            return detected() if len(calls) == 1 else REVIEWED

        output = io.StringIO()
        prompter = ScriptedPrompter(self)
        style = ui.Style(False)
        guide = Guide({}, planner, prompter, style, stream=output)
        with (
            patch.object(guided, "available", return_value=["every"]),
            patch.object(guided, "select", return_value=SELECTION),
        ):
            code = guide.run(["node"], {"source": "only"})
        self.assertEqual(code, 0)
        self.assertEqual(calls, [["every"], SELECTION])
        self.assertEqual(prompter.asked, [])
        printed = output.getvalue().splitlines()
        self.assertEqual(printed[0], "dev-bootstrap · Guided setup")
        reviewed = review(REVIEWED, {"source": "only"}, style)
        self.assertEqual(printed[-len(reviewed) - 2 : -2], reviewed)
        # The review stops short of apply while something blocks it.
        self.assertEqual(
            printed[-1],
            "[ERROR] 2 present, 5 missing, 1 conflict; resolve the review's "
            "blockers before apply.",
        )

    def test_closing_names_the_next_step(self):
        guide = Guide({}, None, None, ui.Style(False))
        self.assertEqual(
            guide.closing(settled()),
            ["[OK]    8 present; nothing to install."],
        )
        work = settled()
        work["setup"]["initialDefaults"] = ["node"]
        self.assertEqual(
            guide.closing(work),
            ["[INFO]  8 present; apply carries out this review."],
        )


if __name__ == "__main__":
    unittest.main()
