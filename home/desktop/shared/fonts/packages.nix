{ pkgs }:
let
  # Retain only the face previously supplied by the Noto Symbols cask.
  notoSansSymbols2 = pkgs.runCommand "noto-sans-symbols-2-${pkgs.noto-fonts.version}" { } ''
    install -Dm444 \
      ${pkgs.noto-fonts}/share/fonts/noto/NotoSansSymbols2-Regular.otf \
      "$out/share/fonts/opentype/NotoSansSymbols2-Regular.otf"
  '';
  common = [ pkgs.julia-mono ];
in
{
  linux = common;
  darwin = [
    pkgs.cm_unicode
    pkgs.fira-code
    pkgs.nerd-fonts.caskaydia-cove
    pkgs.nerd-fonts.fira-code
    pkgs.nerd-fonts.hack
    pkgs.nerd-fonts.iosevka
    pkgs.nerd-fonts.jetbrains-mono
    pkgs.nerd-fonts.monaspace
    pkgs.nerd-fonts.symbols-only
  ]
  ++ common
  ++ [
    notoSansSymbols2
    pkgs.symbola
  ];
  homebrew = [
    "font-sf-mono"
    "font-sf-pro"
  ];
}
