-- =====-----------------------------------------------------------------=====
-- MARKDOWN
--
-- markdownlint (linter) comes from Mason and stays off by default, toggled
-- with <leader>tl. prettier (formatter) isn't installed here: the
-- formatting.prettier LazyVim extra already provides it. This file also adds
-- an in-browser live preview and its own which-key group label.
-- =====-----------------------------------------------------------------=====

return {
  -- 1. MASON: markdownlint for linting.
  {
    "mason-org/mason.nvim",
    ft = { "markdown" },
    opts = require("lang_util").mason_ensure({ "markdownlint" }),
  },

  -- 2. NVIM-LINT: markdownlint is off by default; toggle with <leader>tl.
  {
    "mfussenegger/nvim-lint",
    ft = { "markdown" },
    opts = {
      linters_by_ft = {
        markdown = {},
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
            lint.linters_by_ft.markdown = { linter }
            lint.try_lint()
            vim.notify("Markdown linting enabled", vim.log.levels.INFO)
          else
            lint.linters_by_ft.markdown = {}
            local ns = lint.get_namespace(linter)
            vim.diagnostic.reset(ns, vim.api.nvim_get_current_buf())
            vim.notify("Markdown linting disabled", vim.log.levels.INFO)
          end
        end,
        desc = "Toggle markdown linting",
        ft = "markdown",
      },
    },
  },

  -- 3. CONFORM.NVIM (Formatter): prettier, installed by the prettier extra.
  {
    "stevearc/conform.nvim",
    ft = { "markdown" },
    opts = {
      formatters_by_ft = {
        markdown = { "prettier" },
      },
    },
  },

  -- 4. TREESITTER: markdown parsers.
  {
    "nvim-treesitter/nvim-treesitter",
    ft = { "markdown" },
    opts = require("lang_util").treesitter_ensure({ "markdown", "markdown_inline" }),
  },

  -- 5. MARKDOWN PREVIEW: live preview in browser.
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

  -- 6. WHICH-KEY: register the <leader>t group label.
  {
    "folke/which-key.nvim",
    optional = true,
    opts = function(_, opts)
      opts.spec = opts.spec or {}
      table.insert(opts.spec, { "<leader>t", group = "󰦨 Toggle" })
    end,
  },
}
