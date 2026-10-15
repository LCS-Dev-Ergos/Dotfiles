"""The prompters: Gum behind a fake, line prompts and no terminal.

The fake executable records its arguments and environment and answers from
files, so these tests need neither a terminal nor Gum.
"""

import io
import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from core import prompt, ui
from core.errors import BootstrapError
from core.prompt import (
    GUM_THEME,
    Cancelled,
    GumPrompter,
    LinePrompter,
    Prompter,
)
from tests.unit.test_render import _shell_style

OPTIONS = [("node", "Node"), ("python", "Python"), ("ocaml", "OCaml, 5.5")]


class Fake:
    """An executable that records its call and answers from files."""

    def __init__(self, directory, name):
        self.directory = directory / name
        self.directory.mkdir()
        self.path = self.directory / name
        self.path.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            f"directory = {str(self.directory)!r}\n"
            "def path(name): return os.path.join(directory, name)\n"
            "with open(path('call.json'), 'w') as file:\n"
            "    json.dump({'argv': sys.argv[1:], 'env': dict(os.environ)},\n"
            "              file)\n"
            "if os.path.exists(path('output')):\n"
            "    sys.stdout.write(open(path('output')).read())\n"
            "sys.exit(int(open(path('status')).read()))\n"
        )
        self.path.chmod(0o700)
        self.answer("", 0)

    def answer(self, output, status=0):
        (self.directory / "output").write_text(output)
        (self.directory / "status").write_text(str(status))

    @property
    def call(self):
        return json.loads((self.directory / "call.json").read_text())


class PromptTestCase(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="bootstrap-prompt-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        environment = patch.dict(
            os.environ,
            {
                "HOME": str(self.home),
                # A person's own Gum theme must not win over the shared one.
                "GUM_CHOOSE_CURSOR_FOREGROUND": "212",
                "TERM": "xterm-256color",
            },
        )
        environment.start()
        self.addCleanup(environment.stop)
        self.output = io.StringIO()


class GumTests(PromptTestCase):
    def setUp(self):
        super().setUp()
        self.gum = Fake(self.root, "gum")
        self.prompter = GumPrompter(
            ui.Style(True, 80), gum=str(self.gum.path), stream=self.output
        )

    def test_confirm_reads_gum_statuses(self):
        for status, expected in ((0, True), (1, False)):
            with self.subTest(status=status):
                self.gum.answer("", status)
                self.assertIs(
                    self.prompter.confirm("Apply?", flag="--yes"), expected
                )
        call = self.gum.call
        self.assertEqual(
            call["argv"], ["confirm", "--default=false", "--", "Apply?"]
        )
        for name, value in GUM_THEME.items():
            self.assertEqual(call["env"][name], value, name)
        self.gum.answer("", 130)
        with self.assertRaises(Cancelled):
            self.prompter.confirm("Apply?", default=True, flag="--yes")
        self.assertIn("--default=true", self.gum.call["argv"])
        self.gum.answer("", 2)
        with self.assertRaisesRegex(BootstrapError, "gum confirm exited 2"):
            self.prompter.confirm("Apply?", flag="--yes")

    def test_choose_many_maps_labels_to_keys(self):
        self.gum.answer("ocaml\nnode\n")
        chosen = self.prompter.choose_many(
            "Ecosystems", OPTIONS, selected=["python", "ocaml"], flag="--only"
        )
        # The order of the options, whatever order Gum prints.
        self.assertEqual(chosen, ["node", "ocaml"])
        argv = self.gum.call["argv"]
        self.assertEqual(argv[0], "choose")
        self.assertIn("--no-limit", argv)
        self.assertIn("--header=Ecosystems", argv)
        # A comma would split --selected; labels lose theirs.
        self.assertIn("--selected=Python,OCaml  5.5", argv)
        self.assertEqual(
            argv[argv.index("--") + 1 :],
            ["Node\tnode", "Python\tpython", "OCaml  5.5\tocaml"],
        )

    def test_choose_many_accepts_none_and_cancels_on_escape(self):
        self.gum.answer("\n")
        self.assertEqual(
            self.prompter.choose_many("Pick", OPTIONS, flag="--only"), []
        )
        self.assertFalse(
            any(arg.startswith("--selected") for arg in self.gum.call["argv"])
        )
        for status in (1, 130):
            with self.subTest(status=status):
                self.gum.answer("", status)
                with self.assertRaises(Cancelled):
                    self.prompter.choose_many("Pick", OPTIONS, flag="--only")

    def test_choose_returns_one_key(self):
        self.gum.answer("python\n")
        self.assertEqual(
            self.prompter.choose(
                "Privilege", OPTIONS, default="python", flag="--yes"
            ),
            "python",
        )
        argv = self.gum.call["argv"]
        self.assertIn("--selected=Python", argv)
        self.assertNotIn("--no-limit", argv)

    def test_unexpected_answers_fail(self):
        self.gum.answer("rust\n")
        with self.assertRaisesRegex(BootstrapError, "unknown option"):
            self.prompter.choose("Pick", OPTIONS, flag="--only")
        with self.assertRaisesRegex(BootstrapError, "Two options"):
            self.prompter.choose(
                "Pick", [("a", "Same"), ("b", "Same")], flag="--only"
            )

    def test_ctrl_c_while_gum_asks_cancels(self):
        with (
            patch.object(
                prompt.process, "interact", side_effect=KeyboardInterrupt
            ),
            self.assertRaises(Cancelled),
        ):
            self.prompter.confirm("Apply?", flag="--yes")


class LineTests(PromptTestCase):
    def ask(self, method, answers, *arguments, **options):
        terminal = io.StringIO()
        prompter = LinePrompter(
            ui.Style(False), stream=self.output, terminal=terminal
        )
        with patch.object(sys, "stdin", io.StringIO(answers)):
            result = getattr(prompter, method)(*arguments, **options)
        return result, terminal.getvalue()

    def test_confirm(self):
        for answers, default, expected in (
            ("\n", False, False),
            ("\n", True, True),
            ("y\n", False, True),
            ("YES\n", False, True),
            ("n\n", True, False),
        ):
            with self.subTest(answers=answers, default=default):
                result, asked = self.ask(
                    "confirm", answers, "Apply?", default=default, flag="--yes"
                )
                self.assertIs(result, expected)
        self.assertIn("? Apply? [Y/n]", asked)

    def test_end_of_input_cancels(self):
        with self.assertRaises(Cancelled):
            self.ask("confirm", "", "Apply?", flag="--yes")
        with self.assertRaises(Cancelled):
            self.ask("choose_many", "", "Pick", OPTIONS, flag="--only")

    def test_choose_asks_again_until_an_option(self):
        result, asked = self.ask(
            "choose", "9\nx\n2\n", "Privilege", OPTIONS, flag="--yes"
        )
        self.assertEqual(result, "python")
        self.assertEqual(asked.count("? Choose"), 3)
        self.assertIn("  3) OCaml, 5.5\n", asked)
        result, asked = self.ask(
            "choose", "\n", "Privilege", OPTIONS, default="ocaml", flag="--yes"
        )
        self.assertEqual(result, "ocaml")
        self.assertIn("[1-3, Enter 3]", asked)

    def test_choose_many(self):
        marked = {"selected": ["ocaml", "node"], "flag": "--only"}
        for answers, expected in (
            ("\n", ["node", "ocaml"]),
            ("none\n", []),
            ("3 1\n", ["node", "ocaml"]),
            ("2,3\n", ["python", "ocaml"]),
            ("4\n0\n2\n", ["python"]),
        ):
            with self.subTest(answers=answers):
                result, asked = self.ask(
                    "choose_many", answers, "Ecosystems", OPTIONS, **marked
                )
                self.assertEqual(result, expected)
        self.assertIn("  1) [x] Node\n  2) [ ] Python\n", asked)


class UnattendedTests(PromptTestCase):
    def test_questions_name_the_flag_that_answers_them(self):
        prompter = Prompter(ui.Style(False), stream=self.output)
        for method, arguments in (
            ("confirm", ("Apply this plan?",)),
            ("choose", ("Privilege", OPTIONS)),
            ("choose_many", ("Ecosystems", OPTIONS)),
        ):
            with (
                self.subTest(method=method),
                self.assertRaisesRegex(
                    BootstrapError, "stdin is not a terminal; use --flag"
                ),
            ):
                getattr(prompter, method)(*arguments, flag="use --flag")

    def test_factory_picks_by_terminal(self):
        styled, plain = ui.Style(True), ui.Style(False)
        frontend = {"gum": "/gum"}
        chosen = prompt.prompter(frontend, styled, attended=False)
        self.assertIs(type(chosen), Prompter)
        self.assertIsInstance(
            prompt.prompter(frontend, styled, attended=True), GumPrompter
        )
        self.assertIsInstance(
            prompt.prompter(frontend, plain, attended=True), LinePrompter
        )
        self.assertIsInstance(
            prompt.prompter({}, styled, attended=True), LinePrompter
        )


class SharedThemeTests(unittest.TestCase):
    def test_gum_theme_matches_the_shell_style_module(self):
        shell = _shell_style()
        if shell is None:
            self.skipTest("the Zsh style module is not available here")
        body = re.search(r"_zsh_ui_gum\(\) \{\n(.*?)\n\}", shell, re.S)[1]
        self.assertEqual(dict(re.findall(r"(GUM_\w+)=(\S+)", body)), GUM_THEME)


if __name__ == "__main__":
    unittest.main()
