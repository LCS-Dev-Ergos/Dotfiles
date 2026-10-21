# =====-----------------------------------------------------------------=====
# HYDE OVERLAY REGRESSIONS
#
# Exercise bootstrap, personal preferences and isolation without starting
# Hyprland or executing desktop commands. Native acceptance remains separate.
# =====-----------------------------------------------------------------=====

"""Exercise the optional overlay without a compositor or desktop side effects."""

import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
LUA = os.environ.get("LUA", "lua")

DRIVER = r"""
local configs, monitors, rules, events, commands, env, gestures = {}, {}, {}, {}, {}, {}, {}
hl = {
    config = function(v) configs[#configs + 1] = v end,
    monitor = function(v) monitors[#monitors + 1] = v end,
    gesture = function(v) gestures[#gestures + 1] = v end,
    window_rule = function(v) rules[#rules + 1] = v end,
    on = function(name, fn) assert(name == "hyprland.start"); events[#events + 1] = fn end,
    exec_cmd = function(v) commands[#commands + 1] = v end,
    env = function(k, v) env[k] = v end,
}
local entry = arg[1]
local mode = arg[2]
if mode == "missing" then
    local ok, message = pcall(dofile, entry)
    assert(not ok and message:find("Install native HyDE", 1, true), tostring(message))
    assert(#configs == 0 and #events == 0)
    print("missing core: PASS")
    return
end
dofile(entry)
assert(core_loads == 1 and #configs == 1 and #events == 1)
assert(#monitors == 3 and #rules >= 49)
local input = configs[1].input
assert(input.kb_layout == "us,it" and input.accel_profile == "flat")
assert(input.touchpad.natural_scroll == false and input.numlock_by_default == true)
assert(configs[1].xwayland.force_zero_scaling == true)
assert(configs[1].cursor.no_hardware_cursors == 1)
assert(#gestures == 2 and gestures[1].action == "unset")
assert(gestures[2].direction == "vertical" and gestures[2].action == "workspace")
assert(env.XCURSOR_SIZE == "20" and hyde.config.ui.cursor_size == 20)
assert(monitors[2].mode == "2560x1440@60" and monitors[3].bitdepth == 10)
assert(rules[1].opacity == "0.95 override 0.90 override 1")
assert(hyde.config.start.battery_notify == "", "stale battery command must not start")
events[1]()
assert(commands[1] == "gsettings set org.gnome.desktop.interface cursor-size 20")
assert(commands[2] == "libinput-gestures")
if mode == "rgb" then
    assert(#commands == 3)
    print(commands[3])
else
    assert(#commands == 2)
end
-- Reload with HyDE already present: overrides must run again rather than cache.
dofile(entry)
assert(core_loads == 1 and #configs == 2 and #events == 2)
assert(#monitors == 6 and #rules % 2 == 0)
print("bootstrap, settings and reload: PASS")
"""

CORE = r"""
core_loads = (core_loads or 0) + 1
hyde = { config = { ui = {}, start = { battery_notify = "systemctl suspend" } } }
setmetatable(hyde.config, { __call = function(self, value)
    for k, v in pairs(value.ui) do self.ui[k] = v end
end })
require("hyprland")
"""


class OverlayTests(unittest.TestCase):
    """Verify personal overrides using isolated homes and a simulated HyDE core."""

    def run_overlay(self, *, xdg=True, core=True, rgb=False):
        """Load the overlay in Lua and check startup, settings and reloads.

        Exercise explicit or fallback XDG directories, an optional missing
        core, and an optional RGB script without executing desktop commands.
        """
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp) / "home ' $(touch marker)"
            home.mkdir()
            config = home / ("custom config" if xdg else ".config")
            data = home / ("custom data" if xdg else ".local/share")
            (config / "hypr").mkdir(parents=True)
            (data / "hypr").mkdir(parents=True)
            for target, source in {
                "hyprland.lua": "hyprland.lua",
                "personal.lua": "personal.lua",
                "personal-monitors.lua": "monitors.lua",
                "personal-window-rules.lua": "window-rules.lua",
            }.items():
                (config / "hypr" / target).symlink_to(ROOT / source)
            if core:
                (data / "hypr/hyde.lua").write_text(CORE)
            if rgb:
                (home / "Scripts").mkdir()
                (home / "Scripts/exec_openrgb.sh").write_text("exit 0\n")
            driver = Path(temp) / "driver.lua"
            driver.write_text(DRIVER)
            env = dict(os.environ, HOME=str(home))
            env["XDG_CONFIG_HOME"] = str(config) if xdg else ""
            env["XDG_DATA_HOME"] = str(data) if xdg else ""
            mode = "missing" if not core else "rgb" if rgb else "ordinary"
            result = subprocess.run(
                [LUA, str(driver), str(config / "hypr/hyprland.lua"), mode],
                env=env,
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertEqual(
                result.returncode, 0, result.stdout + result.stderr
            )
            self.assertFalse((home / "marker").exists())
            if rgb:
                self.assertEqual(
                    shlex.split(result.stdout.splitlines()[0]),
                    ["bash", str(home / "Scripts/exec_openrgb.sh")],
                )

    def test_custom_xdg_and_linked_configuration(self):
        """Resolve managed symlinks through custom XDG paths and apply overrides."""
        self.run_overlay()

    def test_empty_xdg_falls_back_to_home(self):
        """Use the home defaults when XDG environment variables are empty."""
        self.run_overlay(xdg=False)

    def test_missing_core_fails_before_startup(self):
        """Report a missing native HyDE core before registering startup actions."""
        self.run_overlay(core=False)

    def test_optional_rgb_path_remains_one_argument(self):
        """Keep spaces, quotes and shell syntax literal in the RGB script path."""
        self.run_overlay(rgb=True)

    def test_reference_preferences_are_not_deployed(self):
        """Keep historical assets and the optional desktop outside active imports."""
        module = (ROOT / "default.nix").read_text()
        self.assertNotIn("mkOutOfStoreSymlink", module)
        self.assertNotIn("reference/", module)
        self.assertNotIn("systemd.user.services", module)
        self.assertIn('!(config.xdg.configFile ? "hypr/legion.lua")', module)
        repo = ROOT.parents[3]
        host = (repo / "hosts/lcs-dev-legion-cachy/home.nix").read_text()
        self.assertIn("../../home/desktop/linux/hyprland", host)
        self.assertNotIn("../../home/desktop/linux/hyde", host)


if __name__ == "__main__":
    unittest.main()
