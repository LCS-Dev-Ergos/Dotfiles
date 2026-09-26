local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

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
  check_interval = 300,
  update_interval = 3600,
  brew_path = find_brew_path(),
  debug = false,
  hover_effect = true,
  widget_name = "widgets.brew",
  package_icon = (icons.package or "[PKG]"):gsub("%s+$", ""),
  log_path = (os.getenv("TMPDIR") or "/tmp/"):gsub("/*$", "/") .. "sketchybar-brew-check-" .. (os.getenv("UID") or os.getenv("USER") or "user") .. ".log"
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
local brew_check_path = config_dir .. "/helpers/event_providers/brew_check/bin/brew_check"

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end
local function debug_log(message)
  if CONFIG.debug then print("[BREW] " .. message) end
end
local function safe_exec(command)
  debug_log("Executing command: " .. command)
  sbar.exec(command)
end
local function start_event_provider()
  local verbose_arg = CONFIG.debug and " --verbose" or ""

  local script = string.format(
    "pkill -TERM -f %s >/dev/null 2>&1; %s brew_update %d %d%s >>%s 2>&1 &",
    shell_quote(brew_check_path .. " brew_update"),
    shell_quote(brew_check_path),
    CONFIG.check_interval,
    CONFIG.update_interval,
    verbose_arg,
    shell_quote(CONFIG.log_path)
  )
  safe_exec("/bin/zsh -c " .. shell_quote(script))
end
local function get_color(count)
  count = tonumber(count) or 0
  local color = colors.muted
  for i = #THRESHOLDS, 1, -1 do
    if count >= THRESHOLDS[i].count then color = THRESHOLDS[i].color; break; end
  end
  return color
end

-- Start event provider (unchanged)
sbar.add("event", "brew_update")
start_event_provider()

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
-- distinguish a failed check from an empty list of outdated packages.
local last_count = nil
brew:subscribe("brew_update", function(env)
  local failed = env.error and env.error ~= "" and env.error ~= "Success"
  local count = tonumber(env.outdated_count)
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
  .. " " .. shell_quote(CONFIG.brew_path) .. " " .. shell_quote(brew_check_path) })

-- Hover effect and surrounding elements (unchanged)
if CONFIG.hover_effect then
  brew:subscribe("mouse.entered", function(env) brew:set({ background = { color = colors.hover }}) end)
  brew:subscribe("mouse.exited", function(env) brew:set({ background = { color = { alpha = 0 } }}) end)
end
sbar.add("bracket", CONFIG.widget_name .. ".bracket", { brew.name }, { background = { color = colors.bg1 }})
sbar.add("item", CONFIG.widget_name .. ".padding", { position = "right", width = settings.group_paddings })

-- Note: Don't trigger brew_update here - let brew_check send the first update
-- when it completes its initial check. This prevents showing stale "0" values.

debug_log("Homebrew widget initialized successfully")
