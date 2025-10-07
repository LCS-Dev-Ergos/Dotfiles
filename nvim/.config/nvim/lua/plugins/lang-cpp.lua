-- File: lua/plugins/lang-cpp.lua
-- A complete, explicit, and robust configuration for C/C++

return {
  -- 1. MASON: Ensures tools are installed and provides their paths.
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      -- Add all our C/C++ tools here
      vim.list_extend(opts.ensure_installed, {
        "clangd",
        "clang-format",
        "codelldb", -- For debugging
      })
    end,
  },

  -- 2. CONFORM.NVIM (Formatter): Explicitly use Mason's clang-format.
  {
    "stevearc/conform.nvim",
    dependencies = { "mason-org/mason.nvim" },
    opts = {
      formatters_by_ft = {
        ["c"] = { "clang-format" },
        ["cpp"] = { "clang-format" },
      },
      -- We don't need to configure clang-format further.
      -- conform.nvim will find the executable from Mason, and
      -- clang-format will find the .clang-format file in project or home directory.
    },
  },

  -- 3. NVIM-LSPCONFIG: Configure clangd with explicit handlers.
  {
    "neovim/nvim-lspconfig",
    dependencies = {
      "mason-org/mason.nvim",
      "mason-lspconfig.nvim", -- This plugin bridges Mason and lspconfig
      "hrsh7th/cmp-nvim-lsp",
    },
    config = function()
      -- This is the bridge. It tells lspconfig to use the servers installed by Mason.
      require("mason-lspconfig").setup {
        -- A list of servers to setup.
        ensure_installed = { "clangd" },
      }

      -- Now we configure clangd specifically
      local lspconfig = require("lspconfig")
      local capabilities = require("cmp_nvim_lsp").default_capabilities()

      lspconfig.clangd.setup {
        -- We provide our own on_attach function here
        on_attach = function(client, bufnr)
          -- This is where you can define your LSP-related keymaps
          local nmap = function(keys, func, desc)
            if desc then desc = "LSP: " .. desc end
            vim.keymap.set("n", keys, func, { buffer = bufnr, desc = desc })
          end

          nmap("gD", vim.lsp.buf.declaration, "Goto Declaration")
          nmap("gd", vim.lsp.buf.definition, "Goto Definition")
          nmap("K", vim.lsp.buf.hover, "Hover Documentation")
          nmap("gi", vim.lsp.buf.implementation, "Goto Implementation")
          nmap("<leader>rn", vim.lsp.buf.rename, "Rename")
          nmap("<leader>ca", vim.lsp.buf.code_action, "Code Action")

          -- Keymap for formatting
          vim.keymap.set(
            "n",
            "<leader>cf",
            function() vim.lsp.buf.format { async = true } end,
            { buffer = bufnr, desc = "Format (LSP)" }
          )
        end,

        -- Pass capabilities for nvim-cmp
        capabilities = capabilities,

        -- Explicitly define the command with arguments
        cmd = {
          "clangd",
          "--background-index",
          "--clang-tidy",
          "--header-insertion=iwyu",
          "--completion-style=detailed",
        },

        -- Explicitly define the root directory logic
        root_dir = lspconfig.util.root_pattern(".clangd", "compile_commands.json", ".git"),
      }
    end,
  },

  -- 4. FILETYPE ASSOCIATION: This part is correct.
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      if not vim.tbl_contains(opts.ensure_installed, "cpp") then
        table.insert(opts.ensure_installed, "cpp")
      end
      vim.filetype.add {
        extension = {
          tpp = "cpp",
        },
      }
    end,
  },
}
