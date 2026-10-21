# Optional HyDE Overlay

This directory preserves personal Hyprland settings as an optional overlay on
native HyDE. No current host imports it. The CachyOS profile continues to select
`../hyprland`, with its existing UWSM services and Lua configuration.

## Ownership And Compatibility

The compatibility reference is HyDE master at
[`fa2fd57afc7203b1b5653d3271f3a57ea3873f97`](https://github.com/HyDE-Project/HyDE/tree/fa2fd57afc7203b1b5653d3271f3a57ea3873f97),
reviewed on 2026-10-21. Its
[Hyprland manifest](https://github.com/HyDE-Project/HyDE/blob/fa2fd57afc7203b1b5653d3271f3a57ea3873f97/Scripts/dots/hyprland.toml)
targets Lua-capable Hyprland and preserves the user's `hyprland.lua` while
updating its core under `$XDG_DATA_HOME/hypr`. This is a source compatibility
reference, not a locked runtime installation or evidence of live acceptance.

| Owner | Files |
| --- | --- |
| Native package manager / HyDE installer | Compositor, UWSM, core Lua modules, scripts, themes, lock layouts, shaders, desktop services and native dependencies |
| This Home Manager module | Personal Lua files, idle policy, Pyprland scratchpad and HyDE cursor preferences |
| HyDE runtime | Generated theme, animation and shader state under XDG state/data/cache directories and installer-owned writable configuration |

The module links individual immutable personal files. It never links an entire
writable Hyprland or HyDE directory into the checkout. Upstream theme and shader
writers must not modify these files. `hyprland.lua` resolves adjacent personal
files through the live XDG config directory, including when Home Manager's
entry point is a symlink into the Nix store.

## Preserved Settings

- `personal.lua`: US/Italian keyboard layouts, flat pointer acceleration,
  numlock, natural scrolling disabled, three-finger vertical workspace gestures,
  XWayland scaling, Bibata cursor at size
  20, NVIDIA cursor workaround, libinput gestures and optional keyboard RGB
  startup. The RGB script is external and is run only when present.
- `monitors.lua`: the former external 2560x1440@60 dock layout and internal
  2560x1600@60 panel with scale 1.333333 and 10-bit depth. These are separate
  from the newer standalone profile's panel settings. Recheck connector names
  and display behavior before choosing this alternative.
- `window-rules.lua`: the original per-application opacity values and additional
  floating-window behavior. Generic upstream rules and shortcuts follow the
  maintained HyDE defaults; deprecated script names such as `dontkillsteam`
  are not restored.
- `pyprland.toml`: the dropdown Kitty scratchpad at 75% by 60%, with the
  original maximum size and animation, deployed at `~/.config/pypr/config.toml`.
- `hypridle.conf`: dim after 60 seconds, lock after 120, DPMS after 300, with
  inhibitors respected and lock-before-sleep handling from current HyDE.

The historical battery-only suspend after 900 seconds is retained as reference,
not enabled. The HyDE battery notifier is disabled: its generated state can
restore a suspend command even when the inherited environment overrides it.
Its original thresholds remain in `reference/Preferences.toml` for an explicit
future policy review. System sleep targets, driver workarounds and suspend
services remain operating-system policy until resume is qualified. The former
`GBM_BACKEND=nvidia-drm` override is recorded, not forced on modern drivers.

`reference/Preferences.toml` retains the previous Vertical animation, vibrance
shader, HyDE lock layout, default workflow, Gruvbox-Retro theme and selected
wallpaper, battery settings and previous NVIDIA values. `reference/theme.ctl`
retains the complete theme/wallpaper/editor-theme choices. `reference/monitors.conf`
also preserves the inactive alternative dock layouts. The original lid/dock
helper and battery-only suspend script are kept under `reference/` and are
never deployed or executed. The old shader referenced a file absent from the
tracked tree; use the current upstream shader instead of restoring that path.

## Future Reactivation

1. Review the referenced upstream revision, current release requirements and
   installer manifests. Install or update native HyDE separately. Its installer
   also manages UWSM, shell, GTK/Qt and application files; back up existing files
   and review ownership collisions before running it. Do not let it replace
   the shared shell configuration or configuration owned by other modules.
2. In the Linux host imports, replace `home/desktop/linux/hyprland` with
   `home/desktop/linux/hyde`. Do not import both: the module asserts that the
   standalone profile is absent. HyDE owns the alternative desktop's session
   services; this overlay does not duplicate polkit or clipboard units.
3. Build the selected Home Manager generation before activation. Resolve actual
   file collisions using the host's backup workflow. Activation and native
   installation are separate operations from building this overlay.
4. Restore appearance choices with the current `hyde-shell` selectors for
   animations, shaders, workflows, themes and hyprlock, consulting `--help`.
   The reference files are an inventory, not generated runtime state to copy
   over the new installation. Confirm that themes and wallpapers are installed.
5. Log out before entering the selected HyDE session. Verify monitor layout,
   configuration errors, shortcuts, RGB/gesture dependencies, clipboard,
   polkit, KWallet, portals, theme switching and lock/password unlock. Keep
   suspend disabled until physical resume testing establishes a safe policy.

The overlay does not install HyDE, provision a second active flake output, or
restore the retired HyDE shell hooks. Package and service ownership must be
reviewed again when reactivating it.

## Retired Runtime And Security Fixes

The former `home/desktop/hypr` and `home/desktop/hyprdots` trees are recoverable
from Git history before this migration. Bundled animation/lock/workflow
libraries, duplicated wallbash palettes, generated colors and the old script
runtime are removed. Caelestia is also recoverable from that history.

The retired runtime contained local protections for GPU cache parsing,
wallpaper path handling and Spotify permissions. Those implementations and
their tests are retired together, rather than copied into a different runtime.
This migration does not certify equivalent protections in upstream HyDE;
review its corresponding implementations before future installation. In
particular, never restore shell evaluation of cache data or theme paths, or
permission grants on a shared Spotify installation.

## Offline Checks

Run `python3 home/desktop/linux/hyde/tests/test_overlay.py`. The tests exercise
bootstrap/reload, XDG paths, personal settings, missing-core diagnostics and
startup command quoting with a simulated core. They do not start Hyprland,
execute desktop commands, test authentication or qualify the native runtime.
