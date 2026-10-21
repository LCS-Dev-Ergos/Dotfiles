-- Application name to sketchybar-app-font ligature. Nix installs the map that
-- ships with the pinned font release as helpers/app_icon_map.lua (see
-- default.nix), so every ligature it names exists in the installed font and
-- a font update brings its new applications along. The additions cover
-- applications that release does not know, with ligatures it has.
local icons = require("helpers.app_icon_map")

for name, ligature in pairs({
  -- JetBrains tools without a glyph of their own.
  ["RustRover"] = ":jetbrains_toolbox:",
  ["dotMemory"] = ":jetbrains_toolbox:",
  ["dotTrace"] = ":jetbrains_toolbox:",
  ["Xcodes"]   = ":xcode:",
}) do
  if not icons[name] then icons[name] = ligature end
end

icons["default"] = ":default:"
return icons
