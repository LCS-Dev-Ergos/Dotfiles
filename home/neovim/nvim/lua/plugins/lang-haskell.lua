-- File: lua/plugins/lang-haskell.lua

return {
  -- haskell-tools manages the LSP (haskell-language-server).
  {
    "mrcjkb/haskell-tools.nvim",
    version = "^4",
    dependencies = { "nvim-lua/plenary.nvim" },
    ft = { "haskell", "lhaskell", "cabal" },
    config = function()
      require("haskell-tools").setup {
        hls = {
          settings = {
            haskell = {
              ghcupExecutablePath = vim.fn.exepath("ghcup"),
              manageHLS = "GHCup",
            },
          },
        },
      }
    end,
  },

  -- 1. CONFORM.NVIM (Formatter): Uses fourmolu, installed via
  -- `cabal install fourmolu` (GHCup's cabal) and already on PATH.
  {
    "stevearc/conform.nvim",
    ft = { "haskell", "lhaskell", "cabal" },
    opts = {
      formatters_by_ft = {
        haskell = { "fourmolu" },
      },
    },
  },

  -- 2. TREESITTER: Ensure the parser for Haskell is installed.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "haskell", "lhaskell", "cabal" },
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "haskell" })
      end
    end,
  },
}
