#!/usr/bin/env python3
"""Opt-in regression against a live bar; temporary items are always removed.

Run with SKETCHYBAR_LIVE_TESTS=1 bash tests/run.sh from the SketchyBar module.
LUA and SKETCHYBAR may select the managed executables. No daemon is restarted.
"""

import json
import os
from pathlib import Path
import pwd
import subprocess
import time
import uuid


ROOT = Path(__file__).resolve().parent.parent


def labels():
    code = """
package.path = arg[1] .. '/?.lua;' .. package.path
package.preload['helpers.runtime'] = function() return {} end
local helper = require('helpers.statwell')
for _, value in ipairs({0, 1, 1023, 1024, 1048575, 1048576, 1073741824, 1e30}) do
  print(helper.rate(value))
end
print(helper.rate_unknown)
"""
    result = subprocess.run(
        [os.environ.get("LUA", "lua"), "-", str(ROOT / "sketchybar")],
        input=code, capture_output=True, text=True, check=True, timeout=5,
    )
    return result.stdout.splitlines()


def bar(*arguments):
    result = subprocess.run(
        [os.environ.get("SKETCHYBAR", "sketchybar"), *arguments],
        env={**os.environ, "USER": os.environ.get("USER") or pwd.getpwuid(os.getuid()).pw_name},
        capture_output=True, text=True, timeout=5,
    )
    if result.returncode != 0:
        raise AssertionError(result.stderr or result.stdout)
    return result.stdout


def query(name, label):
    # The CLI can return no reply while the live bar is busy. Wait for the
    # requested label so an asynchronous redraw cannot produce a false verdict.
    deadline = time.monotonic() + 5
    last = None
    while time.monotonic() < deadline:
        response = bar("--query", name)
        if response:
            last = json.loads(response)
            if last["label"]["value"] == label and last["label"]["width"] == 72:
                return last
        time.sleep(0.05)
    raise AssertionError(f"renderer did not apply {name}={label!r}; last reply: {last}")


def main():
    values = labels()
    assert values and all(len(value) == 12 for value in values)
    prefix = "statwell_geometry_" + uuid.uuid4().hex
    upload, download = prefix + "_up", prefix + "_down"
    created = []
    try:
        for name, width, offset in [(upload, "0", "4"), (download, "92", "-4")]:
            bar("--add", "item", name, "right")
            created.append(name)
            bar("--set", name, "width=" + width, "y_offset=" + offset,
                "scroll_texts=off", "icon.drawing=off", "background.drawing=off",
                "label.font=SF Mono:Bold:9.0", "label.width=72", "label.align=right",
                "label.color=0x00000000", "label=" + values[0])
        expected = None
        for index, value in enumerate(values):
            bar("--set", upload, "label=" + value,
                "--set", download, "label=" + values[-index - 1])
            up = query(upload, value)
            down = query(download, values[-index - 1])
            assert up["label"]["width"] == down["label"]["width"] == 72
            assert down["geometry"]["width"] == 92
            bounds = {
                name: {display: rect["size"] for display, rect in item["bounding_rects"].items()}
                for name, item in [(upload, up), (download, down)]
            }
            assert all(bounds.values()), "live renderer did not expose display bounds"
            if expected is None:
                expected = bounds
            assert bounds == expected, (value, bounds, expected)
        print(f"Live network geometry: fixed bounds for {len(values)} rates/placeholders: PASS")
    finally:
        errors = []
        for name in reversed(created):
            try:
                bar("--remove", name)
            except (AssertionError, subprocess.TimeoutExpired) as error:
                errors.append(f"{name}: {error}")
        if errors:
            raise RuntimeError("temporary item cleanup failed: " + "; ".join(errors))


if __name__ == "__main__":
    main()
