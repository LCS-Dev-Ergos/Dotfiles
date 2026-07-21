{
  config,
  lib,
  pkgs,
  ...
}:
{
  programs = {
    git = {
      enable = true;

      # Adds the git-lfs package and generates the complete [filter "lfs"]
      # block (clean/smudge/process/required). Do not duplicate it manually
      # under settings; Home Manager already owns that integration.
      lfs.enable = true;

      settings = lib.mkMerge [
        {
          user = {
            name = "LCS-Dev";
            email = "xtremexspc@gmail.com";
          };

          "credential \"https://github.com\"".username = "XtremeXSPC";
          "credential \"https://dev.azure.com\"".useHttpPath = true;

          core = {
            excludesFile = "${config.home.homeDirectory}/.gitignore";
            autocrlf = "input";
            fsmonitor = true;
            untrackedcache = true;
            preloadindex = true;
            compression = -1;
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

          init.defaultBranch = "main";

          commit.verbose = true;

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
        }

        (lib.mkIf pkgs.stdenv.isDarwin {
          # The empty helper first clears helpers inherited from lower-priority
          # config files, then installs the real one: the same semantics as the
          # original pair of repeated `helper =` lines. Git expands `manager`
          # to the `git-credential-manager` subcommand installed by the Homebrew
          # cask, avoiding either Intel or Apple-Silicon brew-prefix hardcoding.
          credential.helper = [
            ""
            "manager"
          ];

          # SSH signing uses the 1Password application, not private key
          # material in the Nix store. The public key is safe to declare.
          user.signingkey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDK1I9uQPx0oLehDTvI7S1fyhKKM26mkT27vZvfaSJWtvNW1UxJ3durrtKzzq13RQM9sL6+9b1JtMlRUqNDIHBrZrgA6I3Ji+bNpLroNrlUauCVkPbxrMwT8DHq2Mq6/YtgK3kGMS20xmP4zO18cVk1nCLAugi2r9QCyOq+olSSOUdWen5hnyMYWFcHBh1HQOR7Mj/ZbwDaIVPgN7Zg65pblKshiNU4soBUSAZyJCr2543gzjOPvPHj7DQjM0rjL3Zitm0NZeZn2+TOrkE4uoGugFkMiWd5Xe1jBTATd0wp72AYdYhLcA2/jK/hX++rKTsOJkdDHxblbqhtGU05cUr9VPpcFbS7TkDoek/tT2mifhSlRveYezrxjIRXMKgTSlUR+1PS82byUDB5egMBtFk++y81hfTYCLmFV8UWJFYpVvwO/0hsvnCYIQ5s8nDFMqReXJOprgFk6f7wGsPJh5bwc9ioPq5+cap9405BGHjLNeG22Zi5eEj3rh9D67LmKzXU4z8hWkf1y/oGpY60sdd65klkvWOX3QYiBd8iCS2OtVCf7d/M8M2B7eXMo3zthUTT7cyQdJoPXZoKe44CUYd5lEJUl6qZOuhToHfBZChVtl0oISRGQJ1r+whv4C6fsNqAgP76QGe9yng9IsKTDpSFrKMlNlJ05RJnyR5wkypswQ==";
          gpg.format = "ssh";
          "gpg \"ssh\"".program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";
          commit.gpgsign = true;
        })

        # Do not claim signing support on the provisional Linux host until a
        # real signer is configured there.
        (lib.mkIf pkgs.stdenv.isLinux { commit.gpgsign = false; })
      ];
    };

    delta = {
      enable = true;
      enableGitIntegration = true;
      options = {
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
    };
  };

  # A real, plain ~/.gitignore dated April 2024 predates this migration and has
  # byte-identical content. Without force, Home Manager leaves it untouched and
  # repeats "is in the way ... will be skipped since they are the same" on every
  # switch forever, because the plain file is never replaced by its managed link.
  home.file.".gitignore" = {
    source = ./gitignore-global;
    force = true;
  };

  # programs.git only ever writes ${XDG_CONFIG_HOME}/git/config -- git itself
  # ignores that file entirely as long as ~/.gitconfig exists (its own
  # precedence rule, not a Home Manager quirk). Mirroring the same generated
  # content at ~/.gitconfig is what actually makes it take effect, the same
  # XDG-versus-legacy-path compatibility pattern used for Starship, Nushell,
  # and tealdeer. force is required because the existing plain ~/.gitconfig
  # predates the migration and was never managed by either Nix or Stow.
  home.file.".gitconfig" = {
    source = config.xdg.configFile."git/config".source;
    force = true;
  };
}
