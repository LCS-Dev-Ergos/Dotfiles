# Immutable bootstrap inputs and utilities; native managers and builds stay native.
{
  lib,
  fetchurl,
  fetchzip,
  linkFarm,
  makeWrapper,
  stdenvNoCC,
  bash,
  coreutils,
  curl,
  findutils,
  gnugrep,
  gnumake,
  gnupatch,
  gnused,
  gnutar,
  gzip,
  bzip2,
  xz,
  baseline,
}:
let
  system = stdenvNoCC.hostPlatform.system;
  nodeTarget = (import ./platforms.nix).${system};
  validatedBaseline = import ./validate.nix { inherit baseline system; };
  pythonBuildSource = fetchzip {
    name = "development-bootstrap-python-build-source";
    url = "https://codeload.github.com/pyenv/pyenv/tar.gz/${baseline.python.pythonBuildRevision}";
    hash = baseline.python.pythonBuildHash;
    extension = "tar.gz";
  };
in
builtins.seq validatedBaseline {
  node = map (
    release:
    let
      filename = "node-v${release.version}-${nodeTarget}.tar.gz";
    in
    release
    // {
      inherit filename;
      archive = toString (fetchurl {
        name = filename;
        url = "https://nodejs.org/dist/v${release.version}/${filename}";
        sha256 = release.hashes.${system};
      });
    }
  ) baseline.node;
  pythonDefinition = "${pythonBuildSource}/plugins/python-build/share/python-build/${baseline.python.version}";
  pythonCache = linkFarm "development-recovery-python-sources" (
    map (source: {
      inherit (source) name;
      path = fetchurl { inherit (source) url sha256; };
    }) baseline.python.sources
  );
  pythonBuilder = stdenvNoCC.mkDerivation {
    pname = "development-recovery-python-build";
    version = baseline.python.pythonBuildVersion;
    dontUnpack = true;
    nativeBuildInputs = [ makeWrapper ];
    installPhase = ''
      mkdir -p "$out/bin"
      makeWrapper ${lib.getExe bash} "$out/bin/python-build" \
        --add-flags "--noprofile --norc ${pythonBuildSource}/plugins/python-build/bin/python-build" \
        --prefix PATH : ${
          lib.makeBinPath [
            coreutils
            curl
            findutils
            gnugrep
            gnumake
            gnupatch
            gnused
            gnutar
            gzip
            bzip2
            xz
          ]
        }
    '';
  };
}
