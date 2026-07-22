{
  dotfilesRoot,
  lib,
  pkgs,
  ...
}:
let
  lockSource = ./nvim/lazy-lock.json;
  lockTarget = "${dotfilesRoot}/home/neovim/nvim/lazy-lock.json";

  # Lazy normally rewrites lazy-lock.json inside stdpath("config"). Runtime
  # config is immutable, so updates use a temporary lockfile and promote it to
  # the checkout only after Lazy exits successfully and the JSON validates.
  nvimUpdateLock = pkgs.writeShellApplication {
    name = "nvim-update-lock";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.jq
    ];
    text = ''
      lock_source=${lib.escapeShellArg (toString lockSource)}
      lock_target=${lib.escapeShellArg lockTarget}
      candidate=""
      check_only=0

      if (( $# > 1 )); then
        printf '%s\n' 'usage: nvim-update-lock [--check]' >&2
        exit 64
      fi
      case "''${1:-}" in
        "") ;;
        --check) check_only=1 ;;
        --help|-h)
          printf '%s\n' \
            'usage: nvim-update-lock [--check]' \
            '  --check  Verify that the checkout matches the active generation.'
          exit 0
          ;;
        *)
          printf 'nvim-update-lock: unknown option: %s\n' "$1" >&2
          exit 64
          ;;
      esac

      if ! command -v nvim >/dev/null 2>&1; then
        printf '%s\n' 'nvim-update-lock: nvim is not available on PATH' >&2
        exit 127
      fi
      if [[ ! -f "$lock_target" ]]; then
        printf 'nvim-update-lock: checkout lockfile is missing: %s\n' "$lock_target" >&2
        exit 66
      fi
      if ! cmp -s "$lock_source" "$lock_target"; then
        printf '%s\n' \
          'nvim-update-lock: the checkout differs from the active Nix generation.' \
          'Commit or discard that change, switch, and retry from a matching baseline.' \
          >&2
        exit 65
      fi
      if (( check_only )); then
        printf '%s\n' 'nvim-update-lock: checkout matches the active generation.'
        exit 0
      fi

      temporary_directory="$(mktemp -d "''${TMPDIR:-/tmp}/nvim-lock-update.XXXXXX")"
      cleanup() {
        rm -rf "$temporary_directory"
        if [[ -n "$candidate" ]]; then
          rm -f "$candidate"
        fi
      }
      trap cleanup EXIT HUP INT TERM

      original_lock="$temporary_directory/original.json"
      working_lock="$temporary_directory/lazy-lock.json"
      install -m 0644 "$lock_source" "$original_lock"
      install -m 0644 "$lock_source" "$working_lock"
      export NVIM_LAZY_LOCKFILE="$working_lock"

      if ! nvim --headless '+Lazy! update' '+qa'; then
        printf '%s\n' \
          'nvim-update-lock: update failed; restoring live plugins to the active lock.' \
          >&2
        install -m 0644 "$original_lock" "$working_lock"
        if ! nvim --headless '+Lazy! restore' '+qa'; then
          printf '%s\n' \
            'nvim-update-lock: automatic plugin restore also failed; run :Lazy restore.' \
            >&2
        fi
        exit 1
      fi

      if ! jq -e 'type == "object"' "$working_lock" >/dev/null; then
        printf '%s\n' 'nvim-update-lock: Lazy produced an invalid lockfile' >&2
        exit 65
      fi
      if cmp -s "$original_lock" "$working_lock"; then
        printf '%s\n' 'nvim-update-lock: plugin lock is already current.'
        exit 0
      fi

      candidate="$(mktemp "''${lock_target%/*}/.lazy-lock.json.XXXXXX")"
      install -m 0644 "$working_lock" "$candidate"
      mv -f "$candidate" "$lock_target"
      candidate=""
      printf 'Updated %s; review and commit the lockfile, then switch.\n' "$lock_target"
    '';
  };
in
{
  home.packages = [ nvimUpdateLock ];

  # Plugins, Mason tools, caches, ShaDa, and sessions already use Neovim's
  # XDG data/state/cache roots. The only configuration-tree writer was Lazy's
  # lockfile updater, which is redirected explicitly by nvim-update-lock.
  xdg.configFile."nvim".source = ./nvim;
}
