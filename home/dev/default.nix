{
  pkgs,
  runtimeManagerBackend,
  nativeFnmReady,
  ...
}:
{
  # Everything that builds or checks code, in two layers:
  #  - toolchains/: compilers, linkers and debuggers shared by several
  #    languages, with their versions chosen once in cc-toolchain.nix;
  #  - languages/: per-language tools and configuration, one directory each.
  # Runtimes that a version manager owns (rustup, pyenv, opam, ...) are wired
  # into the shell by home/shells/zsh/config/languages/. Native-manager
  # installation intent lives in native-managers.nix; host facts select the
  # backend explicitly so standalone Linux never implies NixOS.
  imports = [
    ./toolchains
    ./languages
  ];
  # Provisioning is an explicit command, independent of shell startup and
  # activation. Mutable manager roots remain native application data.
  home.packages = [
    (pkgs.callPackage ./bootstrap/package.nix { inherit runtimeManagerBackend; })
  ];
  assertions = [
    {
      assertion = builtins.elem runtimeManagerBackend [
        "native"
        "nixpkgs"
      ];
      message = "runtimeManagerBackend must be explicitly set to native or nixpkgs.";
    }
    {
      assertion = builtins.isBool nativeFnmReady;
      message = "nativeFnmReady must be a Boolean host migration checkpoint.";
    }
  ];
  home.sessionVariables = {
    LCS_RUNTIME_MANAGER_BACKEND = runtimeManagerBackend;
    LCS_NATIVE_FNM_READY = if nativeFnmReady then "1" else "0";
  };
}
