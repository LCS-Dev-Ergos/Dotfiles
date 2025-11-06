-- File: lua/plugins/lang-markdown.lua

return {
  -- 1. MASON: Install linter and prettier for formatting.
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "markdownlint", "prettier" })
    end,
  },

  -- 2. NVIM-LINT: Configure markdownlint with toggle.
  {
    "mfussenegger/nvim-lint",
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
          
          if #current == 0 then
            -- Attiva il linting
            lint.linters_by_ft.markdown = { "markdownlint" }
            lint.try_lint()
            vim.notify("Markdown linting enabled", vim.log.levels.INFO)
          else
            -- Disattiva il linting
            lint.linters_by_ft.markdown = {}
            vim.diagnostic.reset(nil, 0)
            vim.notify("Markdown linting disabled", vim.log.levels.INFO)
          end
        end,
        desc = "Toggle markdown linting",
        ft = "markdown",
      },
    },
  },

  -- 3. CONFORM.NVIM (Optional): Use prettier for markdown formatting.
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        markdown = { "prettier" },
      },
    },
  },

  -- 4. TREESITTER: Ensure markdown parsers are installed.
  {
    "nvim-treesitter/nvim-treesitter",
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

  -- 6. SPELL CHECKING: Configure spell checking for markdown files.
  {
    "LazyVim/LazyVim",
    opts = function(_, opts)
      -- Enable spell checking for markdown files
      vim.api.nvim_create_autocmd("FileType", {
        pattern = "markdown",
        callback = function()
          vim.opt_local.spell = true
          vim.opt_local.spelllang = "it,en"  -- Italiano come prima lingua, inglese come seconda
        end,
      })
    end,
  },
}