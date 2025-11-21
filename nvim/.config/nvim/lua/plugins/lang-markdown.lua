-- File: lua/plugins/lang-markdown.lua

return {
  -- 1. MASON: Install linter and prettier for formatting.
  {
    "mason-org/mason.nvim",
    ft = { "markdown" },
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "markdownlint", "prettier" })
    end,
  },

  -- 2. NVIM-LINT: Configure markdownlint with toggle.
  {
    "mfussenegger/nvim-lint",
    ft = { "markdown" },
    opts = {
      linters_by_ft = {
        markdown = {},  -- Start with no linters enabled for markdown.
      },
    },
    keys = {
      {
        "<leader>tl",
        function()
          local lint = require("lint")
          local current = lint.linters_by_ft.markdown or {}
          local linter = "markdownlint"

          if #current == 0 then
            -- Attiva il linting
            lint.linters_by_ft.markdown = { linter }
            lint.try_lint()
            vim.notify("Markdown linting enabled", vim.log.levels.INFO)
          else
            -- Disattiva il linting
            lint.linters_by_ft.markdown = {}
            local current_buf = vim.api.nvim_get_current_buf()
            local ns = lint.get_namespace(linter)
            vim.diagnostic.reset(ns, current_buf)
            vim.notify("Markdown linting disabled", vim.log.levels.INFO)
          end
        end,
        desc = " Toggle markdown linting",
        ft = "markdown",
      },
    },
  },

  -- 3. CONFORM.NVIM (Optional): Use prettier for markdown formatting.
  {
    "stevearc/conform.nvim",
    ft = { "markdown" },
    opts = {
      formatters_by_ft = {
        markdown = { "prettier" },
      },
    },
  },

  -- 4. TREESITTER: Ensure markdown parsers are installed.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "markdown" },
    opts = function(_, opts)
      if type(opts.ensure_installed) == "table" then
        vim.list_extend(opts.ensure_installed, { "markdown", "markdown_inline" })
      end
    end,
  },

  -- 5. MARKDOWN PREVIEW: Live preview in browser.
  {
    "iamcco/markdown-preview.nvim",
    cmd = { "MarkdownPreviewToggle", "MarkdownPreview", "MarkdownPreviewStop" },
    ft = { "markdown" },
    build = function()
      require("lazy").load({ plugins = { "markdown-preview.nvim" } })
      vim.fn["mkdp#util#install"]()
    end,
    init = function()
      vim.g.mkdp_filetypes = { "markdown" }
    end,
  },

  -- 6. WHICH-KEY: Show a label for the <leader>t group in the main menu.
  {
    "folke/which-key.nvim",
    optional = true,
    opts = function(_, opts)
      opts.spec = opts.spec or {}
      table.insert(opts.spec, { "<leader>t", group = "󰦨 Toggle" })
      table.insert(opts.spec, {
        "<leader>tl",
        desc = " Toggle markdown linting",
        mode = { "n" },
      })
    end,
  },

  -- 7. SPELL CHECKING: Configure spell checking for markdown files.
  {
    "LazyVim/LazyVim",
    ft = { "markdown" },
    opts = function(_, opts)
      -- Enable spell checking for markdown files
      vim.api.nvim_create_autocmd("FileType", {
        pattern = "markdown",
        callback = function()
          vim.opt_local.spell = true
          vim.opt_local.spelllang = "it,en"
        end,
      })
    end,
  },
}
