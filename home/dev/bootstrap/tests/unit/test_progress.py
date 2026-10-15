"""Live progress lines: what a person sees on stderr while a run works."""

import io
import unittest
from unittest.mock import patch

from core import ui
from core.adapters import ADAPTERS
from core.progress import Progress

CATALOG = [
    {
        "language": name,
        "title": ADAPTERS[name].title,
        "componentTitles": ADAPTERS[name].component_titles,
    }
    for name in ("python", "haskell", "node")
]
RUN = "/home/user/.local/state/dev-bootstrap/runs/20261012T110325Z"


def events():
    return [
        {"event": "run-start", "directory": RUN},
        {"event": "stage-start", "stage": "prerequisites"},
        {"event": "packages-start", "packages": ["opam", "sqlite"]},
        {"event": "packages-finish", "outcome": "ok", "duration": 12.4},
        {
            "event": "stage-finish",
            "stage": "prerequisites",
            "outcome": "ok",
            "duration": 13.0,
        },
        {"event": "stage-start", "stage": "runtimes"},
        {
            "event": "ecosystem-start",
            "language": "node",
            "runtimes": [{"version": "24.21.0"}, {"version": "26.11.1"}],
        },
        {
            "event": "ecosystem-finish",
            "language": "node",
            "outcome": "ok",
            "duration": 2.8,
        },
        {
            "event": "ecosystem-start",
            "language": "haskell",
            "runtimes": [{"version": "2.14.0.0", "component": "hls"}],
        },
        {
            "event": "ecosystem-finish",
            "language": "haskell",
            "outcome": "ok",
            "duration": 75.0,
        },
        {
            "event": "ecosystem-start",
            "language": "python",
            "runtimes": [{"version": "3.14.8"}],
        },
        {
            "event": "ecosystem-finish",
            "language": "python",
            "outcome": "failed",
            "duration": 66.1,
        },
        {
            "event": "stage-finish",
            "stage": "runtimes",
            "outcome": "failed",
            "duration": 150.0,
        },
        {
            "event": "run-finish",
            "outcome": "failed",
            "exit": 2,
            "duration": 163.0,
        },
    ]


def shown(style):
    stream = io.StringIO()
    progress = Progress(CATALOG, style, stream)
    with patch.dict("os.environ", {"HOME": "/home/user"}):
        for record in events():
            progress(record)
    return stream.getvalue()


class ProgressTests(unittest.TestCase):
    def test_plain_lines_start_and_end_each_step(self):
        self.assertEqual(
            shown(ui.Style(False)).splitlines(),
            [
                f"logs {RUN}",
                "Prerequisites",
                "  Native packages opam sqlite …",
                "  Native packages opam sqlite: ok after 12 s",
                "Runtimes",
                "  Node 24.21.0, 26.11.1 …",
                "  Node 24.21.0, 26.11.1: ok after 3 s",
                "  Haskell HLS 2.14.0.0 …",
                "  Haskell HLS 2.14.0.0: ok after 1 min 15 s",
                "  Python 3.14.8 …",
                "  Python 3.14.8: failed after 1 min 6 s",
                "Runtimes: failed after 2 min 30 s",
            ],
        )

    def test_a_terminal_ends_each_step_on_its_own_line(self):
        lines = ui.strip(shown(ui.Style(True, 80))).splitlines()
        self.assertEqual(
            lines[0],
            "  logs ~/.local/state/dev-bootstrap/runs/20261012T110325Z",
        )
        self.assertIn("    Node 24.21.0, 26.11.1 … ● ok · 3 s", lines)
        self.assertIn("    Python 3.14.8 … ✖ failed · 1 min 6 s", lines)
        self.assertEqual(len(lines), 8)

    def test_a_narrow_terminal_shortens_the_log_path(self):
        lines = ui.strip(shown(ui.Style(True, 40))).splitlines()
        self.assertLessEqual(ui.text_width(lines[0]), 40)
        self.assertTrue(lines[0].startswith("  logs ~/"))
        self.assertTrue(lines[0].endswith("/20261012T110325Z"))

    def test_an_interruption_closes_the_open_line(self):
        stream = io.StringIO()
        progress = Progress(CATALOG, ui.Style(True, 80), stream)
        progress({"event": "stage-start", "stage": "runtimes"})
        progress(
            {
                "event": "ecosystem-start",
                "language": "node",
                "runtimes": [{"version": "26.11.1"}],
            }
        )
        progress({"event": "stage-start", "stage": "defaults"})
        self.assertEqual(
            ui.strip(stream.getvalue()).splitlines()[1:],
            ["    Node 26.11.1 … ", "  Defaults"],
        )


if __name__ == "__main__":
    unittest.main()
