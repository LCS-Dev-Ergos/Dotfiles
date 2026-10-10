# Shared runtime identities. Defaults are descriptive, never applied at startup.
# Native manager/package and SDK closures remain separate recovery prerequisites.
let
  baseline = {
    schema = 1;
    defaults = {
      node = "26.11.1";
      python = baseline.python.version;
      ocaml = "5.5.1";
    }
    // builtins.mapAttrs (_: toolchain: toolchain.version) baseline.nativeToolchains;
    # Exact identities. scripts/update-runtime-baseline.py reports newer
    # upstream releases and advances patch releases; ordinary manager updates
    # and selections remain user-owned.
    nativeToolchains = {
      rust.version = "1.99.0";
      haskell = {
        version = "9.14.1";
        cabal = "3.16.1.0";
        # The recommended release of GHCup's default metadata channel, which
        # a fresh GHCup reads; both platforms' bindists ship a server for GHC
        # 9.14.1. A release that only the vanilla channel lists fails there.
        hls = "2.14.0.0";
      };
      lean.version = "4.34.1";
      ruby.version = "4.0.7";
      jvm = {
        version = "21.0.12.1";
        candidate = "21.0.12+1.1-tem";
      };
      # SDKMAN candidates that run on the JDK above; Maven 4 is still an RC.
      kotlin.version = "2.4.21";
      maven.version = "3.10.0";
      gradle.version = "9.8.1";
      # Coursier's `scala` app; it runs on the JDK above.
      scala.version = "3.9.0";
      julia.version = "1.12.7";
      # The current LTS feature band; dotnet-install fetches it by version.
      dotnet.version = "10.0.401";
      # Selected only by `--only conda`. Miniforge3 <version>-<build> ships
      # this conda; its installers in native-managers.nix move together with it.
      conda.version = "26.7.2";
    };
    # Native managers fetch these releases from their own upstreams: FNM from
    # nodejs.org, pyenv's python-build from python.org with the checksums its
    # definitions carry. No artifact is retained in the store.
    node.versions = [
      "24.21.0"
      "26.11.1"
    ];
    python.version = "3.14.8";
    ocaml = {
      versions = [
        "5.4.1"
        "5.5.1"
      ];
    };
  };
in
import ./bootstrap/validate.nix { inherit baseline; }
