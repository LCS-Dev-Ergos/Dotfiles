local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local app_icons = require("helpers.app_icons")

local spaces = {}

local function valid_space_id(sid)
  sid = tostring(sid or "")
  return sid:match("^%d+$") and sid or nil
end

for i = 1, 10, 1 do
  local space = sbar.add("space", "space." .. i, {
    space = i,
    icon = {
      font = { family = settings.font.numbers },
      string = i,
      padding_left = 15,
      padding_right = 8,
      color = colors.white,
      highlight_color = colors.red,
    },
    label = {
      padding_right = 20,
      color = colors.grey,
      highlight_color = colors.white,
      font = "sketchybar-app-font:Regular:16.0",
      y_offset = -1,
    },
    padding_right = 1,
    padding_left = 1,
    background = {
      color = colors.bg1,
      border_width = 1,
      height = 26,
      border_color = colors.black,
    },
    popup = { background = { border_width = 5, border_color = colors.black } }
  })

  spaces[i] = space

  -- Single item bracket for space items to achieve double border on highlight
  local space_bracket = sbar.add("bracket", { space.name }, {
    background = {
      color = colors.transparent,
      border_color = colors.bg2,
      height = 28,
      border_width = 2
    }
  })

  -- Padding space
  sbar.add("space", "space.padding." .. i, {
    space = i,
    script = "",
    width = settings.group_paddings,
  })

  local space_popup = sbar.add("item", {
    position = "popup." .. space.name,
    padding_left= 5,
    padding_right= 0,
    background = {
      drawing = true,
      image = {
        corner_radius = 9,
        scale = 0.2,
        border_color = colors.grey,
        border_width = 1,
      }
    }
  })

  space:subscribe("space_change", function(env)
    local selected = env.SELECTED == "true"
    local color = selected and colors.grey or colors.bg2
    space:set({
      icon = { highlight = selected, },
      label = { highlight = selected },
      background = { border_color = selected and colors.black or colors.bg2 }
    })
    space_bracket:set({
      background = { border_color = selected and colors.grey or colors.bg2 }
    })
  end)

  space:subscribe("mouse.clicked", function(env)
    local sid = valid_space_id(env.SID)
    if not sid then return end

    if env.BUTTON == "other" then
      space_popup:set({ background = { image = "space." .. sid } })
      space:set({ popup = { drawing = "toggle" } })
    else
      if env.BUTTON == "right" then
        -- Handle right click to destroy the space
        sbar.exec("command -v yabai >/dev/null 2>&1 && yabai -m space --destroy " .. sid)
      else
        -- Handle left click to switch space
        -- Always switch to the space first, regardless of windows
        sbar.exec(string.format([[
          command -v yabai >/dev/null 2>&1 || exit 0
          yabai -m space --focus %s || exit 0
          if command -v jq >/dev/null 2>&1; then
            WINDOW_ID=$(yabai -m query --spaces --space %s | jq -r '.windows[0] // empty')
          else
            WINDOW_ID=
          fi
          case "$WINDOW_ID" in
            ''|*[!0-9]* ) exit 0 ;;
          esac
          if [ -n "$WINDOW_ID" ]; then
            yabai -m window --focus "$WINDOW_ID"
          fi
        ]], sid, sid))
      end
    end
  end)

  space:subscribe("mouse.exited", function(_)
    space:set({ popup = { drawing = false } })
  end)
end

local space_window_observer = sbar.add("item", {
  drawing = false,
  updates = true,
})

local spaces_indicator = sbar.add("item", {
  padding_left = -3,
  padding_right = 0,
  icon = {
    padding_left = 8,
    padding_right = 9,
    color = colors.grey,
    string = icons.switch.on,
  },
  label = {
    width = 0,
    padding_left = 0,
    padding_right = 8,
    string = "Spaces",
    color = colors.bg1,
  },
  background = {
    color = colors.with_alpha(colors.grey, 0.0),
    border_color = colors.with_alpha(colors.bg1, 0.0),
  }
})

space_window_observer:subscribe("space_windows_change", function(env)
  if not env.INFO or not env.INFO.apps then return end
  local icon_line = ""
  local no_app = true
  for app, count in pairs(env.INFO.apps) do
    no_app = false
    local lookup = app_icons[app]
    local icon = ((lookup == nil) and app_icons["default"] or lookup)
    icon_line = icon_line .. " " .. icon
  end

  if (no_app) then
    icon_line = " —"
  end
  local space_index = tonumber(env.INFO.space)
  if space_index and spaces[space_index] then
    sbar.animate("tanh", 10, function()
      spaces[space_index]:set({ label = icon_line })
    end)
  end
end)

spaces_indicator:subscribe("swap_menus_and_spaces", function(env)
  local currently_on = spaces_indicator:query().icon.value == icons.switch.on
  spaces_indicator:set({
    icon = currently_on and icons.switch.off or icons.switch.on
  })
end)

spaces_indicator:subscribe("mouse.entered", function(env)
  sbar.animate("tanh", 30, function()
    spaces_indicator:set({
      background = {
        color = colors.grey,
        border_color = colors.bg1,
      },
      icon = { color = colors.bg1 }
    })
  end)
  spaces_indicator:set({ label = { width = "dynamic" } })
end)

spaces_indicator:subscribe("mouse.exited", function(env)
  sbar.animate("tanh", 30, function()
    spaces_indicator:set({
      background = {
        color = colors.with_alpha(colors.grey, 0.0),
        border_color = colors.with_alpha(colors.bg1, 0.0),
      },
      icon = { color = colors.grey }
    })
  end)
  spaces_indicator:set({ label = { width = 0 } })
end)

spaces_indicator:subscribe("mouse.clicked", function(env)
  sbar.trigger("swap_menus_and_spaces")
end)
