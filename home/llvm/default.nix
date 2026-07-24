{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Keep the compiler-driver policy behind one package interface. The package
  # exposes cc/c++/clang/clang++/cpp/ld at a higher profile priority than the
  # generic aliases shipped by the stock Clang and GCC wrappers.
  darwinToolchain = pkgs.callPackage ./package.nix { };
  defaultClang = if pkgs.stdenv.isDarwin then darwinToolchain else pkgs.llvmPackages_22.clang;
  goEnv = "${config.home.homeDirectory}/Library/Application Support/go/env";
in
{
  # System-wide C/C++ toolchain, replacing Homebrew's keg-only LLVM. On Darwin,
  # the stock Nix wrapper targets the Nixpkgs compatibility floor (macOS 14)
  # and SDK 14.4. That is correct inside Nix builds but incompatible with
  # host-native toolchains whose runtime objects target macOS 26. The priority-5
  # driver package preserves LLVM 22 as the default while selecting Nix's SDK
  # 26 for every host-side compiler entry point. The underlying stock Clang
  # remains installed for its binutils and as the wrapped implementation.
  home = {
    packages = lib.optionals pkgs.stdenv.isDarwin [ darwinToolchain ] ++ [
      # CMake consumes ccache through its explicit compiler-launcher variables;
      # no compiler-name masquerade directory belongs in the global PATH.
      pkgs.ccache
      pkgs.llvmPackages_22.clang
      pkgs.llvmPackages_22.clang-tools
      pkgs.llvmPackages_22.lld
      pkgs.llvmPackages_22.lldb
    ];

    # Use immutable compiler paths for consumers that honour CC/CXX, while the
    # priority-5 driver names cover tools (including OCaml) that hard-code `cc`.
    # Home Manager renders these into hm-session-vars for every managed shell.
    sessionVariables = {
      CC = "${defaultClang}/bin/clang";
      CXX = "${defaultClang}/bin/clang++";
    }
    // lib.optionalAttrs pkgs.stdenv.isDarwin {
      # Rust and CMake can pass their own target after CC's defaults. Publish
      # the platform-standard policy as well so every host-native link agrees.
      MACOSX_DEPLOYMENT_TARGET = darwinToolchain.darwinMinVersion;
    };

    # Reconcile only Go's compiler keys after each switch. The file remains
    # writable application state, so `go env -w` can preserve unrelated values
    # such as GOPRIVATE while the next activation restores the compiler policy.
    activation.configureGoCompilers = lib.mkIf pkgs.stdenv.isDarwin (
      lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        go_env=${lib.escapeShellArg goEnv}
        go_env_dir="''${go_env%/*}"

        # The candidate assembly cannot be prefixed with $DRY_RUN_CMD: mktemp
        # and the sed redirection are real filesystem writes either way, and
        # mktemp would fail outright while the directory only "would" exist.
        if [[ -v DRY_RUN ]]; then
          echo "Would reconcile CC/CXX in $go_env"
        else
          ${pkgs.coreutils}/bin/install -d -m 0700 "$go_env_dir"

          go_env_candidate="$(${pkgs.coreutils}/bin/mktemp "$go_env_dir/.env.XXXXXX")"
          if [[ -r "$go_env" ]]; then
            ${pkgs.gnused}/bin/sed \
              -e '/^CC=/d' \
              -e '/^CXX=/d' \
              "$go_env" > "$go_env_candidate"
          fi
          printf '%s\n' \
            'CC=${darwinToolchain}/bin/clang' \
            'CXX=${darwinToolchain}/bin/clang++' \
            >> "$go_env_candidate"
          ${pkgs.coreutils}/bin/chmod 0600 "$go_env_candidate"
          ${pkgs.coreutils}/bin/mv -f "$go_env_candidate" "$go_env"
        fi
      ''
    );
  };
}
