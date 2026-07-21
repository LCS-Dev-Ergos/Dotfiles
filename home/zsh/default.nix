{
  config,
  dotfilesRoot,
  lib,
  pkgs,
  ...
}:
let
  repoZsh = "${dotfilesRoot}/home/zsh";
  outOfStore = path: config.lib.file.mkOutOfStoreSymlink "${repoZsh}/${path}";
in
{
  # Keep file placement independent from programs.zsh. Homebrew still owns the
  # Darwin shell binary, while standalone Home Manager installs it on Linux.
  # Separating config relocation from the Darwin binary swap keeps failures
  # attributable to one change; binary ownership remains an intentionally
  # small follow-up after the configuration survives real sessions.
  #
  # The custom config guards against double compinit (20-zinit.zsh runs it;
  # 85-completions.zsh checks whether initialization already happened).
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
  # This is the improved bootstrap that was already written in the repo but had
  # never actually reached the live ~/.zshenv: it uses static environment
  # values rather than forking `eval "$(brew shellenv)"` for every shell, and
  # guards Homebrew paths so the same bootstrap remains portable to Linux.
  # force is needed because the current ~/.zshenv is intentionally a real,
  # pre-Home-Manager file; otherwise the first activation would collide with it.
  home = {
    packages = lib.optionals pkgs.stdenv.isLinux [ pkgs.zsh ];

    file = {
      ".zshenv" = {
        source = ./zshenv-bootstrap;
        force = true;
      };

      ".zprofile".source = outOfStore "zprofile";
      ".zshrc".source = outOfStore "zshrc";
      ".p10k.zsh".source = outOfStore "p10k.zsh";
    };
  };

  # The whole ${XDG_CONFIG_HOME}/zsh tree (lib/, conf.d/, functions/,
  # tests/, etc.) as one live, writable unit.
  # force replaces the empty real directory left by the old per-file Stow
  # layout: `stow -D` removed its child symlinks but correctly left the parent
  # directory itself, which Home Manager will not silently replace. The result
  # is one authoritative live link for the complete tree.
  xdg.configFile."zsh" = {
    source = outOfStore "config";
    force = true;
  };
}
