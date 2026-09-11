"""Bounded Now Playing snapshot; only artwork is cached, outside the Nix store."""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

APPS = {"com.tidal.desktop": "TIDAL", "com.spotify.client": "Spotify", "com.apple.Music": "Music"}


def snapshot(binary):
    result = subprocess.run(
        [binary, "get", "--json", "title", "artist", "album", "playbackRate", "clientBundleIdentifier", "artworkData"],
        capture_output=True, text=True, timeout=4, check=True,
    )
    data = json.loads(result.stdout)
    app = APPS.get(data.get("clientBundleIdentifier"))
    if not app or not data.get("title"):
        return {"state": "stopped"}
    info = {"app": app, "state": "playing" if (data.get("playbackRate") or 0) > 0 else "paused",
            "title": data["title"], "artist": data.get("artist") or "", "artwork": ""}
    artwork = data.get("artworkData")
    if artwork:
        try:
            raw = base64.b64decode(artwork, validate=True)
            if not raw or len(raw) > 8 * 1024 * 1024:
                return info
            cache = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "sketchybar/media"
            cache.mkdir(parents=True, exist_ok=True, mode=0o700)
            target = cache / ("artwork-" + hashlib.sha256(raw).hexdigest() + ".png")
            if not target.exists():
                with tempfile.NamedTemporaryFile(dir=cache, delete=False) as f:
                    temp = Path(f.name)
                    f.write(raw)
                try:
                    subprocess.run(
                        ["/usr/bin/sips", "-s", "format", "png", "-Z", "32", str(temp), "--out", str(temp)],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3, check=True,
                    )
                    os.replace(temp, target)
                finally:
                    temp.unlink(missing_ok=True)
                # Retain the preceding cover until the bar consumes this snapshot.
                others = sorted((p for p in cache.glob("artwork-*.png") if p != target),
                                key=lambda p: p.stat().st_mtime, reverse=True)
                for old in others[1:]:
                    old.unlink(missing_ok=True)
            info["artwork"] = str(target)
        except (ValueError, OSError, subprocess.SubprocessError):
            pass  # Text and controls remain usable without artwork.
    return info


def main():
    try:
        print(json.dumps(snapshot(sys.argv[1]), ensure_ascii=False))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print("media snapshot: " + str(exc), file=sys.stderr)
        print(json.dumps({"state": "unavailable"}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
