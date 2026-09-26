{ externalSources, ... }:
{
  programs.alacritty = {
    enable = true;
    # Parsed straight from the existing TOML rather than hand-transcribed.
    # The keyboard.bindings entries contain raw control-character escapes
    # (e.g. STX, ESC) -- verified these round-trip through Nix strings
    # fine, unlike oh-my-posh's NUL byte, which Nix genuinely can't hold.
    settings = builtins.fromTOML (builtins.readFile ./alacritty.toml);
  };

  # The theme import used to target a live vendored checkout. Alacritty does not
  # mutate theme code, so the checkout is now an immutable flake input and
  # flake.lock makes fresh machines reproducible without an in-place `git pull`
  # side channel. The older colors/current.yml from the pre-TOML setup remains
  # tracked for its history, but is deliberately unmanaged because nothing in
  # alacritty.toml references it.
  xdg.configFile."alacritty/themes".source = externalSources.alacrittyTheme;
}
