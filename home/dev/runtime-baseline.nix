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
    # Exact identities. scripts/updates/update-runtime-baseline.py reports newer
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
      # Alire's crates: gnat_native is the GNAT release, gprbuild its build
      # tool. The crate release is the identity; GNAT reports its GCC's.
      # GCC 16, as the C/C++ toolchain; GNAT 15.1.2's GCC could neither
      # target nor link on macOS 26 and later without extra environment.
      ada = {
        version = "16.1.0";
        gprbuild = "26.0.1";
      };
      # Selected only by `--only android`, with --accept android-sdk-license.
      # version is platform-tools, a floor: sdkmanager serves only its newest.
      # The platform is an API level as sdkmanager names it (android-37.2).
      # tools is the command-line tools release whose sdkmanager the
      # bootstrap runs; 23.0 replaced it with the Android CLI. Its archive in
      # native-managers.nix moves together with it.
      android = {
        version = "37.0.1";
        buildTools = "37.0.0";
        platform = "37.2";
        tools = "22.0";
      };
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
    # Releases the pins above used to declare, each at the same attribute
    # path. `dev-bootstrap prune` removes them where they are still
    # installed; the updater's --apply adds every release it replaces.
    retired = {
      nativeToolchains = {
        julia.version = [ "1.12.6" ];
        lean.version = [ "4.32.0" ];
        ruby.version = [ "4.0.6" ];
        rust.version = [ "1.98.1" ];
      };
      node.versions = [ "26.10.0" ];
      python.version = [ "3.14.7" ];
    };
  };
in
import ./bootstrap/validate.nix { inherit baseline; }
