{
  config,
  dotfilesRoot,
  pkgs,
  ...
}:
{
  # Not using programs.btop.settings: Home Manager's generator writes
  # booleans as Python-style True/False, but btop's own parser expects
  # lowercase true/false (as the original file uses throughout) — silently
  # wrong, not just uncommented. Linking the raw file preserves both the
  # comments and the exact casing btop actually parses.
  programs.btop.enable = true;

  # Out-of-store (live, writable) rather than a store-backed copy: btop.conf
  # has save_config_on_exit = true, so btop rewrites this file itself on
  # every exit. A read-only Nix store symlink made that write fail silently
  # every time, discarding whatever was changed in-session (e.g. picking a
  # different theme) as soon as btop was reopened -- the reported bug. Same
  # writable-symlink treatment as zsh/doom/sketchybar/cpp-tools; btop's own
  # writes now land directly in this tracked file, so `git status` will show
  # a diff after a session where something changed, to review/commit at will.
  xdg.configFile = {
    "btop/btop.conf".source = config.lib.file.mkOutOfStoreSymlink "${dotfilesRoot}/home/btop/btop.conf";

    # btop discovers bundled themes relative to the invoked executable path.
    # Home Manager exposes btop through a profile symlink, so that lookup does
    # not reach pkgs.btop's share directory and the selector otherwise shows
    # only the built-in Default and TTY themes. Recursively linking the
    # immutable packaged themes into btop's documented user theme directory
    # makes the full collection (including tokyo-night) discoverable without
    # making the writable btop.conf store-backed.
    "btop/themes" = {
      source = "${pkgs.btop}/share/btop/themes";
      recursive = true;
    };
  };
}
