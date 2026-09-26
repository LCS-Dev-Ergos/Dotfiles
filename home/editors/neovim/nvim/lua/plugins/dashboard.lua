-- =====-----------------------------------------------------------------=====
-- DASHBOARD (SNACKS)
--
-- Start screen, replacing alpha-nvim (and LazyVim's lazyvim.json ui.alpha
-- extra, which forces snacks.dashboard off — removed together with this
-- file's addition). Snacks.dashboard.pick() defers to whatever picker is
-- actually configured (Snacks' own, since telescope.lua disables telescope),
-- so the file-finding keys stay correct regardless of cwd.
--
-- The two-pane structure follows Snacks' own "advanced" example, while the
-- header, menu, and other visual choices below stay personal.
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
          { icon = "󰂖 ", key = "u", desc = "Update plugins", action = ":!nvim-update-lock" },
          { icon = "󰩈 ", key = "q", desc = "Quit NVIM", action = ":qa" },
        },
      },
      sections = {
        { section = "header" },
        {
          pane = 2,
          section = "terminal",
          -- This colorscript emits an empty first and last row. Trim only
          -- those rows so the three-line drawing fits in the documented
          -- five-row terminal section.
          cmd = "colorscript -e square | sed '1d;$d'",
          height = 5,
          padding = 1,
          ttl = 3600,
          -- `square` is 58 display columns wide. Keep the personal two-column
          -- indent, but preserve the documented 60-column terminal viewport
          -- so Neovim does not soft-wrap at the final character.
          width = 60,
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
  config = function(_, opts)
    require("snacks").setup(opts)

    -- Neovim adds this virtual line when a terminal job exits. Dashboard
    -- sections are read-only snapshots, so retain their output but hide the
    -- process-status decoration only for buffers owned by Snacks Dashboard.
    local exitmsg_namespace = vim.api.nvim_create_namespace("nvim.terminal.exitmsg")
    local dashboard_terminals = vim.api.nvim_create_augroup("LcsDashboardTerminalExit", { clear = true })
    vim.api.nvim_create_autocmd("TermClose", {
      group = dashboard_terminals,
      callback = function(event)
        if vim.bo[event.buf].filetype == "snacks_dashboard" then
          vim.api.nvim_buf_clear_namespace(event.buf, exitmsg_namespace, 0, -1)
        end
      end,
    })
  end,
}
