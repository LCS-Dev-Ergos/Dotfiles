local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local runtime = require("helpers.runtime")
local popup = require("helpers.popup")

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

local volume_slider = sbar.add("slider", popup_width, {
  position = "popup." .. volume_bracket.name,
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
  background = { color = colors.bg1, height = 2, y_offset = -20 },
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

local details_generation = 0
local menu
local function volume_collapse_details()
  details_generation = details_generation + 1
  sbar.remove('/volume.device\\.*/')
end

local function volume_open_details()
  details_generation = details_generation + 1
  local generation = details_generation
  local status = sbar.add("item", "volume.device.status", {
    position = "popup." .. volume_bracket.name,
    width = popup_width,
    icon = { drawing = false },
    background = { drawing = false },
    label = { string = "Loading output devices…", color = colors.muted },
  })
  menu.attach(status)
  sbar.exec(shell_quote(runtime.audio) .. " -t output -c", function(result, code)
    if generation ~= details_generation then return end
    if code ~= 0 or not result or result:match("^%s*$") then
      status:set({ label = { string = "Audio devices unavailable", color = colors.red } })
      return
    end
    local current = result:gsub("[\r\n]+$", "")
    sbar.exec(shell_quote(runtime.audio) .. " -a -t output", function(available, list_code)
      if generation ~= details_generation then return end
      if list_code ~= 0 or not available or available:match("^%s*$") then
        status:set({ label = { string = "Audio devices unavailable", color = colors.red } })
        return
      end
      sbar.remove(status.name)
      local counter = 0

      for device in string.gmatch(available or "", '[^\r\n]+') do
        local color = colors.muted
        if current == device then
          color = colors.white
        end
        local row = sbar.add("item", "volume.device." .. counter, {
          position = "popup." .. volume_bracket.name,
          width = popup_width,
          align = "center",
          icon = { drawing = false },
          background = { drawing = false },
          label = { string = device, color = color, max_chars = 32 },
          click_script = shell_quote(runtime.audio) .. " -s "
            .. shell_quote(device)
            .. " && sketchybar --set /volume.device\\.*/ label.color="
            .. colors.muted
            .. " --set \"$NAME\" label.color="
            .. colors.white

        })
        menu.attach(row)
        counter = counter + 1
      end
    end)
  end)
end

menu = popup.new(volume_bracket, { open = volume_open_details, close = volume_collapse_details })
menu.attach(volume_icon, true)
menu.attach(volume_percent, true)
menu.attach(volume_slider)

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
