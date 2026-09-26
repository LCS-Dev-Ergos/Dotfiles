"""Regression tests for ``media.py``, the media widget's snapshot helper.

``nowplaying-cli`` is replaced by canned JSON payloads, so the tests cover
player filtering, playback state and the bounded artwork cache without
touching MediaRemote.
"""

import base64
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

MEDIA_PATH = Path(__file__).parents[1] / "sketchybar/helpers/media.py"
spec = importlib.util.spec_from_file_location("media", MEDIA_PATH)
assert spec and spec.loader, f"cannot load {MEDIA_PATH}"
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)


class MediaTests(unittest.TestCase):
    """Snapshot parsing and artwork caching of ``media.py``."""

    def fetch(self, payload):
        """Return the snapshot ``media.py`` builds from a nowplaying-cli payload."""
        completed = subprocess.CompletedProcess([], 0, json.dumps(payload))
        with patch.object(media.subprocess, "run", return_value=completed):
            return media.snapshot("/fixture/nowplaying")

    def test_missing_and_unsupported_players(self):
        """An empty payload or a browser player reads as stopped."""
        self.assertEqual(self.fetch({}), {"state": "stopped"})
        browser = {"clientBundleIdentifier": "com.apple.Safari", "title": "Video"}
        self.assertEqual(self.fetch(browser), {"state": "stopped"})

    def test_artwork_cache_is_bounded_and_handles_missing_art(self):
        """The cache keeps two covers, and missing or invalid art is tolerated."""
        with (
            tempfile.TemporaryDirectory() as tmp,
            patch.dict(os.environ, {"XDG_CACHE_HOME": tmp}),
        ):
            payload = {
                "clientBundleIdentifier": "com.tidal.desktop",
                "title": "Track",
                "playbackRate": 1,
            }
            self.assertEqual(self.fetch(payload)["artwork"], "")
            for value in [b"first", b"second", b"third"]:
                payload["artworkData"] = base64.b64encode(value).decode()
                result = self.fetch(payload)
                self.assertEqual(Path(result["artwork"]).read_bytes(), value)
                self.assertEqual(result["state"], "playing")
            self.assertEqual(len(list(Path(tmp).rglob("artwork-*.png"))), 2)
            payload.update(playbackRate=0, artworkData="invalid")
            self.assertEqual(self.fetch(payload)["state"], "paused")


if __name__ == "__main__":
    unittest.main()
