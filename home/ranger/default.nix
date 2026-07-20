{ ... }:
{
  # rc.conf/commands.py/rifle.conf are ranger's own custom formats (Python
  # plugin API, a bespoke command DSL) with no safe Nix parser, so they're
  # linked raw rather than routed through a settings attrset.
  programs.ranger.enable = true;

  xdg.configFile."ranger/rc.conf".source = ./rc.conf;
  xdg.configFile."ranger/commands.py".source = ./commands.py;
  xdg.configFile."ranger/commands_full.py".source = ./commands_full.py;
  xdg.configFile."ranger/rifle.conf".source = ./rifle.conf;
  xdg.configFile."ranger/scope.sh".source = ./scope.sh;
}
