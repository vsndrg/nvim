-- ftplugin/cpp.lua — buffer-local options for C++ files.
-- All C/C++ LSP keymaps, formatting, and tooling are wired in
-- lua/lang/cpp.lua via an LspAttach autocmd.

vim.bo.expandtab = true
vim.bo.shiftwidth = 4
vim.bo.softtabstop = 4
vim.bo.tabstop = 4

vim.bo.cindent = true
vim.bo.cinoptions = "g0,t0,(0,u0,w0"
