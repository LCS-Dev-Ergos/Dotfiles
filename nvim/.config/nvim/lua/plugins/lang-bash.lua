-- File: lua/plugins/lang-bash.lua

return {
  -- 1. MASON: Ensure LSP, formatter, and linter are installed
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, {
        "bash-language-server",  -- LSP for diagnostics and completion
        "shfmt",                 -- Formatter
        "shellcheck",            -- Linter for shell scripts
      })
    end,
  },

  -- 2. CONFORM.NVIM (Formatter): Use shfmt for shell script files
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        bash = { "shfmt" },
        zsh = { "shfmt" },
        sh = { "shfmt" },
      },
    },
  },

  -- 3. NVIM-LINT: Configure shellcheck linter
  {
    "mfussenegger/nvim-lint",
    opts = {
      linters_by_ft = {
        bash = { "shellcheck" },
        zsh = { "shellcheck" },
        sh = { "shellcheck" },
      },
    },
  },

  -- 4. NVIM-LSPCONFIG: Configure the language server (bashls)
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        bashls = {
          filetypes = { "sh", "bash", "zsh" },
        },
      },
    },
  },

  -- 5. TREESITTER: Ensure the parser for bash is installed
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "bash" })
      end
    end,
  },
}