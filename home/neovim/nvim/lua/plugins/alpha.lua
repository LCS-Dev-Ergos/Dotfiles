return {
  "goolord/alpha-nvim",
  event = "VimEnter",
  dependencies = {
    "nvim-tree/nvim-web-devicons",
  },

  config = function()
    local alpha = require("alpha")
    local dashboard = require("alpha.themes.dashboard")

    dashboard.section.header.val = {
      [[																											                              ]],
      [[   ██╗      ██████╗███████╗    ███╗   ██╗███████╗ ██████╗ ██╗   ██╗██╗███╗   ███╗   ]],
      [[   ██║     ██╔════╝██╔════╝    ████╗  ██║██╔════╝██╔═══██╗██║   ██║██║████╗ ████║   ]],
      [[   ██║     ██║     ███████╗    ██╔██╗ ██║█████╗  ██║   ██║██║   ██║██║██╔████╔██║   ]],
      [[   ██║     ██║     ╚════██║    ██║╚██╗██║██╔══╝  ██║   ██║╚██╗ ██╔╝██║██║╚██╔╝██║   ]],
      [[   ███████╗╚██████╗███████║    ██║ ╚████║███████╗╚██████╔╝ ╚████╔╝ ██║██║ ╚═╝ ██║   ]],
      [[   ╚══════╝ ╚═════╝╚══════╝    ╚═╝  ╚═══╝╚══════╝ ╚═════╝   ╚═══╝  ╚═╝╚═╝     ╚═╝   ]],
      [[																											                              ]],
    }

    dashboard.section.buttons.val = {
      dashboard.button("e", "󰈙   New file", ":ene <BAR> startinsert <CR>"),
      dashboard.button("f", "󰈞   Find file", "<cmd>lua require('snacks').picker.files({ cwd = vim.fn.expand('~/Dotfiles') })<cr>"),
      dashboard.button("g", "󰱼   Find word", "<cmd>lua require('snacks').picker.grep()<cr>"),
      dashboard.button("r", "󰋚   Recent", "<cmd>lua require('snacks').picker.recent()<cr>"),
      dashboard.button("c", "󰒓   Config", ":e $MYVIMRC <CR>"),
      dashboard.button("m", "󱌣   Mason", ":Mason<CR>"),
      dashboard.button("l", "󰒲   Lazy", ":Lazy<CR>"),
      dashboard.button("u", "󰂖   Update plugins", "<cmd>lua require('lazy').sync()<CR>"),
      dashboard.button("q", "󰩈   Quit NVIM", ":qa<CR>"),
    }

    dashboard.section.footer.val = ""
    dashboard.opts.opts.noautocmd = true
    alpha.setup(dashboard.opts)

    vim.api.nvim_create_autocmd("User", {
      pattern = "LazyVimStarted",
      callback = function()
        local stats = require("lazy").stats()
        local count = (math.floor(stats.startuptime * 100) / 100)
        dashboard.section.footer.val = {
          "󱐌 " .. stats.count .. " plugins loaded in " .. count .. " ms",
          " ",
          "Made with 󰩖  by LCS.Developer",
          "    Lombardi Costantino",
        }
        pcall(vim.cmd.AlphaRedraw)
      end,
    })
  end,
}
