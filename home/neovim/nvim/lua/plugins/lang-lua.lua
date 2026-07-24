-- =====-----------------------------------------------------------------=====
-- LUA
--
-- lua-language-server (LSP) and stylua (formatter) both come from Mason. The
-- lspconfig settings below teach the server about Neovim's own runtime, so it
-- recognizes globals like `vim` instead of flagging them as undefined.
-- =====-----------------------------------------------------------------=====

return {
  -- 1. MASON: Ensures lua-language-server and stylua are installed.
  {
    "mason-org/mason.nvim",
    ft = { "lua" },
    opts = require("lang_util").mason_ensure({ "lua-language-server", "stylua" }),
  },

  -- 2. CONFORM.NVIM (Formatter): Uses stylua for Lua files.
  {
    "stevearc/conform.nvim",
    ft = { "lua" },
    opts = {
      formatters_by_ft = {
        lua = { "stylua" },
      },
    },
  },

  -- 3. NVIM-LSPCONFIG: Configures lua-language-server (lua_ls) to understand
  -- that we're working in a Neovim environment and recognize globals like "vim".
  {
    "neovim/nvim-lspconfig",
    ft = { "lua" },
    opts = {
      servers = {
        lua_ls = {
          settings = {
            Lua = {
              runtime = {
                -- Uses the LuaJIT version, which is used by Neovim.
                version = "LuaJIT",
              },
              workspace = {
                -- Makes the server aware of Neovim runtime files for autocompletion.
                library = vim.api.nvim_get_runtime_file("", true),
                checkThirdParty = false,
              },
              -- Disables telemetry for privacy.
              telemetry = {
                enable = false,
              },
            },
          },
        },
      },
    },
  },

  -- 4. TREESITTER: Ensures that parsers for Lua and queries (useful for development) are installed.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "lua" },
    opts = require("lang_util").treesitter_ensure({ "lua", "query" }),
  },
}
