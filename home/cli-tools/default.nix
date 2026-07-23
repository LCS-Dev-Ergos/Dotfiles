{ lib, pkgs, ... }:
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
    pkgs.bottom
    pkgs.bun
    pkgs.cbonsai
    pkgs.cmatrix
    pkgs.codex
    pkgs.cppman
    pkgs.csvlens
    pkgs.deadnix
    pkgs.duf
    pkgs.exiftool
    pkgs.findutils
    pkgs.fswatch
    pkgs.gh
    pkgs.git-filter-repo
    pkgs.glab
    pkgs.glow
    pkgs.gnused
    pkgs.gum
    pkgs.jolt-tui
    pkgs.jq
    pkgs.just
    pkgs.just-lsp
    pkgs.lazydocker
    pkgs.llmfit
    pkgs.nix-du
    pkgs.nix-tree
    pkgs.nixd
    pkgs.nixfmt
    # Stable non-interactive fallback; an active FNM multishell remains
    # higher-priority for projects that deliberately select another Node.
    pkgs.nodejs_24
    pkgs.opencode
    pkgs.patch
    pkgs.pipes
    pkgs.procs
    pkgs.pstree
    pkgs.qpdf
    pkgs.ruff
    pkgs.sesh
    pkgs.shellcheck
    pkgs.statix
    pkgs.television
    pkgs.tex-fmt
    pkgs.time
    pkgs.tree
    pkgs.universal-ctags
    pkgs.uv
    pkgs.w3m
    pkgs.wget
  ]
  ++ lib.optionals pkgs.stdenv.isDarwin [
    # These commands use Darwin frameworks or macOS-only APIs.
    pkgs.nowplaying-cli
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
