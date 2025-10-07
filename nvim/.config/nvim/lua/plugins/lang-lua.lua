-- File: lua/plugins/lang-lua.lua
return {
  -- 1. MASON: Assicura che lua-language-server (per LSP) e stylua (per formattazione) siano installati.
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "lua-language-server", "stylua" })
    end,
  },

  -- 2. CONFORM.NVIM (Formatter): Usa stylua per i file Lua.
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        lua = { "stylua" },
      },
    },
  },

  -- 3. NVIM-LSPCONFIG: Configura lua-language-server (lua_ls).
  -- La configurazione qui è molto importante per far capire al LSP
  -- che stiamo lavorando in un ambiente Neovim e per fargli riconoscere globali come "vim".
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        lua_ls = {
          settings = {
            Lua = {
              runtime = {
                -- Usa la versione LuaJIT, che è quella usata da Neovim.
                version = "LuaJIT",
              },
              workspace = {
                -- Rende il server consapevole dei file di runtime di Neovim per l'autocompletamento.
                library = vim.api.nvim_get_runtime_file("", true),
                checkThirdParty = false,
              },
              -- Disabilita la telemetria per la privacy.
              telemetry = {
                enable = false,
              },
            },
          },
        },
      },
    },
  },

  -- 4. TREESITTER: Assicura che i parser per Lua e le query (utili per lo sviluppo) siano installati.
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "lua", "query" })
      end
    end,
  },
}
