-- One hover lifecycle and one row style for every widget menu.
--
-- Hovering a trigger opens its menu, and only one menu is open at a time.
-- Leaving an item closes it after settings.popup.close_delay, which lets the
-- pointer travel into the rows. The close happens only if none of the menu's
-- items is under the pointer by then, so the order in which SketchyBar
-- reports entering one item and leaving another cannot decide it.
--
-- SketchyBar counts an item's own popup as part of that item: moving from
-- an item into its rows reports no exit, and the item then reports no new
-- entry on the next hover. Menus therefore belong to the widget's pill
-- bracket, never to a hovered item. Leaving the bar altogether closes at
-- once.
local colors = require("colors")
local settings = require("settings")
local style = require("helpers.style")

local active
local M = {}

local inset = settings.popup.inset
-- Rows span the menu minus its symmetric inner margins.
M.row_width = settings.popup.width - 2 * inset

--- `host` is the pill bracket the menu hangs from. `options` may set
--- `align` ("center" by default) and the `open` and `close` hooks.
function M.new(host, options)
  options = options or {}
  local opened, generation = false, 0
  -- Names of this menu's items currently under the pointer.
  local inside = {}
  local controller = {}
  host:set({ popup = { align = options.align or "center", height = settings.popup.row_height,
    drawing = false } })

  function controller.keep_open()
    generation = generation + 1
  end

  function controller.is_open() return opened end

  function controller.close()
    controller.keep_open()
    inside = {}
    if not opened then return end
    opened = false
    if active == controller then active = nil end
    host:set({ popup = { drawing = false } })
    if options.close then options.close() end
  end

  function controller.show()
    controller.keep_open()
    if opened then return end
    if active then active.close() end
    opened, active = true, controller
    if options.open then options.open() end
    host:set({ popup = { drawing = true } })
  end

  function controller.schedule_close()
    if not opened then return end
    generation = generation + 1
    local pending = generation
    sbar.delay(settings.popup.close_delay, function()
      if generation == pending and next(inside) == nil then controller.close() end
    end)
  end

  local function hover(item, entered)
    assert(item.name ~= host.name, "a menu belongs to its pill bracket, not to a hovered item")
    item:subscribe("mouse.entered", function()
      inside[item.name] = true
      entered()
    end)
    item:subscribe("mouse.exited", function()
      inside[item.name] = nil
      controller.schedule_close()
    end)
    item:subscribe("mouse.exited.global", controller.close)
  end

  --- Hovering the item on the bar opens the menu.
  function controller.trigger(item) hover(item, controller.show) end

  --- An item inside the menu that keeps its own geometry.
  function controller.member(item) hover(item, controller.keep_open) end

  --- A full-width row inside the menu. Its content is centred in the full
  --- width rather than inset by item padding, so the row's window covers
  --- the whole row and a click can never raise the menu's background
  --- above it (helpers/style.lua).
  function controller.row(item)
    item:set({ width = settings.popup.width, padding_left = 0, padding_right = 0,
      align = "center", scroll_texts = false })
    controller.member(item)
    return item
  end

  --- Adds a row holding one centred text.
  function controller.text_row(name, props)
    return controller.row(sbar.add("item", name, style.merge({
      position = "popup." .. host.name,
      icon = { drawing = false },
      background = { drawing = false },
      label = { align = "center", width = M.row_width, font = style.font.text(),
        color = colors.white },
    }, props)))
  end

  --- Adds a row with a key on the left and its value on the right.
  function controller.detail_row(name, key)
    return controller.row(sbar.add("item", name, {
      position = "popup." .. host.name,
      background = { drawing = false },
      icon = { string = key, align = "left", width = M.row_width / 2,
        font = style.font.text() },
      label = { string = "…", align = "right", width = M.row_width / 2,
        max_chars = 20, font = style.font.body() },
    }))
  end

  return controller
end

return M
