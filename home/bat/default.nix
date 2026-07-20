{ config, ... }:
{
  programs.bat = {
    enable = true;
    # Registers the theme under the name "tokyonight_night", matching the
    # existing file name so anything already using --theme=tokyonight_night
    # (e.g. a BAT_THEME env var set from the still-Stow-managed zsh config)
    # keeps working unchanged. Home Manager runs `bat cache --build` for us.
    themes.tokyonight_night = {
      src = ./themes;
      file = "tokyonight_night.tmTheme";
    };
  };

  # Vendored from https://github.com/victor-gp/cmd-help-sublime-syntax as a
  # live git checkout, same treatment as tmux's plugins/ and alacritty's
  # themes/ (see .gitignore): kept writable via mkOutOfStoreSymlink so
  # `git pull` inside it keeps working, rather than folded into the Nix
  # store as a one-off copy. `bat cache --build` (run above for the theme)
  # picks up any .sublime-syntax files found under here too.
  xdg.configFile."bat/syntaxes/cmd-help-sublime-syntax".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/Dotfiles/home/bat/syntaxes/cmd-help-sublime-syntax";
}
