-- =====-----------------------------------------------------------------=====
-- NIX (LINUX GUARD)
--
-- Not a language-support file like its siblings: this disables the Nix LSP
-- (nil_ls) on Linux hosts that don't have Nix installed (e.g. the Arch
-- install), without turning off Mason's automatic installation for anything
-- else. It skips `nil_ls` in lspconfig and strips it from Mason's
-- ensure_installed, then returns no specs at all on other platforms.
-- =====-----------------------------------------------------------------=====

local uname = vim.loop.os_uname().sysname

if uname == "Linux" then
  return {
    -- Stop LSP setup for "nil_ls".
    {
      "neovim/nvim-lspconfig",
      opts = {
        servers = {
          nil_ls = false,
        },
      },
    },
    -- Remove nil from Mason's ensure_installed list (if present).
    {
      "mason-org/mason.nvim",
      opts = require("lang_util").mason_exclude({ "nil", "nil_ls" }),
    },
  }
end

return {}
