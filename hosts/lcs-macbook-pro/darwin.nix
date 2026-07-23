{
  self,
  lib,
  pkgs,
  homeDirectory,
  username,
  ...
}:
let
  user = lib.escapeShellArg username;
in
{
  # The platform this nix-darwin configuration is built for.
  nixpkgs.hostPlatform = "aarch64-darwin";

  # Register the Nix Zsh as a permissible login shell. The module maps the
  # package to /run/current-system/sw/bin/zsh -- a generation-stable path that
  # survives rollbacks and garbage collection -- and keeps every stock macOS
  # shell (including /bin/zsh) in the generated /etc/shells for recovery.
  environment.shells = [ pkgs.zsh ];

  # users.users.<name>.shell is only enforced for accounts listed in
  # users.knownUsers whose declared uid matches the live account; without
  # both, the dscl UserShell write is silently skipped. Listing the account
  # here hands nix-darwin user management for it, so keep this entry and the
  # users.users record together permanently.
  users.knownUsers = [ username ];

  users.users.${username} = {
    name = username;
    home = homeDirectory;
    # Captured from `id -u` on the live system; the activation script skips
    # the shell update if this ever disagrees with the actual account.
    uid = 501;
    shell = pkgs.zsh;
    # programs.zsh stays disabled (darwin/default.nix): it would generate
    # /etc/zshenv, /etc/zprofile, and /etc/zshrc with a competing global
    # compinit. The repository .zshenv already initializes the Nix daemon
    # environment for every shell type, which is what the assertion behind
    # this flag exists to guarantee.
    ignoreShellProgramCheck = true;
  };

  # nix-darwin does not manage the existing macOS account, so it cannot
  # discover the user's home directory on its own. Home Manager's Darwin
  # integration derives home.username/home.homeDirectory from this record;
  # without both this declaration and system.primaryUser those values become
  # null. The host metadata passed from flake.nix is therefore the single
  # source of truth for both options, rather than two independent literals.

  system = {
    # Set Git commit hash for darwin-version.
    configurationRevision = self.rev or self.dirtyRev or null;

    # Pins which nix-darwin module defaults apply, mirroring what
    # home.stateVersion (home/default.nix) does for Home Manager: it is not
    # a macOS version, a nix-darwin release number, or a rollback boundary,
    # only a compatibility marker so upgrading nix-darwin cannot silently
    # change already-deployed system behavior. Read `darwin-rebuild
    # changelog` before changing this value.
    stateVersion = 4;

    # Also tells nix-darwin which existing account should receive per-user
    # defaults. Keep this consistent with users.users.${username} above.
    primaryUser = username;

    # These values were captured from `defaults read` on the live system and
    # confirmed as intentional customizations: Dock, Finder, and trackpad.
    # Other non-stock values found in that audit (dark mode and an auto-hidden
    # menu bar) remain deliberately undeclared because they were not confirmed.
    #
    # The original system.defaults block was disabled on 2026-07-21 because
    # nix-darwin replayed its `defaults write` operations and Dock/Finder
    # restarts on every switch, even when the stored values already matched.
    # This idempotent activation retains declarative drift correction, but only
    # writes changed keys and only restarts the process affected by a change.
    activationScripts.postActivation.text = lib.mkAfter ''
      _dotfiles_user=${user}
      _dotfiles_uid="$(/usr/bin/id -u -- "$_dotfiles_user")"
      _dotfiles_restart_dock=0
      _dotfiles_restart_finder=0

      _dotfiles_as_user() {
        /bin/launchctl asuser "$_dotfiles_uid" \
          /usr/bin/sudo -u "$_dotfiles_user" -- "$@"
      }

      _dotfiles_ensure_default() {
        _dotfiles_domain="$1"
        _dotfiles_key="$2"
        _dotfiles_type="$3"
        _dotfiles_value="$4"
        _dotfiles_expected="$5"
        _dotfiles_process="$6"
        _dotfiles_current="$(_dotfiles_as_user /usr/bin/defaults read \
          "$_dotfiles_domain" "$_dotfiles_key" 2>/dev/null || true)"

        if [ "$_dotfiles_current" != "$_dotfiles_expected" ]; then
          _dotfiles_as_user /usr/bin/defaults write "$_dotfiles_domain" \
            "$_dotfiles_key" "-$_dotfiles_type" "$_dotfiles_value"
          case "$_dotfiles_process" in
            Dock) _dotfiles_restart_dock=1 ;;
            Finder) _dotfiles_restart_finder=1 ;;
          esac
        fi
      }

      _dotfiles_ensure_default com.apple.dock autohide bool true 1 Dock
      _dotfiles_ensure_default com.apple.dock orientation string left left Dock
      _dotfiles_ensure_default com.apple.dock tilesize int 76 76 Dock
      _dotfiles_ensure_default com.apple.dock magnification bool false 0 Dock
      _dotfiles_ensure_default com.apple.dock show-recents bool false 0 Dock
      _dotfiles_ensure_default com.apple.dock expose-group-apps bool true 1 Dock
      _dotfiles_ensure_default com.apple.dock minimize-to-application bool true 1 Dock
      _dotfiles_ensure_default com.apple.dock mru-spaces bool true 1 Dock

      _dotfiles_ensure_default com.apple.finder ShowPathbar bool true 1 Finder
      _dotfiles_ensure_default com.apple.finder ShowStatusBar bool false 0 Finder
      _dotfiles_ensure_default com.apple.finder FXPreferredViewStyle string Nlsv Nlsv Finder

      for _dotfiles_trackpad_domain in \
        com.apple.AppleMultitouchTrackpad \
        com.apple.driver.AppleBluetoothMultitouch.trackpad
      do
        _dotfiles_ensure_default "$_dotfiles_trackpad_domain" Clicking bool true 1 ""
        _dotfiles_ensure_default "$_dotfiles_trackpad_domain" TrackpadRightClick bool true 1 ""
        _dotfiles_ensure_default "$_dotfiles_trackpad_domain" TrackpadThreeFingerDrag bool false 0 ""
      done

      if [ "$_dotfiles_restart_dock" -eq 1 ]; then
        /usr/bin/killall -q -u "$_dotfiles_user" Dock || true
      fi
      if [ "$_dotfiles_restart_finder" -eq 1 ]; then
        /usr/bin/killall -q -u "$_dotfiles_user" Finder || true
      fi

      unset -f _dotfiles_as_user _dotfiles_ensure_default
      unset _dotfiles_user _dotfiles_uid _dotfiles_restart_dock
      unset _dotfiles_restart_finder _dotfiles_trackpad_domain
      unset _dotfiles_domain _dotfiles_key _dotfiles_type _dotfiles_value
      unset _dotfiles_expected _dotfiles_process _dotfiles_current
    '';
  };
}
