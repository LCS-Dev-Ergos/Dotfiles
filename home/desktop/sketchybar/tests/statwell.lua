-- Lifecycle and race regressions against the real helper and widget modules.
local root = assert(arg[1])
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
package.preload["helpers.runtime"] = function()
  return { statwell = "/nix/store/fixture-statwell/bin/statwell", network_interface = "en0", package_timeout_ms = 30000 }
end
local now = 1790755200
os.time = function() return now end
local fixture = dofile(root .. "/../tests/fixtures/sbar.lua")()
local items, commands, timers = fixture.items, fixture.commands, fixture.timers
sbar = fixture.api

require("items.widgets.homebrew")
require("items.widgets.wifi")
require("items.widgets.cpu")
require("items.widgets.battery")
local helper = require("helpers.statwell")
for _, command in ipairs(commands) do
  assert(not command[1]:find("watch --metric", 1, true), "watchers cannot start before config commit")
end
helper.prepare()
helper.start()
local watcher_count = 0
for _, command in ipairs(commands) do
  if command[1]:find("watch --metric", 1, true) then
    watcher_count = watcher_count + 1
    assert(command[1]:find("pgrep",1,true) and command[1]:find("statwell-",1,true))
    if command[1]:find("statwell_network",1,true) then assert(command[1]:find("en0",1,true)) end
    if command[1]:find("statwell_homebrew",1,true) then
      assert(command[1]:find("HOMEBREW_NO_AUTO_UPDATE=1",1,true) and command[1]:find("30000",1,true))
    end
    command[2]("", 0)
  end
end
assert(watcher_count == 4, "one watcher per metric after commit")
local initial_cache = commands[#commands]
assert(initial_cache[1]:find("snapshot --cached-only",1,true))
helper.reconcile()
assert(commands[#commands] == initial_cache, "one cache read in flight")
local function record(sequence, value, status)
  return { sequence = sequence, sampled_at_unix_ms = now*1000, value_at_unix_ms = now*1000,
    max_age_ms = 6000, status = status or "ok", refreshing = false, value = value }
end
local function document(instance, sequence, total)
  return { schema_version = 1, instance_id = instance, captured_at_unix_ms = now*1000, metrics = {
    homebrew = record(sequence, { total = total }),
    network = record(sequence, { upload_bytes_per_second = 0, download_bytes_per_second = 1024 }),
    cpu = record(sequence, { total_percent = 10 }),
    battery = record(sequence, { percent = 90, charging = false, external_power = false }),
  } }
end
initial_cache[2](document("daemon-a",1,2), 0)
local brew, upload, download = items["widgets.brew"], items["widgets.wifi1"], items["widgets.wifi2"]
assert(brew.props.label.string == "2", "cache heals a missed startup event")
assert(items["widgets.battery"].props.icon.string == require("icons").battery._100, "JSON false stays false")

helper.reconcile()
local late_cache = commands[#commands]
brew.handlers.statwell_homebrew({ instance_id="daemon-b", sequence="2", status="ok", total="7",
  value_at_unix_ms=tostring(now*1000), max_age_ms="6000" })
late_cache[2](document("daemon-a",1,2),0)
assert(brew.props.label.string == "7", "late cache response cannot overwrite a newer event")
brew.handlers.statwell_homebrew({ instance_id="daemon-b",sequence="1",status="ok",total="3",
  value_at_unix_ms=tostring(now*1000),max_age_ms="6000" })
assert(brew.props.label.string == "7", "older sequences are rejected")
brew.handlers.statwell_homebrew({ instance_id="daemon-a",sequence="999",status="ok",total="3",
  value_at_unix_ms=tostring(now*1000),max_age_ms="6000" })
assert(brew.props.label.string == "7", "retired daemon events are rejected")

brew.handlers.statwell_homebrew({ instance_id="daemon-b",sequence="3",status="ok",total="garbage",
  value_at_unix_ms=tostring(now*1000),max_age_ms="6000" })
assert(brew.props.label.string == "7!", "malformed counts do not leave a healthy label")
brew.handlers.statwell_homebrew({ instance_id="daemon-b",sequence="4",status="ok",total="7",refreshing="true",
  value_at_unix_ms=tostring(now*1000),max_age_ms="6000" })
assert(brew.props.label.string == "7…", "refresh is distinguishable from error")
brew.handlers.statwell_homebrew({ instance_id="daemon-b",sequence="4",status="ok",total="7",refreshing="false",
  value_at_unix_ms=tostring(now*1000),max_age_ms="6000" })
now = now + 8
local observer = items["statwell.observer"]
observer.handlers.routine({SENDER="routine"})
assert(brew.props.label.string == "7!", "freshness expires even with no watcher events")
assert(upload.props.label.string == helper.rate_unknown)

for _, n in ipairs({0,1,1023,1024,1048575,1048576,1073741824,1e30}) do
  assert(#helper.rate(n) <= 12 and not helper.rate(n):match("^%s"),
    "rates fit the fixed cell without leading whitespace")
  upload.handlers.statwell_network({ status="ok",value_at_unix_ms=tostring(now*1000),max_age_ms="6000",
    upload_bytes_per_second=tostring(n),download_bytes_per_second=tostring(n) })
  assert(upload.props.label.width == helper.rate_width and download.props.label.width == helper.rate_width)
  assert(download.props.width == "dynamic" and upload.props.width == 0)
end
assert(helper.rate(math.huge) == nil and helper.rate(0/0) == nil and helper.rate(-1) == nil)
assert(not helper.fresh({status="ok",value_at_unix_ms=math.huge,max_age_ms=6000}))
upload.handlers.statwell_network({status="ok",value_at_unix_ms=tostring(now*1000),max_age_ms="6000",
  upload_bytes_per_second="nan",download_bytes_per_second="bad"})
assert(upload.props.label.string == helper.rate_unknown and download.props.label.string == helper.rate_unknown)

observer.handlers.system_will_sleep({SENDER="system_will_sleep"})
local before = #commands
for _=1,60 do observer.handlers.routine({SENDER="routine"}) end
assert(#commands == before, "no cache/provider polling during sleep")
observer.handlers.system_woke({SENDER="system_woke"})
local old_timer = timers[#timers]
observer.handlers.system_woke({SENDER="system_woke"})
old_timer()
assert(#commands == before, "wake bursts coalesce")
timers[#timers]()
local refresh
for i=before+1,#commands do if commands[i][1]:find("refresh --provider",1,true) then refresh=commands[i] end end
assert(refresh and refresh[1]:find("refresh --provider",1,true), "wake requests one provider refresh")
refresh[2]("",0)
local cache = commands[#commands]
assert(cache[1]:find("snapshot --cached-only",1,true))
cache[2](nil,1)
assert(brew.props.label.string == "7!", "missing cache preserves the last valid count")

print("StatWell lifecycle, ordering, freshness and fixed rate cells: PASS")

-- A missing cache callback cannot wedge subsequent reconciliation.
helper.reconcile()
local lost = commands[#commands]
now = now + 11
observer.handlers.routine({SENDER="routine"})
local replacement = commands[#commands]
assert(replacement ~= lost and replacement[1]:find("snapshot --cached-only",1,true))
lost[2](document("daemon-c",1,99),0)
helper.reconcile()
assert(commands[#commands] == replacement, "late callback must not release the replacement request")
replacement[2](document("daemon-c",1,4),0)
assert(brew.props.label.string == "4")

-- Rounded rates can remain equal while the idle/active color changes.
local event = {status="ok",value_at_unix_ms=tostring(now*1000),max_age_ms="6000",
  upload_bytes_per_second="0",download_bytes_per_second="0"}
upload.handlers.statwell_network(event)
local zero_label = upload.props.label.string
event.upload_bytes_per_second="1"
upload.handlers.statwell_network(event)
assert(upload.props.label.string == zero_label and upload.props.label.color == require("colors").magenta)
event.upload_bytes_per_second="0"
upload.handlers.statwell_network(event)
assert(upload.props.label.color == require("colors").muted)
print("Missing callback recovery and rounded-rate colors: PASS")

-- Watcher supervision must also recover a lost callback and ignore late replies.
local function latest_watch(metric)
  for i = #commands, 1, -1 do
    if commands[i][1]:find("watch --metric " .. metric, 1, true) then return commands[i] end
  end
end
local function supervise()
  for _ = 1, 30 do observer.handlers.routine({ SENDER = "routine" }) end
end
now = now + 31
supervise()
local lost_watch = latest_watch("cpu")
now = now + 31
supervise()
local replacement_watch = latest_watch("cpu")
assert(replacement_watch ~= lost_watch, "lost watcher callback must not wedge supervision")
lost_watch[2]("", 0)
supervise()
assert(latest_watch("cpu") == replacement_watch, "late reply must not release a newer watcher launch")
replacement_watch[2]("", 0)
supervise()
assert(latest_watch("cpu") ~= replacement_watch, "completed launches may be checked again")
print("Watcher callback timeout and late-reply isolation: PASS")
