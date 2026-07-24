-- =====-----------------------------------------------------------------=====
-- BASH / SH / ZSH
--
-- The LSP (bash-language-server) comes from Mason. shfmt and shellcheck are
-- installed system-wide by home/cli-tools (Nix) and already on PATH, so only
-- bash-language-server needs Mason to manage it. Shellcheck stays off by
-- default and runs on demand via <leader>cs, since it's noisy against zsh's
-- non-POSIX syntax.
-- =====-----------------------------------------------------------------=====

return {
  -- 1. MASON: Installs the LSP.
  {
    "mason-org/mason.nvim",
    ft = { "sh", "bash", "zsh" },
    opts = require("lang_util").mason_ensure({ "bash-language-server" }),
  },

  -- 2. CONFORM.NVIM (Formatter): Uses shfmt for shell script files.
  {
    "stevearc/conform.nvim",
    ft = { "sh", "bash", "zsh" },
    opts = {
      formatters_by_ft = {
        bash = { "shfmt" },
        zsh = { "shfmt" },
        sh = { "shfmt" },
      },
    },
  },

  -- 3. NVIM-LINT: Shellcheck disabled by default; toggle with <leader>cs.
  {
    "mfussenegger/nvim-lint",
    ft = { "sh", "bash", "zsh" },
    opts = function(_, opts)
      -- Disable shellcheck for shell files
      opts.linters_by_ft = opts.linters_by_ft or {}
      opts.linters_by_ft.bash = {}
      opts.linters_by_ft.zsh = {}
      opts.linters_by_ft.sh = {}
      return opts
    end,
    keys = {
      {
        "<leader>cs",
        function() require("lint").try_lint("shellcheck") end,
        desc = "Run shellcheck on current file",
        ft = { "sh", "bash", "zsh" },
      },
    },
  },

  -- 4. NVIM-LSPCONFIG: Configure the language server (bashls).
  {
    "neovim/nvim-lspconfig",
    ft = { "sh", "bash", "zsh" },
    opts = {
      servers = {
        bashls = {
          filetypes = { "sh", "bash", "zsh" },
        },
      },
    },
  },

  -- 5. TREESITTER: Ensure the parser for bash is installed.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "sh", "bash", "zsh" },
    opts = require("lang_util").treesitter_ensure({ "bash" }),
  },
}
