{ pkgs, ... }:
{
  imports = [ ./homebrew.nix ];

  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  environment.systemPackages = [ pkgs.vim ];

  # Auto upgrade nix package and the daemon service.
  nix.enable = true;

  # Necessary for using flakes on this system.
  nix.settings.experimental-features = "nix-command flakes";

  # Declarative equivalent of `brew cleanup`: prune old generations and
  # hardlink duplicate store files automatically instead of doing it by
  # hand. 14 days keeps a rollback margin while the migration settles.
  nix.gc.automatic = true;
  nix.gc.options = "--delete-older-than 14d";
  nix.optimise.automatic = true;

  # Zsh is managed by the Stow configuration until its future migration to
  # Home Manager. nix-darwin must not generate /etc/zsh* configuration.
  programs.zsh.enable = false;

  # Captured from `defaults read` against the live system, then confirmed
  # with the user as deliberate customizations (not stock macOS defaults):
  # Dock, Finder, and trackpad. Other non-default values found during that
  # same audit (dark mode, auto-hidden menu bar) were left out since they
  # weren't confirmed as intentional.
  system.defaults.dock = {
    autohide = true;
    orientation = "left";
    tilesize = 76;
    magnification = false;
    show-recents = false;
    expose-group-apps = true;
    minimize-to-application = true;
    mru-spaces = true;
  };

  system.defaults.finder = {
    ShowPathbar = true;
    ShowStatusBar = false;
    FXPreferredViewStyle = "Nlsv";
  };

  system.defaults.trackpad = {
    Clicking = true;
    TrackpadRightClick = true;
    TrackpadThreeFingerDrag = false;
  };

  # Required since we never declared users.users.lcs-dev ourselves:
  # the Home Manager darwin integration reads this to resolve
  # home.homeDirectory / home.username. Without it those default to
  # null, which is exactly the error we just hit.
  system.primaryUser = "lcs-dev";

  # nix-darwin doesn't manage real macOS accounts (they already exist),
  # so it has no way to know this user's home directory unless we
  # state it here. Home Manager's darwin integration derives
  # home.homeDirectory from this value, overriding whatever we set
  # directly in home/default.nix — so this is the actual source of
  # truth, not an optional extra.
  users.users.lcs-dev = {
    name = "lcs-dev";
    home = "/Users/lcs-dev";
  };
}
