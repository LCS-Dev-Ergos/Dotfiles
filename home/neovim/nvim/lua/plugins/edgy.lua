-- =====-----------------------------------------------------------------=====
-- WINDOW LAYOUT (EDGY)
--
-- Docks Trouble, quickfix, DAP REPL, and help windows to fixed edge panels
-- instead of leaving them as regular splits.
-- =====-----------------------------------------------------------------=====

return {
  {
    "folke/edgy.nvim",
    event = "VeryLazy",
    opts = {
      animate = { enabled = false },
      bottom = {
        {
          ft = "trouble",
          title = "Problems",
          size = { height = 15 },
          filter = function(_, win)
            local t = vim.w[win].trouble
            return t ~= nil and t.type == "split" and t.position == "bottom"
          end,
        },
        { ft = "qf", title = "QuickFix" },
        { ft = "dap-repl", title = "DAP REPL", size = { height = 10 } },
      },
      right = {
        {
          ft = "trouble",
          title = "Symbols",
          size = { width = 35 },
          filter = function(_, win)
            local t = vim.w[win].trouble
            return t ~= nil and t.type == "split" and t.position == "right"
          end,
        },
        {
          ft = "help",
          title = "Help",
          size = { width = 82 },
          filter = function(buf)
            return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "help"
          end,
        },
      },
      options = {
        bottom = { size = 15 },
        right = { size = 82 },
      },
    },
  },
}
