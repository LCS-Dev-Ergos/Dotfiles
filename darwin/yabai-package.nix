{
  lib,
  stdenvNoCC,
  fetchurl,
}:
# yabai from the LCS-Dev-Ergos fork: upstream plus macOS 27 scripting-addition
# support and payload hardening. The fork's CI builds and signs the release
# with the yabai-lcs-dev certificate, which TCC requires of the binary its
# grants belong to; window-manager.nix runs it from a fixed path, because TCC
# keys those grants to the path. yabai-msg, the client on its own, loads none
# of the daemon's frameworks and needs no grant, so it runs from the store; the
# daemon accepts it because it is signed with the same certificate and
# identifier. The binaries are installed untouched, because any fixup would
# invalidate their signatures.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "yabai";
  version = "8.0.0-lcs.4";

  src = fetchurl {
    url = "https://github.com/LCS-Dev-Ergos/yabai/releases/download/v${finalAttrs.version}/yabai-v${finalAttrs.version}.tar.gz";
    hash = "sha256-dpW2/5qPOpifUijGzFmB8lOGCtEnaaTrzrKLQYRgkWU=";
  };

  sourceRoot = "archive";

  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/yabai "$out/bin/yabai"
    install -Dm755 bin/yabai-msg "$out/bin/yabai-msg"
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
