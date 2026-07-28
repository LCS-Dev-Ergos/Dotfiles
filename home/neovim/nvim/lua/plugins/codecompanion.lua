-- =====-----------------------------------------------------------------=====
-- CODECOMPANION.NVIM
--
-- Agentic AI chat/edit in Neovim (buffer-native chat, inline edits, @lsp
-- context). LazyVim doesn't bundle an extra for it, so this is a plain
-- custom spec, the same way lang-scala.lua and lang-csharp.lua sit outside
-- lazyvim.json's opinionated set.
--
-- Defaults to the Copilot adapter, reusing the OAuth session that
-- lazyvim.json's ai.copilot extra already sets up (no new credential to
-- manage). Switch the adapters below to "anthropic" (needs ANTHROPIC_API_KEY
-- on PATH) to talk to Claude directly instead.
-- =====-----------------------------------------------------------------=====

return {
  "olimorris/codecompanion.nvim",
  cmd = { "CodeCompanion", "CodeCompanionChat", "CodeCompanionActions" },
  keys = {
    { "<leader>aa", "<cmd>CodeCompanionActions<cr>", mode = { "n", "v" }, desc = "CodeCompanion Actions" },
    { "<leader>ac", "<cmd>CodeCompanionChat Toggle<cr>", mode = { "n", "v" }, desc = "CodeCompanion Chat" },
    { "<leader>ap", "<cmd>CodeCompanionChat Add<cr>", mode = "v", desc = "Add Selection to Chat" },
  },
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-treesitter/nvim-treesitter",
  },
  opts = {
    strategies = {
      chat = { adapter = "copilot" },
      inline = { adapter = "copilot" },
    },
  },
}
