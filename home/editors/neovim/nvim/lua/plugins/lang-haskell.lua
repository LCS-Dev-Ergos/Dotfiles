-- =====-----------------------------------------------------------------=====
-- HASKELL
--
-- haskell-tools.nvim manages the LSP (haskell-language-server) directly, the
-- same way rustaceanvim and nvim-metals do for their own languages: it needs
-- GHCup-aware version resolution that a generic lspconfig entry doesn't
-- provide, so there is no plain NVIM-LSPCONFIG section here.
-- fourmolu (formatter) is installed via `cabal install fourmolu` (GHCup's
-- cabal) and is already on PATH.
--
-- lazyvim.json still enables lazyvim.plugins.extras.lang.haskell for its
-- treesitter/snippets/hlint wiring, but that extra also declares Mason's
-- haskell-language-server and haskell-debug-adapter. Both are GHCup-owned
-- (and the debug adapter isn't wired to any dap.adapters.haskell config
-- here), so exclude them or Mason silently reinstalls them.
-- =====-----------------------------------------------------------------=====

return {
  -- 1. MASON: Exclude the LazyVim extra's HLS/debug-adapter duplicates.
  {
    "mason-org/mason.nvim",
    ft = { "haskell", "lhaskell", "cabal" },
    opts = require("lang_util").mason_exclude({
      "haskell-language-server",
      "haskell-debug-adapter",
    }),
  },

  -- 2. HASKELL-TOOLS.NVIM: LSP integration (haskell-language-server via GHCup).
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

  -- 3. CONFORM.NVIM (Formatter): Uses fourmolu.
  {
    "stevearc/conform.nvim",
    ft = { "haskell", "lhaskell", "cabal" },
    opts = {
      formatters_by_ft = {
        haskell = { "fourmolu" },
      },
    },
  },

  -- 4. TREESITTER: Ensure the parser for Haskell is installed.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "haskell", "lhaskell", "cabal" },
    opts = require("lang_util").treesitter_ensure({ "haskell" }),
  },
}
