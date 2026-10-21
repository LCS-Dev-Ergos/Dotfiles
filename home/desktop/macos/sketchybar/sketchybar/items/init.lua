-- =====-------------------------------------------------------------------=====
-- DESKTOP ITEM COMPOSITION
--
-- Select the Yabai or AeroSpace workspace integration, then load
-- application controls, the clock, status widgets and media items.
-- =====-------------------------------------------------------------------=====

require("items.apple")

local handle = io.popen("pgrep -ix aerospace >/dev/null 2>&1")
local _, _, exit_code = handle:close()

if exit_code == 0 then
  require("items.aerospace.menus")
  require("items.aerospace.spaces")
else
  require("items.menus")
  require("items.spaces")
end

require("items.front_app")
require("items.calendar")
require("items.widgets")
require("items.media")