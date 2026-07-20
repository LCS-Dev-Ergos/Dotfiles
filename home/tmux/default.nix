{ pkgs, config, ... }:
{
  # Not using programs.tmux.extraConfig: Home Manager's tmux module always
  # prepends its own opinionated defaults (e.g. clock-mode-style) ahead of
  # extraConfig. Most get correctly overridden by this file's own later
  # directives, but not all -- an unverified, order-dependent difference.
  # Installing the package directly and linking the raw file avoids that.
  home.packages = [ pkgs.tmux ];

  xdg.configFile."tmux/tmux.conf".source = ./tmux.conf;

  # macos.conf/statusline.conf/utility.conf are currently dormant --
  # tmux.conf's own "source ~/.tmux/..." lines for them are commented out
  # -- but preserved at their expected relative path in case they're
  # re-enabled later.
  xdg.configFile."tmux/macos.conf".source = ./macos.conf;
  xdg.configFile."tmux/statusline.conf".source = ./statusline.conf;
  xdg.configFile."tmux/utility.conf".source = ./utility.conf;

  # TPM and its plugins (tmux.conf's `run '~/.config/tmux/plugins/tpm/tpm'`
  # is active) are live git checkouts that TPM itself clones/updates via
  # prefix+I / prefix+U. Kept writable via mkOutOfStoreSymlink rather than
  # folded into the read-only Nix store, same treatment as bat's vendored
  # syntax checkout.
  xdg.configFile."tmux/plugins".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/Dotfiles/home/tmux/plugins";
}
