{ pkgs, ... }:
let
  markdownlintConfig = pkgs.callPackage ./markdownlint-config.nix { };
in
{
  # Options file for the VS Code markdownlint extension; the user settings point
  # "markdownlint.configFile" at ~/.config/markdownlint/config.jsonc. The whole directory
  # is linked because config.jsonc loads rules/*.cjs relative to itself. Packaged, not
  # linked from the checkout, so the custom rule is tested whenever the profile builds.
  xdg.configFile."markdownlint".source = "${markdownlintConfig}/share/markdownlint";
}
