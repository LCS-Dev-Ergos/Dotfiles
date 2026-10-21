local icons = require("icons")
local settings = require("settings")
local style = require("helpers.style")

local apple = sbar.add("item", "apple", {
  icon = { string = icons.apple, padding_left = settings.pill.inset, padding_right = settings.pill.inset },
  label = { drawing = false },
  click_script = "$CONFIG_DIR/helpers/menus/bin/menus -s 0",
})

style.pill("apple.pill", { apple.name })
-- The Desktops follow, and each keeps room for its ring outside its pill
-- (settings.space.ring); this gap leaves that room out. The menu titles,
-- shown instead of the Desktops, add it back with their own lead.
style.gap("apple.gap", "left", nil, settings.pill.gap - settings.space.ring)
