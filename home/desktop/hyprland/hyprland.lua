-- Native Hyprland 0.56.2. The legacy HyDE tree is intentionally not sourced.
require("legion")

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.config({
    general = {
        gaps_in = 5,
        gaps_out = 10,
        border_size = 2,
        layout = "dwindle",
        col = { active_border = "0xffffffff" },
    },
    decoration = { rounding = 10, blur = { enabled = true, size = 3, passes = 1 } },
    dwindle = { preserve_split = true },
    misc = { disable_hyprland_logo = true, force_default_wallpaper = 0 },
    input = { follow_mouse = 1, touchpad = { natural_scroll = true } },
})
hl.animation({ leaf = "global", enabled = true, speed = 6.0, bezier = "default" })
hl.animation({ leaf = "borderangle", enabled = true, speed = 1.0, bezier = "default" })

hl.on("hyprland.start", function()
    -- UWSM exports the ready display before starting session services.
    hl.exec_cmd("/usr/bin/uwsm finalize HYPRLAND_INSTANCE_SIGNATURE XCURSOR_SIZE HYPRCURSOR_SIZE")
    -- Reuse CachyOS's KWallet provider and Plasma Login PAM hooks. D-Bus
    -- owns this shared provider; never run a competing gnome-keyring daemon.
    hl.exec_cmd("/usr/bin/busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus StartServiceByName su org.kde.secretservicecompat 0")
end)

local function app(key, command)
    hl.bind(key, hl.dsp.exec_cmd("/usr/bin/uwsm app -- " .. command))
end

app("SUPER + T", "/usr/bin/kitty")
app("SUPER + E", "/usr/bin/dolphin")
app("SUPER + B", "/usr/bin/firefox")
app("SUPER + C", "/usr/bin/code")
hl.bind("SUPER + SHIFT + Delete", hl.dsp.exec_cmd("/usr/bin/uwsm stop"))
hl.bind("SUPER + Q", hl.dsp.window.close())
hl.bind("ALT + F4", hl.dsp.window.close())
hl.bind("SUPER + W", hl.dsp.window.float({ action = "toggle" }))
hl.bind("SUPER + J", hl.dsp.layout("togglesplit"))

for _, direction in ipairs({ "left", "right", "up", "down" }) do
    hl.bind("SUPER + " .. direction, hl.dsp.focus({ direction = direction }))
end
for i = 1, 10 do
    local key = i % 10
    hl.bind("SUPER + " .. key, hl.dsp.focus({ workspace = i }))
    hl.bind("SUPER + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end
hl.bind("SUPER + S", hl.dsp.workspace.toggle_special("scratchpad"))
hl.bind("SUPER + SHIFT + S", hl.dsp.window.move({ workspace = "special:scratchpad" }))
hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })

local hardware = {
    XF86AudioRaiseVolume = "/usr/bin/wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+",
    XF86AudioLowerVolume = "/usr/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-",
    XF86AudioMute = "/usr/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle",
    XF86AudioMicMute = "/usr/bin/wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle",
    XF86MonBrightnessUp = "/usr/bin/brightnessctl -e4 -n2 set 5%+",
    XF86MonBrightnessDown = "/usr/bin/brightnessctl -e4 -n2 set 5%-",
    XF86AudioPlay = "/usr/bin/playerctl play-pause",
    XF86AudioNext = "/usr/bin/playerctl next",
    XF86AudioPrev = "/usr/bin/playerctl previous",
}
for key, command in pairs(hardware) do
    hl.bind(key, hl.dsp.exec_cmd(command), { locked = true, repeating = true })
end

-- HyprMod stages GUI changes in hyprland-gui.lua. It appends its own include
-- to this file unless it finds the line below, and that rewrite replaces the
-- managed link with a copy. Port the settings worth keeping into these files,
-- then delete the staging file.
if package.searchpath("hyprland-gui", package.path) then
    require("hyprland-gui")
end
