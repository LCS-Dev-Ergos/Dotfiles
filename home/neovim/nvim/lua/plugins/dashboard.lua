-- =====-----------------------------------------------------------------=====
-- DASHBOARD (SNACKS)
--
-- Start screen, replacing alpha-nvim (and LazyVim's lazyvim.json ui.alpha
-- extra, which forces snacks.dashboard off — removed together with this
-- file's addition). Snacks.dashboard.pick() defers to whatever picker is
-- actually configured (Snacks' own, since telescope.lua disables telescope),
-- so the file-finding keys stay correct regardless of cwd.
--
-- Layout follows Snacks' own "advanced" example verbatim (two panes, no
-- width/pane_gap override) instead of a hand-tuned size.
-- =====-----------------------------------------------------------------=====

return {
  "folke/snacks.nvim",
  opts = {
    dashboard = {
      enabled = true,
      preset = {
        header = [[
██╗      ██████╗███████╗   ██████╗ ███████╗██╗   ██╗
██║     ██╔════╝██╔════╝   ██╔══██╗██╔════╝██║   ██║
██║     ██║     ███████╗   ██║  ██║█████╗  ██║   ██║
██║     ██║     ╚════██║   ██║  ██║██╔══╝  ╚██╗ ██╔╝
███████╗╚██████╗███████║██╗██████╔╝███████╗ ╚████╔╝
╚══════╝ ╚═════╝╚══════╝╚═╝╚═════╝ ╚══════╝  ╚═══╝
]],
        keys = {
          { icon = "󰈙 ", key = "e", desc = "New file", action = ":ene | startinsert" },
          { icon = "󰈞 ", key = "f", desc = "Find file", action = function() Snacks.dashboard.pick("files") end },
          { icon = "󰱼 ", key = "g", desc = "Find word", action = function() Snacks.dashboard.pick("live_grep") end },
          { icon = "󰋚 ", key = "r", desc = "Recent", action = function() Snacks.dashboard.pick("oldfiles") end },
          { icon = "󰦛 ", key = "s", desc = "Restore session", section = "session" },
          { icon = "󰒓 ", key = "c", desc = "Config", action = ":e $MYVIMRC" },
          { icon = "󱌣 ", key = "m", desc = "Mason", action = ":Mason" },
          { icon = "󰒲 ", key = "l", desc = "Lazy", action = ":Lazy" },
          { icon = "󰂖 ", key = "u", desc = "Update plugins", action = function() require("lazy").sync() end },
          { icon = "󰩈 ", key = "q", desc = "Quit NVIM", action = ":qa" },
        },
      },
      sections = {
        { section = "header" },
        {
          pane = 2,
          section = "terminal",
          -- height matches `square`'s actual output so the box has no dead
          -- space. The trailing sleep keeps the job alive so Neovim's own
          -- terminal-exit message never appears (jobstart's term=true
          -- always appends one on exit); it's killed on buffer close anyway.
          cmd = "colorscript -e square; sleep 60",
          height = 5,
          padding = 1,
          ttl = 3600,
          indent = 2,
        },
        { section = "keys", gap = 1, padding = 1 },
        { pane = 2, icon = "󰋚 ", title = "Recent Files", section = "recent_files", indent = 2, padding = 1 },
        { pane = 2, icon = "󰉋 ", title = "Projects", section = "projects", indent = 2, padding = 1 },
        {
          pane = 2,
          icon = " ",
          title = "Git Status",
          section = "terminal",
          enabled = function() return Snacks.git.get_root() ~= nil end,
          cmd = "git status --short --branch --renames",
          height = 5,
          padding = 1,
          ttl = 5 * 60,
          indent = 3,
        },
        { section = "startup" },
        {
          align = "center",
          padding = 1,
          text = {
            { "\n Made with 󰩖  by LCS.Developer" },
          },
        },
      },
    },
  },
}
