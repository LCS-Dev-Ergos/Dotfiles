-- Input and display preferences for the Lenovo Legion laptop.
-- No fixed external connector/mode until physically checked on CachyOS.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.monitor({ output = "eDP-1", mode = "preferred", position = "auto", scale = 1.333333 })
hl.config({
    input = { kb_layout = "us,it", kb_options = "grp:alt_shift_toggle" },
    -- Preserve the legacy NVIDIA cursor workaround, without forcing GBM.
    cursor = { no_hardware_cursors = 1 },
})
