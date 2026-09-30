local icons = require("icons")
local colors = require("colors")
local settings = require("settings")
local statwell = require("helpers.statwell")

statwell.watch("battery", "statwell_battery")

local battery = sbar.add("item", "widgets.battery", {
  position = "right",
  icon = {
    font = {
      style = settings.font.style_map["Regular"],
      size = 19.0,
    }
  },
  label = { string = "?", width = 42, align = "right", font = { family = settings.font.numbers } },
  popup = { align = "center" }
})

local remaining_time = sbar.add("item", {
  position = "popup." .. battery.name,
  icon = {
    string = "Time remaining:",
    width = 100,
    align = "left"
  },
  label = {
    string = "Estimating…",
    width = 100,
    align = "right"
  },
})

-- The popup's time estimate still uses pmset on click; the drawn status uses
-- the shared daemon's charge and power readings.
statwell.subscribe(battery, "battery", "statwell_battery", function(env)
  local charge = statwell.fresh(env) and tonumber(env.percent) or nil
  if not charge or charge < 0 or charge > 100 then
    battery:set({ icon = { string = "!", color = colors.red }, label = { string = "?" } })
    return
  end

  local icon, color = icons.battery.charging, colors.green
  if env.external_power ~= "true" and env.charging ~= "true" then
    if charge > 80 then icon = icons.battery._100
    elseif charge > 60 then icon = icons.battery._75
    elseif charge > 40 then icon = icons.battery._50
    elseif charge > 20 then icon, color = icons.battery._25, colors.orange
    else icon, color = icons.battery._0, colors.red end
  end
  battery:set({
    icon = { string = icon, color = color },
    label = { string = string.format("%02d%%", charge) },
  })
end)

battery:subscribe("mouse.clicked", function(env)
  local drawing = battery:query().popup.drawing
  battery:set( { popup = { drawing = "toggle" } })

  if drawing == "off" then
    remaining_time:set({ label = "Estimating…" })
    sbar.exec("pmset -g batt", function(batt_info)
      batt_info = batt_info or ""
      local found, _, remaining = batt_info:find(" (%d+:%d+) remaining")
      local label = found and remaining .. "h" or "No estimate"
      if batt_info:find("charged;") and not batt_info:find("discharging;") then
        label = "Fully charged"
      elseif not found and batt_info:find("AC Power") then
        label = "External power"
      end
      remaining_time:set( { label = label })
    end)
  end
end)

battery:subscribe("mouse.exited.global", function()
  battery:set({ popup = { drawing = false } })
end)

sbar.add("bracket", "widgets.battery.bracket", { battery.name }, {
  background = { color = colors.bg1 }
})

sbar.add("item", "widgets.battery.padding", {
  position = "right",
  width = settings.group_paddings
})
