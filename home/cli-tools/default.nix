{ pkgs, ... }:
{
  # Portable, version-independent command-line tools used across projects.
  # Keeping this baseline in the shared Home Manager configuration gives both
  # hosts the same commands without making project toolchains global.
  home.packages = [
    pkgs.bandwhich
    pkgs.bc
    pkgs.bottom
    pkgs.cbonsai
    pkgs.cmatrix
    pkgs.csvlens
    pkgs.deadnix # Flags dead/unused bindings.
    pkgs.duf
    pkgs.fswatch
    pkgs.gh
    pkgs.glab
    pkgs.glow
    pkgs.gum
    pkgs.jq
    pkgs.just
    pkgs.lazydocker
    pkgs.nixd # Language server (completion, goto-def, diagnostics).
    pkgs.nixfmt # Canonical formatter (RFC 166 style).
    pkgs.procs
    pkgs.pstree
    pkgs.shellcheck
    pkgs.statix # Lints anti-patterns (e.g. `with` scope footguns).
    pkgs.television
    pkgs.tree
    pkgs.w3m
    pkgs.wget
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
    };

    # These modules have no enableZshIntegration option and generate no dormant
    # shell configuration at their defaults; they are package-only here.
    ripgrep.enable = true;
    fd.enable = true;
  };
}
