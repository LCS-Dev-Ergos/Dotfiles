{
  callPackage,
  lib,
  makeWrapper,
  python3,
  stdenvNoCC,
  zsh,
}:
let
  python = lib.fileset.fileFilter (file: file.hasExt "py");
  # The reports are drawn in the terminal style every shell tool shares.
  terminalStyle = callPackage ../../shells/terminal-style/package.nix { };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "dev-doctor";
  version = "1.0.0";

  # Only the Python sources; the Nix glue, the README and any bytecode stay
  # out of the hash.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./dev_doctor.py
      ./toolchain.py
      (python ./core)
      (python ./tests)
    ];
  };

  # The package reads this copy; a repository checkout reads the module.
  postPatch = ''
    install -m 0644 ${terminalStyle}/share/terminal-style/terminal_style.py .
  '';

  nativeBuildInputs = [ makeWrapper ];
  # A test evaluates the shell code `toolchain env` prints in a real zsh.
  nativeCheckInputs = [ zsh ];
  # stdenv's bash can crash in fixupPhase on Darwin without a locale, which
  # cuts the build-directory audit short without failing the build.
  env.LC_ALL = "C";

  dontBuild = true;
  doCheck = true;
  doInstallCheck = true;

  checkPhase = ''
    runHook preCheck

    # The tests build their own homes; none of them may reach the real one.
    # -B keeps bytecode out of core/, which installPhase copies.
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ${lib.getExe python3} -I -B -W error -m unittest discover -s tests -t .

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    # Only the entries, their package and the style; tests never enter the
    # import path.
    share="$out/share/dev-doctor"
    mkdir -p "$share"
    cp dev_doctor.py toolchain.py terminal_style.py "$share/"
    cp -r core "$share/"
    # The store is read-only at run time, so the bytecode is compiled here.
    ${lib.getExe python3} -I -m compileall -q "$share/core" "$share/terminal_style.py"
    # -I: the caller's PYTHONPATH and user site-packages never reach the
    # tools' imports. No PATH is added: the checks must see the caller's.
    for tool in dev_doctor toolchain; do
      makeWrapper ${lib.getExe python3} "$out/bin/''${tool//_/-}" \
        --add-flags "-I $share/$tool.py"
    done
    # The name the Zsh implementation had.
    ln -s dev-doctor "$out/bin/devdoctor"

    runHook postInstall
  '';

  installCheckPhase = ''
    runHook preInstallCheck

    # The package version and core.__version__ must agree.
    "$out/bin/dev-doctor" --version | grep -Fx "dev-doctor ${finalAttrs.version}"
    "$out/bin/toolchain" --version | grep -Fx "toolchain ${finalAttrs.version}"

    runHook postInstallCheck
  '';

  meta = {
    description = "Report the development environment's health and select C/C++ compilers";
    mainProgram = "dev-doctor";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
})
