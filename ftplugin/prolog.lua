-- Buffer-local settings & keymaps for Prolog files (tuProlog dialect).
-- Глобальные LSP-keymaps (K, gd, rn, ...) тут не работают — LSP не подключён.
-- Вместо этого делаем минимальные buffer-local fallback'и.

vim.bo.expandtab     = true
vim.bo.shiftwidth    = 2
vim.bo.softtabstop   = 2
vim.bo.tabstop       = 2
vim.bo.commentstring = "%% %s"
vim.opt_local.iskeyword:append("_")

-- Indent: используется встроенный $VIMRUNTIME/indent/prolog.vim
-- (GetPrologIndent): он понимает :- / --> / `.` / `(` / `;` / `->`.
-- treesitter-indent для prolog отключён в lua/plugins/treesitter.lua.

local ide = require("prolog.ide")

local function map(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { buffer = true, silent = true, desc = desc })
end

-- IDE / REPL управление
map("n", "<leader>pi", function() ide.toggle()           end, "Prolog: toggle 3-pane IDE")
map("n", "<leader>pq", function() ide.focus_query()      end, "Prolog: focus query")
map("n", "<leader>pc", function() ide.consult_current()  end, "Prolog: consult current file")
map("n", "<leader>pr", function() ide.restart()          end, "Prolog: restart REPL")
map("n", "<leader>pt", function() ide.toggle_trace()     end, "Prolog: toggle trace")
map("n", "<leader>ps", function() ide.spy_under_cursor() end, "Prolog: spy <cword>")
map("n", "<leader>pS", function() ide.nospy_under_cursor() end, "Prolog: nospy <cword>")

-- eval — как у clojure: <leader>e отправляет current line / выделение
map("n", "<leader>e", function() ide.send_line()   end, "Prolog: eval line")
map("x", "<leader>e", function()
  -- сохраняем выделение перед вызовом
  vim.cmd('noautocmd normal! "vy')
  ide.send_visual()
end, "Prolog: eval selection")

-- Авто-consult на :w если REPL уже запущен
local repl = require("prolog.repl")
vim.api.nvim_create_autocmd("BufWritePost", {
  buffer = 0,
  callback = function()
    if not repl.is_running() then return end
    ide.consult_current()
  end,
})

-- Buffer-local fallback'и для gd / K (LSP не используется).
-- gd: ищет первый clause с именем под курсором (`name(` или `name :-`)
map("n", "gd", function()
  local word = vim.fn.expand("<cword>")
  if word == "" then return end
  local pat = "\\v^\\s*" .. vim.fn.escape(word, [[\.*$^~[]]) .. "\\s*[(.:]"
  vim.fn.search(pat, "ws")
end, "Prolog: go to clause definition")

-- K: показывает все clauses под именем курсора в floating window
map("n", "K", function()
  local word = vim.fn.expand("<cword>")
  if word == "" then return end
  local matches = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l:match("^%s*" .. vim.pesc(word) .. "%s*[%(%.:]") then
      table.insert(matches, string.format("%4d │ %s", i, l))
    end
  end
  if #matches == 0 then
    vim.notify("Нет clauses для " .. word, vim.log.levels.INFO)
    return
  end
  -- открываем floating window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, matches)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "prolog"
  local width  = math.min(120, math.max(40, vim.fn.max(vim.tbl_map(function(s) return #s end, matches)) + 2))
  local height = math.min(20, #matches + 1)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor", row = 1, col = 0,
    width = width, height = height,
    border = "rounded", style = "minimal",
    title = " " .. word .. " ", title_pos = "left",
  })
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf })
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave", "InsertEnter" }, {
    once = true,
    callback = function() if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end end,
  })
end, "Prolog: show clauses for <cword>")
