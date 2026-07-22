{
  gum,
  lib,
  makeWrapper,
  python3,
  stdenvNoCC,
  zsh,
}:
stdenvNoCC.mkDerivation {
  pname = "cpp-tools";
  version = "0.1.0";

  src = ./cpp-tools;
  nativeBuildInputs = [
    gum
    makeWrapper
    python3
    zsh
  ];

  dontBuild = true;
  doCheck = true;

  checkPhase = ''
    runHook preCheck

    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    CP_UI_STYLE=plain ${lib.getExe zsh} tests/run.zsh

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    runtime="$out/share/cpp-tools"
    mkdir -p "$runtime" "$out/bin"
    install -m 0755 competitive.sh cpptools "$runtime/"
    cp -R modules "$runtime/modules"
    install -m 0644 README.md "$runtime/README.md"

    # Use a pinned interpreter for the standalone command. The sourced Zsh
    # functions intentionally continue to discover the user's selected C++
    # toolchain and optional UI programs from the interactive PATH.
    makeWrapper ${lib.getExe zsh} "$out/bin/cpptools" \
      --add-flags "$runtime/cpptools"

    runHook postInstall
  '';

  meta = {
    description = "Competitive-programming project and build workflow for Zsh";
    mainProgram = "cpptools";
    platforms = lib.platforms.unix;
  };
}
