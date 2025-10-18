-- File: lua/plugins/lang-cpp.lua

return {
  -- 1. MASON: Ensures tools are installed.
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, {
        "clangd",
        "clang-format",
        "codelldb", -- For debugging.
      })
    end,
  },

  -- 2. CONFORM.NVIM (Formatter): Uses Mason's clang-format.
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        c = { "clang_format" },
        cpp = { "clang_format" },
      },
    },
  },

  -- 3. NVIM-LSPCONFIG: Configure clangd using LazyVim's pattern.
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        clangd = {
          -- Command with useful flags.
          cmd = {
            "clangd",
            "--background-index",
            "--clang-tidy",
            "--header-insertion=iwyu",
            "--completion-style=detailed",
            "--function-arg-placeholders",
            "--fallback-style=llvm",
          },
          -- Define root directory detection.
          root_dir = function(fname)
            return require("lspconfig.util").root_pattern(
              ".clangd",
              ".clang-tidy",
              ".clang-format",
              "compile_commands.json",
              "compile_flags.txt",
              "configure.ac",
              ".git"
            )(fname) or vim.fn.getcwd()
          end,
          -- Capabilities are automatically handled by LazyVim.
          capabilities = {
            offsetEncoding = { "utf-16" },
          },
          -- Initial options
          init_options = {
            usePlaceholders = true,
            completeUnimported = true,
            clangdFileStatus = true,
          },
        },
      },
    },
  },

  -- 4. TREESITTER: Ensure C/C++ parsers are installed.
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "c", "cpp" })
      end
    end,
  },

  -- 5. FILETYPE ASSOCIATION: Associate .tpp files with cpp.
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function()
      vim.filetype.add({
        extension = {
          tpp = "cpp",
        },
      })
    end,
  },
}