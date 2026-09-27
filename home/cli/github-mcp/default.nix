{ pkgs, ... }:
let
  # The Claude Code `github` MCP server (user scope in ~/.claude.json) takes
  # its Authorization header from this helper through `headersHelper` rather
  # than from `${GITHUB_PAT}`. A header reference only resolves when Claude is
  # started by the zsh `claude` wrapper, and the VS Code extension launches its
  # own binary directly, so the server failed there with a malformed header.
  # Registering the server:
  #   claude mcp add-json --scope user github '{"type":"http",
  #     "url":"https://api.githubcopilot.com/mcp",
  #     "headersHelper":"<profile>/bin/github-mcp-headers"}'
  # where <profile> is /etc/profiles/per-user/$USER on nix-darwin and
  # ~/.nix-profile on standalone Home Manager.
  #
  # A GITHUB_PAT already in the environment (the zsh wrapper passes one) wins,
  # as in lib/70-ai-tools.zsh; otherwise the token comes from 1Password. The
  # reference below mirrors _AI_SECRET_REFS[GITHUB_PAT] there. `op` stays
  # outside runtimeInputs on purpose: 1Password's desktop-app integration only
  # trusts its own signed install, so the helper looks it up on PATH and in the
  # usual install locations, which a GUI-launched process may not have on PATH.
  githubMcpHeaders = pkgs.writeShellApplication {
    name = "github-mcp-headers";
    text = ''
      ref='op://Personal/GITHUB_PAT/credential'
      token="''${GITHUB_PAT:-}"
      source_name='GITHUB_PAT'

      if [[ -z "$token" ]]; then
        source_name="$ref"
        op_bin=""
        for candidate in "$(command -v op 2>/dev/null || true)" \
          /opt/homebrew/bin/op /usr/local/bin/op /usr/bin/op; do
          if [[ -n "$candidate" && -x "$candidate" ]]; then
            op_bin="$candidate"
            break
          fi
        done
        if [[ -z "$op_bin" ]]; then
          printf '%s\n' 'github-mcp-headers: the 1Password CLI (op) was not found' >&2
          exit 69
        fi
        # op writes diagnostics, never the secret, to stderr.
        if ! token="$("$op_bin" read "$ref")"; then
          printf 'github-mcp-headers: could not read %s (is 1Password unlocked?)\n' \
            "$ref" >&2
          exit 77
        fi
      fi

      # GitHub tokens are prefix_ plus [A-Za-z0-9_]. Checking the shape keeps
      # stray whitespace or a placeholder out of the header, and makes the
      # value safe to embed in JSON verbatim. printf is a builtin, so the token
      # never appears in a process argument list.
      if [[ ! "$token" =~ ^(ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]+$ ]]; then
        printf 'github-mcp-headers: the token from %s is not a GitHub token\n' \
          "$source_name" >&2
        exit 65
      fi
      printf '{"Authorization":"Bearer %s"}\n' "$token"
    '';
  };
in
{
  home.packages = [ githubMcpHeaders ];
}
