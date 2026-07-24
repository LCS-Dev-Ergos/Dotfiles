-- =====-----------------------------------------------------------------=====
-- HASKELL
--
-- haskell-tools.nvim manages the LSP (haskell-language-server) directly, the
-- same way rustaceanvim and nvim-metals do for their own languages: it needs
-- GHCup-aware version resolution that a generic lspconfig entry doesn't
-- provide, so there is no Mason or plain NVIM-LSPCONFIG section here.
-- fourmolu (formatter) is installed via `cabal install fourmolu` (GHCup's
-- cabal) and is already on PATH.
-- =====-----------------------------------------------------------------=====

return {
  -- 1. HASKELL-TOOLS.NVIM: LSP integration (haskell-language-server via GHCup).
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

  -- 2. CONFORM.NVIM (Formatter): Uses fourmolu.
  {
    "stevearc/conform.nvim",
    ft = { "haskell", "lhaskell", "cabal" },
    opts = {
      formatters_by_ft = {
        haskell = { "fourmolu" },
      },
    },
  },

  -- 3. TREESITTER: Ensure the parser for Haskell is installed.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "haskell", "lhaskell", "cabal" },
    opts = require("lang_util").treesitter_ensure({ "haskell" }),
  },
}
