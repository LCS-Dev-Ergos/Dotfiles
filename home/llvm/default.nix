{
  config,
  lib,
  pkgs,
  ...
}:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  # Versions and policy come from the one file every toolchain consumer reads.
  ccToolchain = import ../cc-toolchain.nix pkgs;
  inherit (ccToolchain) llvmPackages;
  # Keep the compiler-driver policy behind one package interface. The package
  # exposes the Clang and GCC drivers, the Apple linker shim and the clang-tools
  # at a higher profile priority than the generic aliases shipped by the stock
  # Clang and GCC wrappers.
  darwinToolchain = pkgs.callPackage ./package.nix {
    inherit ccToolchain;
    inherit (config.home) homeDirectory;
  };
  # The profile path, not a store path: CC and CXX get recorded by whatever
  # configures against them -- rbconfig.rb, CMakeCache.txt, Go's env file --
  # and a store path there stops existing once the garbage collector removes
  # the generation that provided it. The profile always names the current one.
  profileBin = "${config.home.profileDirectory}/bin";
  goEnv = "${config.home.homeDirectory}/Library/Application Support/go/env";
in
{
  # System-wide C/C++ toolchain, replacing Homebrew's keg-only LLVM. On Darwin
  # the stock Nix wrappers target nixpkgs' own SDK and compatibility floor,
  # which is correct inside Nix builds but not for host-native work. The
  # priority-5 driver package keeps LLVM and GCC from Nix while compiling
  # against the host's Apple SDK and linking with Apple's linker. The stock
  # Clang remains installed for its binutils (ar, nm, ranlib, strip, as).
  home = {
    packages =
      lib.optionals isDarwin [
        darwinToolchain
        # cc-toolchain-check refers to the result of the toolchain's check,
        # so installing it makes every system build run that check on the
        # host first: a toolchain that fails it is never deployed. Later it
        # tells whether the verification still holds after an Xcode, SDK or
        # macOS update, which Nix cannot see.
        darwinToolchain.check
      ]
      ++ [
        # CMake consumes ccache through its explicit compiler-launcher
        # variables; no compiler-name masquerade directory belongs in PATH.
        pkgs.ccache
        llvmPackages.clang
        llvmPackages.lld
        llvmPackages.lldb
      ]
      # On Darwin the driver package ships clang-tools itself, run against the
      # host SDK instead of the stock wrappers' nixpkgs headers.
      ++ lib.optionals (!isDarwin) [ llvmPackages.clang-tools ];

    sessionVariables = {
      CC = "${profileBin}/clang";
      CXX = "${profileBin}/clang++";
    }
    // lib.optionalAttrs isDarwin {
      # Rust and CMake can pass their own target after CC's defaults. Publish
      # the platform-standard policy as well so every host-native link agrees.
      MACOSX_DEPLOYMENT_TARGET = ccToolchain.darwinDeploymentTarget;
    };

    # Binaries link the Clang sanitizer and GCC runtimes through this stable
    # directory (see runtimeRelativeDir in package.nix), so each activation
    # must repoint it at the generation that is current.
    file = lib.optionalAttrs isDarwin {
      ${darwinToolchain.runtimeRelativeDir}.source = "${darwinToolchain}/runtime";
    };

    # Reconcile only Go's compiler keys after each switch. The file remains
    # writable application state, so `go env -w` can preserve unrelated values
    # such as GOPRIVATE while the next activation restores the compiler policy.
    activation.configureGoCompilers = lib.mkIf isDarwin (
      lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        go_env=${lib.escapeShellArg goEnv}
        go_env_dir="''${go_env%/*}"

        # Branching on DRY_RUN is the supported idiom ($DRY_RUN_CMD is
        # deprecated upstream), and a per-command prefix could not express this
        # anyway: mktemp and the sed redirection are real filesystem writes
        # either way, and mktemp would fail outright while the directory only
        # "would" exist.
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
            ${lib.escapeShellArg "CC=${profileBin}/clang"} \
            ${lib.escapeShellArg "CXX=${profileBin}/clang++"} \
            >> "$go_env_candidate"
          ${pkgs.coreutils}/bin/chmod 0600 "$go_env_candidate"
          ${pkgs.coreutils}/bin/mv -f "$go_env_candidate" "$go_env"
        fi
      ''
    );
  };
}
