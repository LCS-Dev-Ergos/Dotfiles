{
  config,
  dotfilesRoot,
  pkgs,
  ...
}:
{
  # Kitty itself does not autosave this configuration, so Darwin keeps the
  # standard immutable recursive deployment. On Linux, however, the Hyprdots
  # wallbash integration creates/replaces theme.conf and Wall-Dcol.conf inside
  # Kitty's config tree. Make that platform's complete tree a live writable
  # link so generated theme state and its source files cannot split apart.
  xdg.configFile."kitty" =
    if pkgs.stdenv.isLinux then
      {
        source = config.lib.file.mkOutOfStoreSymlink "${dotfilesRoot}/home/kitty/kitty";
      }
    else
      {
        source = ./kitty;
        recursive = true;
      };
}
