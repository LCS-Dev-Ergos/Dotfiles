-- In-memory SketchyBar API shared by widget and lifecycle regressions.
local function merge(target, values)
  for key, value in pairs(values) do
    if type(value) == "table" and type(target[key]) == "table" then
      merge(target[key], value)
    else
      target[key] = value
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
    if extra_props then props = extra_props end
    if type(name) == "table" then props, name = name, "item." .. #items end
    local item = { name = name, props = props or {}, handlers = {}, sets = 0 }

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

  return { api = api, items = items, commands = commands, timers = timers }
end
