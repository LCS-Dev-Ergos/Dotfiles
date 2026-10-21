-- =====-----------------------------------------------------------------=====
-- HYDE ENTRY POINT
--
-- Load native HyDE defaults before the personal override layer. Resolve managed
-- configuration through XDG paths and reapply overrides on compositor reload.
-- =====-----------------------------------------------------------------=====

-- Search the live config directory even when Home Manager links into the store.
local home = assert(os.getenv("HOME"), "HOME is required to load the HyDE overlay")
local config = os.getenv("XDG_CONFIG_HOME")
if not config or config == "" then config = home .. "/.config" end
package.path = config .. "/hypr/?.lua;" .. package.path

if not hyde then
    local data = os.getenv("XDG_DATA_HOME")
    if not data or data == "" then data = home .. "/.local/share" end
    local entry = data .. "/hypr/hyde.lua"
    local handle = assert(io.open(entry, "r"), "Install native HyDE before selecting its overlay: " .. entry)
    handle:close()
    dofile(entry)
    -- HyDE loads this file again after its defaults; apply overrides only there.
    return
end

-- dofile reapplies overrides on reload; require would cache them.
dofile(config .. "/hypr/personal.lua")
dofile(config .. "/hypr/personal-monitors.lua")
dofile(config .. "/hypr/personal-window-rules.lua")
