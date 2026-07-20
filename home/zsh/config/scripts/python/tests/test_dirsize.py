"""Tests for dirsize presentation policy and Gum table serialization."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from _support import MODULE_ROOT  # noqa: F401
import dirsize


class UiModeTests(unittest.TestCase):
    """Verify shared style resolution without requiring a terminal."""

    def test_no_color_forces_plain_output(self) -> None:
        with mock.patch.dict(
            os.environ, {"ZSH_UI_STYLE": "gum", "NO_COLOR": "1"}, clear=False
        ):
            self.assertEqual(dirsize.resolve_ui_mode(), "plain")

    def test_invalid_style_is_rejected(self) -> None:
        with mock.patch.dict(os.environ, {"ZSH_UI_STYLE": "sparkles"}, clear=False):
            os.environ.pop("NO_COLOR", None)
            with self.assertRaises(ValueError):
                dirsize.resolve_ui_mode()

    @mock.patch("dirsize.sys.stdout.isatty", return_value=True)
    def test_missing_term_defaults_to_plain_output(self, _isatty: mock.Mock) -> None:
        with mock.patch.dict(os.environ, {"ZSH_UI_STYLE": "auto"}, clear=False):
            os.environ.pop("NO_COLOR", None)
            os.environ.pop("TERM", None)
            self.assertEqual(dirsize.resolve_ui_mode(), "plain")


class InputValidationTests(unittest.TestCase):
    """Reject values that could stall pagination or worker creation."""

    def test_positive_int_accepts_positive_values(self) -> None:
        self.assertEqual(dirsize.positive_int("7"), 7)

    def test_positive_int_rejects_zero_and_negative_values(self) -> None:
        for value in ("0", "-1"):
            with self.subTest(value=value):
                with self.assertRaises(dirsize.argparse.ArgumentTypeError):
                    dirsize.positive_int(value)

    def test_worker_count_is_bounded(self) -> None:
        self.assertEqual(dirsize.worker_count("32"), 32)
        with self.assertRaises(dirsize.argparse.ArgumentTypeError):
            dirsize.worker_count("33")

    def test_display_text_escapes_terminal_controls(self) -> None:
        self.assertEqual(
            dirsize.sanitize_display_text("name\x1b[2J\nnext\titem"),
            r"name\x1b[2J\nnext\titem",
        )


class SizeCollectionTests(unittest.TestCase):
    """Verify platform-specific size parsing for hostile filenames."""

    @mock.patch.object(dirsize.sys, "platform", "darwin")
    @mock.patch("dirsize.subprocess.run")
    def test_macos_newline_filename_keeps_its_record_boundary(
        self, run: mock.Mock
    ) -> None:
        path = "/private/tmp/line\nbreak"
        run.return_value = mock.Mock(
            stdout=b"4\t/private/tmp/line\nbreak\n", stderr=b""
        )
        dirsize._interrupted = False

        sizes, errors = dirsize.process_single_batch([path])

        self.assertEqual(sizes, {path: 4})
        self.assertEqual(errors, [])
        self.assertEqual(run.call_args.args[0], ["du", "-sk", path])

    def test_directory_symlinks_are_included_and_annotated(self) -> None:
        with tempfile.TemporaryDirectory(dir=MODULE_ROOT / "tests") as root:
            root_path = Path(root)
            target = root_path / "target"
            target.mkdir()
            linked = root_path / "linked"
            linked.symlink_to(target, target_is_directory=True)
            broken = root_path / "broken"
            broken.symlink_to(root_path / "missing", target_is_directory=True)

            paths, types, warnings = dirsize.scan_directory(root_path)
            all_paths, all_types, all_warnings = dirsize.scan_directory(
                root_path, include_files=True
            )

            self.assertIn(str(linked), paths)
            self.assertEqual(types[str(linked)], "dir@")
            self.assertNotIn(str(broken), paths)
            self.assertIn(str(broken), all_paths)
            self.assertEqual(all_types[str(broken)], "link!")
            self.assertEqual(warnings, [])
            self.assertTrue(any("Broken symlink" in item for item in all_warnings))


class GumRenderingTests(unittest.TestCase):
    """Verify one Gum process receives valid CSV, including special names."""

    @mock.patch("dirsize.subprocess.run")
    def test_serializes_rows_for_one_static_table(self, run: mock.Mock) -> None:
        run.return_value.returncode = 0
        items = [
            {"size_str": "1.0K", "type": "file", "name": "a,b.txt"},
            {"size_str": "2.0K", "type": "dir", "name": "docs"},
        ]

        self.assertTrue(dirsize.render_with_gum(items))
        run.assert_called_once()
        args, kwargs = run.call_args
        self.assertEqual(args[0][:3], ["gum", "table", "--print"])
        self.assertIn('"a,b.txt"', kwargs["input"])
        self.assertTrue(kwargs["check"])
        self.assertNotIn("shell", kwargs)
        self.assertEqual(kwargs["timeout"], 30)

    @mock.patch("dirsize.input", return_value="y")
    @mock.patch("dirsize.subprocess.run", side_effect=FileNotFoundError)
    def test_confirmation_falls_back_when_gum_disappears(
        self, _run: mock.Mock, native_input: mock.Mock
    ) -> None:
        self.assertTrue(dirsize.confirm_next_page("Continue?", "gum"))
        native_input.assert_called_once()


if __name__ == "__main__":
    unittest.main()
