{ ... }:
{
  # config.conf is a bash script neofetch sources directly, no safe Nix
  # parser and no dedicated Home Manager module, so linked raw.
  xdg.configFile."neofetch/config.conf".source = ./config.conf;
}
