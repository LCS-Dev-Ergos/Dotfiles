-- File: lua/plugins/snacks.lua (TO MODIFY)

return {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,
  opts = {
    -- Enable all useful modules, EXCEPT the dashboard
    dashboard = { enabled = false },

    -- All other snacks you want to use
    bigfile = { enabled = true },
    explorer = { enabled = true },
    indent = { enabled = true },
    input = { enabled = true },
    notifier = { enabled = true, timeout = 3000 },
    picker = { enabled = true },
    quickfile = { enabled = true },
    scope = { enabled = true },
    scroll = { enabled = true },
    statuscolumn = { enabled = true },
    words = { enabled = true },
    zen = { enabled = true },
  },
  -- Keep all Snacks shortcuts you have defined
  keys = {
    {
      "<leader><space>",
      function() require("snacks").picker.smart() end,
      desc = "Smart Find Files",
    },
    { "<leader>e", function() require("snacks").explorer() end, desc = "File Explorer" },
    { "<leader>ff", function() require("snacks").picker.files() end, desc = "Find Files" },
    { "<leader>fg", function() require("snacks").picker.grep() end, desc = "Grep" },
    { "<leader>fb", function() require("snacks").picker.buffers() end, desc = "Buffers" },
    { "<leader>z", function() require("snacks").zen() end, desc = "Toggle Zen Mode" },
    { "<leader>bd", function() require("snacks").bufdelete() end, desc = "Delete Buffer" },
    { "<leader>gg", function() require("snacks").lazygit() end, desc = "Lazygit" },
  },
  -- The 'config' function is no longer needed here
}
