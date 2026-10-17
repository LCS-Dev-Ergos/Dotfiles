"""Planning: what a run changes, what it leaves alone, and what it refuses."""

import unittest
from unittest import mock

from core import plan as planning
from core.errors import SettingsError
from core.jsonc import ArrayNode, StringNode, parse
from core.manifest import IGNORED_KEY, LEAVES, QUERY_DRIVER_ARGUMENT
from core.plan import (
    BLOCK_BEGIN,
    BLOCK_END,
    ChangeAction,
    FindingKind,
    Plan,
)
from core.text import Edit
from tests.support import CRLF_SETTINGS, Machine, make_executable


def subjects(plan: Plan, kind: FindingKind) -> list[str]:
    """The subjects of a plan's findings of one kind."""
    return [finding.subject for finding in plan.of_kind(kind)]


def block_of(text: str) -> str:
    """The body of the generated block in ``text``."""
    return text.split(BLOCK_BEGIN)[1].split(BLOCK_END)[0]


class InPlaceTests(unittest.TestCase):
    """Updates to keys that already exist in the file."""

    def setUp(self) -> None:
        """Give the machine a clangd and a clang."""
        self.m = Machine(self)
        self.clangd = self.m.tool("clangd")
        self.clang = self.m.tool("clang")

    def test_replaces_in_place_and_keeps_everything_else(self) -> None:
        """Only the managed literals change; comments and newlines stay."""
        text = self.m.plan(CRLF_SETTINGS).new_text
        documented = f'"clangd.path": "{self.clangd}", // stays documented\r\n'
        self.assertIn(documented, text)
        self.assertIn("// Let clangd ask the drivers.\r\n", text)
        self.assertIn("/* trailing */", text)
        self.assertEqual(text.count("\r\n"), text.count("\n"))
        self.assertIn(QUERY_DRIVER_ARGUMENT, text)
        unmanaged = '"CC": "/etc/profiles/per-user/olduser/bin/clang"'
        self.assertIn(unmanaged, text)

    def test_changes_are_reported_in_manifest_order(self) -> None:
        """Changes come in manifest order: leaves, nested, then the list."""
        changes = self.m.plan(CRLF_SETTINGS).changes
        self.assertEqual(
            [(c.subject, c.action) for c in changes],
            [
                ("clangd.path", ChangeAction.UPDATE),
                ("hostLocal.clangdQueryDriver", ChangeAction.ADD),
                ("java.sharedIndexes.location", ChangeAction.ADD),
                ("clangd.arguments[1]", ChangeAction.UPDATE),
                (IGNORED_KEY, ChangeAction.ADD),
            ],
        )

    def test_unmanaged_host_bound_values_are_reported(self) -> None:
        """A home path outside the manifest is reported, not edited."""
        plan = self.m.plan(CRLF_SETTINGS)
        self.assertEqual(
            subjects(plan, FindingKind.UNMANAGED), ["cmake.environment.CC"]
        )

    def test_second_run_changes_nothing(self) -> None:
        """Planning over a planned result changes nothing."""
        first = self.m.plan(CRLF_SETTINGS)
        second = self.m.plan(first.new_text)
        self.assertFalse(second.changed)
        self.assertEqual(second.changes, ())

    def test_unresolved_value_is_left_alone(self) -> None:
        """A key whose target is missing keeps its value."""
        plan = self.m.plan('{\n  "cmake.cmakePath": "/old/cmake",\n}\n')
        self.assertIn('"cmake.cmakePath": "/old/cmake"', plan.new_text)
        unresolved = subjects(plan, FindingKind.UNRESOLVED)
        self.assertIn("cmake.cmakePath", unresolved)

    def test_unicode_value_is_written_as_is(self) -> None:
        """A non-ASCII path is written as text, not as escapes."""
        tool = self.m.tool("cmake", "zoë/bin")
        self.m.set_env(PATH=str(tool.parent))
        plan = self.m.plan('{\n  "cmake.cmakePath": "/old",\n}\n')
        self.assertIn(f'"cmake.cmakePath": "{tool}"', plan.new_text)


class BlockTests(unittest.TestCase):
    """The generated block that holds keys missing from the file."""

    def setUp(self) -> None:
        """Give the machine a clangd and a clang."""
        self.m = Machine(self)
        self.clangd = self.m.tool("clangd")
        self.m.tool("clang")

    def test_absent_leaf_goes_into_the_generated_block(self) -> None:
        """A missing key goes into one block at the end of the file."""
        text = self.m.plan(CRLF_SETTINGS).new_text
        self.assertEqual(text.count(BLOCK_BEGIN), 1)
        block = block_of(text)
        self.assertIn('"hostLocal.clangdQueryDriver"', block)
        self.assertNotIn('"clangd.path"', block)
        self.assertTrue(text.rstrip().endswith("}"))

    def test_stale_block_entry_is_removed_when_it_stops_resolving(
        self,
    ) -> None:
        """A block entry whose target disappeared is dropped."""
        first = self.m.plan("{\n}\n")
        self.assertIn('"clangd.path"', block_of(first.new_text))
        self.clangd.unlink()
        second = self.m.plan(first.new_text)
        self.assertTrue(second.changed)
        self.assertNotIn('"clangd.path"', block_of(second.new_text))
        found = second.of_kind(FindingKind.UNRESOLVED)
        stale = [f for f in found if f.subject == "clangd.path"]
        self.assertIn("removed from the generated block", stale[0].detail)

    def test_block_disappears_when_it_holds_nothing(self) -> None:
        """A block left without entries is removed with its markers."""
        only_clangd = tuple(
            leaf for leaf in LEAVES if leaf.key == "clangd.path"
        )
        with mock.patch.object(planning, "LEAVES", only_clangd):
            first = self.m.plan('{\n  "a": 1,\n}\n')
            self.assertIn('"clangd.path"', block_of(first.new_text))
            self.clangd.unlink()
            second = self.m.plan(first.new_text)
        self.assertNotIn(BLOCK_BEGIN, second.new_text)
        self.assertEqual(second.new_text.count('"a": 1,'), 1)
        parse(second.new_text)

    def test_block_value_is_refreshed_in_place(self) -> None:
        """A block entry is updated without duplicating the block."""
        first = self.m.plan("{\n}\n")
        newer = self.m.tool("clangd", "elsewhere")
        self.clangd.unlink()
        self.m.set_env(PATH=str(newer.parent))
        second = self.m.plan(first.new_text)
        self.assertIn(f'"clangd.path": "{newer}"', second.new_text)
        self.assertEqual(second.new_text.count(BLOCK_BEGIN), 1)

    def test_missing_trailing_comma_is_added(self) -> None:
        """The member before new text gets the comma it needs."""
        plan = self.m.plan('{\n  "a": 1\n}\n')
        parse(plan.new_text)
        self.assertIn('"a": 1,', plan.new_text)

    def test_empty_object_on_one_line(self) -> None:
        """An empty object on one line is opened up for the block."""
        plan = self.m.plan("{}")
        parse(plan.new_text)
        self.assertIn(str(self.clangd), plan.new_text)

    def test_closing_brace_sharing_a_line_is_refused(self) -> None:
        """No text is appended next to a setting on the brace's line."""
        with self.assertRaisesRegex(SettingsError, "closing brace"):
            self.m.plan('{"a": 1}')

    def test_damaged_block_markers_are_refused(self) -> None:
        """Missing, repeated or reversed markers stop the run."""
        for text in (
            f"{{\n  {BLOCK_BEGIN}\n}}\n",
            f"{{\n  {BLOCK_END}\n  {BLOCK_BEGIN}\n}}\n",
            f"{{\n  {BLOCK_BEGIN}\n  {BLOCK_END}\n  {BLOCK_END}\n}}\n",
        ):
            with self.subTest(text=text):
                with self.assertRaisesRegex(SettingsError, "damaged"):
                    self.m.plan(text)

    def test_block_splitting_a_setting_is_refused(self) -> None:
        """Markers inside a setting stop the run."""
        text = f'{{\n  "a": [\n  {BLOCK_BEGIN}\n  ],\n  {BLOCK_END}\n}}\n'
        with self.assertRaisesRegex(SettingsError, "split"):
            self.m.plan(text)

    def test_unknown_key_inside_the_block_is_refused(self) -> None:
        """A key the tool does not own is never dropped from the block."""
        text = f'{{\n  {BLOCK_BEGIN}\n  "mine": 1,\n  {BLOCK_END}\n}}\n'
        with self.assertRaisesRegex(SettingsError, "not managed"):
            self.m.plan(text)

    def test_marker_after_a_setting_on_its_line_is_not_a_marker(self) -> None:
        """Only a comment on a line of its own counts as a marker."""
        text = f'{{\n  "a": 1, {BLOCK_BEGIN}\n}}\n'
        self.assertEqual(self.m.plan(text).new_text.count(BLOCK_BEGIN), 2)


class IgnoreListTests(unittest.TestCase):
    """The Settings Sync exclusion list."""

    def setUp(self) -> None:
        """Give the machine a clangd."""
        self.m = Machine(self)
        self.m.tool("clangd")

    def test_every_managed_key_is_listed_once(self) -> None:
        """Every managed key is appended once after the existing entries."""
        plan = self.m.plan(CRLF_SETTINGS)
        member = parse(plan.new_text).root.named(IGNORED_KEY)[0]
        assert isinstance(member.value, ArrayNode)
        values = [
            item.value
            for item in member.value.items
            if isinstance(item, StringNode)
        ]
        self.assertEqual(
            values[:3],
            [
                "editor.fontFamily",
                "-sonarlint.pathToNodeExecutable",
                "clangd.path",
            ],
        )
        for leaf in LEAVES:
            self.assertEqual(values.count(leaf.key), 1)

    def test_new_list_goes_before_an_existing_block(self) -> None:
        """A new list is inserted before the block, never inside it."""
        text = (
            f'{{\n  "a": 1,\n  {BLOCK_BEGIN}\n'
            f'  "clangd.path": "/old",\n  {BLOCK_END}\n}}\n'
        )
        planned = self.m.plan(text).new_text
        parse(planned)
        self.assertLess(planned.index(IGNORED_KEY), planned.index(BLOCK_BEGIN))
        self.assertNotIn(IGNORED_KEY, block_of(planned))
        self.assertEqual(planned.count(BLOCK_BEGIN), 1)

    def test_entry_with_minus_keeps_the_key_synced(self) -> None:
        """A '-key' entry is respected and reported."""
        text = '{\n  "settingsSync.ignoredSettings": ["-clangd.path"],\n}\n'
        plan = self.m.plan(text)
        self.assertIn("clangd.path", subjects(plan, FindingKind.NOTICE))
        listed = plan.new_text.split("ignoredSettings")[1].split("]")[0]
        self.assertNotIn('"clangd.path",', listed)

    def test_single_line_list_stays_single_line(self) -> None:
        """A one-line list grows on its line."""
        text = '{\n  "settingsSync.ignoredSettings": ["a"],\n}\n'
        line = next(
            line
            for line in self.m.plan(text).new_text.splitlines()
            if "ignoredSettings" in line
        )
        expected = '  "settingsSync.ignoredSettings": ["a", "clangd.path"'
        self.assertTrue(line.startswith(expected))

    def test_empty_list(self) -> None:
        """An empty list is filled in place."""
        text = '{\n  "settingsSync.ignoredSettings": [],\n}\n'
        plan = self.m.plan(text)
        parse(plan.new_text)
        self.assertIn('["clangd.path"', plan.new_text)

    def test_list_of_the_wrong_type_is_refused(self) -> None:
        """A list that is not all strings stops the run."""
        for value in ('"x"', '["a", 1]'):
            text = f'{{\n  "settingsSync.ignoredSettings": {value},\n}}\n'
            with self.subTest(value=value), self.assertRaises(SettingsError):
                self.m.plan(text)

    def test_duplicated_list_is_refused(self) -> None:
        """A list that appears twice stops the run."""
        text = (
            '{\n  "settingsSync.ignoredSettings": [],\n'
            '  "settingsSync.ignoredSettings": [],\n}\n'
        )
        with self.assertRaisesRegex(SettingsError, "appears 2 times"):
            self.m.plan(text)


class RefusalTests(unittest.TestCase):
    """Files the planner refuses, and bugs the verification catches."""

    def setUp(self) -> None:
        """Give the machine a clangd."""
        self.m = Machine(self)
        self.m.tool("clangd")

    def test_duplicate_managed_key_is_refused(self) -> None:
        """A managed key that appears twice stops the run."""
        text = '{\n  "clangd.path": "a",\n  "clangd.path": "b",\n}\n'
        with self.assertRaisesRegex(SettingsError, "refusing to guess"):
            self.m.plan(text)

    def test_non_string_managed_value_is_refused(self) -> None:
        """A managed key that is not a string stops the run."""
        with self.assertRaisesRegex(SettingsError, "not a string"):
            self.m.plan('{\n  "clangd.path": null,\n}\n')

    def test_verification_catches_an_editing_bug(self) -> None:
        """An edit outside the plan fails the verification."""
        real = planning.apply_edits

        def sabotage(source: str, edits: list[Edit]) -> str:
            """Apply the edits, then change an unmanaged value."""
            return real(source, edits).replace('"last": true', '"last": false')

        with mock.patch.object(planning, "apply_edits", sabotage):
            with self.assertRaisesRegex(SettingsError, "unintended change"):
                self.m.plan(CRLF_SETTINGS)

    def test_verification_catches_a_lost_setting(self) -> None:
        """A setting lost by an edit fails the verification."""
        real = planning.apply_edits

        def sabotage(source: str, edits: list[Edit]) -> str:
            """Apply the edits, then drop an unmanaged setting."""
            return real(source, edits).replace('  "last": true,\r\n', "")

        with mock.patch.object(planning, "apply_edits", sabotage):
            with self.assertRaisesRegex(SettingsError, "unexpected keys"):
                self.m.plan(CRLF_SETTINGS)


class NestedTests(unittest.TestCase):
    """Strings inside containers that must already exist."""

    def setUp(self) -> None:
        """Give the machine an SDKMAN JDK 21."""
        self.m = Machine(self)
        self.base = self.m.home / ".sdkman" / "candidates" / "java"
        make_executable(self.base / "21.0.9-tem" / "bin" / "java")

    def test_absent_target_is_not_created(self) -> None:
        """A missing container is reported and not created."""
        plan = self.m.plan("{\n}\n")
        self.assertIn(
            "clangd.arguments", " ".join(subjects(plan, FindingKind.ABSENT))
        )
        self.assertNotIn('"clangd.arguments"', plan.new_text)

    def test_java_runtime_is_resolved_by_major(self) -> None:
        """Only the runtime of the matching major release is updated."""
        text = (
            '{\n  "java.configuration.runtimes": [\n'
            '    {"name": "JavaSE-17", "path": "/keep/17"},\n'
            '    {"name": "JavaSE-21", "path": "/Users/old/21"},\n'
            "  ],\n}\n"
        )
        plan = self.m.plan(text)
        self.assertIn('"path": "/keep/17"', plan.new_text)
        expected = self.base / "21.0.9-tem"
        self.assertIn(f'"path": "{expected}"', plan.new_text)
        changed = [c.subject for c in plan.changes]
        self.assertIn("java.configuration.runtimes[1].path", changed)

    def test_ambiguous_or_mistyped_targets_are_left_alone(self) -> None:
        """Two matches or a non-string target are left as they are."""
        text = (
            '{\n  "java.configuration.runtimes": [\n'
            '    {"name": "JavaSE-21", "path": "/a"},\n'
            '    {"name": "JavaSE-21", "path": "/b"},\n'
            '    {"name": "JavaSE-25", "path": 25},\n'
            "  ],\n}\n"
        )
        plan = self.m.plan(text)
        notices = [
            f"{f.subject}: {f.detail}"
            for f in plan.of_kind(FindingKind.NOTICE)
        ]
        self.assertIn(
            "java.configuration.runtimes.JavaSE-21.path: 2 matches, "
            "left alone",
            notices,
        )
        self.assertIn(
            "java.configuration.runtimes.JavaSE-25.path: not a string, "
            "left alone",
            notices,
        )
        self.assertIn('"path": "/a"', plan.new_text)


if __name__ == "__main__":
    unittest.main()
