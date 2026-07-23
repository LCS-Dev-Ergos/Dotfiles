-- File: lua/plugins/lang-scala.lua
--
-- nvim-metals manages the LSP (Metals) directly, like haskell-tools.nvim and
-- rustaceanvim do for their own languages: Metals needs build-import
-- handling and decorations that a generic lspconfig entry doesn't provide.
-- Metals comes from Coursier (`cs install metals`), on PATH already.
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

  -- 2. CONFORM.NVIM (Formatter): Uses scalafmt, also from Coursier.
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
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "scala" })
      end
    end,
  },
}
