{
  lib,
  stdenvNoCC,
  fetchurl,
  gawk,
  makeWrapper,
}:
# shdoc is not in nixpkgs. The upstream release is a single AWK program, so
# the package pins that file (the same bytes scripts/install-shdoc.zsh
# verifies on hosts without Nix) and wraps it with this flake's gawk, which
# keeps the documentation toolchain independent of whatever awk is on PATH.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "shdoc";
  version = "1.4";

  src = fetchurl {
    url = "https://raw.githubusercontent.com/reconquest/shdoc/v${finalAttrs.version}/shdoc";
    hash = "sha256-hWvcYtsV5JcMWfAR6ad51qI+hvTxI3B+JfU5DRTJsZE=";
  };

  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    install -Dm644 "$src" "$out/share/shdoc/shdoc.awk"
    makeWrapper ${lib.getExe gawk} "$out/bin/shdoc" \
      --add-flags "-E $out/share/shdoc/shdoc.awk"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/shdoc" --version | grep -Fq "v${finalAttrs.version}"
    runHook postInstallCheck
  '';

  meta = {
    description = "Documentation generator for shell scripts (bash, zsh)";
    homepage = "https://github.com/reconquest/shdoc";
    license = lib.licenses.mit;
    mainProgram = "shdoc";
    platforms = lib.platforms.unix;
  };
})
