"""Selection metadata: requirements, defaults, platforms and consents."""

import copy
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from core.adapters import ADAPTERS
from core.adapters.base import PLATFORMS
from core.engine import Bootstrap
from core.errors import BootstrapError
from core.manifest import validate_manifest
from core.setup import BootstrapSetup
from tests.declaration import declared_manifest


class SelectionTests(unittest.TestCase):
    def setUp(self):
        # Evaluating the declaration needs nix on the caller's PATH.
        self.data = copy.deepcopy(declared_manifest())
        self.data.update(backend="native", platform="aarch64-darwin")
        temporary = tempfile.TemporaryDirectory(prefix="bootstrap-selection-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        environment = patch.dict(
            os.environ,
            {
                "HOME": str(root / "home"),
                "XDG_CACHE_HOME": str(root / "cache"),
                "XDG_STATE_HOME": str(root / "state"),
                "PATH": "/usr/bin:/bin",
            },
            clear=True,
        )
        environment.start()
        self.addCleanup(environment.stop)

    def patched(self, language, **attributes):
        for name, value in attributes.items():
            mock = patch.object(ADAPTERS[language], name, value)
            mock.start()
            self.addCleanup(mock.stop)

    def test_registry_lists_requirements_before_their_dependents(self):
        order = list(ADAPTERS)
        for language, adapter in ADAPTERS.items():
            for required in adapter.requires:
                with self.subTest(language=language, required=required):
                    self.assertLess(
                        order.index(required), order.index(language)
                    )
                    required_adapter = ADAPTERS[required]
                    # An implicit selection must stay closed under requires.
                    self.assertTrue(
                        required_adapter.default_selected
                        or not adapter.default_selected
                    )
                    self.assertTrue(
                        set(adapter.platforms)
                        <= set(required_adapter.platforms)
                    )
            self.assertTrue(set(adapter.platforms) <= set(PLATFORMS))

    def test_explicit_selection_needs_its_requirements(self):
        for language in ("kotlin", "maven", "gradle"):
            with (
                self.subTest(language=language),
                self.assertRaisesRegex(
                    BootstrapError, "requires jvm; select --only jvm as well"
                ),
            ):
                Bootstrap(self.data, [language])
        context = Bootstrap(self.data, ["gradle", "jvm", "kotlin", "gradle"])
        self.assertEqual(context.only, ["jvm", "kotlin", "gradle"])

    def test_implicit_selection_skips_optional_and_unavailable_adapters(self):
        everything = Bootstrap(self.data, None).only
        self.assertEqual(everything, list(ADAPTERS))
        self.patched("julia", default_selected=False)
        self.patched("ruby", platforms=("x86_64-linux",))
        context = Bootstrap(self.data, None)
        self.assertNotIn("julia", context.only)
        self.assertNotIn("ruby", context.only)
        catalog = {row["language"]: row for row in context.catalog()}
        self.assertEqual(set(catalog), set(ADAPTERS))
        self.assertEqual(
            catalog["julia"],
            {
                "language": "julia",
                "manager": "juliaup",
                "requires": [],
                "defaultSelected": False,
                "platforms": list(PLATFORMS),
                "consents": [],
                "available": True,
                "selected": False,
            },
        )
        self.assertFalse(catalog["ruby"]["available"])
        self.assertEqual(catalog["kotlin"]["requires"], ["jvm"])
        # Explicit selection reaches an optional adapter, never a missing one.
        self.assertEqual(Bootstrap(self.data, ["julia"]).only, ["julia"])
        with self.assertRaisesRegex(BootstrapError, "unavailable on aarch64"):
            Bootstrap(self.data, ["ruby"])

    def test_apply_requires_every_selected_consent_before_any_work(self):
        self.patched("julia", consents=("julia-terms",))
        context = Bootstrap(self.data, ["julia"])
        with (
            patch.object(context, "locked") as locked,
            self.assertRaisesRegex(BootstrapError, "--accept julia-terms"),
        ):
            context.apply([])
        locked.assert_not_called()
        context.data["setup"] = {}
        setup = BootstrapSetup(context)
        with (
            patch.object(context, "plan") as plan,
            self.assertRaisesRegex(BootstrapError, "--accept julia-terms"),
        ):
            setup.apply()
        plan.assert_not_called()
        accepted = Bootstrap(self.data, ["julia"], accepted=["julia-terms"])
        accepted.require_consents()
        # Unselected adapters' terms are not asked for.
        Bootstrap(self.data, ["rust"]).require_consents()

    def test_declared_dependents_need_their_requirements_declared(self):
        validate_manifest(self.data)
        broken = copy.deepcopy(self.data)
        del broken["nativeToolchains"]["jvm"]
        with self.assertRaisesRegex(BootstrapError, "requires jvm"):
            validate_manifest(broken)


if __name__ == "__main__":
    unittest.main()
