vim.bo.expandtab = true
vim.bo.shiftwidth = 4
vim.bo.softtabstop = 4
vim.bo.tabstop = 4

local opts = { buffer = true, silent = true }
local function map(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", opts, { desc = desc }))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Hover / Code actions (override global mappings with Rust-enriched versions)
-- ═══════════════════════════════════════════════════════════════════════════

map("n", "K", function() vim.cmd.RustLsp({ "hover", "actions" }) end,
  "Rust hover actions")

map("n", "<leader>ca", function() vim.cmd.RustLsp("codeAction") end,
  "Rust code action (grouped)")

-- ═══════════════════════════════════════════════════════════════════════════
-- Run / Debug / Test
-- ═══════════════════════════════════════════════════════════════════════════

map("n", "<leader>rr", function() vim.cmd.RustLsp("runnables") end, "Runnables")
map("n", "<leader>rd", function() vim.cmd.RustLsp("debuggables") end, "Debuggables")
map("n", "<leader>rt", function() vim.cmd.RustLsp("testables") end, "Testables")

-- ═══════════════════════════════════════════════════════════════════════════
-- Navigation & info
-- ═══════════════════════════════════════════════════════════════════════════

map("n", "<leader>rc", function() vim.cmd.RustLsp("openCargo") end, "Open Cargo.toml")
map("n", "<leader>rp", function() vim.cmd.RustLsp("parentModule") end, "Parent module")
map("n", "<leader>ro", function() vim.cmd.RustLsp("openDocs") end, "Open docs.rs")

-- ═══════════════════════════════════════════════════════════════════════════
-- Diagnostics & macros
-- ═══════════════════════════════════════════════════════════════════════════

map("n", "<leader>re", function() vim.cmd.RustLsp("explainError") end, "Explain error")
map("n", "<leader>rD", function() vim.cmd.RustLsp("renderDiagnostic") end, "Render diagnostic")
map("n", "<leader>rm", function() vim.cmd.RustLsp("expandMacro") end, "Expand macro")

-- ═══════════════════════════════════════════════════════════════════════════
-- Editing helpers
-- ═══════════════════════════════════════════════════════════════════════════

map("n", "J", function() vim.cmd.RustLsp("joinLines") end, "Rust smart join")

map("n", "<leader>rH", function()
  vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled())
end, "Toggle inlay hints")

map("n", "<leader>rf", function()
  vim.lsp.buf.format({ async = true })
end, "Format file (rustfmt)")

map("v", "<leader>rf", function()
  vim.lsp.buf.format({ async = true })
end, "Format selection")
