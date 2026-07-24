-- =====-----------------------------------------------------------------=====
-- SCALA
--
-- nvim-metals manages the LSP (Metals) directly, the same way
-- haskell-tools.nvim and rustaceanvim do for their own languages: Metals
-- needs build-import handling and decorations that a generic lspconfig entry
-- doesn't provide, so there is no Mason or NVIM-LSPCONFIG section here.
-- Metals and scalafmt (formatter) both come from Coursier
-- (`cs install metals`), already on PATH.
-- =====-----------------------------------------------------------------=====

return {
  -- 1. NVIM-METALS: LSP integration (build import, decorations, etc.).
  {
    "scalameta/nvim-metals",
    ft = { "scala", "sbt" },
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      local metals_config = require("metals").bare_config()
      metals_config.init_options.statusBarProvider = "on"
      metals_config.settings = {
        showImplicitArguments = true,
      }
      vim.api.nvim_create_autocmd("FileType", {
        pattern = { "scala", "sbt" },
        callback = function() require("metals").initialize_or_attach(metals_config) end,
        group = vim.api.nvim_create_augroup("nvim-metals", { clear = true }),
      })
    end,
  },

  -- 2. CONFORM.NVIM (Formatter): Uses scalafmt.
  {
    "stevearc/conform.nvim",
    ft = { "scala", "sbt" },
    opts = {
      formatters_by_ft = { scala = { "scalafmt" }, sbt = { "scalafmt" } },
    },
  },

  -- 3. TREESITTER: Installs the parser.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "scala", "sbt" },
    opts = require("lang_util").treesitter_ensure({ "scala" }),
  },
}
