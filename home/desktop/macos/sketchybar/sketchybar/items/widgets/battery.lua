local icons = require("icons")
local colors = require("colors")
local settings = require("settings")
local statwell = require("helpers.statwell")
local style = require("helpers.style")
local popup = require("helpers.popup")
local popup_data = require("helpers.popup_data")

statwell.watch("battery", "statwell_battery")

local battery = sbar.add("item", "widgets.battery", {
  position = "right",
  icon = { string = icons.battery._100, color = colors.muted,
    padding_left = settings.pill.inset, padding_right = settings.spacing },
  label = style.merge(style.end_cell(settings.cell.percent), {
    string = "?%",
    font = style.font.number(),
  }),
})

local battery_pill = style.pill("widgets.battery.bracket", { battery.name })
style.gap("widgets.battery.padding", "right")

-- Charge and power come from the shared daemon. The icon stays in the text
-- color while discharging normally; green means charging or on power, and
-- orange and red mark a low and a critical charge.
statwell.subscribe(battery, "battery", "statwell_battery", function(env)
  local charge = statwell.fresh(env) and tonumber(env.percent) or nil
  if not charge or charge ~= charge or charge < 0 or charge > 100 then
    battery:set({ icon = { string = icons.battery._0, color = colors.red }, label = { string = "?%" } })
    return
  end

  local icon, color = icons.battery.charging, colors.green
  if env.external_power ~= "true" and env.charging ~= "true" then
    color = colors.white
    if charge > 80 then icon = icons.battery._100
    elseif charge > 60 then icon = icons.battery._75
    elseif charge > 40 then icon = icons.battery._50
    elseif charge > 20 then icon, color = icons.battery._25, colors.orange
    else icon, color = icons.battery._0, colors.red end
  end
  battery:set({
    icon = { string = icon, color = color },
    label = { string = string.format("%d%%", math.floor(charge + 0.5)) },
  })
end)

-- pmset's estimate for the menu; StatWell does not report time remaining.
local menu, cache
menu = popup.new(battery_pill, { open = function() cache.show() end })
menu.trigger(battery)
battery:subscribe("mouse.clicked", menu.show)
local remaining = menu.detail_row("widgets.battery.remaining", "Time remaining")
local source = menu.detail_row("widgets.battery.source", "Power source")

local function render(snapshot)
  remaining:set({ label = { string = snapshot and (snapshot.remaining or "Unavailable") or "Estimating…" } })
  source:set({ label = { string = snapshot and (snapshot.source or "Unavailable") or "…" } })
end

local function load(done)
  sbar.exec("pmset -g batt", function(info, code)
    info = code == 0 and type(info) == "string" and info or ""
    if info == "" then done({}) return end
    local snapshot = {}
    local found, _, time = info:find(" (%d+:%d+) remaining")
    snapshot.source = info:find("AC Power", 1, true) and "Power adapter" or "Battery"
    if info:find("charged;", 1, true) and not info:find("discharging;", 1, true) then
      snapshot.remaining = "Fully charged"
    elseif found and time ~= "0:00" then
      -- While charging, pmset's estimate is the time until full.
      snapshot.remaining = time .. (info:find("; charging;", 1, true) and " h until full" or " h")
    elseif snapshot.source == "Power adapter" then
      snapshot.remaining = "Not discharging"
    else
      snapshot.remaining = "Calculating…"
    end
    done(snapshot)
  end)
end

cache = popup_data.new(load, render, menu.is_open, {})
