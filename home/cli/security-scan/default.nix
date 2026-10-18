{ pkgs, ... }:
{
  # Structural checks and YARA are bundled; ClamAV is used when the host
  # provides clamscan and a signature database (Homebrew on macOS).
  home.packages = [ (pkgs.callPackage ./package.nix { }) ];
}
