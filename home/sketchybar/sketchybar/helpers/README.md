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
for SketchyBar, SF Symbols, SF Mono, and SF Pro as declared in
`darwin/homebrew.nix`; service lifecycle remains with the existing Homebrew
installation. Home Manager owns the media/audio CLI packages. The temporary
nowplaying-cli 2.1 override can be retired once nixpkgs supplies that adapter.
