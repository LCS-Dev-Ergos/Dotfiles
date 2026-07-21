{ config, dotfilesRoot, ... }:
{
  # Not using programs.btop.settings: Home Manager's generator writes
  # booleans as Python-style True/False, but btop's own parser expects
  # lowercase true/false (as the original file uses throughout) — silently
  # wrong, not just uncommented. Linking the raw file preserves both the
  # comments and the exact casing btop actually parses.
  programs.btop.enable = true;

  # color_theme is the bare name "tokyo-night", not an absolute path: btop
  # resolves it itself from "../share/btop/themes" relative to its own
  # binary, and pkgs.btop already ships that file there (verified against
  # the Nix store output) — no Homebrew Cellar path to hardcode or
  # substitute at build time.

  # Out-of-store (live, writable) rather than a store-backed copy: btop.conf
  # has save_config_on_exit = true, so btop rewrites this file itself on
  # every exit. A read-only Nix store symlink made that write fail silently
  # every time, discarding whatever was changed in-session (e.g. picking a
  # different theme) as soon as btop was reopened -- the reported bug. Same
  # writable-symlink treatment as zsh/doom/sketchybar/cpp-tools; btop's own
  # writes now land directly in this tracked file, so `git status` will show
  # a diff after a session where something changed, to review/commit at will.
  xdg.configFile."btop/btop.conf".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfilesRoot}/home/btop/btop.conf";
}
