local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local app_icons = require("helpers.app_icons")

local spaces = {}

-- Create workspace indicators statically for workspaces 1-10 (no dynamic calls to AeroSpace)
for i = 1, 10, 1 do
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
  sbar.add("item", "space.padding." .. i, {
    drawing = false,
    width = settings.group_paddings,
  })

  local space_popup = sbar.add("item", {
    position = "popup." .. space.name,
    padding_left = 5,
    padding_right = 0,
    background = {
      drawing = true,
      image = {
        corner_radius = 9,
        scale = 0.2
      }
    }
  })

  -- Subscribe to AeroSpace workspace change event (ONLY reactive, no calls during setup)
  space:subscribe("aerospace_workspace_change", function(env)
    local selected = (tostring(i) == env.FOCUSED_WORKSPACE)
    
    -- Tokyo Night color scheme for highlighting
    local active_bg = "#7aa2f7"         -- Tokyo Night blue
    local inactive_bg = colors.bg1      -- Original background
    local active_border = "#7dcfff"     -- Tokyo Night cyan
    local inactive_border = colors.bg2  -- Original border
    
    space:set({
      icon = { 
        highlight = selected,
        color = selected and colors.bg1 or colors.white,
      },
      label = { 
        highlight = selected,
        color = selected and colors.white or colors.grey,
      },
      background = { 
        color = selected and active_bg or inactive_bg,
        border_color = selected and active_border or inactive_border,
        border_width = selected and 2 or 1,
      }
    })
    
    space_bracket:set({
      background = { 
        border_color = selected and active_border or inactive_border,
        border_width = selected and 3 or 2,
      }
    })
  end)

  -- Mouse click handlers (safe, only execute on user action)
  space:subscribe("mouse.clicked", function(env)
    if env.BUTTON == "other" then
      space_popup:set({ background = { image = "space." .. i } })
      space:set({ popup = { drawing = "toggle" } })
    else
      if env.BUTTON == "right" then
        -- Right click - focus workspace (don't try to close)
        sbar.exec("aerospace workspace " .. i)
      else
        -- Left click - switch to workspace
        sbar.exec("aerospace workspace " .. i)
      end
    end
  end)

  space:subscribe("mouse.exited", function(_)
    space:set({ popup = { drawing = false } })
  end)
end

-- Simplified space indicator and app icon management
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

-- Function to safely update app icons for all workspaces
local function update_workspace_app_icons()
  for i = 1, 10 do
    local space = spaces[i]
    if space then
      -- Get windows in this workspace (safe, non-blocking call)
      local workspace_str = tostring(i)
      local cmd = "timeout 1 aerospace list-windows --workspace " .. workspace_str .. " --format '%{app-name}' 2>/dev/null || echo ''"
      local windows_handle = io.popen(cmd)
      local apps = {}
      local icon_line = ""
      local no_app = true
      
      if windows_handle then
        for app in windows_handle:lines() do
          if app and app ~= "" and app ~= "timeout" then
            no_app = false
            -- Avoid duplicate apps
            if not apps[app] then
              apps[app] = true
              local lookup = app_icons[app]
              local icon = ((lookup == nil) and app_icons["default"] or lookup)
              icon_line = icon_line .. " " .. icon
            end
          end
        end
        windows_handle:close()
      end
      
      if no_app then
        icon_line = " —"
      end
      
      -- Update the space label smoothly
      sbar.animate("tanh", 10, function()
        space:set({ label = icon_line })
      end)
    end
  end
end

-- Create a hidden observer for workspace changes (safe approach)
local space_window_observer = sbar.add("item", {
  drawing = false,
  updates = true,
})

-- Update app icons only when workspace changes (reactive, not continuous)
space_window_observer:subscribe("aerospace_workspace_change", function(env)
  -- Small delay to let AeroSpace settle after workspace change
  sbar.exec("sleep 0.1")
  update_workspace_app_icons()
end)

-- Alternative: Update app icons when explicitly triggered by external events
-- This can be called by AeroSpace callbacks when windows open/close
space_window_observer:subscribe("aerospace_app_icons_update", function(env)
  update_workspace_app_icons()
end)

-- Safe initialization: populate app icons after Sketchybar is fully loaded
-- Use a delayed single call to avoid interference during startup
local function safe_initial_update()
  -- Wait for AeroSpace and Sketchybar to fully initialize
  sbar.exec("sleep 1.5 && sketchybar --trigger aerospace_app_icons_update")
end

-- Initialize app icons on startup (safe, delayed approach)
sbar.add("item", {
  drawing = false,
  updates = false,
  script = "sleep 1.5 && sketchybar --trigger aerospace_app_icons_update",
})

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
        color = { alpha = 1.0 },
        border_color = { alpha = 1.0 },
      },
      icon = { color = colors.bg1 },
      label = { width = "dynamic" }
    })
  end)
end)

spaces_indicator:subscribe("mouse.exited", function(env)
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

spaces_indicator:subscribe("mouse.clicked", function(env)
  sbar.trigger("swap_menus_and_spaces")
end)