{ lib, pkgs, ... }:
let
  # Credentials for AI and developer tools, keyed by the environment variable
  # that carries each one. `ref` is the 1Password reference; `shape` is the value's
  # expected form, checked before anything is handed out. Every shape must
  # stay within [A-Za-z0-9._-]: the helper embeds values in JSON and HTTP
  # headers verbatim, and it re-checks that set on top of the shape.
  secrets = {
    GITHUB_PAT = {
      ref = "op://Personal/GITHUB_PAT/credential";
      shape = "^(ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]+$";
    };
    CONTEXT7_API_KEY = {
      ref = "op://Personal/CONTEXT7_API_KEY/credential";
      shape = "^ctx7sk-[A-Za-z0-9-]+$";
    };
    GEMINI_API_KEY = {
      ref = "op://Personal/Gemini API Key/credential";
      shape = "^AIza[A-Za-z0-9_-]+$";
    };
    # A JWT: three base64url segments.
    KILO_API_KEY = {
      ref = "op://Personal/Kilo API Key/credential";
      shape = "^[A-Za-z0-9_-]+[.][A-Za-z0-9_-]+[.][A-Za-z0-9_-]+$";
    };
    # SonarQube MCP server in VS Code (mcp.json), started through
    # `ai-secret exec SONARQUBE_TOKEN -- docker run -e SONARQUBE_TOKEN ...`.
    SONARQUBE_TOKEN = {
      ref = "op://Personal/SonarQube Token/credential";
      shape = "^(sq[apu]_)?[0-9a-f]{40}$";
    };
  };

  # Remote MCP servers whose Claude Code entry (~/.claude.json, user scope)
  # names `ai-secret headers <server>` as its headersHelper. Registering one:
  #   claude mcp add-json --scope user <server> '{"type":"http",
  #     "url":"<url>","headersHelper":"<profile>/bin/ai-secret headers <server>"}'
  # where <profile> is /etc/profiles/per-user/$USER on nix-darwin and
  # ~/.nix-profile on standalone Home Manager.
  mcpHeaders = {
    github = {
      secret = "GITHUB_PAT";
      header = "Authorization";
      scheme = "Bearer";
    };
    context7 = {
      secret = "CONTEXT7_API_KEY";
      header = "CONTEXT7_API_KEY";
      scheme = null;
    };
  };

  # Names and header parts are spliced into shell and JSON unquoted, so they
  # are restricted at evaluation time rather than trusted.
  checked =
    let
      bad =
        lib.filter (name: builtins.match "[A-Z][A-Z0-9_]*" name == null) (lib.attrNames secrets)
        ++ lib.concatLists (
          lib.mapAttrsToList (
            server: h:
            lib.optional (builtins.match "[a-z][a-z0-9-]*" server == null) server
            ++ lib.optional (!(secrets ? ${h.secret})) "${server}.secret"
            ++ lib.optional (builtins.match "[A-Za-z][A-Za-z0-9_-]*" h.header == null) "${server}.header"
            ++ lib.optional (h.scheme != null && builtins.match "[A-Za-z]+" h.scheme == null) "${server}.scheme"
          ) mcpHeaders
        );
    in
    lib.assertMsg (bad == [ ]) "ai-secrets: invalid entries: ${lib.concatStringsSep ", " bad}";

  secretCases = lib.concatStrings (
    lib.mapAttrsToList (name: s: ''
      ${name})
        ref=${lib.escapeShellArg s.ref}
        shape=${lib.escapeShellArg s.shape}
        ;;
    '') secrets
  );

  serverCases = lib.concatStrings (
    lib.mapAttrsToList (
      server: h:
      let
        prefix = lib.optionalString (h.scheme != null) "${h.scheme} ";
      in
      ''
        ${server})
          secret=${h.secret}
          format=${lib.escapeShellArg "{\"${h.header}\":\"${prefix}%s\"}\\n"}
          ;;
      ''
    ) mcpHeaders
  );

  # The value is printed with the printf builtin, so it never appears in a
  # process argument list. `op` stays outside runtimeInputs on purpose:
  # 1Password's desktop-app integration only trusts its own signed install,
  # which a GUI-launched process may not have on PATH either.
  #
  # The primary source is the 1Password Environment "AI-Secrets", mounted by
  # the desktop app as a named pipe (Developer > Environments > Destinations >
  # Local .env file) at $XDG_STATE_HOME/ai-secrets/secrets.env. Its variable
  # names are the keys of `secrets` above; `ref` is the fallback.
  aiSecret = pkgs.writeShellApplication {
    name = "ai-secret";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.flock
    ];
    text = ''
      usage() {
        printf '%s\n' \
          'usage: ai-secret get <NAME>        print a credential' \
          '       ai-secret ref <NAME>        print its 1Password reference' \
          '       ai-secret headers <server>  print MCP request headers as JSON' \
          '       ai-secret exec <NAME>... -- <command> [args]' \
          '                                   run a command with credentials exported' \
          '       ai-secret warm              ask 1Password for access to the Environment' \
          '       ai-secret list              list credentials and servers' \
          >&2
        exit 64
      }

      # Sets ref and shape for a credential name.
      lookup_secret() {
        case "$1" in
        ${secretCases}
        *)
          printf 'ai-secret: unknown credential: %s\n' "$1" >&2
          exit 64
          ;;
        esac
      }

      # Where credentials come from, in order: an exported variable of the same
      # name; the 1Password Environment, which the desktop app serves through
      # the named pipe `env_file` (one authorization covers every process until
      # 1Password locks); `op read`, whose authorization is per process tree and
      # so prompts once for each application that starts helpers.
      #
      # The pipe serves one reader at a time, and helpers start together (one
      # per MCP server, per application), so the readers take turns on an flock
      # on fd 9. The kernel drops that lock when its holder dies, and no step
      # below waits without a bound:
      #   - the lock wait outlasts the longest holder and then goes ahead unlocked;
      #   - a pipe read or `op` call is cut off after env_timeout/op_timeout;
      #   - after a pipe read times out, the next env_skip seconds go straight
      #     to `op`, so a dead mount costs one wait, not one per helper;
      #   - waits run as background jobs so SIGTERM (Claude Code ends a slow
      #     helper) interrupts them, and the EXIT trap then cleans up.
      # Children close fd 9, so a leftover reader never keeps the lock alive.
      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/ai-secrets"
      env_file="''${AI_SECRET_ENV_FILE:-$state_dir/secrets.env}"
      env_timeout="''${AI_SECRET_ENV_TIMEOUT:-60}"
      # A zero would disable the limit; anything but 1-999 seconds is ignored.
      [[ "$env_timeout" =~ ^[1-9][0-9]{0,2}$ ]] || env_timeout=60
      op_timeout=120
      env_skip=300
      skip_marker="$state_dir/env-file.skip"
      have_lock=0
      child_pid=""
      env_loaded=0
      env_lines=()
      captured=()

      cleanup() {
        if [[ -n "$child_pid" ]]; then
          kill "$child_pid" 2>/dev/null || true
        fi
        exec 9>&-
      }
      trap cleanup EXIT
      trap 'exit 129' HUP
      trap 'exit 130' INT
      trap 'exit 143' TERM

      # Creates the state directory for our own use only. Returns 1 when it
      # cannot be made private, which callers treat as "no lock, no marker"
      # instead of writing into a directory somebody else controls.
      ensure_state_dir() {
        (umask 077 && mkdir -p "$state_dir") 2>/dev/null || return 1
        [[ -d "$state_dir" && ! -L "$state_dir" && -O "$state_dir" && -w "$state_dir" ]] || return 1
        chmod go-rwx "$state_dir" 2>/dev/null
      }

      acquire_lock() {
        (( have_lock )) && return 0
        ensure_state_dir || return 0
        [[ ! -L "$state_dir/op.lock" ]] || return 0
        exec 9>"$state_dir/op.lock"
        flock -w $(( env_timeout + op_timeout + 30 )) 9 &
        child_pid=$!
        if wait "$child_pid"; then
          have_lock=1
        else
          exec 9>&-
        fi
        child_pid=""
      }

      release_lock() {
        exec 9>&-
        have_lock=0
      }

      # Runs a command for at most $1 seconds and leaves its output lines in
      # `captured`. Returns the command's status, 124 on a timeout.
      capture_bounded() {
        local secs="$1" fd rc=0
        shift
        captured=()
        exec {fd}< <(exec timeout -k 2 "$secs" "$@" 9>&-)
        child_pid=$!
        mapfile -t -u "$fd" captured || true
        exec {fd}<&-
        wait "$child_pid" || rc=$?
        child_pid=""
        return "$rc"
      }

      env_skipped() {
        local now mtime
        [[ -e "$skip_marker" ]] || return 1
        mtime="$(stat -c %Y "$skip_marker" 2>/dev/null)" || return 1
        printf -v now '%(%s)T' -1
        (( now - mtime < env_skip ))
      }

      # Reads the whole Environment into env_lines, once per run. Returns 1
      # when the pipe is absent, skipped or does not answer.
      load_env_file() {
        local rc=0
        (( env_loaded )) && return 0
        # Only our own pipe qualifies: a regular file would hold the keys on
        # disk, and somebody else's pipe could serve a value of their choosing.
        [[ -p "$env_file" && ! -L "$env_file" && -O "$env_file" ]] || return 1
        env_skipped && return 1
        acquire_lock
        # The size cap bounds memory if the writer never stops.
        capture_bounded "$env_timeout" head -c 262144 -- "$env_file" || rc=$?
        release_lock
        if (( rc == 124 )) && ensure_state_dir; then
          touch "$skip_marker" 2>/dev/null || true
        fi
        (( rc == 0 )) || return 1
        rm -f "$skip_marker"
        env_lines=("''${captured[@]}")
        captured=()
        env_loaded=1
      }

      # Sets value from the Environment, as dotenv would: the last assignment
      # wins, `export ` and one pair of quotes are optional.
      env_value() {
        local name="$1" line
        value=""
        load_env_file || return 1
        for line in "''${env_lines[@]}"; do
          line="''${line%$'\r'}"
          if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ &&
            "''${BASH_REMATCH[2]}" == "$name" ]]; then
            value="''${BASH_REMATCH[3]}"
            if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
              value="''${BASH_REMATCH[1]}"
            fi
          fi
        done
        [[ -n "$value" ]]
      }

      op_value() {
        local op_bin="" candidate
        for candidate in "$(command -v op 2>/dev/null || true)" \
          /opt/homebrew/bin/op /usr/local/bin/op /usr/bin/op; do
          if [[ -n "$candidate" && -x "$candidate" ]]; then
            op_bin="$candidate"
            break
          fi
        done
        if [[ -z "$op_bin" ]]; then
          printf '%s\n' 'ai-secret: the 1Password CLI (op) was not found' >&2
          exit 69
        fi
        acquire_lock
        # op writes diagnostics, never the secret, to stderr.
        capture_bounded "$op_timeout" "$op_bin" read "$ref" || true
        release_lock
        value="''${captured[0]:-}"
        captured=()
        if [[ -z "$value" ]]; then
          printf 'ai-secret: could not read %s (is 1Password unlocked?)\n' \
            "$ref" >&2
          exit 77
        fi
      }

      # Prints a credential. Whatever the source, the value must match the
      # credential's shape before anyone gets it.
      read_secret() {
        local name="$1" value source_name
        lookup_secret "$name"
        value="''${!name:-}"
        source_name="$name"
        if [[ -z "$value" ]]; then
          if env_value "$name"; then
            source_name="1Password Environment"
          else
            source_name="$ref"
            op_value
          fi
        fi
        if [[ ! "$value" =~ $shape || ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
          printf 'ai-secret: the value of %s from %s has an unexpected form\n' \
            "$name" "$source_name" >&2
          exit 65
        fi
        REPLY="$value"
      }

      (( $# >= 1 )) || usage
      command="$1"
      shift
      case "$command" in
      get)
        (( $# == 1 )) || usage
        read_secret "$1"
        printf '%s\n' "$REPLY"
        ;;
      ref)
        (( $# == 1 )) || usage
        lookup_secret "$1"
        printf '%s\n' "$ref"
        ;;
      headers)
        # Claude Code names the server in the environment of its helper.
        (( $# <= 1 )) || usage
        server="''${1:-''${CLAUDE_CODE_MCP_SERVER_NAME:-}}"
        case "$server" in
        ${serverCases}
        *)
          printf 'ai-secret: no headers defined for MCP server: %s\n' "$server" >&2
          exit 64
          ;;
        esac
        read_secret "$secret"
        # shellcheck disable=SC2059 # the format comes from the Nix table.
        printf "$format" "$REPLY"
        ;;
      exec)
        # For consumers that only read the environment. The values reach the
        # command and its children only, never this script's caller.
        names=()
        while (( $# > 0 )) && [[ "$1" != -- ]]; do
          names+=("$1")
          shift
        done
        (( ''${#names[@]} > 0 && $# >= 2 )) || usage
        shift
        for name in "''${names[@]}"; do
          read_secret "$name"
          export "$name=$REPLY"
        done
        unset REPLY
        exec "$@"
        ;;
      warm)
        # Raises the Environment's authorization prompt now, so helpers that
        # Claude Code cuts off after ten seconds find it already approved.
        (( $# == 0 )) || usage
        ensure_state_dir || true
        rm -f "$skip_marker"
        if [[ ! -p "$env_file" || -L "$env_file" || ! -O "$env_file" ]]; then
          printf 'ai-secret: no Environment pipe at %s; check the destination in 1Password\n' \
            "$env_file" >&2
          exit 75
        fi
        if ! load_env_file; then
          printf 'ai-secret: the Environment at %s did not answer\n' \
            "$env_file" >&2
          exit 75
        fi
        ;;
      list)
        (( $# == 0 )) || usage
        printf '%s\n' ${
          lib.escapeShellArgs (
            map (n: "credential ${n}") (lib.attrNames secrets)
            ++ lib.mapAttrsToList (s: h: "server ${s} (${h.secret})") mcpHeaders
          )
        }
        ;;
      *) usage ;;
      esac
    '';
  };
in
assert checked;
{
  home.packages = [ aiSecret ];
}
