-- 3-pane Prolog IDE layout (как в tuProlog IDE):
--   ┌─ editor (current .pl)
--   ├─ [prolog-query]   — поле ввода query (Enter — отправить, S-CR/C-CR — newline)
--   └─ [prolog-output]  — append-only вывод результатов
--
-- Все взаимодействие с tuProlog проходит через lua/prolog/repl.lua.

local repl = require("prolog.repl")

local M = {}

local QUERY_NAME  = "prolog://query"
local OUTPUT_NAME = "prolog://output"

local state = {
  query_buf   = nil,
  output_buf  = nil,
  query_win   = nil,
  output_win  = nil,
  trace_on    = false,
  history     = {},
  history_idx = 0,
}

-- ──────────────── helpers ────────────────

local function buf_by_name(name)
  local nr = vim.fn.bufnr(name)
  if nr ~= -1 and vim.api.nvim_buf_is_valid(nr) then return nr end
  return nil
end

local function ensure_buf(name, ft, modifiable)
  local b = buf_by_name(name)
  if b then return b end
  b = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, b, name)
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "hide"
  vim.bo[b].swapfile = false
  if ft then vim.bo[b].filetype = ft end
  if modifiable ~= nil then vim.bo[b].modifiable = modifiable end
  return b
end

local function append_output(text)
  if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then return end
  vim.bo[state.output_buf].modifiable = true
  local lines = vim.split(text or "", "\n", { plain = true })
  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  table.insert(lines, "")  -- разделитель между блоками
  local last = vim.api.nvim_buf_line_count(state.output_buf)
  -- если буфер пустой (одна пустая строка), пишем с самого начала
  if last == 1 then
    local first = vim.api.nvim_buf_get_lines(state.output_buf, 0, 1, false)[1] or ""
    if first == "" then last = 0 end
  end
  vim.api.nvim_buf_set_lines(state.output_buf, last, last, false, lines)
  vim.bo[state.output_buf].modifiable = false
  if state.output_win and vim.api.nvim_win_is_valid(state.output_win) then
    local lc = vim.api.nvim_buf_line_count(state.output_buf)
    pcall(vim.api.nvim_win_set_cursor, state.output_win, { lc, 0 })
  end
end

local function reply(prefix)
  return function(result)
    vim.schedule(function()
      append_output((prefix or "") .. (result or ""))
    end)
  end
end

local function ensure_output_visible()
  if state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf) then return true end
  return false
end

local function send_query_text(text)
  if not text or text:match("^%s*$") then return end
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text:sub(1, 2) == "?-" then text = text:sub(3):gsub("^%s+", "") end
  if not text:match("%.$") then text = text .. "." end

  table.insert(state.history, text)
  state.history_idx = #state.history + 1

  append_output("?- " .. text)
  repl.query(text, reply(""))
end

local function submit_current_query()
  if not state.query_buf or not vim.api.nvim_buf_is_valid(state.query_buf) then return end
  local lines = vim.api.nvim_buf_get_lines(state.query_buf, 0, -1, false)
  local text  = table.concat(lines, "\n")
  if text:match("^%s*$") then return end
  send_query_text(text)
  vim.api.nvim_buf_set_lines(state.query_buf, 0, -1, false, { "" })
  if state.query_win and vim.api.nvim_win_is_valid(state.query_win) then
    pcall(vim.api.nvim_win_set_cursor, state.query_win, { 1, 0 })
  end
end

local function recall_history(delta)
  if #state.history == 0 then return end
  state.history_idx = math.max(1, math.min(#state.history, (state.history_idx or #state.history) + delta))
  local item = state.history[state.history_idx]
  if not item then return end
  local lines = vim.split(item, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(state.query_buf, 0, -1, false, lines)
  -- place cursor at end of last line so editing continues naturally
  if state.query_win and vim.api.nvim_win_is_valid(state.query_win) then
    local last_line = #lines
    pcall(vim.api.nvim_win_set_cursor, state.query_win, { last_line, #lines[last_line] })
  end
end

local function setup_query_keymaps(buf)
  local opts = { buffer = buf, silent = true }

  -- <CR> submits and stays in current mode (insert stays in insert).
  vim.keymap.set({ "n", "i" }, "<CR>", submit_current_query, opts)

  -- newline variants (multi-line queries):
  vim.keymap.set("i", "<S-CR>", "<CR>", opts)
  vim.keymap.set("i", "<C-CR>", "<CR>", opts)
  vim.keymap.set("i", "<M-CR>", "<CR>", opts)

  vim.keymap.set("n", ";", function()
    repl.next(reply(""))
  end, opts)

  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    repl.stop_solve(reply(""))
  end, opts)

  -- History: arrows in normal AND insert (overrides cmp's <Up>/<Down> navigation
  -- for the completion popup in this buffer; use <A-j>/<A-k> for cmp instead).
  vim.keymap.set({ "n", "i" }, "<Up>",   function() recall_history(-1) end, opts)
  vim.keymap.set({ "n", "i" }, "<Down>", function() recall_history( 1) end, opts)
end

local function setup_output_keymaps(buf)
  local opts = { buffer = buf, silent = true }
  vim.keymap.set("n", "q", function()
    if state.output_win and vim.api.nvim_win_is_valid(state.output_win) then
      vim.api.nvim_win_close(state.output_win, false)
    end
  end, opts)
  vim.keymap.set("n", "C", function()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    vim.bo[buf].modifiable = false
  end, opts)
end

-- ──────────────── публичный API ────────────────

function M.open()
  if not repl.start() then return end

  -- стартовый буфер — это «editor», его трогать не будем.
  local editor_win = vim.api.nvim_get_current_win()

  state.query_buf  = ensure_buf(QUERY_NAME,  "prolog", true)
  state.output_buf = ensure_buf(OUTPUT_NAME, nil,     false)

  -- сворачиваем потенциально лежащие старые windows этих буферов
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if (b == state.query_buf or b == state.output_buf) and w ~= editor_win then
      pcall(vim.api.nvim_win_close, w, false)
    end
  end

  -- query — снизу под editor
  vim.api.nvim_set_current_win(editor_win)
  vim.cmd("rightbelow split")
  state.query_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.query_win, state.query_buf)
  vim.wo[state.query_win].number = false
  vim.wo[state.query_win].relativenumber = false

  -- output — снизу под query
  vim.cmd("rightbelow split")
  state.output_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.output_win, state.output_buf)
  vim.wo[state.output_win].number = false
  vim.wo[state.output_win].relativenumber = false
  vim.wo[state.output_win].wrap = true

  -- equalalways=true (дефолт Neovim) перераспределяет окна поровну после
  -- каждого :split, поэтому числа `Nsplit` игнорируются. Задаём высоту
  -- явно и сразу лочим winfixheight, иначе следующий set_height отнимет
  -- строки у уже отредактированного соседа.
  vim.api.nvim_win_set_height(state.query_win, 4)
  vim.wo[state.query_win].winfixheight = true
  vim.api.nvim_win_set_height(state.output_win, 8)
  vim.wo[state.output_win].winfixheight = true

  setup_query_keymaps(state.query_buf)
  setup_output_keymaps(state.output_buf)

  -- Когда переключаешься в query-окно из любого другого — автоматически
  -- входим в insert mode (REPL-поведение). Чистим предыдущий autocmd на
  -- этот буфер, чтобы при повторном открытии IDE не плодить дубли.
  vim.api.nvim_clear_autocmds({ buffer = state.query_buf, group = nil })
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = state.query_buf,
    callback = function()
      -- защита от срабатывания, когда буфер уже в insert mode
      if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
        vim.cmd("startinsert")
      end
    end,
  })

  -- consult текущего .pl файла
  local editor_buf = vim.api.nvim_win_get_buf(editor_win)
  if vim.bo[editor_buf].filetype == "prolog" then
    local path = vim.api.nvim_buf_get_name(editor_buf)
    if path ~= "" and vim.fn.filereadable(path) == 1 then
      repl.consult(path, reply(""))
    end
  end

  -- подсказка пользователю
  if vim.api.nvim_buf_line_count(state.query_buf) == 1 and
     (vim.api.nvim_buf_get_lines(state.query_buf, 0, 1, false)[1] or "") == "" then
    vim.api.nvim_buf_set_lines(state.query_buf, 0, -1, false, { "" })
  end

  -- курсор остаётся в editor — пользователь сам перейдёт в query (через
  -- <C-j> или клик), и тогда BufEnter autocmd выше включит insert mode.
  vim.api.nvim_set_current_win(editor_win)
end

function M.close()
  -- закрываем все окна, показывающие наши буферы (state.*_win может
  -- устареть, если пользователь закрыл их вручную и переоткрыл из IDE).
  local targets = {}
  if state.query_buf  and vim.api.nvim_buf_is_valid(state.query_buf)  then targets[state.query_buf]  = true end
  if state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf) then targets[state.output_buf] = true end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if targets[vim.api.nvim_win_get_buf(w)] then
      pcall(vim.api.nvim_win_close, w, false)
    end
  end
  state.query_win  = nil
  state.output_win = nil
end

function M.is_open()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if (state.query_buf and b == state.query_buf)
       or (state.output_buf and b == state.output_buf) then
      return true
    end
  end
  return false
end

function M.toggle()
  if M.is_open() then M.close() else M.open() end
end

function M.focus_query()
  if not (state.query_win and vim.api.nvim_win_is_valid(state.query_win)) then
    M.open()
  end
  -- BufEnter autocmd на query_buf сам включит insert mode
  if state.query_win and vim.api.nvim_win_is_valid(state.query_win) then
    vim.api.nvim_set_current_win(state.query_win)
  end
end

function M.consult_current()
  if not repl.start() then return end
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    vim.notify("Файл не сохранён", vim.log.levels.WARN)
    return
  end
  repl.consult(path, function(result)
    vim.schedule(function()
      if ensure_output_visible() then
        append_output(result)
      else
        vim.notify(result, vim.log.levels.INFO)
      end
    end)
  end)
end

function M.send_line()
  if not repl.start() then return end
  if not ensure_output_visible() then M.open() end
  send_query_text(vim.api.nvim_get_current_line())
end

function M.send_visual()
  if not repl.start() then return end
  if not ensure_output_visible() then M.open() end
  local s = vim.fn.getpos("'<")
  local e = vim.fn.getpos("'>")
  local lines = vim.api.nvim_buf_get_lines(0, s[2] - 1, e[2], false)
  send_query_text(table.concat(lines, "\n"))
end

function M.toggle_trace()
  if not repl.start() then return end
  state.trace_on = not state.trace_on
  repl.trace(state.trace_on, function(result)
    vim.schedule(function()
      if ensure_output_visible() then
        append_output(result)
      else
        vim.notify(result, vim.log.levels.INFO)
      end
    end)
  end)
end

local function ask_arity_and(action)
  local word = vim.fn.expand("<cword>")
  if word == "" then
    vim.notify("Курсор не на имени предиката", vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = action .. " " .. word .. "/" }, function(arity)
    if not arity or arity == "" then return end
    local pred = word .. "/" .. arity
    if action == "spy" then
      repl.spy(pred, reply(""))
    else
      repl.nospy(pred, reply(""))
    end
  end)
end

function M.spy_under_cursor()    if repl.start() then ask_arity_and("spy")    end end
function M.nospy_under_cursor()  if repl.start() then ask_arity_and("nospy")  end end

function M.restart()
  repl.stop()
  vim.defer_fn(function()
    if repl.start() then
      vim.notify("tuProlog REPL restarted", vim.log.levels.INFO)
    end
  end, 200)
end

return M
