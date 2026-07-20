{ config, ... }:
{
  programs.alacritty = {
    enable = true;
    # Parsed straight from the existing TOML rather than hand-transcribed.
    # The keyboard.bindings entries contain raw control-character escapes
    # (e.g. STX, ESC) -- verified these round-trip through Nix strings
    # fine, unlike oh-my-posh's NUL byte, which Nix genuinely can't hold.
    settings = builtins.fromTOML (builtins.readFile ./alacritty.toml);
  };

  # colors/current.yml isn't referenced anywhere in alacritty.toml (which
  # uses the vendored theme import instead) -- looks like leftover
  # content from before the TOML/theme-import setup was adopted, but
  # preserved as-is rather than assumed dead.
  xdg.configFile."alacritty/colors/current.yml".source = ./colors/current.yml;

  # The vendored alacritty-theme checkout (referenced by alacritty.toml's
  # `import`) is a live git checkout, same treatment as bat's vendored
  # syntax and tmux's plugins: kept writable via mkOutOfStoreSymlink.
  xdg.configFile."alacritty/themes".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/Dotfiles/home/alacritty/themes";
}
