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

pcall(vim.keymap.del, 'n', '<leader>cf', { buffer = true })
pcall(vim.keymap.del, 'v', '<leader>cf', { buffer = true })

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

local function split_lines(text)
  local lines = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    lines[#lines + 1] = line
  end
  return lines
end

local function format_cpp()
  local bufnr = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)

  if filename == "" then
    vim.notify("Save file before clang-format/clang-tidy", vim.log.levels.WARN)
    return
  end

  if vim.fn.executable("clang-format") ~= 1 then
    vim.notify("clang-format not found in PATH", vim.log.levels.ERROR)
    return
  end

  local source_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local input = table.concat(source_lines, "\n")
  if #source_lines > 0 then
    input = input .. "\n"
  end

  local fmt = vim.system({
    "clang-format",
    "-style=file",
    "-fallback-style=none",
    "--assume-filename",
    filename,
  }, {
    text = true,
    stdin = input,
  }):wait()

  if fmt.code ~= 0 then
    vim.notify((fmt.stderr and fmt.stderr ~= "") and fmt.stderr or "clang-format failed", vim.log.levels.ERROR)
    return
  end

  local formatted = vim.split(fmt.stdout, "\n", { plain = true })
  if formatted[#formatted] == "" then
    table.remove(formatted, #formatted)
  end

  if not vim.deep_equal(source_lines, formatted) then
    local view = vim.fn.winsaveview()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, formatted)
    vim.fn.winrestview(view)
  end

  vim.cmd("silent update")
end

local function tidy_cpp()
  local bufnr = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)

  if filename == "" then
    vim.notify("Save file before clang-tidy", vim.log.levels.WARN)
    return
  end

  if vim.bo[bufnr].modified then
    vim.cmd("silent update")
  end

  if vim.fn.executable("clang-tidy") ~= 1 then
    vim.notify("clang-tidy not found in PATH", vim.log.levels.WARN)
    return
  end

  local search_from = vim.fs.dirname(filename)
  local compile_db = vim.fs.find("compile_commands.json", { upward = true, path = search_from })[1]
  if not compile_db then
    vim.notify("Skipped clang-tidy: compile_commands.json not found", vim.log.levels.WARN)
    return
  end

  local tidy_cfg = vim.fs.find(".clang-tidy", { upward = true, path = search_from })[1]
  local tidy_cmd = {
    "clang-tidy",
    filename,
    "-p",
    vim.fs.dirname(compile_db),
    "--quiet",
  }

  if tidy_cfg then
    tidy_cmd[#tidy_cmd + 1] = "--config-file=" .. tidy_cfg
  end

  local tidy = vim.system(tidy_cmd, { text = true }):wait()
  local lines = split_lines((tidy.stdout or "") .. "\n" .. (tidy.stderr or ""))

  if #lines > 0 then
    vim.fn.setqflist({}, "r", {
      title = "clang-tidy: " .. vim.fn.fnamemodify(filename, ":t"),
      lines = lines,
      efm = "%f:%l:%c: %trror: %m,%f:%l:%c: %tarning: %m,%f:%l:%c: %tnote: %m",
    })
    vim.cmd("cwindow")
  else
    vim.fn.setqflist({}, "r", { title = "clang-tidy: " .. vim.fn.fnamemodify(filename, ":t"), lines = {} })
    vim.cmd("cclose")
  end

  if tidy.code == 0 then
    vim.notify("clang-tidy completed", vim.log.levels.INFO)
  else
    vim.notify("clang-tidy finished with diagnostics", vim.log.levels.WARN)
  end
end

-- Биндинги без пересечений: не являются префиксами других и не имеют префиксов
vim.keymap.set('n', '<leader>x', format_cpp,
  vim.tbl_extend('force', opts, { desc = "clang-format (.clang-format)" }))
vim.keymap.set('n', '<leader>X', tidy_cpp,
  vim.tbl_extend('force', opts, { desc = "clang-tidy (.clang-tidy)" }))

-- Быстрая компиляция текущего файла (для проверки синтаксиса)
vim.keymap.set('n', '<leader>cc', function()
  local file = vim.fn.expand('%')
  vim.cmd('!g++ -std=c++20 -Wall -Wextra -fsyntax-only ' .. file)
end, vim.tbl_extend('force', opts, { desc = "Syntax check" }))
