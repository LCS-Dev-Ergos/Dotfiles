local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local config_dir = os.getenv("CONFIG_DIR") or os.getenv("HOME") .. "/.config/sketchybar"
local cpu_provider = config_dir .. "/helpers/event_providers/cpu_load/bin/cpu_load"

-- Execute the event provider binary which provides the event "cpu_update" for
-- the cpu load data, which is fired every 2.0 seconds.
sbar.exec("pkill -TERM -f " .. shell_quote(cpu_provider .. " cpu_update") .. " >/dev/null 2>&1; " .. shell_quote(cpu_provider) .. " cpu_update 2.0")

local cpu = sbar.add("graph", "widgets.cpu" , 42, {
  position = "right",
  graph = { color = colors.blue },
  background = {
    height = 22,
    color = { alpha = 0 },
    border_color = { alpha = 0 },
    drawing = true,
  },
  icon = { string = icons.cpu },
  label = {
    string = "cpu ??%",
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Bold"],
      size = 9.0,
    },
    align = "right",
    padding_right = 0,
    width = 0,
    y_offset = 4
  },
  padding_right = settings.paddings + 6
})

cpu:subscribe("cpu_update", function(env)
  -- Also available: env.user_load, env.sys_load
  local load = tonumber(env.total_load) or 0
  cpu:push({ load / 100. })

  local color = colors.blue
  if load > 30 then
    if load < 60 then
      color = colors.yellow
    elseif load < 80 then
      color = colors.orange
    else
      color = colors.red
    end
  end

  cpu:set({
    graph = { color = color },
    label = "cpu " .. env.total_load .. "%",
  })
end)

cpu:subscribe("mouse.clicked", function(env)
  sbar.exec("open -a 'Activity Monitor'")
end)

-- Background around the cpu item
sbar.add("bracket", "widgets.cpu.bracket", { cpu.name }, {
  background = { color = colors.bg1 }
})

-- Background around the cpu item
sbar.add("item", "widgets.cpu.padding", {
  position = "right",
  width = settings.group_paddings
})
