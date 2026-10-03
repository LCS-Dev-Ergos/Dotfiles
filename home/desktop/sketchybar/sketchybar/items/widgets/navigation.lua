-- The Desktop navigation effect yabai's settings choose for space.sh: off,
-- the veil, or the crossfade with its curve. navfx.sh (bound in skhdrc)
-- changes it and announces the change; a click here switches it on or off.
local colors = require("colors")
local runtime = require("helpers.runtime")
local settings = require("settings")
local style = require("helpers.style")

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local script = shell_quote(runtime.navfx_script)

local CURVES = { smooth = "smooth", ease_out = "ease-out" }

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

-- Anything but the words navfx.sh reports reads as unknown.
local last_label, last_color
local function show(effect, kind, curve)
  local label, color
  if effect == "off" and (kind == "crossfade" or kind == "veil") then
    label, color = "No effect", colors.muted
  elseif effect == "on" and kind == "veil" then
    label, color = "Veil", colors.white
  elseif effect == "on" and kind == "crossfade" and CURVES[curve] then
    label, color = "Crossfade " .. CURVES[curve], colors.white
  else
    label, color = "?", colors.red
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
