{
  externalSources,
  pkgs,
  ...
}:
let
  plugins = externalSources.tmuxPlugins;
  pluginTree = pkgs.linkFarm "tmux-plugins" [
    {
      name = "tpm";
      path = plugins.tpm;
    }
    {
      name = "tokyo-night-tmux";
      path = plugins.tokyoNight;
    }
    {
      name = "vim-tmux-navigator";
      path = plugins.vimNavigator;
    }
    {
      name = "tmux-resurrect";
      path = plugins.resurrect;
    }
    {
      name = "tmux-continuum";
      path = plugins.continuum;
    }
    {
      name = "t-smart-tmux-session-manager";
      path = plugins.smartSessionManager;
    }
    {
      name = "tmux-yank";
      path = plugins.yank;
    }
  ];
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
    # but TPM and every plugin are immutable flake inputs assembled into one
    # link farm. Prefix+I/U mutation is deliberately disabled in tmux.conf;
    # updates are explicit flake.lock changes rather than hidden writes to live
    # nested git checkouts.
    #
    # force handles the one-time migration from the old whole-directory
    # out-of-store link. Replacing that parent link is safer than forcing each
    # child: Home Manager unlinks only ~/.config/tmux/plugins, preserving the
    # ignored local checkout it previously pointed at under this repository.
    #
    # macos.conf, statusline.conf, and utility.conf are preserved in the repo,
    # but every tmux.conf source line for them was already commented out. They
    # stay deliberately unmanaged until tmux.conf actively sources them again;
    # this keeps the work/history without creating dead deployment paths.
    "tmux/plugins" = {
      source = pluginTree;
      force = true;
    };
  };
}
