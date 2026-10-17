{
  lib,
  python3,
  stdenvNoCC,
  zsh,
}:
stdenvNoCC.mkDerivation {
  pname = "terminal-style";
  version = "1.0.0";

  # The two implementations and their tests; documentation and Nix glue stay
  # out of the hash, so editing them rebuilds no consumer.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./terminal-style.zsh
      ./terminal_style.py
      ./tests/__init__.py
      ./tests/test_terminal_style.py
      ./tests/test-terminal-style.zsh
    ];
  };

  # stdenv's bash can crash in fixupPhase on Darwin without a locale, which
  # cuts the build-directory audit short without failing the build.
  env.LC_ALL = "C";

  dontBuild = true;
  doCheck = true;
  # The spinner test starts a second zsh by name.
  nativeCheckInputs = [ zsh ];

  checkPhase = ''
    runHook preCheck

    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    # The glyphs are measured as characters only in a UTF-8 locale; the
    # derivation's own C locale would count their bytes.
    LC_ALL=C.UTF-8 zsh tests/test-terminal-style.zsh
    # -B keeps bytecode out of the sources installPhase copies.
    ${lib.getExe python3} -I -B -W error -m unittest discover -s tests -t .

    runHook postCheck
  '';

  # Consumers copy these files into their own runtime; nothing here is run
  # from the package itself.
  installPhase = ''
    runHook preInstall

    install -Dm0644 terminal-style.zsh "$out/share/terminal-style/terminal-style.zsh"
    install -Dm0644 terminal_style.py "$out/share/terminal-style/terminal_style.py"

    runHook postInstall
  '';

  meta = {
    description = "The terminal style shared by the shell tools, for Zsh and Python";
    platforms = lib.platforms.all;
  };
}
