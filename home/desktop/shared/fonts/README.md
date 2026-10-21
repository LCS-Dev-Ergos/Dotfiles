# Shared Font Policy

`packages.nix` is the central inventory for general desktop fonts. It preserves
the existing platform sets: Linux installs JuliaMono through Home Manager;
macOS installs the open font families through nix-darwin and Apple SF Mono/Pro
through Homebrew. Sharing the catalog does not expand either platform's set.

`default.nix` is the Home Manager entry point, imported by `home/common.nix`.
`darwin.nix` is a system module, imported by `darwin/default.nix`; it also owns
the reviewed Symbola license exception and Apple font casks. Do not import the
system module into Home Manager.

SketchyBar's application icon font remains with its matching application icon
map in `../../macos/sketchybar/default.nix`. The font and map form one versioned
component contract. Terminal code point maps remain under `scripts/updates/`.
