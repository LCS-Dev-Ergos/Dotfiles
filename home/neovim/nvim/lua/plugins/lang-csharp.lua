-- File: lua/plugins/lang-csharp.lua
--
-- csharp-ls comes from `dotnet tool install --global csharp-ls`, on PATH
-- via ~/.dotnet/tools -- the same server Doom's eglot config expects (see
-- home/doom/doom/config.el, C# section). csharpier (formatter) comes from
-- home/doom/default.nix (Nix).
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
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "c_sharp" })
      end
    end,
  },
}
