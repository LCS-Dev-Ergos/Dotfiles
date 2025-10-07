-- File: lua/plugins/haskell.lua
return {
  -- haskell-tools manages the LSP (haskell-language-server)
  {
    "mrcjkb/haskell-tools.nvim",
    version = "^4",
    dependencies = { "nvim-lua/plenary.nvim" },
    ft = { "haskell", "lhaskell", "cabal" },
    config = function()
      require('haskell-tools').setup({
        hls = {
          settings = {
            haskell = {
              ghcupExecutablePath = vim.fn.exepath('ghcup'),
              manageHLS = 'GHCup',
            },
          },
        },
      })
      -- Set default GHC
      vim.g.haskell_tools_ghc_version = "9.12.2"
    end,
  },

  -- 1. MASON: Ensure the formatter is installed
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "fourmolu" }) -- or "ormolu"
    end,
  },

  -- 2. CONFORM.NVIM (Formatter): Use fourmolu
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        haskell = { "fourmolu" },
      },
    },
  },

  -- 3. TREESITTER
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "haskell" })
      end
    end,
  },
}
