-- In-memory SketchyBar API shared by widget and lifecycle regressions.
-- SketchyBar receives serialized properties, so the fixture copies every
-- table it is given: a widget can never alias another item's properties.
local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, field in pairs(value) do result[key] = copy(field) end
  return result
end

-- `icon = "text"` and `label = "text"` are SketchyBar's shorthand for
-- setting only the string; the other text properties stay.
local shorthand = { icon = true, label = true }

local function merge(target, values)
  for key, value in pairs(values) do
    if shorthand[key] and type(value) ~= "table" then
      if type(target[key]) ~= "table" then target[key] = {} end
      target[key].string = value
    elseif type(value) == "table" and type(target[key]) == "table" then
      merge(target[key], value)
    else
      target[key] = copy(value)
    end
  end
end

return function()
  local items, commands, timers = {}, {}, {}
  local api = {
    exec = function(command, callback) table.insert(commands, { command, callback }) end,
    delay = function(_, callback) table.insert(timers, callback) end,
    remove = function() end,
  }

  function api.add(kind, name, props, extra_props)
    if kind == "event" then return end
    local graph_width = kind == "graph" and props or nil
    if extra_props and kind ~= "bracket" then props = extra_props end
    if type(name) == "table" then props, name = name, "item." .. #items end
    local members
    if kind == "bracket" then members, props = props, extra_props end
    local item = { name = name, kind = kind, props = copy(props or {}), handlers = {}, sets = 0,
      members = members, graph_width = graph_width, slider_width = kind == "slider" and name or nil }

    function item:set(value)
      self.sets = self.sets + 1
      merge(self.props, value)
    end

    function item:push(value) self.last_push = value end

    function item:query()
      local drawing = self.props.popup and self.props.popup.drawing == true
      return { popup = { drawing = drawing and "on" or "off" } }
    end

    function item:subscribe(events, callback)
      if type(events) == "string" then events = { events } end
      for _, event in ipairs(events) do self.handlers[event] = callback end
    end

    table.insert(items, item)
    items[name] = item
    return item
  end

  function api.set(name, values)
    assert(items[name], "unknown item: " .. tostring(name)):set(values)
  end

  return { api = api, items = items, commands = commands, timers = timers }
end
