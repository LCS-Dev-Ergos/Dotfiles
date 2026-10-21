-- One Desktop pill: its number and the icons of its applications, and a
-- ring around it while it is focused. Shared by the yabai and AeroSpace
-- variants.
--
-- The pill is the item's own background, which covers exactly the item's
-- window. The ring is a transparent bracket that reaches into the item's
-- padding; a click there may raise it, which hides nothing.
local app_icons = require("helpers.app_icons")
local colors = require("colors")
local settings = require("settings")
local style = require("helpers.style")

local M = {}

M.empty = "—"

--- Icon string for a set of application names, in a stable order.
function M.icons(apps)
  local names = {}
  for app in pairs(apps) do names[#names + 1] = app end
  if #names == 0 then return M.empty end
  table.sort(names)
  for index, app in ipairs(names) do names[index] = app_icons[app] or app_icons["default"] end
  return table.concat(names, " ")
end

local space = settings.space

--- Adds the Desktop item `space.<id>`, its ring and the gap after it.
--- Returns the item and a function that marks it focused or not.
function M.add(kind, id, props)
  local item = sbar.add(kind, "space." .. id, style.merge({
    padding_left = space.ring,
    padding_right = space.ring,
    background = style.pill_background(),
    icon = {
      string = id,
      font = style.font.space(),
      color = colors.white,
      highlight_color = colors.red,
      padding_left = space.inset,
      padding_right = space.spacing,
    },
    label = {
      string = M.empty,
      font = "sketchybar-app-font:Regular:16.0",
      color = colors.grey,
      highlight_color = colors.white,
      padding_right = space.inset,
      y_offset = -1,
    },
  }, props))
  local ring = sbar.add("bracket", "spaces.ring." .. id, { item.name }, {
    background = {
      drawing = true,
      color = colors.transparent,
      border_color = colors.transparent,
      border_width = space.ring_width,
      height = settings.pill.height + 2 * space.ring,
      corner_radius = settings.pill.corner_radius + space.ring,
    },
  })
  -- The rings reach into the gap; the pills themselves stay one gap apart.
  style.gap("space.padding." .. id, "left", kind == "space" and props.space or nil,
    settings.pill.gap - 2 * space.ring)

  local focused
  local function select(selected)
    if selected == focused then return end
    focused = selected
    item:set({ icon = { highlight = selected }, label = { highlight = selected } })
    ring:set({ background = { border_color = selected and colors.grey or colors.transparent } })
  end
  return item, select
end

return M
