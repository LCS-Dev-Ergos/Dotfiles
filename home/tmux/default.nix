{
  externalSources,
  pkgs,
  ...
}:
let
  plugins = externalSources.tmuxPlugins;
in
{
  # Not using programs.tmux.extraConfig: Home Manager's tmux module always
  # prepends its own opinionated defaults (e.g. clock-mode-style) ahead of
  # extraConfig. Most get correctly overridden by this file's own later
  # directives, but not all -- an unverified, order-dependent difference.
  # Installing the package directly and linking the raw file avoids that.
  home.packages = [ pkgs.tmux ];

  xdg.configFile = {
    "tmux/tmux.conf".source = ./tmux.conf;

    # TPM remains the active loader (`run .../plugins/tpm/tpm` in tmux.conf),
    # but TPM and every plugin are immutable flake inputs. Prefix+I/U mutation
    # is deliberately disabled in tmux.conf; updates are explicit flake.lock
    # changes rather than hidden writes to live nested git checkouts.
    #
    # macos.conf, statusline.conf, and utility.conf are preserved in the repo,
    # but every tmux.conf source line for them was already commented out. They
    # stay deliberately unmanaged until tmux.conf actively sources them again;
    # this keeps the work/history without creating dead deployment paths.
    "tmux/plugins/tpm".source = plugins.tpm;
    "tmux/plugins/tokyo-night-tmux".source = plugins.tokyoNight;
    "tmux/plugins/vim-tmux-navigator".source = plugins.vimNavigator;
    "tmux/plugins/tmux-resurrect".source = plugins.resurrect;
    "tmux/plugins/tmux-continuum".source = plugins.continuum;
    "tmux/plugins/t-smart-tmux-session-manager".source = plugins.smartSessionManager;
    "tmux/plugins/tmux-yank".source = plugins.yank;
  };
}
