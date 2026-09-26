# SketchyBar Helper Ownership

The top-level `makefile` builds four native helpers: `menus`, `brew_check`,
`cpu_load`, and `network_load`. Home Manager runs that build in the pinned Nix
environment and places the results at the relative `helpers/**/bin` paths used
by the Lua configuration. Generated binaries remain ignored in the checkout;
manual compilation is useful for development, but is not part of deployment.

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

`brew_check` reads the count every five minutes, independently of hourly
metadata updates. stderr stays in its log; errors are visible in the widget.
`brew_action.sh` signals the helper from inside the terminal after the brew
command finishes. Left click lists updates, right click upgrades, and the
middle button refreshes the count.

The terminal launch passes the quoted helper command as Ghostty's single
`--initial-command=...` option. Positional script paths after `-e` can reach
AppKit's file-opening handler and cause execution prompts and extra windows.
The dedicated instance disables window restoration and exits when its last
window closes; the user's normal Ghostty configuration is unchanged.

Regression checks: `bash home/sketchybar/tests/run.sh` from the repository root.

The `sketchybar-app-font` v2.0.5 asset is fetched by Nix with its reviewed
SHA-256 checksum and declared at `~/Library/Fonts`. Home Manager accepts an
existing byte-identical file and replaces drift. Homebrew remains responsible
for SF Symbols, SF Mono, and SF Pro as declared in `darwin/homebrew.nix`.
Home Manager owns SketchyBar, its launchd service and the media/audio CLI packages.
The temporary
nowplaying-cli 2.1 override can be retired once nixpkgs supplies that adapter.

SketchyBar 2.24.0 has a local patch in `home/sketchybar/display-reconcile.patch`.
Upstream destroys and recreates every bar and item window (206 with two
displays, 0.3 to 0.9 s each) for every display callback and twice per wake,
inside the CoreGraphics callback that WindowServer waits on. A wake with two
external displays produced five such rebuilds. The patch coalesces display
callbacks and wakes into one check 150 ms after the burst, compares the
active displays and their bounds with those the bars were built for, and
rebuilds only when they differ. An unchanged layout keeps its windows and is
refreshed in about 10 ms. For 6 s after a wake, a different layout is treated
as the transient placeholder macOS shows while it reprobes displays. Behind the
lock screen an unchanged layout is left untouched, because the unlock that
follows runs the same check immediately and refreshes it. Each check logs its outcome and
duration to `service.log`. The package tests the routing and decisions at
build time and requires revalidation when the upstream version changes.

The service label is `org.nix-community.home.sketchybar`. It runs the immutable
config directly, writes logs to `$XDG_STATE_HOME/sketchybar/service.log`, and
starts at login. Stop the legacy `homebrew.mxcl.sketchybar` service once before
activating the new service; do not run both. Homebrew's old package is left
installed by `cleanup = "none"` for rollback, but is no longer declared.
Use the normal full Darwin build/switch to deploy subsequent changes.

The initial migration can install the generated user LaunchAgent after a full
system build, without switching unrelated Darwin settings. Its temporary
`$XDG_STATE_HOME/sketchybar/bootstrap-gcroot` protects the service closure until
the next complete Home Manager activation removes that bootstrap root.

The second native patch, `home/sketchybar/window-order.patch`, places the
bar background one window level below the items. This separates the opaque
background from the level in which clicks can raise item windows. Widget levels,
popup levels and the unlock patch retain their existing behavior. An SDK 26.5
control build reproduced the same occlusion, as did the original pilot binary
and direct launchd execution; changing the SDK or launch wrapper did not fix it.
The stock nixpkgs SDK selection is therefore retained.

Runtime check for this horizontal bar, after an app/desktop click followed by
a bar click (exit 0 requires visible item windows with none behind the background):

```sh
clang -fobjc-arc -framework Foundation -framework CoreGraphics \
  home/sketchybar/tests/window_order.m -o /tmp/sketchybar-window-order-check
/tmp/sketchybar-window-order-check
```

This read-only check requires the running GUI session. Build-time unit checks
alone do not validate focus, clicks or the user-visible compositor result.

UX refinements retain the dark palette and native window patches. Secondary
status text uses a brighter muted color; Brew keeps its count next to the icon,
percentages reserve compact space, and popup backgrounds are more opaque. Paused media
keeps its cover and playback controls, while unchanged stopped snapshots and
network rates avoid redundant redraws. Audio popup requests are invalidated
on close so delayed replies cannot recreate stale device rows.
