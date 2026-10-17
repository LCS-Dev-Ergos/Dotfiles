"""``dev-doctor --deep``: reading dev-bootstrap's health report."""

import json
import unittest

from core.deep import deep, read
from tests.support import Machine

REPORT = {
    "schema": 1,
    "catalog": [
        {
            "language": "haskell",
            "title": "Haskell",
            "componentTitles": {"ghc": "GHC", "cabal": "Cabal"},
            "primaryComponent": "ghc",
        },
        {"language": "python", "title": "Python"},
    ],
    "runtimes": [
        {"language": "haskell", "state": "ok", "actualVersion": "9.14.1"},
        {
            "language": "haskell",
            "component": "cabal",
            "state": "ok",
            "version": "3.16",
        },
        {
            "language": "python",
            "state": "conflict",
            "version": "3.14.8",
            "reason": "ssl does not load.",
            "remediation": "pyenv install --force 3.14.8",
        },
    ],
}


class ReadTests(unittest.TestCase):
    """The report's rows."""

    def test_rows_titles_and_ranks(self) -> None:
        """Components are named; a conflict is broken."""
        rows = read(json.dumps(REPORT))
        self.assertEqual(
            [row.title for row in rows],
            ["Haskell (GHC)", "Haskell (Cabal)", "Python"],
        )
        self.assertEqual(rows[0].version, "9.14.1")
        self.assertEqual(rows[2].rank, 2)
        self.assertIn("Rebuild: pyenv install", rows[2].detail)

    def test_anything_else_is_refused(self) -> None:
        """Another schema, or no runtimes, is not read."""
        for report in ('{"schema": 2, "runtimes": []}', '{"schema": 1}', "[]"):
            with self.assertRaises(ValueError):
                read(report)


class RunTests(unittest.TestCase):
    """Running dev-bootstrap."""

    def setUp(self) -> None:
        """An empty machine."""
        self.machine = Machine(self)

    def test_without_dev_bootstrap(self) -> None:
        """A missing bootstrap is inconclusive."""
        found = deep(self.machine.host)
        self.assertEqual((found.rank, found.rows), (1, ()))

    def test_a_report_and_a_failure(self) -> None:
        """Exit 1 still carries a report; exit 2 is broken."""
        self.machine.tool(
            "dev-bootstrap", f"echo '{json.dumps(REPORT)}'; exit 1"
        )
        found = deep(self.machine.host)
        self.assertEqual((len(found.rows), found.rank), (3, 2))
        self.machine.tool("dev-bootstrap", "exit 2")
        self.assertEqual(deep(self.machine.host).level, 2)
        self.machine.tool("dev-bootstrap", "echo nonsense")
        self.assertIn("schema", deep(self.machine.host).error)

    def test_the_command_line_shows_it(self) -> None:
        """--deep adds a section and its share of the status."""
        self.machine.tool("dev-bootstrap", f"echo '{json.dumps(REPORT)}'")
        code, out, err = self.machine.doctor("--deep", "--json")
        self.assertEqual(code, 2)
        self.assertEqual(len(json.loads(out)["deep"]["runtimes"]), 3)
        self.assertIn("dev-bootstrap verify --health", err)
        _, out, _ = self.machine.doctor("--deep")
        self.assertIn("Deep health · 3", out)


if __name__ == "__main__":
    unittest.main()
