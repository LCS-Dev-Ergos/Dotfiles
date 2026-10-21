-- =====-----------------------------------------------------------------=====
-- HYDE MONITOR LAYOUT
--
-- Preserve the historical dock and internal-panel configuration. This layout
-- belongs to the optional HyDE profile, independently of standalone Hyprland.
-- =====-----------------------------------------------------------------=====

-- Historical dock layout, independent of the currently selected standalone profile.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.monitor({ output = "DP-1", mode = "2560x1440@60", position = "0x0", scale = 1 })
hl.monitor({ output = "eDP-1", mode = "2560x1600@60", position = "auto", scale = 1.333333, bitdepth = 10 })
