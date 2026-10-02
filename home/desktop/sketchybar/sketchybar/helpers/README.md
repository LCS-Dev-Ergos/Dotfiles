# SketchyBar Helper Ownership

The top-level `makefile` builds the native `menus` helper. Home Manager runs
that build in the pinned Nix environment and places the result at the relative
`helpers/menus/bin` path used by the Lua configuration. Generated binaries
remain ignored in the checkout; manual compilation is useful for development,
but is not part of deployment.

SbarLua and its Lua interpreter are built from the same pinned `sbarlua` input.
The build verifies dynamic module loading and substitutes the interpreter and
module paths into the config. `runtime.lua` contains exact Nix paths for
nowplaying-cli, SwitchAudioSource and Python; these dependencies do not rely
on the service PATH.

`media.py` obtains a bounded snapshot through nowplaying-cli's MediaRemote
adapter. The widget permits one snapshot at a time and polls every three
seconds. Artwork is resized to 32 pixels and cached under
`$XDG_CACHE_HOME/sketchybar/media` (default `~/.cache/sketchybar/media`), keeping
two covers. No state is written into the configuration or Nix store.

StatWell supplies CPU, network rates, battery, and Homebrew events to the bar.
The widgets also call `statwell snapshot --cached-only` and `statwell
refresh`, which StatWell has had since PR #7 (merged into main as 5768225).
The config build runs both commands against an empty runtime directory and
fails if StatWell rejects their arguments, which is how an incompatible pin
would otherwise show up: as a permanent "Connection unavailable" in the
Homebrew menu.
The old event-provider C daemons are removed; Git history retains their
rollback source.
`brew_action.sh` requests a targeted StatWell package refresh after a Brew command.
Left click lists updates, right click upgrades, and the middle button refreshes
the count.

The terminal launch passes the quoted helper command as Ghostty's single
`--initial-command=...` option. Positional script paths after `-e` can reach
AppKit's file-opening handler and cause execution prompts and extra windows.
The dedicated instance disables window restoration and exits when its last
window closes; the user's normal Ghostty configuration is unchanged.

Regression checks: `bash home/desktop/sketchybar/tests/run.sh` from the repository root.

The `sketchybar-app-font` v3.0.5 font and the `icon_map.lua` of the same
release are fetched by Nix with their SHA-256 checksums. macOS ignores a font
that is a symlink into the store, so the font is a package in `home.packages`,
which Home Manager copies into `~/Library/Fonts/HomeManager`. SketchyBar
resolves a font only when it creates an item, and an unknown font shows every
ligature as its name; the launch agent therefore changes with the font,
restarts with it, and waits until that exact file is installed. The map is
installed as `helpers/app_icon_map.lua`, so the Desktop icons follow the
release (Claude, ChatGPT, Codex and some 870 other application names) and
every ligature it names exists in the font; `helpers/app_icons.lua` adds the
few applications the release lacks. The config build checks that the installed
map resolves. Updating the release means updating both hashes in
`default.nix`. Homebrew remains responsible for SF Symbols, SF Mono, and SF
Pro as declared in `darwin/homebrew.nix`.
Home Manager owns SketchyBar, its launchd service and the media/audio CLI packages.
The temporary
nowplaying-cli 2.1 override can be retired once nixpkgs supplies that adapter.

SketchyBar is the signed release of the LCS-Dev-Ergos fork, pinned in
`home/desktop/sketchybar/package.nix`; `scripts/update-sketchybar.sh --check`
reports a newer release and `--apply` rewrites the version and hash. The fork's
CI builds, tests under ASan, UBSan and TSan, fuzzes and signs every release with
the `sketchybar-lcs-dev` certificate, and its `docs/` describe the changes. The
two changes that used to be local patches are summarised here.

Display reconciliation (`fix(display)`): upstream destroys and recreates every bar and item window (206 with two
displays, 0.3 to 0.9 s each) for every display callback and twice per wake,
inside the CoreGraphics callback that WindowServer waits on. A wake with two
external displays produced five such rebuilds. The fork coalesces display
callbacks and wakes into one check 150 ms after the burst, compares the
active displays and their bounds with those the bars were built for, and
rebuilds only when they differ. An unchanged layout keeps its windows and is
refreshed in about 10 ms. For 6 s after a wake, a different layout is treated
as the transient placeholder macOS shows while it reprobes displays. Behind the
lock screen an unchanged layout is left untouched, because the unlock that
follows runs the same check immediately and refreshes it. Each check logs its outcome and
duration to `service.log`.

The service label is `org.nix-community.home.sketchybar`. It runs the immutable
config directly, writes logs to `$XDG_STATE_HOME/sketchybar/service.log`, and
starts at login. The Homebrew formula and its `homebrew.mxcl.sketchybar`
service are neither declared nor installed; do not run both.
Use the normal full Darwin build/switch to deploy subsequent changes.

The initial migration can install the generated user LaunchAgent after a full
system build, without switching unrelated Darwin settings. Its temporary
`$XDG_STATE_HOME/sketchybar/bootstrap-gcroot` protects the service closure until
the next complete Home Manager activation removes that bootstrap root.

Window order (`fix(bar)`): the bar background sits one window level below the
items. This separates the opaque background from the level in which clicks
can raise item windows. Widget and popup levels retain their existing
behavior. An SDK 26.5
control build reproduced the same occlusion, as did the original pilot binary
and direct launchd execution; changing the SDK or launch wrapper did not fix it.
The stock nixpkgs SDK selection is therefore retained.

Runtime check for this horizontal bar, after an app/desktop click followed by
a bar click (exit 0 requires visible item windows with none behind the background):

```sh
curl -fsSL -o /tmp/window_order.m \
  https://raw.githubusercontent.com/LCS-Dev-Ergos/SketchyBar/v2.24.0-lcs.1/tools/window_order.m
clang -fobjc-arc -framework Foundation -framework CoreGraphics \
  /tmp/window_order.m -o /tmp/sketchybar-window-order-check
/tmp/sketchybar-window-order-check
```

This read-only check requires the running GUI session. Build-time unit checks
alone do not validate focus, clicks or the user-visible compositor result.

UX refinements retain the dark palette and the fork's window order. Secondary
status text uses a brighter muted color; Brew keeps its count next to the icon,
percentages reserve compact space, and popup backgrounds are more opaque. Paused media
keeps its cover and playback controls, while unchanged stopped snapshots and
network rates avoid redundant redraws. Audio and network details are prefetched
and cached for 15 seconds; one request is shared by repeated hover events.
Each refresh publishes a complete snapshot in one callback, with a three-second
loading limit. Replies received while closed populate the cache without drawing
rows; wake/network changes invalidate obsolete requests.

Homebrew, volume and network details share `helpers/popup.lua`: hover opens
one menu at a time, and a 150 ms exit delay lets the pointer reach interactive
rows. Global exit closes the menu; delayed replies and clipboard feedback
cannot update a closed or reopened menu. `settings.popup` controls the shared
280-point width, 30-point row height, 13-point text size and symmetric 12-point
insets. Text-only rows are centered; network details use equal key/value cells.
The audio track has additional inner margins for the knob at both endpoints.
Borders, corners,
colors and shadows inherit the common defaults. Brew retains its button
actions; volume retains scrolling, the slider, device selection and the
right-click Sound settings shortcut; network rows retain click-to-copy.

The widget tests exercise these transitions without launching system commands.
`SKETCHYBAR_LIVE_TESTS=1 bash home/desktop/sketchybar/tests/run.sh` also checks
rate and CPU text geometry plus the complete Brew, Wi-Fi and audio popup rows
on the running renderer, including the slider knob at 0% and 100%, with temporary
items. After deployment, verify pointer travel into the audio slider/device
rows and network copy rows on each display; geometry checks alone do not
establish live pointer-event behavior.
