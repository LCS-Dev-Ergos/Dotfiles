-- File: lua/plugins/haskell.lua
return {
  -- haskell-tools gestisce l'LSP (haskell-language-server)
  {
    "mrcjkb/haskell-tools.nvim",
    version = "^4",
    dependencies = { "nvim-lua/plenary.nvim" },
    ft = { "haskell", "lhaskell", "cabal" },
  },

  -- 1. MASON: Assicura che il formattatore sia installato
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "fourmolu" }) -- o "ormolu"
    end,
  },

  -- 2. CONFORM.NVIM (Formatter): Usa fourmolu
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
