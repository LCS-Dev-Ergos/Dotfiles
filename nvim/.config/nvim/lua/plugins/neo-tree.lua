-- File: lua/plugins/neo-tree.lua

return {
  "nvim-neo-tree/neo-tree.nvim",
  branch = "v3.x",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-tree/nvim-web-devicons",
    "MunifTanjim/nui.nvim",
  },
  opts = {
    close_if_last_window = true,
    popup_border_style = "rounded",
    enable_git_status = true,
    enable_diagnostics = true,

    -- Default options for all commands.
    default_component_configs = {
      -- Configuration for the git_status component.
      git_status = {
        symbols = {
          -- used by 'git status'
          added = "", -- "", "", ""
          deleted = "", -- "", "", ""
          modified = "", -- "", ""
          renamed = "", -- ""
          -- used by 'git diff'
          unmerged = "",
          untracked = "",
          ignored = "◌",
          staged = "✓",
          unstaged = "✗",
          conflict = "",
        },
      },
    },

    -- Defines the windows and their composition.
    window = {
      -- Key mappings inside neo-tree.
      mappings = {
        ["<space>"] = "none",
        ["A"] = "git_add_all",
        ["gu"] = "git_unstage_file",
        ["ga"] = "git_add_file",
        ["gr"] = "git_revert_file",
        ["gc"] = "git_commit",
        ["gp"] = "git_push",
        ["gg"] = "refresh",
      },
    },

    -- Specific configuration for the filesystem.
    filesystem = {
      -- Order in which components are rendered for each line.
      renderers = {
        name = {
          { "git_status", "icon", "name" },
        },
      },
      filtered_items = {
        visible = true,
        hide_dotfiles = false,
        hide_gitignored = true,
        hide_by_name = {
          ".git",
          ".DS_Store",
          "thumbs.db",
        },
      },
    },
  },
}
