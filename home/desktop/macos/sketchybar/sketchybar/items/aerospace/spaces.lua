local space_pill = require("helpers.space_pill")

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function valid_workspace(workspace)
  workspace = tostring(workspace or "")
  return workspace:match("^%d+$") and workspace or nil
end

-- Update icons for a specific workspace
local function update_workspace_icons(workspace_name, space_item)
  workspace_name = valid_workspace(workspace_name)
  if not workspace_name then return end

  local cmd = "command -v aerospace >/dev/null 2>&1 && aerospace list-windows --workspace "
    .. shell_quote(workspace_name)
    .. " --json"

  sbar.exec(cmd, function(result)
    if type(result) ~= "table" then return end
    local apps = {}
    for _, window in ipairs(result) do
      if window["app-name"] then apps[window["app-name"]] = true end
    end
    space_item:set({ label = { string = space_pill.icons(apps) } })
  end)
end

-- Only numeric workspaces get a pill; the others are configuration helpers.
local workspaces = {}
local file = io.popen("command -v aerospace >/dev/null 2>&1 && aerospace list-workspaces --all")
local result = file and file:read("*a") or ""
if file then file:close() end
for workspace in result:gmatch("[^\n]+") do
  if workspace:match("^%d+$") then table.insert(workspaces, workspace) end
end

-- aerospace.toml triggers this event; SketchyBar drops events nobody added.
sbar.add("event", "aerospace_workspace_change")

-- Track previous workspace for optimized updates
local previous_workspace = nil

for _, workspace in ipairs(workspaces) do
  local space_item, select = space_pill.add("item", workspace, {})

  space_item:subscribe("mouse.clicked", function()
    sbar.exec("command -v aerospace >/dev/null 2>&1 && aerospace workspace " .. shell_quote(workspace))
  end)

  -- Update icons on hover (manual fallback)
  space_item:subscribe("mouse.entered", function()
    update_workspace_icons(workspace, space_item)
  end)

  -- Only the focused and the previously focused workspace can have changed
  -- their windows, so only those two re-read them (suggested by FelixKratz).
  space_item:subscribe("aerospace_workspace_change", function(env)
    local selected = tostring(env.FOCUSED_WORKSPACE) == workspace
    select(selected)
    if selected then
      update_workspace_icons(workspace, space_item)
      previous_workspace = workspace
    elseif previous_workspace == workspace then
      update_workspace_icons(workspace, space_item)
    end
  end)

  update_workspace_icons(workspace, space_item)
end

-- Highlight the current workspace at startup.
sbar.exec("command -v aerospace >/dev/null 2>&1 && aerospace list-workspaces --focused", function(current_ws)
  local trimmed_ws = type(current_ws) == "string" and current_ws:gsub("%s+", "") or ""
  if trimmed_ws:match("^%d+$") then
    sbar.trigger("aerospace_workspace_change", "FOCUSED_WORKSPACE=" .. trimmed_ws)
  end
end)
