-- =====-----------------------------------------------------------------=====
-- C#
--
-- csharp-ls comes from `dotnet tool install --global csharp-ls`, on PATH via
-- ~/.dotnet/tools -- the same server Doom Emacs' eglot config expects (see
-- home/doom/doom/config.el, C# section). csharpier (formatter) comes from
-- home/doom/default.nix (Nix). Neither tool needs Mason.
-- =====-----------------------------------------------------------------=====

return {
  -- 1. NVIM-LSPCONFIG: Configures csharp_ls.
  {
    "neovim/nvim-lspconfig",
    ft = { "cs" },
    opts = {
      servers = {
        csharp_ls = { mason = false },
      },
    },
  },

  -- 2. CONFORM.NVIM (Formatter): Uses csharpier.
  {
    "stevearc/conform.nvim",
    ft = { "cs" },
    opts = {
      formatters_by_ft = { cs = { "csharpier" } },
    },
  },

  -- 3. TREESITTER: Installs the parser.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "cs" },
    opts = require("lang_util").treesitter_ensure({ "c_sharp" }),
  },
}
