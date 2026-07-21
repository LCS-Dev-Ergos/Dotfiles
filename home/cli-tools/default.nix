{ pkgs, ... }:
{
  # Nix language tooling, available in every shell regardless of which
  # project is open -- no per-project devShell needed just to get an LSP,
  # a formatter, and basic lint/dead-code checks while editing .nix files.
  home.packages = [
    pkgs.nixd # Language server (completion, goto-def, diagnostics).
    pkgs.nixfmt # Canonical formatter (RFC 166 style).
    pkgs.statix # Lints anti-patterns (e.g. `with` scope footguns).
    pkgs.deadnix # Flags dead/unused bindings.
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
