-- Disable Nix LSP on systems without Nix (e.g., Arch install), without
-- turning off Mason's automatic installation for everything else.
-- It just skips `nil_ls` and avoids adding it to Mason's ensure_installed.
local uname = vim.loop.os_uname().sysname

if uname == "Linux" then
  return {
    -- Stop LSP setup for nil_ls
    {
      "neovim/nvim-lspconfig",
      opts = {
        servers = {
          nil_ls = false,
        },
      },
    },
    -- Remove nil from Mason's ensure_installed list (if present)
    {
      "williamboman/mason.nvim",
      opts = function(_, opts)
        local skip = { nil = true, nil_ls = true }
        opts.ensure_installed = vim.tbl_filter(function(pkg)
          return not skip[pkg]
        end, opts.ensure_installed or {})
      end,
    },
  }
end

return {}
