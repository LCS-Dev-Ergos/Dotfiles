{
  config,
  dotfilesRoot,
  lib,
  pkgs,
  ...
}:
let
  lockSource = ./nvim/lazy-lock.json;
  lockTarget = "${dotfilesRoot}/home/neovim/nvim/lazy-lock.json";
  runtimeLockDirectory = "${config.xdg.stateHome}/nvim";
  runtimeLock = "${runtimeLockDirectory}/lazy-lock.json";

  # Lazy's operational lock lives in writable state. Deliberate repository
  # updates still use an isolated temporary lock and promote it only after Lazy
  # exits successfully and the JSON validates.
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
      runtime_lock=${lib.escapeShellArg runtimeLock}
      checkout_candidate=""
      runtime_candidate=""
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
            '  --check  Verify checkout and runtime state against the active generation.'
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
      if [[ ! -f "$runtime_lock" ]]; then
        printf '%s\n' \
          'nvim-update-lock: the runtime lock is missing; switch the Nix generation first.' \
          >&2
        exit 66
      fi
      if ! cmp -s "$lock_source" "$runtime_lock"; then
        printf '%s\n' \
          'nvim-update-lock: Lazy runtime state differs from the active generation.' \
          'Switch to reset it before performing a deliberate repository update.' \
          >&2
        exit 65
      fi
      if (( check_only )); then
        printf '%s\n' \
          'nvim-update-lock: checkout and runtime state match the active generation.'
        exit 0
      fi

      temporary_directory="$(mktemp -d "''${TMPDIR:-/tmp}/nvim-lock-update.XXXXXX")"
      cleanup() {
        rm -rf "$temporary_directory"
        if [[ -n "$checkout_candidate" ]]; then
          rm -f "$checkout_candidate"
        fi
        if [[ -n "$runtime_candidate" ]]; then
          rm -f "$runtime_candidate"
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

      checkout_candidate="$(mktemp "''${lock_target%/*}/.lazy-lock.json.XXXXXX")"
      runtime_candidate="$(mktemp "''${runtime_lock%/*}/.lazy-lock.json.XXXXXX")"
      install -m 0644 "$working_lock" "$checkout_candidate"
      install -m 0600 "$working_lock" "$runtime_candidate"
      mv -f "$checkout_candidate" "$lock_target"
      checkout_candidate=""
      mv -f "$runtime_candidate" "$runtime_lock"
      runtime_candidate=""
      printf 'Updated %s; review and commit the lockfile, then switch.\n' "$lock_target"
    '';
  };
in
{
  home.packages = [ nvimUpdateLock ];

  # Lazy rewrites its lock after installing missing plugins as well as during
  # explicit updates. Synchronize an operational state copy from the declared
  # lock on every activation, then let normal sessions write only that copy.
  # A direct :Lazy update can no longer hit the Nix store, but the updater's
  # baseline guard detects that drift and requires a switch before promotion.
  home.activation.syncNeovimRuntimeLock = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -d -m 0700 \
      ${lib.escapeShellArg runtimeLockDirectory}
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -m 0600 \
      ${lib.escapeShellArg (toString lockSource)} \
      ${lib.escapeShellArg "${runtimeLock}.new"}
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/mv -f \
      ${lib.escapeShellArg "${runtimeLock}.new"} \
      ${lib.escapeShellArg runtimeLock}
  '';

  # Plugins, Mason tools, caches, ShaDa, sessions, and the operational Lazy
  # lock use Neovim's XDG data/state/cache roots. Configuration remains
  # immutable, while nvim-update-lock is the deliberate repository workflow.
  xdg.configFile."nvim".source = ./nvim;
}
