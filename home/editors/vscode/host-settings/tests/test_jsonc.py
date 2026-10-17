"""The JSONC reader, structural comparison and the text helpers."""

import unittest

from core.errors import SettingsError
from core.jsonc import (
    ArrayNode,
    ObjectNode,
    ScalarNode,
    StringNode,
    describe_path,
    diff_paths,
    parse,
)
from core.text import Edit, Layout, apply_edits, json_string


class ParserTests(unittest.TestCase):
    """The strict JSONC reader."""

    def test_accepts_comments_and_trailing_commas(self) -> None:
        """Comments and trailing commas are part of the accepted syntax."""
        doc = parse('{ // a\n "a": [1, 2,], /* b */ "b": {"c": null,}, }')
        self.assertEqual([m.key for m in doc.root.members], ["a", "b"])

    def test_node_kinds_and_spans(self) -> None:
        """Each value gets its node type and its exact span in the source."""
        text = '{"s": "x", "n": 1.5, "a": [true], "o": {}}'
        values = [m.value for m in parse(text).root.members]
        kinds = [type(value) for value in values]
        self.assertEqual(
            kinds, [StringNode, ScalarNode, ArrayNode, ObjectNode]
        )
        self.assertEqual(text[values[0].start : values[0].end], '"x"')
        scalar = values[1]
        assert isinstance(scalar, ScalarNode)
        self.assertEqual(scalar.value, 1.5)

    def test_rejects_damaged_input(self) -> None:
        """Anything not fully understood is an error, never a guess."""
        damaged = (
            "",
            "[]",
            '{"a": 1',
            '{"a" 1}',
            '{"a": "x',
            '{"a": 1} x',
            "{,}",
            '{"a": 1,, "b": 2}',
            '{"a": /* open}',
            '{"a": "bad\\q"}',
            '{"a": NaN}',
            '{"a": -Infinity}',
            '{"a": "tab\there"}',
            '{"a": tru}',
        )
        for text in damaged:
            with self.subTest(text=text), self.assertRaises(SettingsError):
                parse(text)

    def test_error_reports_line_and_column(self) -> None:
        """An error names the line and column where reading stopped."""
        with self.assertRaisesRegex(SettingsError, r"\(2:6\)"):
            parse('{\n "a" 1\n}')

    def test_nesting_is_bounded(self) -> None:
        """Deep nesting is refused before it exhausts the recursion."""
        with self.assertRaises(SettingsError):
            parse('{"a":' + "[" * 200 + "]" * 200 + "}")

    def test_unicode_and_escapes_decode(self) -> None:
        """Strings decode escapes and keep non-ASCII text."""
        member = parse('{"a": "caf\\u00e9 \\"q\\" ✓"}').root.members[0]
        assert isinstance(member.value, StringNode)
        self.assertEqual(member.value.value, 'café "q" ✓')

    def test_only_line_comments_are_recorded(self) -> None:
        """Line comments are recorded; block comments are only skipped."""
        text = '{\n  // line\n  /* block */\n  "a": 1, // tail\n}'
        doc = parse(text)
        spans = [text[start:end] for start, end in doc.comments]
        self.assertEqual(spans, ["// line", "// tail"])


class DiffTests(unittest.TestCase):
    """Structural comparison of two values."""

    def diff(self, before: str, after: str) -> set[tuple[str | int, ...]]:
        """The paths at which two documents' roots differ."""
        return diff_paths(parse(before).root, parse(after).root)

    def test_layout_and_comments_are_not_differences(self) -> None:
        """Whitespace, comments and trailing commas do not count."""
        before = '{"a": [1, 2], "b": {"c": "x"}}'
        after = '{\n  // note\n  "a": [1, 2,],\n  "b": {"c": "x",},\n}'
        self.assertEqual(self.diff(before, after), set())

    def test_value_change_is_reported_where_it_is(self) -> None:
        """A changed value is reported at its own path."""
        before = '{"a": {"b": ["x", "y"]}}'
        after = '{"a": {"b": ["x", "z"]}}'
        self.assertEqual(self.diff(before, after), {("a", "b", 1)})

    def test_shape_changes_are_reported_at_the_container(self) -> None:
        """Reordered keys, resized arrays and new types are reported above."""
        self.assertEqual(
            self.diff('{"a": 1, "b": 2}', '{"b": 2, "a": 1}'), {()}
        )
        self.assertEqual(self.diff('{"a": [1]}', '{"a": [1, 2]}'), {("a",)})
        self.assertEqual(self.diff('{"a": [1]}', '{"a": "1"}'), {("a",)})

    def test_scalars_differ_by_type(self) -> None:
        """1, 1.0, true and "1" all differ; 1e2 and 100.0 do not."""
        for after in ('{"a": 1.0}', '{"a": true}', '{"a": "1"}'):
            with self.subTest(after=after):
                self.assertEqual(self.diff('{"a": 1}', after), {("a",)})
        self.assertEqual(self.diff('{"a": 1e2}', '{"a": 100.0}'), set())

    def test_describe_path(self) -> None:
        """Paths are spelled the way the Settings editor spells them."""
        path = ("java.configuration.runtimes", 1, "path")
        expected = "java.configuration.runtimes[1].path"
        self.assertEqual(describe_path(path), expected)
        self.assertEqual(describe_path(()), "")


class TextTests(unittest.TestCase):
    """Edits, JSON string literals and layout detection."""

    def test_overlapping_edits_are_refused(self) -> None:
        """Overlapping edits are a planning bug and are refused."""
        with self.assertRaises(SettingsError):
            apply_edits("abcdef", [Edit(0, 3, "x"), Edit(2, 4, "y")])

    def test_insertion_after_a_replacement_at_its_end(self) -> None:
        """An insertion at a replacement's end lands after it."""
        edits = [Edit(1, 3, "XY"), Edit(3, 3, ",")]
        self.assertEqual(apply_edits("abcd", edits), "aXY,d")

    def test_insertions_at_one_offset_keep_their_order(self) -> None:
        """Insertions at one offset keep the order they were given in."""
        edits = [Edit(1, 1, "1"), Edit(1, 1, "2")]
        self.assertEqual(apply_edits("ab", edits), "a12b")

    def test_json_string_keeps_unicode_and_escapes_quotes(self) -> None:
        """Literals keep non-ASCII text and escape quotes and backslashes."""
        self.assertEqual(json_string("/home/zoë/bin"), '"/home/zoë/bin"')
        self.assertEqual(json_string('a"b\\c'), '"a\\"b\\\\c"')

    def test_layout_detection(self) -> None:
        """The newline follows the majority and the indent the first key."""
        crlf = Layout.detect(parse('{\r\n\t"a": 1,\r\n}\n'))
        self.assertEqual(crlf, Layout("\r\n", "\t"))
        inline = Layout.detect(parse('{"a": 1}'))
        self.assertEqual(inline, Layout("\n", "  "))


if __name__ == "__main__":
    unittest.main()
