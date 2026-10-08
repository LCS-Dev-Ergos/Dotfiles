# Shared runtime identities. Defaults are descriptive, never applied at startup.
# Native manager/package and SDK closures remain separate recovery prerequisites.
let
  baseline = {
    schema = 1;
    defaults = {
      node = "26.10.0";
      python = baseline.python.version;
      ocaml = "5.5.1";
    }
    // builtins.mapAttrs (_: toolchain: toolchain.version) baseline.nativeToolchains;
    # Exact initial identities, observed on the native host on 2026-10-07.
    # Ordinary manager updates and selections remain user-owned afterwards.
    nativeToolchains = {
      rust.version = "1.98.1";
      haskell = {
        version = "9.14.1";
        cabal = "3.16.1.0";
      };
      lean.version = "4.32.0";
      ruby.version = "4.0.6";
      jvm = {
        version = "21.0.12.1";
        candidate = "21.0.12+1.1-tem";
      };
      julia.version = "1.12.6";
    };
    # Native managers fetch these releases from their own upstreams: FNM from
    # nodejs.org, pyenv's python-build from python.org with the checksums its
    # definitions carry. No artifact is retained in the store.
    node.versions = [
      "24.21.0"
      "26.10.0"
    ];
    python.version = "3.14.7";
    ocaml = {
      versions = [
        "5.4.1"
        "5.5.1"
      ];
    };
  };
in
import ./bootstrap/validate.nix { inherit baseline; }
