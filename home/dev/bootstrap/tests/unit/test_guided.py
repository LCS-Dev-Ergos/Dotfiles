"""The guided setup's screens: the summary, the review and their order.

The planner and the prompter are replaced, so these tests read what the
flow does with given reports. Golden files hold the screens as test_render
holds reports (ESC written as \\e); rewrite them with
DEV_BOOTSTRAP_TEST_UPDATE_GOLDEN=1 and review the diff.
"""

import copy
import io
import json
import os
import shlex
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from core import guided, ui
from core.adapters import ADAPTERS
from core.guided import Guide, blockers, command_lines, review
from core.prompt import Cancelled
from tests.prompter import ScriptedPrompter
from tests.unit.test_render import CASES, HOME, escaped

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

    def test_unselected_ecosystems_keep_only_their_state(self):
        guide = Guide({}, None, None, ui.Style(False))
        lines = guide.summary(detected(), ["node"])
        self.assertNotIn("  apply installs ghcup first", lines)
        self.assertIn(
            "  apply installs ghcup first", self.summary(ui.Style(False))
        )

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


def planned(selection, base=None):
    """A settled report for the selection, as the planner would give it."""
    result = copy.deepcopy(base or settled())
    for described in result["catalog"]:
        described["selected"] = described["language"] in selection
    result["runtimes"] = [
        runtime
        for runtime in result["runtimes"]
        if runtime["language"] in selection
    ]
    return result


def privileged():
    result = settled()
    result["preflight"].update(
        missing=["zip"],
        privileged=True,
        command=["sudo", "/usr/bin/pacman", "-S", "--needed", "zip"],
    )
    return result


class FlowTests(unittest.TestCase):
    """Every branch of the flow, with a scripted person and fake executor."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="bootstrap-guided-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.selection_file = self.root / "config/selection.json"
        environment = patch.dict(
            os.environ,
            {"HOME": HOME, "XDG_STATE_HOME": str(self.root / "state")},
        )
        environment.start()
        self.addCleanup(environment.stop)
        for name, value in (
            ("available", SELECTION + ["conda"]),
            # The engine's own resolution is tested elsewhere: here the
            # selection is the one the options name, or the defaults.
            ("select", None),
        ):
            mock = patch.object(
                guided,
                name,
                side_effect=(lambda manifest, only: list(only or SELECTION))
                if value is None
                else None,
                return_value=value,
            )
            mock.start()
            self.addCleanup(mock.stop)
        self.attend = patch.object(guided.process, "attend").start()
        self.addCleanup(patch.stopall)
        self.planned = []
        self.applied = []
        self.base = None
        self.code = 0
        self.run_effect = None

    def planner(self, selection):
        self.planned.append(list(selection))
        if len(self.planned) == 1:
            return detected()
        return planned(selection, self.base)

    def executor(self, selection, accepted):
        self.applied.append((selection, list(accepted)))
        if self.run_effect:
            return self.run_effect()
        return self.code

    def guide(self, answers=(), *, origin=None, only=None, yes=False, **kw):
        self.prompter = ScriptedPrompter(self, answers, **kw)
        self.output = io.StringIO()
        guide = Guide(
            {"setup": {"authenticate": ["sudo", "-v"]}},
            self.planner,
            self.prompter,
            ui.Style(False),
            executor=self.executor,
            selection_file=self.selection_file,
            stream=self.output,
        )
        code = guide.run(only, origin or {"source": "default"}, yes=yes)
        self.prompter.finished()
        return code

    def printed(self):
        return self.output.getvalue().splitlines()

    def test_a_blocked_review_asks_nothing_and_applies_nothing(self):
        self.base = REVIEWED
        code = self.guide(only=SELECTION, origin={"source": "only"})
        self.assertEqual(code, 1)
        self.assertEqual(self.planned, [SELECTION + ["conda"], SELECTION])
        self.assertEqual(self.applied, [])
        printed = self.printed()
        self.assertEqual(printed[0], "dev-bootstrap · Guided setup")
        self.assertIn("Blockers · apply stops on these", printed)
        self.assertEqual(
            printed[-1].split(";")[1],
            " resolve the review's blockers before apply.",
        )

    def test_partial_selection_is_saved_and_applied(self):
        code = self.guide(
            [("choose_many", ["python", "node"]), ("confirm", True)]
        )
        self.assertEqual(code, 0)
        kind, header, details = self.prompter.asked[0]
        self.assertEqual(details["selected"], SELECTION)
        # Every detected ecosystem is offered, with its state and cost.
        self.assertEqual(
            details["options"][2],
            ("haskell", "Haskell  missing · download · large"),
        )
        self.assertEqual(len(details["options"]), 6)
        self.assertEqual(self.planned[1], ["node", "python"])
        self.assertEqual(
            json.loads(self.selection_file.read_text())["ecosystems"],
            ["node", "python"],
        )
        # apply reads the selection back from the file it was saved in.
        self.assertEqual(self.applied, [({"only": None, "all": False}, [])])
        printed = self.printed()
        self.assertIn("Selection · chosen here", printed)
        self.assertIn("dev-bootstrap apply --only node --only python", printed)
        self.assertIn("Next", printed)

    def test_an_unchanged_selection_is_not_saved(self):
        self.guide([("choose_many", SELECTION), ("confirm", True)])
        self.assertFalse(self.selection_file.exists())
        self.assertEqual(self.applied, [({"only": None, "all": False}, [])])

    def test_an_empty_selection_changes_nothing(self):
        code = self.guide([("choose_many", [])])
        self.assertEqual(code, 0)
        self.assertEqual(len(self.planned), 1)
        self.assertEqual(self.applied, [])
        self.assertFalse(self.selection_file.exists())
        self.assertEqual(
            self.printed()[-1], "Nothing selected; setup changes nothing."
        )

    def test_a_missing_requirement_is_added_and_asked_again(self):
        self.guide(
            [
                ("choose_many", ["kotlin"]),
                ("choose_many", ["kotlin", "jvm"]),
                ("confirm", True),
            ]
        )
        self.assertEqual(
            self.prompter.asked[1][2]["selected"], ["kotlin", "jvm"]
        )
        self.assertIn(
            "Kotlin needs JVM, now selected as well: confirm or change.",
            self.printed(),
        )
        # Registry order: requirements first.
        self.assertEqual(self.planned[1], ["jvm", "kotlin"])

    def test_options_answer_the_selection_question(self):
        for origin in ({"source": "only"}, {"source": "all"}):
            with self.subTest(origin=origin):
                self.guide([("confirm", True)], origin=origin, only=["node"])
        self.assertEqual(
            [selection for selection, _ in self.applied],
            [{"only": ["node"], "all": False}, {"only": None, "all": True}],
        )

    def test_a_declared_selection_file_is_not_asked_about(self):
        self.selection_file.parent.mkdir(parents=True)
        self.selection_file.symlink_to(self.root / "declared.json")
        self.guide([("confirm", True)])
        self.assertEqual(self.applied, [({"only": None, "all": False}, [])])

    def test_cancelling_before_apply_changes_nothing(self):
        for answers in (
            [("choose_many", Cancelled)],
            [("choose_many", ["node"]), ("confirm", False)],
            [("choose_many", ["node"]), ("confirm", Cancelled)],
        ):
            with self.subTest(answers=answers), self.assertRaises(Cancelled):
                self.guide(answers)
        self.assertEqual(self.applied, [])
        self.assertFalse(self.selection_file.exists())

    def test_privilege_choices(self):
        self.base = privileged()
        with self.assertRaises(Cancelled):
            self.guide([("choose_many", ["node"]), ("choose", "cancel")])
        self.assertFalse(self.selection_file.exists())

        code = self.guide([("choose_many", ["node"]), ("choose", "manual")])
        self.assertEqual(code, 0)
        self.assertEqual(self.applied, [])
        self.assertEqual(
            self.printed()[-1], "sudo /usr/bin/pacman -S --needed zip"
        )
        # The person comes back to the same choice.
        self.assertTrue(self.selection_file.exists())
        self.attend.assert_not_called()

        self.guide([("choose_many", ["node"]), ("choose", "authenticate")])
        self.attend.assert_called_once_with(["sudo", "-v"])
        self.assertEqual(len(self.applied), 1)
        details = self.prompter.asked[1][2]
        self.assertEqual(details["default"], "authenticate")

    def test_without_a_terminal_only_yes_accepts(self):
        with self.assertRaisesRegex(
            guided.BootstrapError,
            "Apply this review: nobody can answer here, since stdin is not "
            "a terminal; accept the review with --yes",
        ):
            self.guide(attended=False)
        self.assertEqual(self.applied, [])
        # The saved or default selection stands; nothing asks for it.
        self.assertEqual(self.prompter.asked[0][0], "confirm")
        self.base = privileged()
        self.assertEqual(self.guide(attended=False, yes=True), 0)
        self.assertEqual(self.applied, [({"only": None, "all": False}, [])])
        self.attend.assert_not_called()

    def test_terms_are_accepted_or_the_flow_stops(self):
        self.base = settled()
        self.base["catalog"][0]["consents"] = ["node-terms"]
        with self.assertRaises(Cancelled):
            self.guide([("choose_many", SELECTION), ("confirm", False)])
        self.guide(
            [("choose_many", SELECTION), ("confirm", True), ("confirm", True)]
        )
        self.assertEqual(
            self.prompter.asked[1][1],
            "Accept node-terms, which Node requires?",
        )
        self.assertEqual(
            self.applied, [({"only": None, "all": False}, ["node-terms"])]
        )

    def record(self, report):
        """A run the fake apply records, as core.runs keeps one."""
        directory = self.root / "state/dev-bootstrap/runs/20261015T120000Z"
        directory.mkdir(parents=True)
        (directory / "report.json").write_text(json.dumps(report))

    def test_a_failed_apply_shows_what_it_left(self):
        def fail():
            self.record(CASES["stopped"])
            return 2

        self.run_effect = fail
        code = self.guide([("choose_many", SELECTION), ("confirm", True)])
        self.assertEqual(code, 2)
        printed = self.printed()
        self.assertIn("dev-bootstrap · Apply failed", printed)
        self.assertNotIn("Next", printed)

    def test_an_older_run_is_never_shown_as_this_one(self):
        self.record(CASES["stopped"])
        self.code = 2
        self.guide([("choose_many", SELECTION), ("confirm", True)])
        self.assertNotIn("dev-bootstrap · Apply failed", self.printed())

    def test_ctrl_c_during_apply_shows_what_finished(self):
        def interrupt():
            self.record(CASES["stopped"])
            raise KeyboardInterrupt

        self.run_effect = interrupt
        with self.assertRaises(KeyboardInterrupt):
            self.guide([("choose_many", SELECTION), ("confirm", True)])
        self.assertIn("dev-bootstrap · Apply failed", self.printed())

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
