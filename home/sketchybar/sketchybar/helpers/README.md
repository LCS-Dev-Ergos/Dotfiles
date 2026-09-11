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

Regression checks: `bash home/sketchybar/tests/run.sh` from the repository root.

The `sketchybar-app-font` v2.0.5 asset is fetched by Nix with its reviewed
SHA-256 checksum and declared at `~/Library/Fonts`. Home Manager accepts an
existing byte-identical file and replaces drift. Homebrew remains responsible
for SF Symbols, SF Mono, and SF Pro as declared in `darwin/homebrew.nix`.
Home Manager owns SketchyBar, its launchd service and the media/audio CLI packages.
The temporary
nowplaying-cli 2.1 override can be retired once nixpkgs supplies that adapter.

SketchyBar 2.24.0 has a local patch in `home/sketchybar/unlock.patch`: a screen unlock
refreshes existing windows, while a real wake and display topology changes
retain the upstream reset path. The package checks the actual native event
handler at build time and requires revalidation when the upstream version changes.
The user confirmed that this removed the lock/unlock freeze on macOS 27.

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
