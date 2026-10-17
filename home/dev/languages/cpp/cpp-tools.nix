{
  callPackage,
  gum,
  lib,
  makeWrapper,
  python3,
  stdenvNoCC,
  zsh,
}:
let
  # The terminal style every shell tool shares; cpp-tools draws with it.
  terminalStyle = callPackage ../../../shells/terminal-style/package.nix { };
in
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

  # The modules look for the shared style next to them first, so the tests
  # and the installed runtime both read this copy.
  postPatch = ''
    install -Dm0644 ${terminalStyle}/share/terminal-style/terminal-style.zsh \
      lib/terminal-style.zsh
  '';

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
    install -Dm0644 lib/terminal-style.zsh "$runtime/lib/terminal-style.zsh"
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
