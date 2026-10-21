-- The switch between Desktops and menu titles, and the front application,
-- each in its own pill. The front app is drawn only on the active display.
local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local style = require("helpers.style")

-- The last Desktop's ring room and its own gap fall short of a full gap by
-- the ring's room once more.
style.gap("spaces.tail", "left", nil, settings.space.ring)

local switch = sbar.add("item", "spaces_indicator", {
  icon = { string = icons.switch.on, color = colors.muted,
    padding_left = settings.pill.inset, padding_right = settings.pill.inset },
  label = { drawing = false },
})
style.pill("spaces_indicator.pill", { switch.name })
style.gap("spaces_indicator.gap", "left")

local front_app = sbar.add("item", "front_app", {
  display = "active",
  icon = { drawing = false },
  label = { font = style.font.strong(),
    padding_left = settings.pill.inset, padding_right = settings.pill.inset },
  updates = true,
})
style.pill("front_app.pill", { front_app.name })

local last_front_app = nil
local function show(name)
  if name == last_front_app then return end
  last_front_app = name
  front_app:set({ label = { string = name } })
end
front_app:subscribe("front_app_switched", function(env) show(env.INFO) end)

-- SketchyBar reports the front application only when it changes, so read
-- the current one once; lsappinfo prints its display name first, quoted.
sbar.exec('/usr/bin/lsappinfo info -only name "$(/usr/bin/lsappinfo front)"', function(result)
  local name = type(result) == "string" and result:match('^"(.-)"') or nil
  if name and name ~= "" and last_front_app == nil then show(name) end
end)

local showing_spaces = true
switch:subscribe("swap_menus_and_spaces", function()
  showing_spaces = not showing_spaces
  switch:set({ icon = showing_spaces and icons.switch.on or icons.switch.off })
end)

local function swap() sbar.trigger("swap_menus_and_spaces") end
switch:subscribe("mouse.clicked", swap)
front_app:subscribe("mouse.clicked", swap)
