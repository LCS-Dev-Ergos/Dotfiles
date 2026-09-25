{
  externalSources,
  lib,
  pkgs,
  ...
}:
let
  # `colorscript` isn't packaged in nixpkgs or Homebrew under any name.
  # Upstream's own install path is a hardcoded /opt directory (see its
  # Makefile/colorscript.sh), which doesn't fit a Nix store path, so this
  # vendors just the art and wraps it with a small launcher instead of
  # patching theirs.
  shellColorScriptsData = pkgs.stdenvNoCC.mkDerivation {
    pname = "shell-color-scripts-data";
    version = "unstable-2024-04-28";
    src = externalSources.shellColorScripts;

    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r colorscripts/* $out/
      rm -rf $out/blacklisted
      runHook postInstall
    '';
  };

  shellColorScripts = pkgs.writeShellApplication {
    name = "colorscript";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      dir=${shellColorScriptsData}
      case "''${1:-}" in
        -e | --exec) exec "$dir/''${2:?missing script name}" ;;
        -r | --random | "") exec "$(find "$dir" -maxdepth 1 -type f | shuf -n1)" ;;
        -l | --list) find "$dir" -maxdepth 1 -type f -printf '%f\n' | sort ;;
        *)
          echo "usage: colorscript [-e NAME | -r | -l]" >&2
          exit 64
          ;;
      esac
    '';
  };

  # Locale-pinned so the build survives fixupPhase on macOS 26.6. The stdenv's
  # bash links gettext's libintl, whose setlocale() falls through to
  # CFLocaleCopyPreferredLanguages when no locale is set in the environment.
  # That CFPreferences lookup segfaults under the nixbld build user, which has
  # no preferences container to read, and it takes down the isELF loops in
  # audit-tmpdir and auto-fix-elf-files with it.
  #
  # Nothing about bottom provokes this -- it is simply the one package here
  # with no aarch64-darwin binary in the cache, so it is the one that has to
  # build locally. Pinning the locale keeps libintl on the environment path so
  # it never reaches CoreFoundation at all.
  #
  # This costs us substitution: the override changes the hash, so bottom will
  # keep building locally even after Hydra publishes it. Drop this binding
  # once nixpkgs' bash no longer consults CoreFoundation for locale lookups.
  bottom = pkgs.bottom.overrideAttrs (previous: {
    env = (previous.env or { }) // {
      LC_ALL = "C";
      LANG = "C";
    };
  });
in
{
  # Portable, version-independent command-line tools used across projects.
  # Keeping this baseline in the shared Home Manager configuration gives both
  # hosts the same commands without making project toolchains global.
  home.packages = [
    pkgs._7zz
    pkgs.ansible
    pkgs.ansible-lint
    pkgs.atac
    pkgs.bandwhich
    pkgs.bc
    pkgs.bear
    pkgs.beautysh
    bottom
    pkgs.bun
    pkgs.cbonsai
    pkgs.cmatrix
    shellColorScripts
    pkgs.cppman
    pkgs.csvlens
    pkgs.deadnix
    pkgs.duf
    pkgs.exiftool
    pkgs.fswatch
    pkgs.gh
    pkgs.git-filter-repo
    pkgs.glab
    pkgs.glow
    pkgs.gum
    pkgs.jolt-tui
    pkgs.jq
    pkgs.just
    pkgs.just-lsp
    pkgs.lazydocker
    pkgs.llmfit
    pkgs.nix-du
    pkgs.nix-tree
    pkgs.patch
    pkgs.pipes
    # pdftotext and friends, for the ranger and nnn PDF previews.
    pkgs.poppler-utils
    pkgs.procs
    pkgs.pstree
    pkgs.qpdf
    pkgs.sesh
    pkgs.television
    pkgs.tex-fmt
    pkgs.time
    pkgs.tree
    pkgs.universal-ctags
    pkgs.w3m
    pkgs.wget
  ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    # macOS ships the BSD implementations of these three, and enough of this
    # setup assumes GNU behaviour that they belong on PATH there. Linux gets
    # them from its own base system, so installing them again would only add a
    # second identical copy. opam is the concrete case for tar: it resolves the
    # binary to an absolute path before extracting sources, and Darwin's bsdtar
    # 3.5.3 rejects valid self-hardlink metadata emitted by GitHub archives.
    pkgs.findutils
    pkgs.gnused
    pkgs.gnutar

    # These commands use Darwin frameworks or macOS-only APIs.
    (pkgs.callPackage ./nowplaying-cli.nix { })
    pkgs.switchaudio-osx
  ];

  # fzf, zoxide, eza, and direnv already have full shell integration and
  # aliases hand-written and lazy-loaded in the custom Zsh setup --
  # functions/fzf.zsh, functions/cli-tools.zsh, lib/50-tools.zsh. zsh here
  # never sets programs.zsh.enable, so any enableZshIntegration output from
  # these modules would be generated but never sourced by that setup. Keep
  # them disabled so there is only one integration path, with no dormant
  # generated integration waiting to surface if Zsh management changes later.
  # What each module still does today: install its package via Nix rather
  # than Homebrew (the live PATH already resolves the Nix profile ahead of
  # Homebrew, so this is the version that actually wins).
  programs = {
    fzf = {
      enable = true;
      enableZshIntegration = false;

      # Both fzf and Atuin bind Ctrl-R in Fish/Nushell, the two shells whose
      # integration Home Manager renders here. Atuin is the established history
      # manager throughout this setup, so fzf's history widget steps aside.
      historyWidget = {
        fish.command = "";
        nushell.command = "";
      };
    };

    zoxide = {
      enable = true;
      enableZshIntegration = false;
    };

    eza = {
      enable = true;
      enableZshIntegration = false;
    };

    direnv = {
      enable = true;
      enableZshIntegration = false;

      # Alire (Ada's toolchain manager) exposes gnat/gprbuild only inside a
      # project, via `alr printenv` -- not globally on PATH like ghcup, opam,
      # or elan. An Ada project's .envrc should contain a single line:
      # `use alr`. The `-n -q` flags follow Alire's own documented
      # recommendation (`alr printenv --help`) for scripted use.
      stdlib = ''
        use_alr() {
          eval "$(alr -n -q printenv --unix)"
        }
      '';
    };

    # These modules have no enableZshIntegration option and generate no dormant
    # shell configuration at their defaults; they are package-only here.
    ripgrep.enable = true;
    fd.enable = true;
  };
}
