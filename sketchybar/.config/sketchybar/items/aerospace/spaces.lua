local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local app_icons = require("helpers.app_icons")

-- Parse string into table (from FelixKratz)
function parse_string_to_table(s)
  local result = {}
  for line in s:gmatch("([^\n]+)") do
    table.insert(result, line)
  end
  return result
end

-- Simple app icon lookup
local function get_icon_for_app(app_name)
  if not app_name then return nil end
  if app_icons[app_name] then
    return app_icons[app_name]
  end
  return app_icons["default"] or "?"
end

-- Update icons for a specific workspace
local function update_workspace_icons(workspace_name, space_item)
  local cmd = string.format("aerospace list-windows --workspace %s --json", workspace_name)
  
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
    
    -- Update the workspace label
    if space_item then
      space_item:set({ label = { string = icons_str } })
    end
  end)
end

-- Get only numeric workspaces (filter out config items)
local file = io.popen("aerospace list-workspaces --all")
local result = file:read("*a")
file:close()
local all_workspaces = parse_string_to_table(result)

-- Filter only numeric workspaces
local workspaces = {}
for _, workspace in ipairs(all_workspaces) do
  if workspace:match("^%d+$") then  -- Only numeric workspaces
    table.insert(workspaces, workspace)
  end
end

-- Store space references for later use
local space_items = {}

-- Track previous workspace for optimized updates
local previous_workspace = nil

-- Create workspace items dynamically
for i, workspace in ipairs(workspaces) do
  local space = sbar.add("item", "space." .. workspace, {
    icon = {
      font = { family = settings.font.numbers },
      string = workspace,
      padding_left = 15,
      padding_right = 8,
      color = colors.white,
      highlight_color = "#1a1b26", -- Dark text on light background when active
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

  -- Bracket for double border effect
  local space_bracket = sbar.add("bracket", { space.name }, {
    background = {
      color = colors.transparent,
      border_color = colors.bg2,
      height = 28,
      border_width = 2
    }
  })

  -- Store bracket reference
  space.bracket = space_bracket

  -- Padding
  sbar.add("item", "space.padding." .. workspace, {
    drawing = false,
    width = settings.group_paddings,
  })

  -- Store reference for icon updates
  space_items[workspace] = space

  -- Mouse click to switch workspace
  space:subscribe("mouse.clicked", function()
    sbar.exec("aerospace workspace " .. workspace)
  end)
  
  -- Update icons on hover (manual fallback)
  space:subscribe("mouse.entered", function()
    update_workspace_icons(workspace, space)
  end)
end

-- Subscribe to workspace change events for automatic updates
-- This updates only the focused and previous workspace for better performance
for _, workspace in ipairs(workspaces) do
  local space_item = space_items[workspace]
  
  if space_item then
    space_item:subscribe("aerospace_workspace_change", function(env)
      local focused_ws = tostring(env.FOCUSED_WORKSPACE)
      local current_ws = tostring(workspace)
      local selected = (focused_ws == current_ws)
      
      -- Update icon highlight color
      space_item:set({
        icon = {
          color = selected and colors.red or colors.white,
        }
      })
      
      -- Update workspace icons for focused and previous workspace only
      -- This optimization significantly improves performance (suggested by FelixKratz)
      if focused_ws == current_ws then
        -- Update current workspace
        update_workspace_icons(workspace, space_item)
        previous_workspace = workspace
      elseif previous_workspace == current_ws then
        -- Update previous workspace to reflect changes
        update_workspace_icons(workspace, space_item)
      end
    end)
  end
end

-- Initial update of all workspace icons at startup
for _, workspace in ipairs(workspaces) do
  local space_item = space_items[workspace]
  if space_item then
    update_workspace_icons(workspace, space_item)
  end
end

-- Try to highlight current workspace at startup
sbar.exec("aerospace list-workspaces --focused", function(current_ws)
  if current_ws then
    local trimmed_ws = current_ws:gsub("%s+", "")
    if trimmed_ws:match("^%d+$") then
      sbar.trigger("aerospace_workspace_change", "FOCUSED_WORKSPACE=" .. trimmed_ws)
    end
  end
end)

-- Spaces indicator (toggle button)
local spaces_indicator = sbar.add("item", "spaces_indicator", {
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
    color = colors.transparent,
    border_color = colors.transparent,
  }
})

spaces_indicator:subscribe("mouse.entered", function()
  sbar.animate("tanh", 30, function()
    spaces_indicator:set({
      background = {
        color = colors.grey,
        border_color = colors.bg1,
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
        color = colors.transparent,
        border_color = colors.transparent,
      },
      icon = { color = colors.grey },
      label = { width = 0 }
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