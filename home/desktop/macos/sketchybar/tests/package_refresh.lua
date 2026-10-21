-- Check legacy Brew notifications, sleep handling and popup refresh throttling.
-- Exercises the real widget with a fake clock, without invoking Homebrew.
-- Usage: lua package_refresh.lua <sketchybar-config-dir>

local root = assert(arg[1])
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
package.preload["helpers.runtime"] = function()
  return {statwell="/fixture/statwell", package_timeout_ms=30000}
end
local now = 1000
os.time = function() return now end
local fixture = dofile(root .. "/../tests/fixtures/sbar.lua")()
sbar = fixture.api
require("items.widgets.homebrew")
local helper = require("helpers.statwell")
helper.prepare()
local observer, brew = fixture.items["statwell.observer"], fixture.items["widgets.brew"]
local function refresh_count()
  local count = 0
  for _, command in ipairs(fixture.commands) do
    if command[1]:find("refresh --provider 'homebrew'",1,true) then count = count + 1 end
  end
  return count
end
assert(observer.handlers.brew_update, "existing shells must still notify StatWell through brew_update")
observer.handlers.brew_update({SENDER="brew_update"})
assert(refresh_count() == 1, "legacy notification must request a provider check")
observer.handlers.system_will_sleep({SENDER="system_will_sleep"})
observer.handlers.brew_update({SENDER="brew_update"})
assert(refresh_count() == 1, "no provider requests during sleep")
observer.handlers.system_woke({SENDER="system_woke"})

brew.handlers.statwell_homebrew({status="ok",total="2",value_at_unix_ms=tostring(now*1000),max_age_ms="900000"})
brew.handlers["mouse.entered"]()
assert(refresh_count() == 1, "opening a recently checked popup must reuse the result")
brew.handlers["mouse.exited.global"]()
now = now + 61
brew.handlers["mouse.entered"]()
assert(refresh_count() == 2, "opening a popup must refresh a result older than one minute")
brew.handlers["mouse.exited.global"]()
brew.handlers["mouse.entered"]()
assert(refresh_count() == 2, "hover bursts must not enqueue more checks")
brew.handlers["mouse.exited.global"]()
now = now + 31
brew.handlers.statwell_homebrew({status="ok",total="2",refreshing="true",value_at_unix_ms="1000000",max_age_ms="900000"})
brew.handlers["mouse.entered"]()
assert(refresh_count() == 2, "a pending provider check must not be duplicated")
print("PASS: legacy shell notifications, sleep, popup freshness and request throttling")
