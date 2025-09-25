local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local app_icons = require("helpers.app_icons")

local spaces = {}

-- Simple app name normalization
local function get_icon_for_app(app_name)
  if not app_name then return nil end
  
  -- Try exact match first
  if app_icons[app_name] then
    return app_icons[app_name]
  end
  
  return app_icons["default"] or "?"
end

-- Fast function to update icons for a specific workspace
local function update_workspace_icons(workspace_num)
  local cmd = string.format("aerospace list-windows --workspace %d --json", workspace_num)
  
  sbar.exec(cmd, function(result)
    if type(result) ~= "table" then return end
    
    local seen = {}
    local icons_str = ""
    
    -- Collect unique app icons
    for _, window in ipairs(result) do
      local app = window["app-name"]
      if app and not seen[app] then
        seen[app] = true
        local icon = get_icon_for_app(app)
        icons_str = icons_str .. " " .. icon
      end
    end
    
    -- Default to em dash if empty
    if icons_str == "" then
      icons_str = " —"
    end
    
    -- Update only if changed
    if spaces[workspace_num] then
      spaces[workspace_num]:set({ label = icons_str })
    end
  end)
end

-- DIAGNOSTIC VERSION: Let's see what's happening step by step
local function highlight_workspace(workspace_num)
  -- First, let's log that this function is being called
  sbar.exec("echo 'DEBUG: highlight_workspace called for workspace " .. workspace_num .. "' >> /tmp/sketchybar_debug.log")
  
  for i = 1, 10 do
    local is_active = (i == workspace_num)
    
    -- Let's use colors that definitely exist and should work
    local active_bg = colors.red    -- Using existing color that we know works
    local active_border = colors.white
    local inactive_bg = colors.bg1
    local inactive_border = colors.bg2
    
    -- Log what we're trying to do
    if is_active then
      sbar.exec("echo 'DEBUG: Setting workspace " .. i .. " as ACTIVE' >> /tmp/sketchybar_debug.log")
    end
    
    if spaces[i] then
      -- Try the most basic version of highlighting first
      spaces[i]:set({
        background = {
          color = is_active and active_bg or inactive_bg,
          border_color = is_active and active_border or inactive_border,
        }
      })
      
      -- Update bracket if it exists
      if spaces[i].bracket then
        spaces[i].bracket:set({
          background = {
            border_color = is_active and active_border or inactive_border,
            border_width = is_active and 3 or 2,
          }
        })
      end
    else
      sbar.exec("echo 'DEBUG: spaces[" .. i .. "] is nil!' >> /tmp/sketchybar_debug.log")
    end
  end
  
  -- Update icons for the active workspace
  update_workspace_icons(workspace_num)
end

-- Create all 10 workspace indicators (keeping your exact original code)
for i = 1, 10 do
  local space = sbar.add("item", "space." .. i, {
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
      string = " —",
    },
    padding_right = 1,
    padding_left = 1,
    background = {
      color = colors.bg1,
      border_width = 1,
      height = 26,
      border_color = colors.bg2,
    },
  })

  spaces[i] = space

  -- Bracket for double border effect
  local space_bracket = sbar.add("bracket", { space.name }, {
    background = {
      color = colors.transparent,
      border_color = colors.bg2,
      height = 28,
      border_width = 2
    }
  })

  -- Store bracket reference for later updates
  space.bracket = space_bracket

  -- Padding
  sbar.add("item", "space.padding." .. i, {
    drawing = false,
    width = settings.group_paddings,
  })

  -- Mouse click to switch workspace
  space:subscribe("mouse.clicked", function()
    sbar.exec("aerospace workspace " .. i)
  end)
  
  -- Update icons on hover for freshness
  space:subscribe("mouse.entered", function()
    update_workspace_icons(i)
  end)
end

-- DIAGNOSTIC EVENT HANDLER - Let's see what's really happening
sbar.add("item", {
  drawing = false,
  updates = true,
}):subscribe("aerospace_workspace_change", function(env)
  -- Log everything we receive
  sbar.exec("echo 'DEBUG: Received trigger event' >> /tmp/sketchybar_debug.log")
  
  for key, value in pairs(env or {}) do
    sbar.exec("echo 'DEBUG: env." .. key .. " = " .. tostring(value) .. "' >> /tmp/sketchybar_debug.log")
  end
  
  -- Get the focused workspace from the event
  local focused = tonumber(env.FOCUSED_WORKSPACE)
  sbar.exec("echo 'DEBUG: Parsed workspace number: " .. tostring(focused) .. "' >> /tmp/sketchybar_debug.log")
  
  if focused and focused >= 1 and focused <= 10 then
    highlight_workspace(focused)
  else
    sbar.exec("echo 'DEBUG: Invalid or missing workspace number' >> /tmp/sketchybar_debug.log")
  end
end)

-- Update all workspace icons periodically (simple batch update)
local function update_all_icons()
  for i = 1, 10 do
    update_workspace_icons(i)
  end
end

-- Initialize: Get current workspace and update everything once
sbar.exec("aerospace list-workspaces --focused", function(result)
  sbar.exec("echo 'DEBUG: Initial workspace detection: " .. tostring(result) .. "' >> /tmp/sketchybar_debug.log")
  local workspace = tonumber(result)
  if workspace and workspace >= 1 and workspace <= 10 then
    highlight_workspace(workspace)
  end
  
  -- Initial icon update for all workspaces
  update_all_icons()
end)

-- Spaces indicator (keeping your exact original code)
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

spaces_indicator:subscribe("mouse.entered", function()
  sbar.animate("tanh", 30, function()
    spaces_indicator:set({
      background = {
        color = { alpha = 1.0 },
        border_color = { alpha = 1.0 },
      },
      icon = { color = colors.bg1 },
      label = { width = "dynamic" }
    })
  end)
end)

spaces_indicator:subscribe("mouse.exited", function()
  sbar.animate("tanh", 30, function()
    spaces_indicator:set({
      background = {
        color = { alpha = 0.0 },
        border_color = { alpha = 0.0 },
      },
      icon = { color = colors.grey },
      label = { width = 0, }
    })
  end)
end)

spaces_indicator:subscribe("mouse.clicked", function()
  sbar.trigger("swap_menus_and_spaces")
end)

spaces_indicator:subscribe("swap_menus_and_spaces", function()
  local currently_on = spaces_indicator:query().icon.value == icons.switch.on
  spaces_indicator:set({
    icon = currently_on and icons.switch.off or icons.switch.on
  })
end)