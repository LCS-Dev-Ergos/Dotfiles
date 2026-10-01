local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local runtime = require("helpers.runtime")
local popup = require("helpers.popup")
local popup_data = require("helpers.popup_data")

local popup_width = settings.popup.width

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local volume_percent = sbar.add("item", "widgets.volume1", {
  position = "right",
  padding_left = 3,
  icon = { drawing = false },
  label = {
    string = "??%",
    width = 34,
    align = "left",
    padding_left = 1,
    font = { family = settings.font.numbers }
  },
})

local volume_icon = sbar.add("item", "widgets.volume2", {
  position = "right",
  padding_right = 0,
  icon = {
    string = icons.volume._100,
    width = "dynamic",
    align = "left",
    padding_right = 2,
    color = colors.white,
    font = {
      style = settings.font.style_map["Regular"],
      size = 14.0,
    },
  },
  label = { drawing = false },
})

local volume_bracket = sbar.add("bracket", "widgets.volume.bracket", {
  volume_icon.name,
  volume_percent.name
}, {
  background = { color = colors.bg1 },
  popup = { align = "center" }
})

sbar.add("item", "widgets.volume.padding", {
  position = "right",
  width = settings.group_paddings
})

local volume_slider = sbar.add("slider", popup_width - 4 * settings.popup.inset, {
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
    knob= {
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

  local lead = ""
  if volume < 10 then
    lead = "0"
  end

  volume_icon:set({ icon = { string = icon } })
  volume_percent:set({ label = lead .. volume .. "%" })
  volume_slider:set({ slider = { percentage = volume } })
end)

local menu, cache
local rendered
local status = sbar.add("item", "volume.device.status", {
  position = "popup." .. volume_bracket.name,
  icon = { drawing = false }, background = { drawing = false },
  label = { string = "Loading output devices…", align = "center", width = popup_width - 2 * settings.popup.inset,
    padding_left = 0, padding_right = 0, color = colors.muted },
})
local function render_devices(snapshot)
  if snapshot == rendered and snapshot then return end
  rendered = snapshot
  sbar.remove('/volume.device.row\\.*/')
  status:set({ drawing = not snapshot or not snapshot.devices,
    label = { string = snapshot and "Audio devices unavailable" or "Loading output devices…" } })
  if not snapshot or not snapshot.devices then return end
  for index, device in ipairs(snapshot.devices) do
    local row = sbar.add("item", "volume.device.row." .. index, {
      position = "popup." .. volume_bracket.name,
      icon = { drawing = false }, background = { drawing = false },
      label = { string = device, align = "center", width = popup_width - 2 * settings.popup.inset,
        padding_left = 0, padding_right = 0, max_chars = 32,
        color = snapshot.current == device and colors.white or colors.muted },
      click_script = shell_quote(runtime.audio) .. " -s " .. shell_quote(device)
        .. " && sketchybar --set /volume.device.row\\.*/ label.color=" .. colors.muted
        .. " --set \"$NAME\" label.color=" .. colors.white,
    })
    menu.attach(row)
  end
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
menu = popup.new(volume_bracket, { open = function() cache.show() end })
cache = popup_data.new(load_devices, render_devices, menu.is_open, {})
menu.attach(volume_icon, true)
menu.attach(volume_percent, true)
menu.attach(volume_slider)
menu.attach(status)
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
