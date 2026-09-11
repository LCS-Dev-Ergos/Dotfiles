local root = assert(arg[1])
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
package.preload['helpers.runtime'] = function()
  return { nowplaying = '/fixture/nowplaying', python = '/fixture/python', audio = '/fixture/audio' }
end
local items, commands, timers = {}, {}, {}
local function merge(a, b)
  for k, v in pairs(b) do
    if type(v) == 'table' and type(a[k]) == 'table' then merge(a[k], v) else a[k] = v end
  end
end
sbar = {
  exec = function(command, callback) table.insert(commands, { command, callback }) end,
  delay = function(_, callback) table.insert(timers, callback) end,
  add = function(kind, name, props)
    if kind == 'event' then return end
    if type(name) == 'table' then props, name = name, 'item.' .. #items end
    local item = { name = name, props = props or {}, handlers = {} }
    function item:set(value) merge(self.props, value) end
    function item:subscribe(events, callback)
      if type(events) == 'string' then events = { events } end
      for _, event in ipairs(events) do self.handlers[event] = callback end
    end
    table.insert(items, item); items[name] = item
    return item
  end,
}
require('items.widgets.homebrew')
local brew = items['widgets.brew']
assert(brew.props.label.string == '?')
brew.handlers.brew_update({ outdated_count = '7' })
brew.handlers.brew_update({})
assert(brew.props.label.string == '7', 'empty event must preserve count')
brew.handlers.brew_update({ outdated_count = '0', error = 'Command execution failed' })
assert(brew.props.label.string == '7!', 'failure must not look like zero updates')
brew.handlers.brew_update({ outdated_count = '0', error = 'Success' })
assert(brew.props.label.string == '0', 'recovery must clear the error')
require('items.media')
local cover, observer = items['media.cover'], items['media.observer']
assert(not cover.handlers.media_change, 'must not enable the obsolete native media backend')
local first = commands[#commands]
observer.handlers.routine({})
assert(commands[#commands] == first, 'at most one snapshot in flight')
first[2]({ state = 'playing', app = 'TIDAL', title = 'Track', artist = 'Artist', artwork = '/fixture/cover.img' }, 0)
assert(cover.props.drawing == true and cover.props.background.image.string == '/fixture/cover.img')
observer.handlers.routine({})
commands[#commands][2]({ state = 'stopped' }, 0)
assert(cover.props.drawing == false, 'empty/unsupported player must hide stale artwork')
observer.handlers.routine({})
commands[#commands][2]({ state = 'playing', app = 'Music', title = 'Track', artwork = '' }, 0)
assert(cover.props.drawing == true and cover.props.icon.drawing == true, 'text-only media needs a visible fallback')
observer.handlers.routine({})
commands[#commands][2](nil, 1)
assert(cover.props.drawing == false, 'failed snapshot must clear stale media')
observer.handlers.system_will_sleep({})
local before = #commands
observer.handlers.routine({})
assert(#commands == before, 'do not poll during sleep')
require('items.spaces')
local spaces_observer
for _, item in ipairs(items) do if item.handlers.space_windows_change then spaces_observer = item end end
local function space_event(apps)
  spaces_observer.handlers.space_windows_change({ INFO = { space = 1, apps = apps } })
end
local num_timers = #timers
space_event({ Music = 1 })
space_event({ TIDAL = 1 })
assert(#timers == num_timers + 1, 'coalesce window-event bursts')
timers[#timers]()
local label = items['space.1'].props.label
assert(label and label ~= '', 'flush latest icons')
spaces_observer.handlers.session_locked({})
num_timers = #timers
space_event({})
assert(#timers == num_timers and items['space.1'].props.label == label, 'no icon redraws while locked')
spaces_observer.handlers.session_unlocked({})
timers[#timers]()
assert(items['space.1'].props.label == ' —', 'apply final state after unlock')
print('widget callbacks: PASS')
