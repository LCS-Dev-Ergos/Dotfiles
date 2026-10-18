{
  config,
  dataRoot,
  pkgs,
  ...
}:
let
  vault = "${config.home.homeDirectory}/Documents/LCS-Vault/Σ/Blog";
in
{
  # `blog` reads where the vault and the Hugo site are from this file; the
  # site lives on the data volume, whose mount point is a host fact.
  home.packages = [ (pkgs.callPackage ./package.nix { }) ];

  xdg.configFile."blog/config.toml".source = (pkgs.formats.toml { }).generate "blog-config.toml" {
    site = "${dataRoot}/Blog/CS-Topics";
    posts = "${vault}/posts";
    images = "${vault}/images";
  };
}
