local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

local popup_width = 250

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local volume_percent = sbar.add("item", "widgets.volume1", {
  position = "right",
  icon = { drawing = false },
  label = {
    string = "??%",
    padding_left = -1,
    font = { family = settings.font.numbers }
  },
})

local volume_icon = sbar.add("item", "widgets.volume2", {
  position = "right",
  padding_right = -1,
  icon = {
    string = icons.volume._100,
    width = 0,
    align = "left",
    color = colors.grey,
    font = {
      style = settings.font.style_map["Regular"],
      size = 14.0,
    },
  },
  label = {
    width = 25,
    align = "left",
    font = {
      style = settings.font.style_map["Regular"],
      size = 14.0,
    },
  },
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

volume_percent:subscribe("volume_change", function(env)
  local volume = tonumber(env.INFO) or 0
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

  volume_icon:set({ label = icon })
  volume_percent:set({ label = lead .. volume .. "%" })
  volume_slider:set({ slider = { percentage = volume } })
end)

local function volume_collapse_details()
  local drawing = volume_bracket:query().popup.drawing == "on"
  if not drawing then return end
  volume_bracket:set({ popup = { drawing = false } })
  sbar.remove('/volume.device\\.*/')
end

local current_audio_device = "None"
local function volume_toggle_details(env)
  if env.BUTTON == "right" then
    sbar.exec("open /System/Library/PreferencePanes/Sound.prefpane")
    return
  end

  local should_draw = volume_bracket:query().popup.drawing == "off"
  if should_draw then
    volume_bracket:set({ popup = { drawing = true } })
    sbar.exec("command -v SwitchAudioSource >/dev/null 2>&1 && SwitchAudioSource -t output -c", function(result)
      if not result or result == "" then
        sbar.add("item", "volume.device.0", {
          position = "popup." .. volume_bracket.name,
          width = popup_width,
          align = "center",
          label = { string = "SwitchAudioSource unavailable", color = colors.red },
        })
        return
      end
      current_audio_device = result:gsub("[\r\n]+$", "")
      sbar.exec("command -v SwitchAudioSource >/dev/null 2>&1 && SwitchAudioSource -a -t output", function(available)
        local current = current_audio_device
        local counter = 0

        for device in string.gmatch(available or "", '[^\r\n]+') do
          local color = colors.grey
          if current == device then
            color = colors.white
          end
          sbar.add("item", "volume.device." .. counter, {
            position = "popup." .. volume_bracket.name,
            width = popup_width,
            align = "center",
            label = { string = device, color = color },
            click_script = "command -v SwitchAudioSource >/dev/null 2>&1 && SwitchAudioSource -s "
              .. shell_quote(device)
              .. " && sketchybar --set /volume.device\\.*/ label.color="
              .. colors.grey
              .. " --set \"$NAME\" label.color="
              .. colors.white

          })
          counter = counter + 1
        end
      end)
    end)
  else
    volume_collapse_details()
  end
end

local function volume_scroll(env)
  local delta = tonumber(env.SCROLL_DELTA)
  if not delta then return end
  sbar.exec('osascript -e "set volume output volume (output volume of (get volume settings) + ' .. delta .. ')"')
end

volume_icon:subscribe("mouse.clicked", volume_toggle_details)
volume_icon:subscribe("mouse.scrolled", volume_scroll)
volume_percent:subscribe("mouse.clicked", volume_toggle_details)
volume_percent:subscribe("mouse.exited.global", volume_collapse_details)
volume_percent:subscribe("mouse.scrolled", volume_scroll)
