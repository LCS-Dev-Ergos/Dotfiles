-- =====-----------------------------------------------------------------=====
-- JULIA
--
-- LanguageServer.jl is installed with Julia's Pkg in the nvim-lspconfig
-- environment, using the runtime on PATH. Its JuliaFormatter integration
-- supplies formatting through Conform's LSP support. Mason must not install
-- a second server. Mathematical Unicode input stays in Blink's menu.
-- Install with the active Julia runtime:
-- julia --project=~/.julia/environments/nvim-lspconfig \
--   -e 'using Pkg; Pkg.add("LanguageServer")'
-- =====-----------------------------------------------------------------=====

return {
  -- 1. MASON: Excludes the Julia-owned language server.
  {
    "mason-org/mason.nvim",
    ft = { "julia" },
    opts = require("lang_util").mason_exclude { "julia-lsp" },
  },

  -- 2. CONFORM.NVIM (Formatter): Uses JuliaFormatter through the language server.
  {
    "stevearc/conform.nvim",
    ft = { "julia" },
    opts = {
      formatters_by_ft = {
        julia = { lsp_format = "prefer" },
      },
    },
  },

  -- 3. NVIM-LSPCONFIG: Uses the native Julia toolchain and project environment.
  {
    "neovim/nvim-lspconfig",
    ft = { "julia" },
    opts = {
      servers = {
        julials = {
          mason = false,
          -- Keep the server's packages separate from the project's dependencies.
          cmd = function(dispatchers, config)
            local cmd = {
              "julia",
              "--startup-file=no",
              "--history-file=no",
              "--project=" .. vim.fn.expand("~/.julia/environments/nvim-lspconfig"),
              "-e",
              "using LanguageServer; LanguageServer.runserver(stdin, stdout, ARGS[1])",
              config.root_dir or vim.fn.getcwd(),
            }
            return vim.lsp.rpc.start(cmd, dispatchers, {
              cwd = config.root_dir,
              env = config.cmd_env,
            })
          end,
          settings = {
            julia = {
              completionmode = "qualify",
            },
          },
        },
      },
    },
  },

  -- 4. TREESITTER: Installs the Julia parser.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "julia" },
    opts = require("lang_util").treesitter_ensure { "julia" },
  },

  -- 5. BLINK.CMP: Adds LaTeX-style abbreviations for mathematical Unicode.
  {
    "saghen/blink.cmp",
    dependencies = { "kdheepak/cmp-latex-symbols", "saghen/blink.compat" },
    opts = {
      sources = {
        compat = { "latex_symbols" },
        providers = {
          latex_symbols = {
            kind = "LatexSymbols",
            async = true,
            opts = { strategy = 0 },
          },
        },
      },
    },
  },
}
