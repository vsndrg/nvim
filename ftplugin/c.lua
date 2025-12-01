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
-- Это базовые значения; при желании можно тонко подстроить позже.
vim.bo.cinoptions = "g0,t0,(0,u0,w0"

-- Не трогаем global smartindent; используем cindent в ftplugin

