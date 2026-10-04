{ pkgs, ... }:
let
  markdownlintConfig = pkgs.callPackage ./markdownlint-config.nix { };
in
{
  # markdownlint rule sets for the VS Code extension, whose user settings point
  # "markdownlint.configFile" at ~/.config/markdownlint/config.jsonc. The whole directory
  # is linked because the options files load rules/*.cjs and extend safe.jsonc relative
  # to themselves. Packaged, not linked from the checkout, so the rules and the mdlint
  # command are tested whenever the profile builds.
  home.packages = [ markdownlintConfig ];
  xdg.configFile."markdownlint".source = "${markdownlintConfig}/share/markdownlint";
}
