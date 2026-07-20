{ config, lib, ... }:
let
  repoZsh = "${config.home.homeDirectory}/Dotfiles/home/zsh";
  outOfStore = path: config.lib.file.mkOutOfStoreSymlink "${repoZsh}/${path}";
in
{
  # Config-only: zsh itself stays Homebrew-managed for now (not
  # programs.zsh.enable). Deliberately kept separate from placing these
  # files so a config-relocation mistake and a shell-binary swap can never
  # land in the same change -- if something breaks after switching, it's
  # unambiguous which half caused it. Package ownership is a natural,
  # low-risk follow-up once this has proven stable across real sessions.
  #
  # The double-compinit bug this migration has been warned about is
  # already self-guarded inside the existing config (20-zinit.zsh runs
  # it, 85-completions.zsh explicitly checks "avoid double compinit").
  # Not using programs.zsh's own options at all means Home Manager never
  # generates a second compinit call to conflict with that.
  #
  # Everything below is mkOutOfStoreSymlink (live, writable) rather than a
  # read-only store copy: functions/productivity.zsh's --rebuild flow
  # recompiles .zwc caches back into this same tree, same reasoning as
  # cpp-tools/doom/sketchybar.

  # ~/.zshenv is the one exception: a real (non-symlink) file by design,
  # since it's the very first thing zsh reads for every shell type,
  # before ZDOTDIR is even set -- a dangling symlink here would break
  # every shell invocation, not just interactive ones. Home Manager can't
  # produce a truly independent copy (all its file management is
  # symlink-based), so this uses a store-backed symlink instead of
  # mkOutOfStoreSymlink: durable against the live repo being in a
  # transient git state, at the cost of needing a switch to pick up
  # future edits (same as any other store-copied file in this repo).
  #
  # Content is the improved template (static Homebrew env vars, no
  # `eval "$(brew shellenv)"` fork on every shell) that was already
  # written into the repo but never actually deployed to the live
  # ~/.zshenv -- this migration is what finally applies it.
  # force = true: the live ~/.zshenv today is a real, non-symlink file
  # (by design, per the comment above) that Home Manager has never
  # managed before, so it would otherwise collide on first switch.
  home.file.".zshenv" = {
    source = ./zshenv-bootstrap;
    force = true;
  };

  home.file.".zprofile".source = outOfStore "zprofile";
  home.file.".zshrc".source = outOfStore "zshrc";
  home.file.".p10k.zsh".source = outOfStore "p10k.zsh";

  # The whole ${XDG_CONFIG_HOME}/zsh tree (lib/, conf.d/, functions/,
  # tests/, etc.) as one live, writable unit.
  # force = true: unlike the other entries above (which were live Stow
  # symlinks stow -D cleanly removed), ~/.config/zsh was a real directory
  # under per-file Stow management. Removing its individual file symlinks
  # left the (now-empty) directory itself behind, which Home Manager
  # won't silently replace with its own symlink.
  xdg.configFile."zsh" = {
    source = outOfStore "config";
    force = true;
  };
}
