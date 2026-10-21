-- The front application's menu titles, shown in place of the Desktops while
-- the switch beside the front app is off (items/front_app.lua).
local settings = require("settings")
local style = require("helpers.style")

local M = {}

local menu_watcher = sbar.add("item", "menus.watcher", {
  drawing = false,
  updates = false,
})
local space_menu_swap = sbar.add("item", "menus.swap", {
  drawing = false,
  updates = true,
})
sbar.add("event", "swap_menus_and_spaces")

-- Titles keep one spacing on each side; the outermost titles take the
-- pill's inset instead.
local max_items = 15
local menu_items = {}
for i = 1, max_items, 1 do
  menu_items[i] = sbar.add("item", "menu." .. i, {
    drawing = false,
    icon = { drawing = false },
    label = {
      -- The first title is the application's name.
      font = i == 1 and style.font.strong() or style.font.text(),
      padding_left = i == 1 and settings.pill.inset or settings.spacing,
      padding_right = settings.spacing,
    },
    click_script = "$CONFIG_DIR/helpers/menus/bin/menus -s " .. i,
  })
end

-- The Apple gap and the gap before the switch both leave out the room of a
-- Desktop's ring (items/apple.lua, items/front_app.lua); with the titles
-- shown instead of the Desktops, these two complete them.
local menu_lead = style.gap("menus.lead", "left", nil, settings.space.ring)
style.pill("menus.pill", { "/menu\\..*/" })
local menu_gap = style.gap("menus.gap", "left", nil, settings.pill.gap - settings.space.ring)
menu_lead:set({ drawing = false })
menu_gap:set({ drawing = false })

local showing_menus = false
local menu_generation = 0
local function update_menus()
  menu_generation = menu_generation + 1
  local generation = menu_generation
  sbar.exec("$CONFIG_DIR/helpers/menus/bin/menus -l", function(menus)
    if generation ~= menu_generation or not showing_menus then return end
    local titles = {}
    for menu in string.gmatch(type(menus) == "string" and menus or "", "[^\r\n]+") do
      if #titles == max_items then break end
      titles[#titles + 1] = menu
    end
    for i, item in ipairs(menu_items) do
      item:set({
        drawing = titles[i] ~= nil,
        label = {
          string = titles[i] or "",
          padding_right = i == #titles and settings.pill.inset or settings.spacing,
        },
      })
    end
    menu_lead:set({ drawing = true })
    menu_gap:set({ drawing = true })
  end)
end

menu_watcher:subscribe("front_app_switched", update_menus)

--- Runs after the Desktops are shown again (the AeroSpace variant re-reads
--- its focused workspace there).
function M.on_spaces_shown(callback) M.spaces_shown = callback end

space_menu_swap:subscribe("swap_menus_and_spaces", function()
  showing_menus = not showing_menus
  if showing_menus then
    menu_watcher:set({ updates = true })
    sbar.set("/space\\..*/", { drawing = false })
    sbar.set("front_app", { drawing = false })
    update_menus()
  else
    menu_generation = menu_generation + 1
    menu_watcher:set({ updates = false })
    sbar.set("/menu\\..*/", { drawing = false })
    menu_lead:set({ drawing = false })
    menu_gap:set({ drawing = false })
    sbar.set("/space\\..*/", { drawing = true })
    sbar.set("front_app", { drawing = true })
    if M.spaces_shown then M.spaces_shown() end
  end
end)

return M
