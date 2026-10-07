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
    node = [
      {
        version = "24.21.0";
        hashes = {
          aarch64-darwin = "bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057";
          x86_64-linux = "6e1db87ef58b8819e5d5402eff1536491b18edd8eb7bee5ef7897876e88dc5ff";
        };
      }
      {
        version = "26.10.0";
        hashes = {
          aarch64-darwin = "751fdf7439f115d87ee2a8f3f18c065b6151852068e3e666ac60ac2996f75ac9";
          x86_64-linux = "cb5c9ce9c80d7b8821e3a258543c71b939138cf17c74d5cc44bbe85d6dbc5ad8";
        };
      }
    ];
    python = {
      version = "3.14.7";
      pythonBuildVersion = "2.8.8";
      pythonBuildRevision = "07171d013cac53d1cc9248b4c160217f288a2965";
      pythonBuildHash = "sha256-sgsgifSrYIwFgnWwVIuvRCDExnilSLzogyhU4EFFbrs=";
      sources = [
        {
          name = "Python-3.14.7.tar.xz";
          url = "https://www.python.org/ftp/python/3.14.7/Python-3.14.7.tar.xz";
          sha256 = "3b48dac8fb59f62eaa67ac83c1eb12bda1b7a08406dd286e252c11a66be27f81";
        }
        {
          name = "Python-3.14.7.tar.gz";
          url = "https://www.python.org/ftp/python/3.14.7/Python-3.14.7.tgz";
          sha256 = "62859805f6fdf25e2bcbf3fa3217801e1996887ca33e6a2af80674bdfa2dbe07";
        }
        {
          name = "openssl-4.0.1.tar.gz";
          url = "https://github.com/openssl/openssl/releases/download/openssl-4.0.1/openssl-4.0.1.tar.gz";
          sha256 = "2db3f3a0d6ea4b59e1f094ace2c8cd536dffb87cdc39084c5afa1e6f7f37dd09";
        }
        {
          name = "readline-8.3.tar.gz";
          url = "https://ftpmirror.gnu.org/readline/readline-8.3.tar.gz";
          sha256 = "fe5383204467828cd495ee8d1d3c037a7eba1389c22bc6a041f627976f9061cc";
        }
      ];
    };
    ocaml = {
      versions = [
        "5.4.1"
        "5.5.1"
      ];
    };
  };
in
import ./bootstrap/validate.nix { inherit baseline; }
