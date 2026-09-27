{
  lib,
  stdenvNoCC,
  fetchurl,
}:
# SketchyBar from the LCS-Dev-Ergos fork: upstream plus display reconciliation,
# the bar background one window level below its items, and message, script
# and IPC hardening, each tested in the fork's CI. The CI builds and signs the
# release with the sketchybar-lcs-dev certificate, so the signature stays the
# same across updates. The binary is installed untouched, because any fixup
# would invalidate the signature.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "sketchybar";
  version = "2.24.0-lcs.2";

  src = fetchurl {
    url = "https://github.com/LCS-Dev-Ergos/SketchyBar/releases/download/v${finalAttrs.version}/sketchybar-v${finalAttrs.version}.tar.gz";
    hash = "sha256-eQd9twYpJlr0m7SOQP/YxfrTFcXEe/yx9h4uEAYpCEw=";
  };

  sourceRoot = "archive";

  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/sketchybar "$out/bin/sketchybar"
    install -Dm644 LICENSE.md "$out/share/doc/sketchybar/LICENSE.md"
    runHook postInstall
  '';

  meta = {
    description = "Highly customizable macOS status bar replacement (LCS-Dev-Ergos fork)";
    homepage = "https://github.com/LCS-Dev-Ergos/SketchyBar";
    license = lib.licenses.gpl3;
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "sketchybar";
  };
})
