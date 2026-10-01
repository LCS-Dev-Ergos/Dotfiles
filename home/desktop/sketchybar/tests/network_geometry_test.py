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


def layout():
    code = """
package.path = arg[1] .. '/?.lua;' .. package.path
package.preload['helpers.runtime'] = function() return {} end
local fixture = dofile(arg[1] .. '/../tests/fixtures/sbar.lua')()
sbar = fixture.api
require('items.widgets.wifi')
require('items.widgets.cpu')
require('items.widgets.homebrew')
require('items.widgets.volume')
fixture.items['widgets.volume1'].handlers['mouse.entered']({})
fixture.commands[#fixture.commands - 1][2]('LSX II\\n', 0)
fixture.commands[#fixture.commands][2]('MacBook Pro Speakers\\n', 0)
local helper = require('helpers.statwell')
for _, value in ipairs({0, 1, 1023, 1024, 1048575, 1048576, 1073741824, 1e30}) do
  print('rate\\t' .. helper.rate(value))
end
print('rate\\t' .. helper.rate_unknown)
local settings = require('settings')
local function emit(group, props, prefix)
  prefix = prefix or ''
  for key, value in pairs(props) do
    if key ~= 'background' and key ~= 'color' and key ~= 'position' and key ~= 'click_script' then
      local name = prefix .. key
      if key == 'font' then
        value = (value.family or settings.font.text) .. ':' .. (value.style or 'Semibold') .. ':' .. (value.size or 13)
      elseif type(value) == 'table' then
        emit(group, value, name .. '.')
        value = nil
      end
      if value ~= nil then
        if key == 'string' then name = prefix:sub(1, -2) end
        if type(value) == 'boolean' then value = value and 'on' or 'off' end
        print(group .. '\\t' .. name .. '=' .. tostring(value))
      end
    end
  end
end
emit('up', fixture.items['widgets.wifi1'].props)
emit('down', fixture.items['widgets.wifi2'].props)
emit('cpu', fixture.items['widgets.cpu'].props)
emit('details', fixture.items['widgets.brew.details'].props)
emit('checked', fixture.items['widgets.brew.checked'].props)
emit('audio', fixture.items['volume.device.row.1'].props)
for _, name in ipairs({'ssid', 'hostname', 'ip', 'mask', 'router'}) do
  emit(name, fixture.items['widgets.wifi.' .. name].props)
end
for _, item in ipairs(fixture.items) do
  if item.slider_width then
    emit('slider', item.props)
    print('track\\t' .. item.slider_width)
  end
end
print('graph\\t' .. fixture.items['widgets.cpu'].graph_width)
"""
    result = subprocess.run(
        [os.environ.get("LUA", "lua"), "-", str(ROOT / "sketchybar")],
        input=code, capture_output=True, text=True, check=True, timeout=5,
    )
    groups = {}
    for line in result.stdout.splitlines():
        group, value = line.split("\t", 1)
        groups.setdefault(group, []).append(value)
    return groups


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
            if last["label"]["value"] == label and last["bounding_rects"]:
                return last
        time.sleep(0.05)
    raise AssertionError(f"renderer did not apply {name}={label!r}; last reply: {last}")


def main():
    config = layout()
    values = config["rate"]
    assert values and all(len(value) <= 12 and value == value.lstrip() for value in values)
    prefix = "statwell_geometry_" + uuid.uuid4().hex
    upload, download, cpu, measure = (prefix + suffix for suffix in ["_up", "_down", "_cpu", "_measure"])
    created = []
    try:
        for name, group in [(upload, "up"), (download, "down")]:
            bar("--add", "item", name, "right")
            created.append(name)
            bar("--set", name, *config[group], "background.drawing=off",
                "icon.color=0x00000000", "label.color=0x00000000", "label=" + values[0])
        expected = None
        for index, value in enumerate(values):
            bar("--set", upload, "label=" + value,
                "--set", download, "label=" + values[-index - 1])
            up = query(upload, value)
            down = query(download, values[-index - 1])
            assert up["label"]["width"] == down["label"]["width"]
            bounds = {
                name: {display: rect["size"] for display, rect in item["bounding_rects"].items()}
                for name, item in [(upload, up), (download, down)]
            }
            assert all(bounds.values()), "live renderer did not expose display bounds"
            if expected is None:
                expected = bounds
            assert bounds == expected, (value, bounds, expected)
        # Measure natural text width using the renderer's actual font, rather
        # than assuming a character count proves the last unit fits in its cell.
        bar("--add", "item", measure, "right")
        created.append(measure)
        bar("--set", measure, "width=dynamic", "icon.drawing=off",
            "background.drawing=off", "label.width=0", "label.padding_left=0",
            "label.padding_right=0", "label.color=0x00000000")

        def measured_width(text, font):
            bar("--set", measure, "label.font=" + font, "label=" + text)
            item = query(measure, text)
            return max(rect["size"][0] for rect in item["bounding_rects"].values())

        for value in values:
            assert measured_width(value, down["label"]["font"]) <= down["label"]["width"], value
        for item in [up, down]:
            assert measured_width(item["icon"]["value"], item["icon"]["font"]) <= (
                item["icon"]["width"] + item["icon"]["padding_right"]
            ), "the direction arrow must not overlap the rate"

        graph_width = int(config["graph"][0])
        bar("--add", "graph", cpu, "right", str(graph_width))
        created.append(cpu)
        bar("--set", cpu, *config["cpu"], "background.drawing=off",
            "graph.color=0x00000000", "graph.fill_color=0x00000000",
            "icon.color=0x00000000", "label.color=0x00000000")
        cpu_bounds = None
        for value in ["0%", "25%", "100%", "?%"]:
            bar("--set", cpu, "label=" + value)
            item = query(cpu, value)
            assert measured_width(value, item["label"]["font"]) <= graph_width, value
            bounds = {display: rect["size"] for display, rect in item["bounding_rects"].items()}
            if cpu_bounds is None:
                cpu_bounds = bounds
            assert bounds == cpu_bounds, (value, bounds, cpu_bounds)
        # Both popup rows must accommodate their longest normal/error message.
        for group, messages in [
            ("details", ["Checking for updates…", "Connection unavailable", "999 updates available"]),
            ("checked", ["Last checked at 23:59:59", "Homebrew will retry automatically"]),
        ]:
            props = dict(argument.split("=", 1) for argument in config[group])
            available = int(props["width"]) - int(props["label.padding_left"]) - int(props["label.padding_right"])
            for message in messages:
                assert measured_width(message, props["label.font"]) <= available, message
        # Exercise complete popup rows in actual popup windows, including the
        # slider. Main-bar text width alone did not catch the old overflow.
        previous = None
        for menu, groups in [("brew", ["details", "checked"]),
                             ("wifi", ["ssid", "hostname", "ip", "mask", "router"]),
                             ("volume", ["slider", "audio"])]:
            host = prefix + "_" + menu
            bar("--add", "item", host, "right", "--set", host,
                "icon.drawing=off", "label.drawing=off", "width=1",
                "popup.height=30", "popup.background.border_width=2")
            created.append(host)
            rows = []
            for group in groups:
                name = host + "_" + group
                if group == "slider":
                    bar("--add", "slider", name, "popup." + host, config["track"][0])
                else:
                    bar("--add", "item", name, "popup." + host)
                created.append(name)
                bar("--set", name, *config[group], "background.drawing=off")
                rows.append((group, name))
            if previous:
                bar("--set", previous, "popup.drawing=off")
            bar("--set", host, "popup.drawing=on")
            previous = host
            bounds = []
            for group, name in rows:
                props = dict(argument.split("=", 1) for argument in config[group])
                item = query(name, props.get("label", ""))
                rect = next(iter(item["bounding_rects"].values()))
                bounds.append(rect)
                assert 256 <= rect["size"][0] <= 258, (menu, group, rect)
                assert rect["size"][1] == 30, (menu, group, rect)
                assert item["geometry"]["padding_left"] == item["geometry"]["padding_right"] == 12
                if group == "slider":
                    assert int(item["slider"]["width"]) == 232
                    assert rect["size"][0] - 232 >= 24, "slider must fit both endpoints inside the row"
                    knob = item["slider"]["knob"]
                    assert measured_width(knob["value"], knob["font"]) <= 24
                    for endpoint in ["0", "100"]:
                        bar("--set", name, "slider.percentage=" + endpoint)
                        endpoint_item = query(name, "")
                        assert int(endpoint_item["slider"]["percentage"]) == int(endpoint)
                        assert endpoint_item["bounding_rects"] == item["bounding_rects"]
                elif group in ["details", "checked", "audio"]:
                    assert item["label"]["align"] == "center"
                    assert measured_width(item["label"]["value"], item["label"]["font"]) <= 256
                elif group != "ssid":
                    assert item["icon"]["width"] == item["label"]["width"] == 128
            assert all(rect["origin"][0] == bounds[0]["origin"][0] for rect in bounds)
            assert all(right["origin"][1] - left["origin"][1] == 30
                       for left, right in zip(bounds, bounds[1:]))
        print(f"Live geometry: {len(values)} network rates, CPU through 100%, and three complete popups: PASS")
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
