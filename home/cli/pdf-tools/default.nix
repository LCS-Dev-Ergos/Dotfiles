{ pkgs, ... }:
{
  # Lossy compression and DjVu conversion use Ghostscript and ddjvu from
  # PATH; the shell's dependency manifest lists both.
  home.packages = [ (pkgs.callPackage ./package.nix { }) ];
}
