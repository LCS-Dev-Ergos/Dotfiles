# Retire this override when nixpkgs includes the MediaRemote adapter (>= 2.1).
{ nowplaying-cli, fetchurl }:
nowplaying-cli.overrideAttrs {
  version = "2.1.0";
  src = fetchurl {
    url = "https://github.com/kirtan-shah/nowplaying-cli/archive/refs/tags/v2.1.0.tar.gz";
    hash = "sha256-x8I1ZGV79bVZi99Y954RyN/73pCeNk302nw6SaJuN1M=";
  };
  makeFlags = [
    "CXX=clang++"
    "OBJC=clang"
  ];
  installPhase = ''
    runHook preInstall
    make install PREFIX="$out"
    runHook postInstall
  '';
}
