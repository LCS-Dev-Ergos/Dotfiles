{
  lib,
  pkgs,
  statwellPackage,
  ...
}:
let
  kittyConfig = pkgs.runCommand "kitty-config" { } ''
    mkdir -p "$out"
    cp -R ${./kitty}/. "$out/"
    chmod u+w "$out/tab_bar.py"
    substituteInPlace "$out/tab_bar.py" \
      --replace-fail '@statwell@' '${lib.getExe statwellPackage}'
  '';
in
{
  # Kitty never writes to its configuration, so both platforms use the
  # standard immutable recursive deployment; edits take effect after a switch
  # and a config reload (ctrl+shift+f5).
  xdg.configFile."kitty" = {
    source = kittyConfig;
    recursive = true;
  };
}
