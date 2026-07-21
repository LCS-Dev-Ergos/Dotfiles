{ config, ... }:
{
  programs.git = {
    enable = true;

    # Adds the git-lfs package and generates the [filter "lfs"] block itself
    # (clean/smudge/process/required) -- do not also hand-write that section
    # under settings, it would just duplicate what this produces.
    lfs.enable = true;

    settings = {
      user = {
        name = "LCS-Dev.Mac";
        email = "xtremexspc@gmail.com";
        signingkey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDK1I9uQPx0oLehDTvI7S1fyhKKM26mkT27vZvfaSJWtvNW1UxJ3durrtKzzq13RQM9sL6+9b1JtMlRUqNDIHBrZrgA6I3Ji+bNpLroNrlUauCVkPbxrMwT8DHq2Mq6/YtgK3kGMS20xmP4zO18cVk1nCLAugi2r9QCyOq+olSSOUdWen5hnyMYWFcHBh1HQOR7Mj/ZbwDaIVPgN7Zg65pblKshiNU4soBUSAZyJCr2543gzjOPvPHj7DQjM0rjL3Zitm0NZeZn2+TOrkE4uoGugFkMiWd5Xe1jBTATd0wp72AYdYhLcA2/jK/hX++rKTsOJkdDHxblbqhtGU05cUr9VPpcFbS7TkDoek/tT2mifhSlRveYezrxjIRXMKgTSlUR+1PS82byUDB5egMBtFk++y81hfTYCLmFV8UWJFYpVvwO/0hsvnCYIQ5s8nDFMqReXJOprgFk6f7wGsPJh5bwc9ioPq5+cap9405BGHjLNeG22Zi5eEj3rh9D67LmKzXU4z8hWkf1y/oGpY60sdd65klkvWOX3QYiBd8iCS2OtVCf7d/M8M2B7eXMo3zthUTT7cyQdJoPXZoKe44CUYd5lEJUl6qZOuhToHfBZChVtl0oISRGQJ1r+whv4C6fsNqAgP76QGe9yng9IsKTDpSFrKMlNlJ05RJnyR5wkypswQ==";
      };

      # Empty helper first, then the real one: clears any helper inherited
      # from a lower-priority config file before setting GCM, same effect
      # as the original two repeated `helper =` lines.
      credential.helper = [
        ""
        "/usr/local/share/gcm-core/git-credential-manager"
      ];
      "credential \"https://github.com\"".username = "XtremeXSPC";
      "credential \"https://dev.azure.com\"".useHttpPath = true;

      core = {
        pager = "delta";
        excludesFile = "${config.home.homeDirectory}/.gitignore";
        autocrlf = "input";
        fsmonitor = true;
        untrackedcache = true;
        preloadindex = true;
        compression = -1;
      };

      delta = {
        navigate = true;
        light = false;
        side-by-side = true;
        line-numbers = true;
        syntax-theme = "tokyonight_night";
        line-numbers-minus-style = "red";
        line-numbers-plus-style = "green";
        line-numbers-zero-style = "#666666";
        line-numbers-left-format = "{nm:>4}│";
        line-numbers-right-format = "{np:>4}│";
        line-numbers-left-style = "blue";
        line-numbers-right-style = "blue";
        file-style = "bold yellow ul";
        file-decoration-style = "none";
        hunk-header-decoration-style = "cyan box";
        hunk-header-style = "file line-number syntax";
        hyperlinks = true;
        hyperlinks-file-link-format = "vscode://file/{path}:{line}";
      };

      merge = {
        conflictstyle = "zdiff3";
        tool = "vscode";
        rerere = true;
      };
      "mergetool \"vscode\"".cmd = "code --wait --merge $REMOTE $LOCAL $BASE $MERGED";

      diff = {
        colorMoved = "default";
        algorithm = "histogram";
        renames = "copies";
        mnemonicPrefix = true;
      };

      interactive.diffFilter = "delta --color-only";

      init.defaultBranch = "main";

      # SSH-based commit signing via 1Password, not OpenPGP -- signingkey
      # above is a public SSH key, safe to keep in the world-readable Nix
      # store; no private key material is involved here.
      gpg.format = "ssh";
      "gpg \"ssh\"".program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";

      commit = {
        gpgsign = true;
        verbose = true;
      };

      push = {
        default = "current";
        autoSetupRemote = true;
        followTags = true;
      };

      pull = {
        rebase = true;
        autoStash = true;
      };

      rebase = {
        autoStash = true;
        autoSquash = true;
        updateRefs = true;
      };

      fetch = {
        prune = true;
        pruneTags = true;
        parallel = 0;
      };

      status = {
        showStash = true;
        submoduleSummary = true;
      };

      log = {
        date = "relative";
        follow = true;
      };

      help.autocorrect = 15;

      alias = {
        s = "status -sb";
        l = "log --oneline --graph --decorate --all";
        lg = "log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit";
        c = "commit";
        ca = "commit --amend";
        cane = "commit --amend --no-edit";
        b = "branch";
        co = "checkout";
        cob = "checkout -b";
        d = "diff";
        ds = "diff --staged";
        last = "log -1 HEAD --stat";
        undo = "reset --soft HEAD^";
        nuke = "reset --hard HEAD";
        cleanup = "clean -fd";
        contributors = "shortlog -sn";
        find = "log --all --oneline --grep";
        contains = "branch --contains";
        sync = "!git fetch --prune && git pull";
        ri = "rebase -i";
        current = "branch --show-current";
      };
    };
  };

  # force = true: a real, plain ~/.gitignore (dated April 2024, pre-dating
  # this migration) already sits here with byte-identical content. Without
  # force, Home Manager leaves that pre-existing file alone and reprints
  # "is in the way ... will be skipped since they are the same" on every
  # single switch, forever, since it's never actually replaced by the
  # managed symlink.
  home.file.".gitignore" = {
    source = ./gitignore-global;
    force = true;
  };

  # programs.git only ever writes ${XDG_CONFIG_HOME}/git/config -- git itself
  # ignores that file entirely as long as ~/.gitconfig exists (its own
  # precedence rule, not a Home Manager quirk). Mirroring the same generated
  # content at ~/.gitconfig is what actually makes it take effect, same
  # pattern already used for starship/nushell/tealdeer's XDG-vs-legacy-path
  # mismatches. force = true: a real, plain ~/.gitconfig predates this
  # migration and was never Nix- or Stow-managed.
  home.file.".gitconfig" = {
    source = config.xdg.configFile."git/config".source;
    force = true;
  };
}
