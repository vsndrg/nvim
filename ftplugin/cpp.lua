-- ftplugin/cpp.lua
-- Настройки только для C++
vim.bo.expandtab = true
vim.bo.shiftwidth = 2
vim.bo.softtabstop = 2
vim.bo.tabstop = 2

vim.bo.cindent = true
vim.bo.cinoptions = "g0,t0,(0,u0,w0"

-- ═══════════════════════════════════════════════════════════════════════════
-- C++ специфичные keymaps (clangd)
-- ═══════════════════════════════════════════════════════════════════════════

local opts = { buffer = true, silent = true }

-- Переключение между header (.h/.hpp) и source (.c/.cpp) — ОЧЕНЬ полезно
vim.keymap.set('n', '<leader>ch', '<cmd>ClangdSwitchSourceHeader<cr>',
  vim.tbl_extend('force', opts, { desc = "Switch header/source" }))

-- Альтернативный маппинг на F4 (как в VS/Qt Creator)
vim.keymap.set('n', '<F4>', '<cmd>ClangdSwitchSourceHeader<cr>', opts)

-- Информация о символе под курсором
vim.keymap.set('n', '<leader>ci', '<cmd>ClangdSymbolInfo<cr>',
  vim.tbl_extend('force', opts, { desc = "Symbol info" }))

-- Type hierarchy (показывает наследование классов)
vim.keymap.set('n', '<leader>ct', '<cmd>ClangdTypeHierarchy<cr>',
  vim.tbl_extend('force', opts, { desc = "Type hierarchy" }))

-- AST дерево (для дебага парсинга)
vim.keymap.set('n', '<leader>cA', '<cmd>ClangdAST<cr>',
  vim.tbl_extend('force', opts, { desc = "Show AST" }))

-- Memory usage (полезно для больших проектов)
vim.keymap.set('n', '<leader>cm', '<cmd>ClangdMemoryUsage<cr>',
  vim.tbl_extend('force', opts, { desc = "Memory usage" }))

-- Toggle inlay hints (показ типов, имён параметров)
vim.keymap.set('n', '<leader>cH', function()
  vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled())
end, vim.tbl_extend('force', opts, { desc = "Toggle inlay hints" }))

-- Форматирование файла через clang-format
vim.keymap.set('n', '<leader>cf', function()
  vim.lsp.buf.format({ async = true })
end, vim.tbl_extend('force', opts, { desc = "Format file" }))

-- Форматирование выделенного участка
vim.keymap.set('v', '<leader>cf', function()
  vim.lsp.buf.format({ async = true })
end, vim.tbl_extend('force', opts, { desc = "Format selection" }))

-- Быстрая компиляция текущего файла (для проверки синтаксиса)
vim.keymap.set('n', '<leader>cc', function()
  local file = vim.fn.expand('%')
  vim.cmd('!g++ -std=c++20 -Wall -Wextra -fsyntax-only ' .. file)
end, vim.tbl_extend('force', opts, { desc = "Syntax check" }))

