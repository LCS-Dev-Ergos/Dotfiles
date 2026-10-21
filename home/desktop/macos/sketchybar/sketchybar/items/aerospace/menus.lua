-- AeroSpace shares the menu titles; showing the workspaces again re-reads
-- the focused one, because AeroSpace sends no event while they are hidden.
require("items.menus").on_spaces_shown(function()
  sbar.exec("command -v aerospace >/dev/null 2>&1 && aerospace list-workspaces --focused", function(current_ws)
    local trimmed_ws = type(current_ws) == "string" and current_ws:gsub("%s+", "") or ""
    if trimmed_ws:match("^%d+$") then
      sbar.trigger("aerospace_workspace_change", "FOCUSED_WORKSPACE=" .. trimmed_ws)
    end
  end)
end)
