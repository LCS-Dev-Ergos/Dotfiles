-- File: lua/plugins/lang-rust.lua
return {
  -- 1. MASON: Assicura che rust_analyzer, rustfmt e codelldb (per debug) siano installati
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "rust-analyzer", "rustfmt", "codelldb" })
    end,
  },

  -- 2. CONFORM.NVIM (Formatter): Usa rustfmt
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        rust = { "rustfmt" },
      },
    },
  },

  -- 3. NVIM-LSPCONFIG: Configura rust_analyzer
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        rust_analyzer = {}, -- Configurazione di default, solitamente sufficiente
      },
    },
  },

  -- 4. TREESITTER: Assicura che il parser per Rust sia installato
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "rust" })
      end
    end,
  },
}
