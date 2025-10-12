-- File: lua/plugins/lang-lua.lua

return {
  -- 1. MASON: Ensures that lua-language-server (for LSP) and stylua (for formatting) are installed.
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "lua-language-server", "stylua" })
    end,
  },

  -- 2. CONFORM.NVIM (Formatter): Uses stylua for Lua files.
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        lua = { "stylua" },
      },
    },
  },

  -- 3. NVIM-LSPCONFIG: Configures lua-language-server (lua_ls).
  -- The configuration here is very important to make the LSP
  -- understand that we are working in a Neovim environment and to recognize globals like "vim".
  {
    "neovim/nvim-lspconfig",
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
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "lua", "query" })
      end
    end,
  },
}
