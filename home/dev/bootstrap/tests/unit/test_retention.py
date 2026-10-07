"""GC-root lifecycle contract without touching the host Nix store or opam."""

import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from core import process
from core.adapters.ocaml import OcamlAdapter
from core.errors import BootstrapError


class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name).resolve()
        self.source = Path("/nix/store/fixture-opam-repository")
        self.root = self.state / "opam-sources" / self.source.name
        self.context = SimpleNamespace(
            state=self.state,
            backend="native",
            data={
                "ocaml": {
                    "source": str(self.source),
                    "retainCommand": "nix-store",
                },
            },
        )
        with patch.dict(os.environ, {"OPAMROOT": str(self.state / "opam")}):
            self.adapter = OcamlAdapter(self.context)

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

        with patch.object(process, "run", side_effect=register) as run:
            with patch.object(Path, "is_file", return_value=True):
                for phase in ("initial", "rerun"):
                    with self.subTest(phase=phase):
                        self.adapter.before_apply()
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
                        process,
                        "run",
                        side_effect=failure
                        if kind == "command-failure"
                        else None,
                    ) as run,
                ):
                    with self.assertRaises(BootstrapError):
                        self.adapter.before_apply()
                    if kind in ("file", "redirect"):
                        run.assert_not_called()
                if kind == "file":
                    self.assertEqual(self.root.read_text(), "owned state")
                if kind == "redirect":
                    self.assertEqual(
                        self.root.resolve(), self.state / "another-source"
                    )
                self.root.unlink(missing_ok=True)

    def test_undeclared_retention_does_not_create_roots(self):
        for backend, declaration in (
            ("nixpkgs", self.context.data["ocaml"]),
            ("native", {"source": str(self.source)}),
        ):
            with self.subTest(backend=backend, declaration=declaration):
                self.context.backend = backend
                self.context.data["ocaml"] = declaration
                with patch.object(process, "run") as run:
                    self.adapter.before_apply()
                    run.assert_not_called()
                self.assertFalse(self.root.parent.exists())


if __name__ == "__main__":
    unittest.main()
