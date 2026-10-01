local root = assert(arg[1])
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
package.preload["helpers.runtime"] = function()
  return { audio = "/fixture/audio", statwell = "/fixture/statwell" }
end
local fixture = dofile(root .. "/../tests/fixtures/sbar.lua")()
sbar = fixture.api
require("items.widgets.volume")
local items, commands = fixture.items, fixture.commands
local volume = items["widgets.volume1"]
local host = items["widgets.volume.bracket"]
local original_set = host.set
function host:set(props)
  if props.popup and props.popup.drawing then
    assert(items["volume.device.status"].props.label.string == "Loading output devices…"
      or items["volume.device.row.1"], "prepare the rows before opening the popup")
  end
  original_set(self, props)
end
volume.handlers["mouse.entered"]({})
local queries = #commands
volume.handlers["mouse.exited.global"]({})
volume.handlers["mouse.entered"]({})
assert(#commands == queries, "rapid hover must reuse the in-flight audio fetch")
commands[1][2]("LSX II\n", 0)
assert(not items["volume.device.row.1"], "do not publish half an audio snapshot")
commands[2][2]("LSX II\nMacBook Pro Speakers\n", 0)
local settings = require("settings")
local row = items["volume.device.row.1"].props
assert(row.label.align == "center" and row.label.width == 256)
assert(row.padding_left == 12 and row.padding_right == 12)
for _, item in ipairs(items) do
  if item.slider_width then
    assert(item.slider_width == 232)
    assert(item.props.width - item.slider_width == 2 * settings.popup.inset,
      "reserve space inside the row for both slider endpoints and the knob")
    assert(not item.props.icon.drawing and not item.props.label.drawing)
  end
end

-- Drive time explicitly: cache age, invalidation, timeout and late results.
local now, original_time = 100, os.time
os.time = function() return now end
local requests, renders, visible = {}, {}, true
local cache = require("helpers.popup_data").new(function(done)
  requests[#requests + 1] = done
end, function(snapshot)
  renders[#renders + 1] = snapshot or false
end, function() return visible end, { state = "unavailable" })
cache.show()
cache.show()
assert(#requests == 1 and renders[1] == false)
local snapshot = { state = "ready" }
requests[1](snapshot)
snapshot.state = "mutated by a late callback"
cache.show()
assert(renders[#renders].state == "ready", "keep a stable complete snapshot")
assert(#requests == 1, "reuse a fresh cached snapshot")
now = 116
cache.show()
assert(#requests == 2 and renders[#renders].state == "ready")
cache.invalidate()
assert(#requests == 3 and renders[#renders] == false)
requests[2]({ state = "obsolete" })
assert(renders[#renders] == false, "ignore results from an invalidated network")
fixture.timers[#fixture.timers]()
assert(renders[#renders].state == "unavailable", "bound the loading state")
requests[3]({ state = "too late" })
assert(renders[#renders].state == "unavailable")
now = 132
cache.refresh()
visible = false
local count = #renders
requests[4]({ state = "ready while closed" })
assert(#renders == count, "never redraw a closed popup from an async callback")
visible = true
cache.show()
assert(renders[#renders].state == "ready while closed" and #requests == 4)
os.time = original_time
print("popup loading and geometry: PASS")
