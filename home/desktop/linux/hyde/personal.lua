-- =====-----------------------------------------------------------------=====
-- HYDE PERSONAL PREFERENCES
--
-- Input, cursor, gestures and session startup overrides for the optional desktop.
-- Keep the battery notifier disabled until suspend/resume is qualified.
-- =====-----------------------------------------------------------------=====

local home = assert(os.getenv("HOME"))
hyde.config({ ui = { cursor_theme = "Bibata-Modern-Ice", cursor_size = 20 } })
-- Generated HyDE state can restore a suspend command; do not start that notifier.
hyde.config.start.battery_notify = ""
hl.env("XCURSOR_THEME", "Bibata-Modern-Ice")
hl.env("XCURSOR_SIZE", "20")
hl.env("HYPRCURSOR_SIZE", "20")
hl.config({
    input = {
        kb_layout = "us,it", follow_mouse = 1, sensitivity = 0,
        force_no_accel = false, accel_profile = "flat", numlock_by_default = true,
        touchpad = { natural_scroll = false },
    },
    xwayland = { force_zero_scaling = true },
    cursor = { sync_gsettings_theme = false, no_hardware_cursors = 1 },
})
hl.gesture({ fingers = 3, direction = "horizontal", action = "unset" })
hl.gesture({ fingers = 3, direction = "vertical", action = "workspace" })

-- These session variables remain local to the optional compositor.
hl.env("LIBVA_DRIVER_NAME", "nvidia")
hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
-- GBM_BACKEND is retained in reference/Preferences.toml, not forced on modern drivers.

hl.on("hyprland.start", function()
    hl.exec_cmd("gsettings set org.gnome.desktop.interface cursor-size 20")
    hl.exec_cmd("libinput-gestures")
    local rgb = home .. "/Scripts/exec_openrgb.sh"
    local file = io.open(rgb, "r")
    if file then
        file:close()
        hl.exec_cmd("bash '" .. rgb:gsub("'", "'\\''") .. "'")
    end
end)
