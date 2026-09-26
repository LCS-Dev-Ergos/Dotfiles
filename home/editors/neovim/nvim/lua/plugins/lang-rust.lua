-- =====-----------------------------------------------------------------=====
-- RUST
--
-- LazyVim's lang.rust extra already enables rustaceanvim, Mason
-- (rust-analyzer, codelldb), and Treesitter. This file only overrides
-- rustaceanvim settings and disables the plain lspconfig rust_analyzer entry
-- that would otherwise conflict with it. rustfmt (formatter) ships with the
-- Rust toolchain (rustup), not Mason.
-- =====-----------------------------------------------------------------=====

return {
  -- 1. RUSTACEANVIM: override server settings (clippy, all features).
  -- LazyVim's lang.rust extra provides the plugin and merges opts into
  -- vim.g.rustaceanvim via its config function.
  {
    "mrcjkb/rustaceanvim",
    ft = { "rust" },
    opts = {
      server = {
        settings = {
          ["rust-analyzer"] = {
            cargo = { allFeatures = true },
            checkOnSave = { command = "clippy" },
          },
        },
      },
    },
    keys = {
      -- RustLsp debuggables: picks the Cargo target to debug automatically,
      -- bypassing the manual executable prompt that plain <F5> shows.
      { "<leader>rd", "<cmd>RustLsp debuggables<cr>", ft = "rust", desc = "Rust Debuggables" },
      { "<leader>rr", "<cmd>RustLsp runnables<cr>",   ft = "rust", desc = "Rust Runnables"   },
      { "<leader>re", "<cmd>RustLsp expandMacro<cr>", ft = "rust", desc = "Rust Expand Macro" },
    },
  },

  -- 2. NVIM-LSPCONFIG: disable the plain rust_analyzer entry. rustaceanvim
  -- manages the server directly and a second lspconfig entry would start a
  -- duplicate.
  {
    "neovim/nvim-lspconfig",
    ft = { "rust" },
    opts = {
      servers = {
        rust_analyzer = { mason = false, autostart = false },
      },
    },
  },

  -- 3. CONFORM.NVIM (Formatter): rustfmt, from rustup.
  {
    "stevearc/conform.nvim",
    ft = { "rust" },
    opts = {
      formatters_by_ft = {
        rust = { "rustfmt" },
      },
    },
  },
}
