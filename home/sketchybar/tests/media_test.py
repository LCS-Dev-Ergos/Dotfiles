import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('media', Path(__file__).parents[1] / 'sketchybar/helpers/media.py')
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)


class MediaTests(unittest.TestCase):
    def fetch(self, payload):
        with patch.object(media.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(payload))):
            return media.snapshot('/fixture/nowplaying')

    def test_missing_and_unsupported_players(self):
        self.assertEqual(self.fetch({}), {'state': 'stopped'})
        self.assertEqual(self.fetch({'clientBundleIdentifier': 'com.apple.Safari', 'title': 'Video'}), {'state': 'stopped'})

    def test_artwork_cache_is_bounded_and_handles_missing_art(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {'XDG_CACHE_HOME': tmp}):
            payload = {'clientBundleIdentifier': 'com.tidal.desktop', 'title': 'Track', 'playbackRate': 1}
            self.assertEqual(self.fetch(payload)['artwork'], '')
            for value in [b'first', b'second', b'third']:
                payload['artworkData'] = base64.b64encode(value).decode()
                result = self.fetch(payload)
                self.assertEqual(Path(result['artwork']).read_bytes(), value)
                self.assertEqual(result['state'], 'playing')
            self.assertEqual(len(list(Path(tmp).rglob('artwork-*.png'))), 2)
            payload.update(playbackRate=0, artworkData='invalid')
            self.assertEqual(self.fetch(payload)['state'], 'paused')


if __name__ == '__main__':
    unittest.main()
