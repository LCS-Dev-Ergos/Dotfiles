local settings = require("settings")
local style = require("helpers.style")

local cal = sbar.add("item", "calendar", {
  position = "right",
  icon = {
    font = style.font.text(),
    padding_left = settings.pill.inset,
    padding_right = settings.spacing,
  },
  label = { font = style.font.number(), padding_right = settings.pill.inset },
  -- Every second, so the minute turns over on time; only a new minute redraws.
  update_freq = 1,
})

style.pill("calendar.pill", { cal.name })
style.gap("calendar.gap", "right")

local shown
local function update()
  local date, time = os.date("%a. %d %b."), os.date("%H:%M")
  if date .. time == shown then return end
  shown = date .. time
  cal:set({ icon = date, label = time })
end
update()
cal:subscribe({ "forced", "routine", "system_woke" }, update)
