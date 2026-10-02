local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local runtime = require("helpers.runtime")
local style = require("helpers.style")
local popup = require("helpers.popup")
local popup_data = require("helpers.popup_data")

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Right-hand items are laid out from the right: the percentage comes first.
local volume_percent = sbar.add("item", "widgets.volume1", {
  position = "right",
  icon = { drawing = false },
  label = style.merge(style.end_cell(settings.cell.percent), {
    string = "?%",
    font = style.font.number(),
  }),
})

-- The speaker symbols differ in width; a fixed cell keeps the pill steady.
-- It starts the pill, so it holds the inset and the spacing after it.
local volume_icon = sbar.add("item", "widgets.volume2", {
  position = "right",
  icon = {
    string = icons.volume._100,
    width = settings.pill.inset + settings.cell.volume_icon + settings.spacing,
    align = "left",
    padding_left = settings.pill.inset,
  },
  label = { drawing = false },
})

local volume_bracket = style.pill("widgets.volume.bracket", {
  volume_icon.name,
  volume_percent.name
})
style.gap("widgets.volume.padding", "right")

local menu, cache
menu = popup.new(volume_bracket, { open = function() cache.show() end })

-- The track leaves one popup inset at both ends inside the row, so the knob
-- stays within the menu at 0% and 100%.
local volume_slider = sbar.add("slider", popup.row_width - 2 * settings.popup.inset, {
  position = "popup." .. volume_bracket.name,
  icon = { drawing = false },
  label = { drawing = false },
  slider = {
    highlight_color = colors.blue,
    background = {
      height = 6,
      corner_radius = 3,
      color = colors.bg2,
    },
    knob = {
      string = "􀀁",
      drawing = true,
    },
  },
  background = { drawing = false },
  click_script = [[
    case "$PERCENTAGE" in
      ''|*[!0-9.]* ) exit 0 ;;
    esac
    osascript -e "set volume output volume $PERCENTAGE"
  ]]
})
menu.row(volume_slider)

local last_volume
volume_percent:subscribe("volume_change", function(env)
  local volume = tonumber(env.INFO)
  if not volume or volume ~= volume or volume < 0 or volume > 100 then return end
  if volume == last_volume then return end
  last_volume = volume
  local icon = icons.volume._0
  if volume > 60 then
    icon = icons.volume._100
  elseif volume > 30 then
    icon = icons.volume._66
  elseif volume > 10 then
    icon = icons.volume._33
  elseif volume > 0 then
    icon = icons.volume._10
  end

  volume_icon:set({ icon = { string = icon } })
  volume_percent:set({ label = string.format("%d%%", volume) })
  volume_slider:set({ slider = { percentage = volume } })
end)

-- Output devices. Rows are created on first use and then reused: a longer
-- list adds rows, a shorter one hides the rest.
local status = menu.text_row("volume.device.status", {
  label = { string = "Loading output devices…", color = colors.muted },
})
local rows, rendered = {}, nil
local select_device

local function color_rows(current)
  for _, row in ipairs(rows) do
    if row.device then
      row.item:set({ label = { color = row.device == current and colors.white or colors.muted } })
    end
  end
end

local function render_devices(snapshot)
  if snapshot == rendered and snapshot then return end
  rendered = snapshot
  local devices = snapshot and snapshot.devices or {}
  status:set({ drawing = #devices == 0,
    label = { string = snapshot and "Audio devices unavailable" or "Loading output devices…" } })
  for index, device in ipairs(devices) do
    local row = rows[index]
    if not row then
      row = { item = menu.text_row("volume.device.row." .. index, { label = { max_chars = 32 } }) }
      row.item:subscribe("mouse.clicked", function() select_device(row.device) end)
      rows[index] = row
    end
    row.device = device
    row.item:set({ drawing = true, label = { string = device } })
  end
  for index = #devices + 1, #rows do
    rows[index].device = nil
    rows[index].item:set({ drawing = false })
  end
  color_rows(snapshot and snapshot.current)
end

select_device = function(device)
  if not device then return end
  sbar.exec(shell_quote(runtime.audio) .. " -t output -s " .. shell_quote(device), function(_, code)
    if code ~= 0 then return end
    if rendered and rendered.devices then rendered.current = device end
    color_rows(device)
  end)
end

local function load_devices(done)
  local current, devices, remaining = nil, nil, 2
  local function finish()
    remaining = remaining - 1
    if remaining == 0 then done(current and devices and { current = current, devices = devices } or {}) end
  end
  sbar.exec(shell_quote(runtime.audio) .. " -t output -c", function(result, code)
    if code == 0 and type(result) == "string" and not result:match("^%s*$") then
      current = result:gsub("[\r\n]+$", "")
    end
    finish()
  end)
  sbar.exec(shell_quote(runtime.audio) .. " -a -t output", function(result, code)
    if code == 0 and type(result) == "string" and not result:match("^%s*$") then
      devices = {}
      for device in result:gmatch('[^\r\n]+') do devices[#devices + 1] = device end
    end
    finish()
  end)
end

cache = popup_data.new(load_devices, render_devices, menu.is_open, {})
menu.trigger(volume_icon)
menu.trigger(volume_percent)
volume_icon:subscribe("system_woke", function() cache.invalidate() end)
cache.refresh()

local function volume_click(env)
  if env.BUTTON == "right" then
    sbar.exec("open /System/Library/PreferencePanes/Sound.prefpane")
  else
    menu.show()
  end
end

local function volume_scroll(env)
  local delta = tonumber(env.SCROLL_DELTA)
  if not delta or delta ~= delta or math.abs(delta) == math.huge then return end
  delta = math.max(-100, math.min(100, delta))
  sbar.exec('osascript -e "set volume output volume (output volume of (get volume settings) + ' .. delta .. ')"')
end

volume_icon:subscribe("mouse.clicked", volume_click)
volume_icon:subscribe("mouse.scrolled", volume_scroll)
volume_percent:subscribe("mouse.clicked", volume_click)
volume_percent:subscribe("mouse.scrolled", volume_scroll)
