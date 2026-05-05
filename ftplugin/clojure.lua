vim.bo.expandtab = true
vim.bo.shiftwidth = 2
vim.bo.softtabstop = 2
vim.bo.tabstop = 2

-- Format on save via clojure-lsp
vim.api.nvim_create_autocmd("BufWritePre", {
  buffer = 0,
  callback = function()
    vim.lsp.buf.format({ async = false, timeout_ms = 3000 })
  end,
})

local opts = { buffer = true, silent = true }
local function map(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", opts, { desc = desc }))
end

-- Manual format
map("n", "<leader>vf", function() vim.lsp.buf.format({ async = true }) end, "Format (cljfmt)")
map("v", "<leader>vf", function() vim.lsp.buf.format({ async = true }) end, "Format selection")

-- Tests (via Conjure nREPL)
map("n", "<leader>vt", function()
  vim.cmd("ConjureEval (clojure.test/run-tests)")
end, "Run tests in current ns")

map("n", "<leader>vT", function()
  vim.cmd("ConjureEval (clojure.test/run-all-tests)")
end, "Run all tests")

-- Reload namespaces (cider-refresh equivalent)
map("n", "<leader>vr", function()
  vim.cmd('ConjureEval (require \'clojure.tools.namespace.repl) (clojure.tools.namespace.repl/refresh)')
end, "Reload all namespaces")

-- Silent visual eval (override Conjure's default to suppress command flash)
map("v", "<localleader>E", function() vim.cmd("ConjureEvalVisual") end, "Eval selection")

-- nREPL connection
map("n", "<leader>vc", "<cmd>ConjureConnect<CR>", "Connect to nREPL")
map("n", "<leader>vd", "<cmd>ConjureDisconnect<CR>", "Disconnect from nREPL")
