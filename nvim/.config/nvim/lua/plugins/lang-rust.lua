-- File: lua/plugins/lang-rust.lua
return {
  -- 1. MASON: Ensures rust_analyzer, rustfmt and codelldb (for debugging) are installed.
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "rust-analyzer", "rustfmt", "codelldb" })
    end,
  },

  -- 2. CONFORM.NVIM (Formatter): Uses rustfmt.
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        rust = { "rustfmt" },
      },
    },
  },

  -- 3. NVIM-LSPCONFIG: Configures rust_analyzer.
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        rust_analyzer = {}, -- Default configuration, usually sufficient.
      },
    },
  },

  -- 4. TREESITTER: Ensures the parser for Rust is installed.
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "rust" })
      end
    end,
  },
}
