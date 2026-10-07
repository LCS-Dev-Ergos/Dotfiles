"""Malformed declarations fail before runtime paths or adapters are used."""

import copy
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch

from core.cli import main
from core.errors import BootstrapError
from core.manifest import load_manifest


BASELINE = {
    "schema": 1,
    "backend": "native",
    "platform": "aarch64-darwin",
    "defaults": {
        "node": "24.21.0",
        "python": "3.14.7",
        "ocaml": "5.5.1",
        "rust": "1.98.1",
    },
    "node": [{"version": "24.21.0", "hashes": {"aarch64-darwin": "a" * 64}}],
    "python": {"version": "3.14.7", "pythonBuildVersion": "2.8.8"},
    "ocaml": {
        "versions": ["5.5.1"],
        "repository": "https://github.com/ocaml/opam-repository.git",
        "revision": "a" * 40,
    },
    "nativeToolchains": {"rust": {"version": "1.98.1"}},
}


class ManifestTests(unittest.TestCase):
    def test_invalid_inputs_report_cli_errors_before_adapter_creation(self):
        missing = copy.deepcopy(BASELINE)
        del missing["backend"]
        native = copy.deepcopy(BASELINE)
        native["nativeToolchains"]["rust"]["version"] = "../../outside"
        node_default = copy.deepcopy(BASELINE)
        node_default["defaults"]["node"] = "99.0.0"
        native_default = copy.deepcopy(BASELINE)
        native_default["defaults"]["rust"] = "99.0.0"
        cases = (
            ("malformed JSON", "{", "Invalid baseline"),
            ("wrong shape", "[]", "Invalid baseline"),
            ("missing field", json.dumps(missing), "Invalid baseline"),
            ("native identity", json.dumps(native), "exact releases"),
            ("seed default", json.dumps(node_default), "Default node"),
            ("native default", json.dumps(native_default), "Default rust"),
        )
        with tempfile.TemporaryDirectory(prefix="bootstrap-manifest-") as root:
            path = Path(root) / "baseline.json"
            path.write_text(json.dumps(BASELINE))
            self.assertEqual(load_manifest(path), BASELINE)
            for label, payload, message in cases:
                with self.subTest(case=label):
                    path.write_text(payload)
                    with self.assertRaisesRegex(BootstrapError, message):
                        load_manifest(path)
                    stderr = io.StringIO()
                    with (
                        patch.object(
                            sys,
                            "argv",
                            ["dev-bootstrap", "--manifest", str(path)],
                        ),
                        patch("core.cli.Bootstrap") as engine,
                        patch("core.cli.os.umask"),
                        redirect_stderr(stderr),
                    ):
                        self.assertEqual(main(), 2)
                    engine.assert_not_called()
                    self.assertIn("dev-bootstrap:", stderr.getvalue())
                    self.assertIn(message, stderr.getvalue())
                    self.assertNotIn("Traceback", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
