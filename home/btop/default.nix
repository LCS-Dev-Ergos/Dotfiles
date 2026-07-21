{ pkgs, ... }:
{
  # Not using programs.btop.settings: Home Manager's generator writes
  # booleans as Python-style True/False, but btop's own parser expects
  # lowercase true/false (as the original file uses throughout) — silently
  # wrong, not just uncommented. Linking the raw file preserves both the
  # comments and the exact casing btop actually parses.
  programs.btop.enable = true;

  # Store-backed (read-only) deployment, the first migration of the
  # practical-immutability plan. btop.conf sets save_config_on_exit = false,
  # so btop no longer rewrites its own config on exit; the earlier
  # out-of-store symlink existed only to absorb that autosave. Durable
  # changes are made by editing this file and switching; in-app tweaks
  # (theme picker, layout toggles) last for the session only.
  xdg.configFile = {
    "btop/btop.conf".source = ./btop.conf;

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
