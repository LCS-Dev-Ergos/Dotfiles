"""GC-root lifecycle contract without touching the host Nix store or opam."""

import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import retention
from retention import retain_opam_source
from support import BootstrapError


class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name).resolve()
        self.source = Path("/nix/store/fixture-opam-repository")
        self.root = self.state / "opam-sources" / self.source.name
        self.recovery = SimpleNamespace(
            state=self.state,
            only=["ocaml"],
            data={
                "backend": "native",
                "ocaml": {
                    "source": str(self.source),
                    "retainCommand": "nix-store",
                },
            },
        )

    def test_initial_and_existing_root_are_registered(self):
        def register(arguments, **kwargs):
            self.assertEqual(
                arguments,
                [
                    "nix-store",
                    "--realise",
                    str(self.source),
                    "--add-root",
                    str(self.root),
                    "--indirect",
                ],
            )
            self.assertEqual(kwargs["cwd"], str(self.state))
            if not self.root.is_symlink():
                self.root.symlink_to(self.source)

        with patch.object(retention, "run", side_effect=register) as run:
            with patch.object(Path, "is_file", return_value=True):
                for phase in ("initial", "rerun"):
                    with self.subTest(phase=phase):
                        retain_opam_source(self.recovery)
                        self.assertEqual(self.root.resolve(), self.source)
            self.assertEqual(run.call_count, 2)

    def test_conflicts_and_failed_registration_do_not_replace_state(self):
        for kind in ("file", "redirect", "missing-result", "command-failure"):
            with self.subTest(kind=kind):
                self.root.parent.mkdir(exist_ok=True)
                if kind == "file":
                    self.root.write_text("owned state")
                elif kind == "redirect":
                    self.root.symlink_to(self.state / "another-source")
                failure = BootstrapError("Nix unavailable")
                with (
                    patch.object(Path, "is_file", return_value=True),
                    patch.object(
                        retention,
                        "run",
                        side_effect=failure
                        if kind == "command-failure"
                        else None,
                    ) as run,
                ):
                    with self.assertRaises(BootstrapError):
                        retain_opam_source(self.recovery)
                    if kind in ("file", "redirect"):
                        run.assert_not_called()
                if kind == "file":
                    self.assertEqual(self.root.read_text(), "owned state")
                if kind == "redirect":
                    self.assertEqual(
                        self.root.resolve(), self.state / "another-source"
                    )
                self.root.unlink(missing_ok=True)

    def test_unselected_ecosystems_do_not_create_roots(self):
        for backend, languages in (
            ("native", ["node"]),
            ("nixpkgs", ["ocaml"]),
        ):
            with self.subTest(backend=backend, languages=languages):
                self.recovery.data["backend"] = backend
                self.recovery.only = languages
                with patch.object(retention, "run") as run:
                    retain_opam_source(self.recovery)
                    run.assert_not_called()
                self.assertFalse(self.root.parent.exists())


if __name__ == "__main__":
    unittest.main()
