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

-- Keep the last confirmed value while exposing pending, stale and error states.
local last_count
local details = sbar.add("item", CONFIG.widget_name .. ".details", {
  position = "popup." .. brew.name,
  width = 270,
  icon = { drawing = false },
  label = { string = "Waiting for the first check", max_chars = 48 },
})
brew:set({ popup = { align = "center" } })

local function valid_count(value)
  value = tonumber(value)
  return value and value == value and value >= 0 and value < math.huge
    and value % 1 == 0 and value or nil
end

statwell.subscribe(brew, "homebrew", "statwell_homebrew", function(env)
  if not env.status then return end
  local count = valid_count(env.total)
  local value_at = tonumber(env.value_at_unix_ms)
  -- An error payload can carry the daemon's last valid value after a Lua restart.
  if not last_count and count and value_at and value_at > 0 and value_at < math.huge then
    last_count = count
  end
  local pending = env.status == "unavailable" or env.refreshing == "true"
  local fresh = statwell.fresh(env) and count ~= nil
  local label, color, state
  if pending then
    label, color, state = last_count and (tostring(last_count) .. "…") or "?", colors.muted, "Checking"
  elseif not fresh then
    label, color = last_count and (tostring(last_count) .. "!") or "?", colors.red
    if env.status == "transport_error" then state = "Connection unavailable"
    elseif env.status == "error" then state = "Check failed: " .. tostring(env.error or "unknown")
    elseif not count then state = "Invalid package count"
    else state = "Last result expired" end
  else
    last_count = count
    label, color = tostring(count), get_color(count)
    state = count == 0 and "No updates available" or (tostring(count) .. (count == 1 and " update available" or " updates available"))
  end
  brew:set({ icon = { string = CONFIG.package_icon, color = color },
    label = { string = label, color = color } })
  local checked = ""
  if value_at and value_at > 0 and value_at < math.huge and value_at < 1e14 then
    checked = " · " .. os.date("%H:%M:%S", math.floor(value_at / 1000))
  end
  details:set({ label = { string = state .. checked, color = color } })
end)

-- The terminal command signals the provider after brew actually completes.
brew:set({ click_script = "/bin/bash " .. shell_quote(config_dir .. "/helpers/brew_action.sh")
  .. " " .. shell_quote(CONFIG.brew_path) .. " " .. shell_quote(require("helpers.runtime").statwell)
  .. " " .. shell_quote(require("helpers.runtime").runtime_dir or "") })

-- Hover effect and surrounding elements (unchanged)
if CONFIG.hover_effect then
  brew:subscribe("mouse.entered", function(env) brew:set({ background = { color = colors.hover }, popup = { drawing = true } }) end)
  brew:subscribe("mouse.exited", function(env) brew:set({ background = { color = { alpha = 0 } }, popup = { drawing = false } }) end)
end
sbar.add("bracket", CONFIG.widget_name .. ".bracket", { brew.name }, { background = { color = colors.bg1 }})
sbar.add("item", CONFIG.widget_name .. ".padding", { position = "right", width = settings.group_paddings })

-- The first event arrives only after a real StatWell check; unknown is not zero.
