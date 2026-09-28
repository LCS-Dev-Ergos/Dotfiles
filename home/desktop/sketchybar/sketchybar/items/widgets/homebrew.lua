local icons = require("icons")
local colors = require("colors")
local settings = require("settings")
local statwell = require("helpers.statwell")

--[[ Widget for managing Homebrew updates ]]

local function find_brew_path()
  for _, path in ipairs({"/opt/homebrew/bin/brew", "/usr/local/bin/brew"}) do
    local file = io.open(path, "r")
    if file then
      file:close()
      return path
    end
  end
  return "/opt/homebrew/bin/brew"
end

-- Configuration
local CONFIG = {
  brew_path = find_brew_path(),
  hover_effect = true,
  widget_name = "widgets.brew",
  package_icon = (icons.package or "[PKG]"):gsub("%s+$", ""),
}

-- Color threshold definitions
local THRESHOLDS = {
  { count = 0,  color = colors.muted },
  { count = 1,  color = colors.blue },
  { count = 5,  color = colors.yellow },
  { count = 10, color = colors.orange },
  { count = 15, color = colors.red }
}

-- Helper functions
local config_dir = os.getenv("CONFIG_DIR") or os.getenv("HOME") .. "/.config/sketchybar"

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end
local function get_color(count)
  count = tonumber(count) or 0
  local color = colors.muted
  for i = #THRESHOLDS, 1, -1 do
    if count >= THRESHOLDS[i].count then color = THRESHOLDS[i].color; break; end
  end
  return color
end

statwell.watch("homebrew", "statwell_homebrew")

-- Main widget - always visible (unchanged)
local brew = sbar.add("item", CONFIG.widget_name, {
  position = "right",
  icon = {
    string = CONFIG.package_icon,
    color = colors.muted,
    font = { family = settings.font.text, style = settings.font.style_map["Regular"], size = 13.0, },
    padding_right = 2,
  },
  label = {
    string = "?",
    font = { family = settings.font.numbers, style = settings.font.style_map["Semibold"], size = 11.0, },
    color = colors.muted,
    align = "left", padding_left = 3, padding_right = 2, width = "dynamic",
  },
  padding_right = settings.paddings + 6,
  background = { height = 22, color = { alpha = 0 }, border_color = { alpha = 0 }, drawing = true, },
})

-- A missing payload is not a successful zero. Keep the last valid count and
-- distinguish a pending refresh from a failed package check.
local last_count = nil
brew:subscribe("statwell_homebrew", function(env)
  if not env.status then return end
  if env.status == "unavailable" then
    brew:set({
      icon = { color = colors.muted },
      label = { string = "?", color = colors.muted },
    })
    return
  end
  local failed = not statwell.fresh(env)
  local count = tonumber(env.total)
  if failed then
    brew:set({
      icon = { color = colors.red },
      label = { string = last_count and (tostring(last_count) .. "!") or "?", color = colors.red },
    })
    return
  end
  if not count or count < 0 or count % 1 ~= 0 then return end
  last_count = count
  local color = get_color(count)
  brew:set({
    icon = { string = CONFIG.package_icon, color = color },
    label = { string = tostring(count), color = color },
  })
end)

-- The terminal command signals the provider after brew actually completes.
brew:set({ click_script = "/bin/bash " .. shell_quote(config_dir .. "/helpers/brew_action.sh")
  .. " " .. shell_quote(CONFIG.brew_path) })

-- Hover effect and surrounding elements (unchanged)
if CONFIG.hover_effect then
  brew:subscribe("mouse.entered", function(env) brew:set({ background = { color = colors.hover }}) end)
  brew:subscribe("mouse.exited", function(env) brew:set({ background = { color = { alpha = 0 } }}) end)
end
sbar.add("bracket", CONFIG.widget_name .. ".bracket", { brew.name }, { background = { color = colors.bg1 }})
sbar.add("item", CONFIG.widget_name .. ".padding", { position = "right", width = settings.group_paddings })

-- The first event arrives only after a real StatWell check; unknown is not zero.
