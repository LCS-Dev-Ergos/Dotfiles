-- One hover lifecycle for widget triggers and their interactive popup rows.
local settings = require("settings")
local active
local M = {}

function M.new(host, callbacks)
  callbacks = callbacks or {}
  local opened, generation = false, 0
  local controller = {}
  host:set({ popup = { align = "center", height = settings.popup.row_height,
    drawing = false } })

  function controller.keep_open()
    generation = generation + 1
  end

  function controller.is_open() return opened end

  function controller.close()
    controller.keep_open()
    if not opened then return end
    opened = false
    if active == controller then active = nil end
    host:set({ popup = { drawing = false } })
    if callbacks.close then callbacks.close() end
  end

  function controller.show()
    controller.keep_open()
    if opened then return end
    if active then active.close() end
    opened, active = true, controller
    if callbacks.open then callbacks.open() end
    host:set({ popup = { drawing = true } })
  end

  function controller.schedule_close()
    if not opened then return end
    generation = generation + 1
    local pending = generation
    sbar.delay(settings.popup.close_delay, function()
      if generation == pending then controller.close() end
    end)
  end

  function controller.attach(item, trigger)
    if not trigger then
      item:set({ width = settings.popup.width - 2 * settings.popup.inset,
        padding_left = settings.popup.inset, padding_right = settings.popup.inset,
        align = "center", scroll_texts = false })
    end
    item:subscribe("mouse.entered", trigger and controller.show or controller.keep_open)
    item:subscribe("mouse.exited", controller.schedule_close)
    item:subscribe("mouse.exited.global", controller.close)
  end

  return controller
end

return M
