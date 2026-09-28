local colors = require("colors")

-- Equivalent to the --bar domain
sbar.bar({
  position = "top",
  -- Keep MenuBarAgent from intercepting clicks above the visible widgets.
  topmost = "on",
  height = 40,
  color = colors.bar.bg,
  padding_right = 2,
  padding_left = 2,
})
