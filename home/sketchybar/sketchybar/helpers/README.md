# SketchyBar Helper Ownership

The top-level `makefile` builds four native helpers: `menus`, `brew_check`,
`cpu_load`, and `network_load`. Home Manager runs that build in the pinned Nix
environment and places the results at the relative `helpers/**/bin` paths used
by the Lua configuration. Generated binaries remain ignored in the checkout;
manual compilation is useful for development, but is not part of deployment.

SbarLua is built from the revision pinned as the `sbarlua` flake input and its
store path is substituted into `init.lua` during the same build. The previous
mutable installation under `~/.local/share/sketchybar_lua` is no longer used.

The `sketchybar-app-font` v2.0.5 asset is fetched by Nix with its reviewed
SHA-256 checksum and declared at `~/Library/Fonts`. Home Manager accepts an
existing byte-identical file and replaces drift. Homebrew remains responsible
for SketchyBar, Lua, `switchaudio-osx`, `nowplaying-cli`, SF Symbols, SF Mono,
and SF Pro as declared in `darwin/homebrew.nix`; service lifecycle remains with
the existing Homebrew installation.
