{
  lib,
  stdenvNoCC,
  fetchurl,
}:
# yabai from the LCS-Dev-Ergos fork: upstream plus macOS 27 scripting-addition
# support and payload hardening. The fork's CI builds and signs the release
# with the yabai-lcs-dev certificate; TCC keys the Accessibility grant to that
# certificate, so it survives updates. The binary is installed untouched,
# because any fixup would invalidate the signature.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "yabai";
  version = "7.1.25-lcs.1";

  src = fetchurl {
    url = "https://github.com/LCS-Dev-Ergos/yabai/releases/download/v${finalAttrs.version}/yabai-v${finalAttrs.version}.tar.gz";
    hash = "sha256-yPB9DKFRFIGjT4efWtHAa8d8+xJ6Yi1wqw/95aEN1xI=";
  };

  sourceRoot = "archive";

  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/yabai "$out/bin/yabai"
    install -Dm644 doc/yabai.1 "$out/share/man/man1/yabai.1"
    install -Dm644 -t "$out/share/yabai/examples" examples/yabairc examples/skhdrc
    runHook postInstall
  '';

  meta = {
    description = "Tiling window manager for macOS based on binary space partitioning (LCS-Dev-Ergos fork)";
    homepage = "https://github.com/LCS-Dev-Ergos/yabai";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "yabai";
  };
})
