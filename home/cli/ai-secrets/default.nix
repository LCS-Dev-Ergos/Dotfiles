{ lib, pkgs, ... }:
let
  # Credentials for AI tools, keyed by the environment variable that carries
  # each one. `ref` is the 1Password reference; `shape` is the value's
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
  aiSecret = pkgs.writeShellApplication {
    name = "ai-secret";
    text = ''
      usage() {
        printf '%s\n' \
          'usage: ai-secret get <NAME>        print a credential' \
          '       ai-secret ref <NAME>        print its 1Password reference' \
          '       ai-secret headers <server>  print MCP request headers as JSON' \
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

      # Prints a credential: an exported variable of the same name wins,
      # otherwise it is read from 1Password.
      read_secret() {
        local name="$1" value source_name op_bin="" candidate
        lookup_secret "$name"
        value="''${!name:-}"
        source_name="$name"
        if [[ -z "$value" ]]; then
          source_name="$ref"
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
          # op writes diagnostics, never the secret, to stderr.
          if ! value="$("$op_bin" read "$ref")" || [[ -z "$value" ]]; then
            printf 'ai-secret: could not read %s (is 1Password unlocked?)\n' \
              "$ref" >&2
            exit 77
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
