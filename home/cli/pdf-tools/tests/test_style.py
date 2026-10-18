"""Source conventions: docstrings, section banners, and no other comments.

Intent belongs in docstrings. The only comments allowed are section banners
(the title on the left, dashes up to exactly column 80), the entry point's
shebang and ``noqa`` markers.
"""

import ast
import io
import re
import tokenize
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WIDTH = 80
BANNER = re.compile(r"(?P<indent> *)# [A-Z][^-]*[^ -] -+")
NOQA = re.compile(r"# noqa: [A-Z]+\d+(, [A-Z]+\d+)*")


def sources() -> list[Path]:
    """Every Python file of the tool and its tests."""
    files = [ROOT / "pdf_tools.py"]
    files += sorted((ROOT / "core").glob("*.py"))
    files += sorted((ROOT / "tests").glob("*.py"))
    return files


class StyleTests(unittest.TestCase):
    """The conventions every source file follows."""

    def test_sources_are_found(self) -> None:
        """The scan covers the package, the entry point and the tests."""
        names = {path.name for path in sources()}
        self.assertTrue({"cli.py", "watermarks.py", "test_style.py"} <= names)

    def test_comments_are_banners_or_markers(self) -> None:
        """Every comment is a full-width banner, the shebang or a noqa."""
        for path in sources():
            text = path.read_text(encoding="utf-8")
            lines = text.splitlines()
            tokens = tokenize.generate_tokens(io.StringIO(text).readline)
            for token in tokens:
                if token.type != tokenize.COMMENT:
                    continue
                row, column = token.start
                where = f"{path.name}:{row}"
                if row == 1 and token.string.startswith("#!"):
                    continue
                if NOQA.fullmatch(token.string):
                    continue
                with self.subTest(where=where):
                    self.assertEqual(
                        column,
                        len(lines[row - 1]) - len(lines[row - 1].lstrip()),
                        f"{where}: trailing comment {token.string!r}",
                    )
                    self.assertRegex(lines[row - 1], BANNER)
                    self.assertEqual(len(lines[row - 1]), WIDTH, where)

    def test_lines_fit_the_width(self) -> None:
        """No line is wider than 80 columns."""
        for path in sources():
            for row, line in enumerate(path.read_text().splitlines(), 1):
                with self.subTest(where=f"{path.name}:{row}"):
                    self.assertLessEqual(len(line), WIDTH)

    def test_modules_classes_and_functions_have_docstrings(self) -> None:
        """Every module, class and function says what it is for."""
        for path in sources():
            tree = ast.parse(path.read_text(encoding="utf-8"))
            with self.subTest(where=path.name):
                self.assertIsNotNone(ast.get_docstring(tree))
            for node in ast.walk(tree):
                if not isinstance(
                    node, ast.ClassDef | ast.FunctionDef | ast.AsyncFunctionDef
                ):
                    continue
                if node.name.startswith("__") and node.name.endswith("__"):
                    continue
                with self.subTest(where=f"{path.name}:{node.lineno}"):
                    self.assertIsNotNone(ast.get_docstring(node), node.name)


if __name__ == "__main__":
    unittest.main()
