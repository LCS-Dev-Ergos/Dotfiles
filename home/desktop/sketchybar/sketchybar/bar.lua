local colors = require("colors")

-- Equivalent to the --bar domain
sbar.bar({
  position = "top",
  -- Keep external displays at window level and switch the built-in bar at the top edge.
  topmost = "window",
  native_menu_switch = "on",
  height = 40,
  color = colors.bar.bg,
  padding_right = 2,
  padding_left = 2,
})
