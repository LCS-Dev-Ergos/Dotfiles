-- Input and display preferences for the Lenovo Legion laptop.
-- External outputs keep the preferred mode until checked physically. The
-- internal panel is matched by EDID description, which survives a connector
-- rename when the GPU mode changes. Its mode, bit depth and VRR were chosen
-- physically in HyprMod; Plasma drives the same panel at 165 Hz.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.monitor({
    output = "desc:California Institute of Technology 0x1600",
    mode = "2560x1600@60.01Hz",
    position = "0x0",
    scale = 1.333333,
    bitdepth = 10,
})
hl.config({
    input = { kb_layout = "us,it", kb_options = "grp:alt_shift_toggle" },
    -- Preserve the legacy NVIDIA cursor workaround, without forcing GBM.
    cursor = { no_hardware_cursors = 1 },
    misc = { vrr = 1 },
})
