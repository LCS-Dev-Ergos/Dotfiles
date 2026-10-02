local colors = require("colors")
local settings = require("settings")

-- Equivalent to the --bar domain
sbar.bar({
  position = "top",
  -- Keep external displays at window level and switch the built-in bar at the top edge.
  topmost = "window",
  native_menu_switch = "on",
  height = settings.bar.height,
  color = colors.bar.bg,
  padding_right = settings.bar.margin,
  padding_left = settings.bar.margin,
})
