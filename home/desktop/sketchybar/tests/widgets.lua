-- Regression checks for the SketchyBar Lua widgets.
--
-- Loads the real item modules against an in-memory `sbar` stub. Commands and
-- timers are recorded instead of executed, so each check drives a callback by
-- hand and inspects the properties the widget set.
--
-- Usage: lua widgets.lua <sketchybar-config-dir>

local root = assert(arg[1], "usage: lua widgets.lua <sketchybar-config-dir>")
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
package.preload["helpers.runtime"] = function()
  return {
    nowplaying = "/fixture/nowplaying",
    statwell = "/nix/store/fixture-statwell/bin/statwell",
    network_interface = "en0",
    package_timeout_ms = 30000,
    python = "/fixture/python",
    audio = "/fixture/audio",
    yabai = "/fixture/yabai",
    space_script = "/fixture/space.sh",
  }
end

local fixture = dofile(root .. "/../tests/fixtures/sbar.lua")()
local items, commands, timers = fixture.items, fixture.commands, fixture.timers
sbar = fixture.api

--- Answers the most recent `sbar.exec` call.
--- @param ... any Arguments for the command's callback.
local function reply(...) commands[#commands][2](...) end

-- Homebrew: a daemon restart is pending, not a failed package check.
require("items.widgets.homebrew")
local brew = items["widgets.brew"]
local brew_details, brew_checked = items["widgets.brew.details"], items["widgets.brew.checked"]
assert(brew.props.label.string == "?")
local helper = require("helpers.statwell")
helper.prepare()
helper.start()
local brew_watch
for _, cmd in ipairs(commands) do if cmd[1]:find("statwell_homebrew", 1, true) then brew_watch=cmd[1] end end
assert(brew_watch:find("HOMEBREW_NO_AUTO_UPDATE=1", 1, true) and
  brew_watch:find("--package-timeout-ms 30000", 1, true),
  "Homebrew fallback needs the same environment and deadline as the daemon")
local brew_now = tostring(os.time() * 1000)
brew.handlers.statwell_homebrew({ status = "ok", value_at_unix_ms = brew_now, max_age_ms = "10800000", total = "1" })
brew.handlers.statwell_homebrew({ status = "unavailable" })
assert(brew.props.label.string == "1…", "pending refresh must not show a stale 1!")
assert(brew.props.label.color == require("colors").muted, "pending refresh must not look like an error")
brew.handlers.statwell_homebrew({ status = "ok", value_at_unix_ms = brew_now, max_age_ms = "10800000", total = "2" })
assert(brew.props.label.string == "2", "completed refresh must show the new count")
assert(brew_details.props.label.string == "2 updates available")
assert(brew_checked.props.label.string:match("^Last checked at %d%d:%d%d:%d%d$"),
  "the check time belongs in the secondary popup row")

-- Empty events preserve the count; actual failures stay visible.
brew.handlers.statwell_homebrew({ status = "ok", value_at_unix_ms = brew_now, max_age_ms = "10800000", total = "7" })
brew.handlers.statwell_homebrew({})
assert(brew.props.label.string == "7", "empty event must preserve count")
brew.handlers.statwell_homebrew({ status = "error", total = "0" })
assert(brew.props.label.string == "7!", "failure must not look like zero updates")
brew.handlers.statwell_homebrew({ status = "error", error = "system_failure" })
assert(brew_details.props.label.string == "Update check failed")
assert(brew_checked.props.label.string == "Homebrew will retry automatically",
  "startup errors need readable feedback without hiding the failure")
brew.handlers.statwell_homebrew({ status = "ok", value_at_unix_ms = brew_now, max_age_ms = "10800000", total = "0" })
assert(brew.props.label.string == "0", "recovery must clear the error")

-- Media: one snapshot at a time, and the cover follows the playback state.
require("items.media")
local cover, observer = items["media.cover"], items["media.observer"]
assert(not cover.handlers.media_change, "must not enable the obsolete native media backend")
local first = commands[#commands]
observer.handlers.routine({})
assert(commands[#commands] == first, "at most one snapshot in flight")
first[2]({
  state = "playing",
  app = "TIDAL",
  title = "Track",
  artist = "Artist",
  artwork = "/fixture/cover.img",
}, 0)
assert(cover.props.drawing == true and cover.props.background.image.string == "/fixture/cover.img")

observer.handlers.routine({})
reply({
  state = "paused",
  app = "TIDAL",
  title = "Track",
  artist = "Artist",
  artwork = "/fixture/cover.img",
}, 0)
assert(cover.props.drawing == true, "paused media must retain accessible playback controls")

observer.handlers.routine({})
reply({ state = "stopped" }, 0)
assert(cover.props.drawing == false, "empty/unsupported player must hide stale artwork")
local hidden_sets = cover.sets
observer.handlers.routine({})
reply({ state = "stopped" }, 0)
assert(cover.sets == hidden_sets, "unchanged stopped playback needs no redraw")

observer.handlers.routine({})
reply({ state = "playing", app = "Music", title = "Track", artwork = "" }, 0)
assert(
  cover.props.drawing == true and cover.props.icon.drawing == true,
  "text-only media needs a visible fallback"
)

observer.handlers.routine({})
reply(nil, 1)
assert(cover.props.drawing == false, "failed snapshot must clear stale media")

observer.handlers.system_will_sleep({})
local before = #commands
observer.handlers.routine({})
assert(#commands == before, "do not poll during sleep")

-- Spaces: window-event bursts coalesce, and nothing redraws while locked.
require("items.spaces")
items["space.1"].handlers["mouse.clicked"]({ BUTTON = "left", SID = "12" })
assert(commands[#commands][1] == "'/fixture/space.sh' focus 12", "space click uses the managed script")
items["space.1"].handlers["mouse.clicked"]({ BUTTON = "right", SID = "12" })
assert(commands[#commands][1] == "'/fixture/yabai' -m space --destroy 12", "space menu uses managed yabai")
local spaces_observer
for _, item in ipairs(items) do
  if item.handlers.space_windows_change then spaces_observer = item end
end

--- Delivers a `space_windows_change` event for space 1.
--- @param apps table Window counts by application name.
local function space_event(apps)
  spaces_observer.handlers.space_windows_change({ INFO = { space = 1, apps = apps } })
end

local num_timers = #timers
space_event({ Music = 1 })
space_event({ TIDAL = 1 })
assert(#timers == num_timers + 1, "coalesce window-event bursts")
timers[#timers]()
local label = items["space.1"].props.label
assert(label and label ~= "", "flush latest icons")

spaces_observer.handlers.session_locked({})
num_timers = #timers
space_event({})
assert(
  #timers == num_timers and items["space.1"].props.label == label,
  "no icon redraws while locked"
)
spaces_observer.handlers.session_unlocked({})
timers[#timers]()
assert(items["space.1"].props.label == " —", "apply final state after unlock")

-- Volume: replies that arrive after the popup closed are ignored.
require("items.widgets.volume")
local volume = items["widgets.volume1"]
volume.handlers["mouse.clicked"]({ BUTTON = "left" })
local stale_current = commands[#commands]
volume.handlers["mouse.exited.global"]({})
local count = #commands
stale_current[2]("Speakers\n", 0)
assert(#commands == count, "closed audio popup must not continue fetching devices")

volume.handlers["mouse.clicked"]({ BUTTON = "left" })
reply("Speakers\n", 0)
local stale_list = commands[#commands]
volume.handlers["mouse.exited.global"]({})
local item_count = #items
stale_list[2]("Speakers\nHeadphones\n", 0)
assert(#items == item_count, "late device list must not recreate closed popup rows")

volume.handlers["mouse.clicked"]({ BUTTON = "left" })
reply("Speakers\n", 0)
reply("Speakers\nHeadphones\n", 0)
assert(
  items["volume.device.0"] and items["volume.device.1"],
  "fresh device list must still populate"
)

-- CPU: a fresh event updates the graph; stale readings remain unknown.
require("items.widgets.cpu")
local cpu = items["widgets.cpu"]
local now_ms = tostring(os.time() * 1000)
assert(require("helpers.statwell").fresh({ status = "ok", value_at_unix_ms = tostring(os.time() * 1000 + 500), max_age_ms = "6000" }))
cpu.handlers.statwell_cpu({ status = "ok", value_at_unix_ms = now_ms, max_age_ms = "6000", total_percent = "25" })
assert(cpu.props.label == "25%" and cpu.last_push[1] == 0.25)
cpu.handlers.statwell_cpu({ status = "ok", value_at_unix_ms = now_ms, max_age_ms = "6000", total_percent = "100" })
assert(cpu.props.label == "100%" and cpu.last_push[1] == 1,
  "the maximum CPU label must fit beside the icon")
cpu.handlers.statwell_cpu({ status = "error", value_at_unix_ms = now_ms, max_age_ms = "6000" })
assert(cpu.props.label == "?%", "failed CPU probe must not become zero")

-- Battery: charge comes from StatWell; errors never display as zero percent.
require("items.widgets.battery")
local battery = items["widgets.battery"]
battery.handlers.statwell_battery({ status = "ok", value_at_unix_ms = now_ms, max_age_ms = "90000", percent = "8", charging = "false", external_power = "false" })
assert(battery.props.label.string == "08%", "battery charge comes from StatWell")
battery.handlers.statwell_battery({ status = "error" })
assert(battery.props.label.string == "?", "failed battery probe must not become zero")

-- Network: only a changed direction is redrawn.
require("items.widgets.wifi")
-- Late-loaded widgets have queued watches; start is normally called after all modules.
local watched_network = false
for _, cmd in ipairs(commands) do if cmd[1]:find("statwell_network",1,true) then watched_network=true end end
local upload, download = items["widgets.wifi1"], items["widgets.wifi2"]
assert(upload.props.label.width == helper.rate_width and download.props.label.width == helper.rate_width,
  "both rate cells need identical fixed geometry")
assert(download.props.width == "dynamic" and upload.props.width == 0,
  "stacked rows reserve the fixed cells plus their actual padding once")
local network_zero = { status = "ok", value_at_unix_ms = now_ms, max_age_ms = "6000", upload_bytes_per_second = "0", download_bytes_per_second = "1024" }
upload.handlers.statwell_network(network_zero)
local up_sets, down_sets = upload.sets, download.sets
upload.handlers.statwell_network(network_zero)
assert(
  upload.sets == up_sets and download.sets == down_sets,
  "identical network rates need no redraw"
)
upload.handlers.statwell_network({ status = "ok", value_at_unix_ms = now_ms, max_age_ms = "6000", upload_bytes_per_second = "2048", download_bytes_per_second = "1024" })
assert(
  upload.sets == up_sets + 1 and download.sets == down_sets,
  "redraw only the changed direction"
)
upload.handlers.statwell_network({ status = "error" })
assert(upload.props.label.string == require("helpers.statwell").rate_unknown, "network errors must remain unknown")

print("widget callbacks: PASS")
