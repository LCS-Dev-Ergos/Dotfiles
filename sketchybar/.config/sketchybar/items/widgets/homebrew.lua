local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

--[[ Widget for managing Homebrew updates ]]

-- Configuration
local CONFIG = {
  check_interval = 60,
  update_interval = 900,
  brew_path = "/opt/homebrew/bin/brew",
  terminal_app = "ghostty",
  timeout = 120,
  debug = true,
  hover_effect = true,
  widget_name = "widgets.brew",
  package_icon = icons.package or "[PKG]"
}

-- Color threshold definitions
local THRESHOLDS = {
  { count = 0,  color = colors.grey },
  { count = 1,  color = colors.blue },
  { count = 5,  color = colors.yellow },
  { count = 10, color = colors.orange },
  { count = 15, color = colors.red }
}

-- Visual feedback colors
local FEEDBACK_COLORS = {
  updating = "0xff00ff00",
  success = "0xff55ff55",
  error = "0xffff5555",
  loading = "0x55ffffff"
}

-- Helper functions
local function debug_log(message)
  if CONFIG.debug then print("[BREW] " .. message) end
end
local function safe_exec(command)
  debug_log("Executing command: " .. command)
  sbar.exec(command)
end
local function start_event_provider()
  -- Get the config directory by querying sketchybar
  local config_dir = os.getenv("CONFIG_DIR") or os.getenv("HOME") .. "/.config/sketchybar"
  local brew_check_path = config_dir .. "/helpers/event_providers/brew_check/bin/brew_check"

  local command = string.format(
    "/bin/zsh -c 'source ~/.zshrc >/dev/null 2>&1; " ..
    "pkill -f \"brew_check\" >/dev/null 2>&1; " ..
    "\"%s\" brew_update %d %d \"%s\" >/tmp/brew_check.log 2>&1 &'",
    brew_check_path,
    CONFIG.check_interval,
    CONFIG.update_interval,
    CONFIG.debug and "--verbose" or ""
  )
  safe_exec(command)
end
local function get_color(count)
  count = tonumber(count) or 0
  local color = colors.grey
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
    color = colors.grey,
    font = { family = settings.font.icons, style = settings.font.style_map["Regular"], size = 10.0, },
    padding_right = 4,
  },
  label = {
    string = "0",
    font = { family = settings.font.numbers, style = settings.font.style_map["Bold"], size = 9.0, },
    color = colors.grey,
    align = "right", padding_right = 0, width = 0, y_offset = 4
  },
  padding_right = settings.paddings + 6,
  background = { height = 22, color = { alpha = 0 }, border_color = { alpha = 0 }, drawing = true, },
})

-- Subscribe to update event (modified for robustness)
brew:subscribe("brew_update", function(env)
  local info = env.outdated_count
  if CONFIG.debug then
    print("DEBUG: brew_update received env.outdated_count:", info)
    os.execute("echo 'Lua received: " .. tostring(info) .. "' >> /tmp/brew_check.log")
  end
  local count = tonumber(info) or 0
  local color = get_color(count)

  -- Ensure the icon is always set to prevent disappearing
  brew:set({
    icon = { string = CONFIG.package_icon, color = color },
    label = { string = tostring(count), color = color }
  })

  -- Note: tooltip property is not supported by sketchybar, removed to fix errors
  if env.error and env.error ~= "" and env.error ~= "Success" then
    debug_log("Error from brew_check: " .. env.error)
  end
  debug_log(string.format("Updated brew widget: %d packages", count))
end)

-- === INTEGRATED AND ROBUST CLICK SCRIPT ===
brew:set({
  click_script = string.format([[
    #!/bin/bash
    # Robust, self-contained and reliable click controller.

    # ----- Configuration ----- #
    WIDGET_NAME="%s"
    TERMINAL_APP="%s"
    PACKAGE_ICON="%s"
    BREW_PATH="%s"
    CHECK_PROCESS_NAME="brew_check"

    # ----- Main Logic ----- #

    # 1. Instant and Safe Visual Feedback
    #    Set both icon and "loading" color to solve the problem
    #    of disappearing icon. Restoration will happen later.
    sketchybar --set "$WIDGET_NAME" icon.color='0x55ffffff'

    # ----- Click Handling ----- #

    if [ "$BUTTON" = "middle" ]; then
        # Middle click: Send refresh signal to background process.
        pkill -USR1 -f "$CHECK_PROCESS_NAME"
        # After a brief moment, trigger an event to ensure UI restores.
        sleep 0.5
        sketchybar --trigger brew_update
        exit 0
    fi

    # For left and right clicks, execute all logic in a background subshell
    # (&) to never block Sketchybar's interface.
    (
      # Determine the command to execute in terminal.
      # Always check the real state of brew, don't trust the widget value
      # which might be outdated or still initializing.
      task_command="'$BREW_PATH' outdated" # Default for left click
      if [ "$BUTTON" = "right" ]; then
        task_command="'$BREW_PATH' upgrade"
      fi

      # 2. Launch terminal in background and capture its PID.
      #    Ghostty on macOS requires 'open -a' command with -n flag for new instance.
      if [ "$TERMINAL_APP" = "ghostty" ]; then
        open -n -a Ghostty --args -e bash -c "echo; echo 'Checking for updates...'; $task_command; echo; read -p 'Press Enter to close...'" &
        TERMINAL_PID=$!
      else
        # Alacritty or other terminals with direct CLI support
        "$TERMINAL_APP" -e bash -c "echo 'Checking for updates...'; $task_command; echo; read -p 'Press Enter to close...'" &
        TERMINAL_PID=$!
      fi

      # 3. Wait for the terminal process (and only that) to finish.
      #    This is a blocking call, but happens in a background subshell,
      #    so it doesn't freeze the bar.
      wait $TERMINAL_PID

      # 4. AFTER the terminal closes, send a signal to the C helper
      #    to force counter update.
      pkill -USR1 -f "$CHECK_PROCESS_NAME"

    ) & # The final ampersand is crucial for UI responsiveness.

  ]], CONFIG.widget_name, CONFIG.terminal_app, CONFIG.package_icon, CONFIG.brew_path)
})

-- Hover effect and surrounding elements (unchanged)
if CONFIG.hover_effect then
  brew:subscribe("mouse.entered", function(env) brew:set({ background = { color = colors.bg2 }}) end)
  brew:subscribe("mouse.exited", function(env) brew:set({ background = { color = { alpha = 0 } }}) end)
end
sbar.add("bracket", CONFIG.widget_name .. ".bracket", { brew.name }, { background = { color = colors.bg1 }})
sbar.add("item", CONFIG.widget_name .. ".padding", { position = "right", width = settings.group_paddings })

-- Note: Don't trigger brew_update here - let brew_check send the first update
-- when it completes its initial check. This prevents showing stale "0" values.

debug_log("Homebrew widget initialized successfully")
