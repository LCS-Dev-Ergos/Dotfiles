-- The Desktop navigation effect yabai's settings choose for space.sh, in
-- short: "XF·S" and "XF·E" for the crossfade with the smooth or ease-out
-- curve, "Veil" for the veil, dimmed while the effects are off. navfx.sh
-- (bound in skhdrc) changes it and announces the change; a click here
-- switches it on or off.
local colors = require("colors")
local runtime = require("helpers.runtime")
local settings = require("settings")
local style = require("helpers.style")

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local script = shell_quote(runtime.navfx_script)

local CURVES = { smooth = "S", ease_out = "E" }

sbar.add("event", "navigation_effect_changed")

local navigation = sbar.add("item", "widgets.navigation", {
  position = "right",
  icon = { drawing = false },
  label = {
    string = "?",
    font = style.font.text(),
    color = colors.muted,
    padding_left = settings.pill.inset,
    padding_right = settings.pill.inset,
  },
})
style.pill("widgets.navigation.bracket", { navigation.name })
style.gap("widgets.navigation.padding", "right")

-- Switched off, the item still names the effect the bindings would bring
-- back. Anything but the words navfx.sh reports reads as unknown.
local last_label, last_color
local function show(effect, kind, curve)
  local label
  if kind == "veil" and CURVES[curve] then
    label = "Veil"
  elseif kind == "crossfade" and CURVES[curve] then
    label = "XF·" .. CURVES[curve]
  end
  local color = colors.white
  if not label or (effect ~= "on" and effect ~= "off") then
    label, color = "?", colors.red
  elseif effect == "off" then
    color = colors.muted
  end
  if label == last_label and color == last_color then return end
  navigation:set({ label = { string = label, color = color } })
  last_label, last_color = label, color
end

local function refresh()
  sbar.exec(script .. " status", function(result)
    local effect, kind, curve
    if type(result) == "string" then
      effect, kind, curve = result:match("^(%S+) (%S+) (%S+)")
    end
    show(effect, kind, curve)
  end)
end

navigation:subscribe("navigation_effect_changed", function(env)
  show(env.EFFECT, env.TYPE, env.CURVE)
end)

navigation:subscribe("mouse.clicked", function()
  sbar.exec(script .. " toggle")
end)

-- yabai keeps the settings in memory: read them once at load. A yabai
-- restart announces them from yabairc.
refresh()
