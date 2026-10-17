"""brew-stats against a fake Homebrew."""

import contextlib
import io
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

import terminal_style as ui

from core.cli import main
from core.homebrew import human

TOOLS = os.pathsep.join(
    sorted(
        {
            os.path.dirname(found)
            for found in map(shutil.which, ("cat", "du", "sh", "cmp"))
            if found
        }
    )
)


class Brew:
    """A temporary Cellar, Caskroom and cache behind a fake ``brew``.

    The fake lists what ``formulae`` and ``casks`` hold; a file named
    ``fail-<argument>`` makes the call with that argument fail.
    """

    def __init__(self, testcase: unittest.TestCase) -> None:
        temporary = tempfile.TemporaryDirectory()
        testcase.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.cellar = self.root / "Cellar"
        self.caskroom = self.root / "Caskroom"
        self.cache = self.root / "cache"
        self.bin = self.root / "bin"
        for directory in (self.cellar, self.caskroom, self.cache, self.bin):
            directory.mkdir()
        self.formulae: list[str] = []
        self.casks: list[str] = []
        self.env = {"PATH": f"{self.bin}:{TOOLS}", "HOME": str(self.root)}
        self.script("brew", self._brew())

    def script(self, name: str, body: str) -> None:
        """An executable shell script in the fake's bin."""
        path = self.bin / name
        path.write_text(f"#!/bin/sh\nPATH={TOOLS}\n{body}\n")
        path.chmod(0o755)

    def _brew(self) -> str:
        """The fake brew."""
        root = self.root
        return "\n".join(
            [
                f'for a in "$@"; do [ -e "{root}/fail-$a" ] && exit 9; done',
                'case "$1" in',
                f'  --cellar) echo "{self.cellar}" ;;',
                f'  --caskroom) echo "{self.caskroom}" ;;',
                f'  --cache) cat "{root}/cache-path" 2>/dev/null '
                f'|| echo "{self.cache}" ;;',
                '  list) case "$2" in',
                f'    --formula) cat "{root}/formulae" ;;',
                f'    --cask) cat "{root}/casks" ;;',
                "  esac ;;",
                "esac",
            ]
        )

    def formula(self, name: str, kb: int) -> Path:
        """A formula with a file of about ``kb`` kilobytes."""
        directory = self.cellar / name / "1.0"
        directory.mkdir(parents=True)
        (directory / "data").write_bytes(os.urandom(kb * 1024))
        self.formulae.append(name)
        self.publish()
        return self.cellar / name

    def cask(self, name: str, kb: int, roots: dict[str, str] | None = None):
        """A cask with data and a safe config naming its install roots."""
        directory = self.caskroom / name
        (directory / "1.0").mkdir(parents=True)
        (directory / "1.0" / "data").write_bytes(os.urandom(kb * 1024))
        metadata = directory / ".metadata"
        metadata.mkdir()
        config = metadata / "config.json"
        config.write_text(json.dumps({"default": roots or {}}))
        config.chmod(0o600)
        self.casks.append(name)
        self.publish()
        return directory

    def publish(self) -> None:
        """Publish the listings."""
        (self.root / "formulae").write_text(
            "".join(f"{n}\n" for n in self.formulae)
        )
        (self.root / "casks").write_text("".join(f"{n}\n" for n in self.casks))

    def fail(self, argument: str) -> None:
        """Make every brew call with this argument fail."""
        (self.root / f"fail-{argument}").write_text("")

    def run(self, *argv: str) -> tuple[int, str, str]:
        """Run brew-stats: its status, standard output and error."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = main(list(argv), self.env, ui.Style(False))
            except SystemExit as exit:
                code = int(exit.code or 0)
        return code, out.getvalue(), err.getvalue()


class ReportTests(unittest.TestCase):
    """What the report lists."""

    def setUp(self) -> None:
        """Two formulae and a cask with an app outside the Caskroom."""
        self.brew = Brew(self)
        self.brew.formula("pkg-large", 400)
        self.brew.formula("pkg-small", 40)
        apps = self.brew.root / "Applications"
        app = apps / "Big.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents" / "data").write_bytes(os.urandom(800 * 1024))
        (app / "Contents" / "self").symlink_to(app)
        cask = self.brew.cask("big", 10, {"appdir": str(apps)})
        (cask / "1.0" / "Big.app").symlink_to(app)

    def names(self, out: str) -> list[str]:
        """The package column of a plain report."""
        lines = out.split("\n\n")[0].splitlines()[1:]
        return [line.split()[0] for line in lines]

    def test_size_order_and_summary(self) -> None:
        """Largest first, the cask with its app; counts, total and cache."""
        code, out, err = self.brew.run()
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(self.names(out), ["big", "pkg-large", "pkg-small"])
        self.assertIn("Formulae  2 · ", out)
        self.assertIn("Total     3 packages · ", out)
        self.assertRegex(out, rf"Cache     [0-9.]+ KB · {self.brew.cache}")

    def test_scope_sort_and_top(self) -> None:
        """--formula, --cask, --sort name and --top select the rows."""
        self.assertEqual(
            self.names(self.brew.run("--formula")[1]),
            ["pkg-large", "pkg-small"],
        )
        self.assertEqual(self.names(self.brew.run("--cask")[1]), ["big"])
        out = self.brew.run("--sort", "name")[1]
        self.assertEqual(self.names(out), ["big", "pkg-large", "pkg-small"])
        self.assertEqual(self.names(self.brew.run("--top", "1")[1]), ["big"])

    def test_quiet_prints_only_the_table(self) -> None:
        """--quiet has no summary."""
        _, out, _ = self.brew.run("-q")
        self.assertNotIn("Homebrew disk usage", out)
        self.assertTrue(out.startswith("PACKAGE"))

    def test_usage_errors(self) -> None:
        """Conflicting or invalid options exit 2."""
        for argv in (("-f", "-c"), ("--top", "0"), ("--sort", "x")):
            with self.subTest(argv=argv):
                self.assertEqual(self.brew.run(*argv)[0], 2)

    def test_human_sizes(self) -> None:
        """Kilobytes become the largest unit under 1024."""
        self.assertEqual(human(0), "0.0 KB")
        self.assertEqual(human(1536), "1.5 MB")
        self.assertEqual(human(3 * 1024**3), "3.0 TB")


class FailureTests(unittest.TestCase):
    """What stops the report, and what only leaves an artifact out."""

    def setUp(self) -> None:
        """One formula and one cask."""
        self.brew = Brew(self)
        self.brew.formula("pkg", 10)
        self.cask = self.brew.cask("app", 10, {"appdir": "/Applications"})

    def failure(self, expected: str, *argv: str) -> None:
        """The run fails with status 1 and a diagnostic naming ``expected``."""
        code, _, err = self.brew.run(*argv)
        self.assertEqual(code, 1, err)
        self.assertIn(expected, err)

    def test_listing_and_directory_failures(self) -> None:
        """An unreadable listing or a missing directory fails."""
        self.brew.fail("--formula")
        self.failure("formula inventory", "-f", "-q")
        (self.brew.root / "fail---formula").unlink()
        self.brew.formulae.append("ghost")
        self.brew.publish()
        self.failure("directory is missing: ghost", "-f", "-q")

    def test_an_entry_escaping_its_root_fails(self) -> None:
        """A Cellar entry that links outside the Cellar is refused."""
        outside = self.brew.root / "outside"
        outside.mkdir()
        (self.brew.cellar / "escaped").symlink_to(outside)
        self.brew.formulae.append("escaped")
        self.brew.publish()
        self.failure("escapes the Cellar", "-f", "-q")

    def test_unsafe_artifacts_are_left_out_and_named(self) -> None:
        """Broken links, foreign targets and unsafe records are reported."""
        (self.cask / "1.0" / "Broken.app").symlink_to(self.brew.root / "none")
        foreign = self.brew.root / "foreign"
        foreign.mkdir()
        (self.cask / "1.0" / "Foreign.app").symlink_to(foreign)
        code, out, err = self.brew.run("-c")
        self.assertEqual(code, 1)
        self.assertIn("app", out)
        self.assertIn("Broken.app: broken link", err)
        self.assertIn("Foreign.app: outside the recorded install roots", err)
        record = self.cask / ".metadata" / "config.json"
        record.write_text(json.dumps({"default": {"appdir": str(foreign)}}))
        record.chmod(0o666)
        self.assertIn("Foreign.app: outside", self.brew.run("-c")[2])
        record.chmod(0o600)
        self.assertNotIn("Foreign.app", self.brew.run("-c")[2])

    def test_a_changing_inventory_fails(self) -> None:
        """A listing that differs after measuring fails the report."""
        listing = self.brew.root / "formulae"
        churn = self.brew.root / "churn"
        self.brew.script(
            "du",
            f'[ -e "{churn}" ] || '
            f'{{ echo extra >> "{listing}"; : > "{churn}"; }}'
            '\nexec du "$@"',
        )
        self.brew.env["PATH"] = f"{self.brew.bin}:{TOOLS}"
        self.failure("inventory changed", "-f", "-q")

    def test_cache_failures(self) -> None:
        """A cache that cannot be resolved or is not a directory fails."""
        self.brew.fail("--cache")
        self.failure("Homebrew cache", "-f")
        (self.brew.root / "fail---cache").unlink()
        path = self.brew.root / "cache-path"
        for target, expected in (
            ("relative", "Invalid Homebrew cache path"),
            (str(self.brew.root / "formulae"), "not a directory"),
        ):
            path.write_text(f"{target}\n")
            self.failure(expected, "-f")
        broken = self.brew.root / "broken-cache"
        broken.symlink_to(self.brew.root / "missing")
        path.write_text(f"{broken}\n")
        self.failure("broken symlink", "-f")

    def test_an_unsafe_cache_path_is_sanitized(self) -> None:
        """Control characters in the cache path never reach the terminal."""
        unsafe = self.brew.root / "cache-\033[2J"
        unsafe.mkdir()
        (self.brew.root / "cache-path").write_text(f"{unsafe}\n")
        code, out, err = self.brew.run("-f")
        self.assertEqual(code, 1, err)
        self.assertIn("Invalid Homebrew cache path", err)
        self.assertNotIn("\033", out)


if __name__ == "__main__":
    unittest.main()
