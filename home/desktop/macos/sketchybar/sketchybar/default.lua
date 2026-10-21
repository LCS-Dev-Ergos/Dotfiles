local settings = require("settings")
local colors = require("colors")
local style = require("helpers.style")

-- Equivalent to the --default domain. Items start with no padding at all:
-- each widget states its spacing explicitly from settings, and pill
-- backgrounds come from brackets (helpers/style.lua).
sbar.default({
  updates = "when_shown",
  icon = {
    font = style.font.icon(),
    color = colors.white,
    padding_left = 0,
    padding_right = 0,
  },
  label = {
    font = style.font.text(),
    color = colors.white,
    padding_left = 0,
    padding_right = 0,
  },
  background = {
    height = settings.pill.height,
    corner_radius = settings.pill.corner_radius,
    border_width = 0,
  },
  -- The fork draws popups without a window shadow and skips
  -- background.shadow on them, so a menu's edge is its border alone.
  popup = {
    background = {
      border_width = settings.popup.border_width,
      corner_radius = settings.pill.corner_radius,
      border_color = colors.popup.border,
      color = colors.popup.bg,
    },
    blur_radius = 15,
  },
  padding_left = 0,
  padding_right = 0,
  scroll_texts = true,
})
