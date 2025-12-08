-- ftplugin/c.lua
-- Настройки только для C (локально для буфера)
-- Allman + 2 пробела
vim.bo.expandtab = true
vim.bo.shiftwidth = 2
vim.bo.softtabstop = 2
vim.bo.tabstop = 2

-- Включаем cindent для корректной перестановки отступов в C-family
vim.bo.cindent = true

-- Настройка cinoptions для более «приближённого» поведения Allman
vim.bo.cinoptions = "g0,t0,(0,u0,w0"

-- ═══════════════════════════════════════════════════════════════════════════
-- C специфичные keymaps (clangd)
-- ═══════════════════════════════════════════════════════════════════════════

local opts = { buffer = true, silent = true }

-- Переключение между header (.h) и source (.c)
vim.keymap.set('n', '<leader>ch', '<cmd>ClangdSwitchSourceHeader<cr>',
  vim.tbl_extend('force', opts, { desc = "Switch header/source" }))
vim.keymap.set('n', '<F4>', '<cmd>ClangdSwitchSourceHeader<cr>', opts)

-- Информация о символе под курсором
vim.keymap.set('n', '<leader>ci', '<cmd>ClangdSymbolInfo<cr>',
  vim.tbl_extend('force', opts, { desc = "Symbol info" }))

-- Type hierarchy
vim.keymap.set('n', '<leader>ct', '<cmd>ClangdTypeHierarchy<cr>',
  vim.tbl_extend('force', opts, { desc = "Type hierarchy" }))

-- Toggle inlay hints
vim.keymap.set('n', '<leader>cH', function()
  vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled())
end, vim.tbl_extend('force', opts, { desc = "Toggle inlay hints" }))

-- Форматирование через clang-format
vim.keymap.set('n', '<leader>cf', function()
  vim.lsp.buf.format({ async = true })
end, vim.tbl_extend('force', opts, { desc = "Format file" }))

vim.keymap.set('v', '<leader>cf', function()
  vim.lsp.buf.format({ async = true })
end, vim.tbl_extend('force', opts, { desc = "Format selection" }))

-- Быстрая проверка синтаксиса
vim.keymap.set('n', '<leader>cc', function()
  local file = vim.fn.expand('%')
  vim.cmd('!gcc -Wall -Wextra -fsyntax-only ' .. file)
end, vim.tbl_extend('force', opts, { desc = "Syntax check" }))

