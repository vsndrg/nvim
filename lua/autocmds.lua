-- -- ===============
-- -- Auto Commands
-- -- ===============

-- Автоудаление терминального буфера когда процесс завершился.
-- vim.schedule, чтобы избежать reentrant-удаления: TermClose вызывается
-- из контекста, где буфер уже "in use" (напр. изнутри :%bw! при восстановлении
-- сессии auto-session'ом). Прямой nvim_buf_delete оттуда даёт E937 на [No Name].
vim.api.nvim_create_autocmd("TermClose", {
  callback = function(ev)
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(ev.buf) then
        pcall(vim.api.nvim_buf_delete, ev.buf, { force = true })
      end
    end)
  end,
})

-- Убить все терминалы перед выходом, чтобы :q/:qa/:wqa не блокировались (E948 fix)
local function kill_terminals()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
      local job_id = vim.b[buf].terminal_job_id
      if job_id and job_id > 0 then
        pcall(vim.fn.jobstop, job_id)
      end
    end
  end
end

vim.api.nvim_create_autocmd("QuitPre", {
  callback = kill_terminals,
})


-- Terminator-then-Esc: при наборе клозинг-символа в конце строки сразу
-- выходим из insert mode. Внутри строки символ ведёт себя обычно.
local function setup_eol_escape(filetypes, char)
  vim.api.nvim_create_autocmd("FileType", {
    pattern = filetypes,
    callback = function()
      vim.keymap.set("i", char, function()
        local line = vim.api.nvim_get_current_line()
        local col  = vim.fn.col(".")        -- 1-based позиция курсора
        if col == #line + 1 then
          return char .. "<Esc>"
        else
          return char
        end
      end, { expr = true, noremap = true, buffer = true })
    end,
  })
end

setup_eol_escape({ "c", "cpp", "java", "rust", "systemverilog", "javascript", "typescript" }, ";")
setup_eol_escape({ "prolog" }, ".")

-- Signature help по Ctrl+k (единственный способ)
-- vim.api.nvim_create_autocmd("LspAttach", {
--   callback = function(args)
--     vim.keymap.set("i", "<C-k>", vim.lsp.buf.signature_help, { buffer = args.buf, silent = true })
--     vim.keymap.set("n", "<C-k>", vim.lsp.buf.signature_help, { buffer = args.buf, silent = true })
--   end,
-- })

vim.api.nvim_create_autocmd("BufEnter", {
  callback = function()
    vim.cmd(":set formatoptions-=ro")
  end
})

-- При переходе в терминальный буфер автоматически включаем insert mode
-- (terminal-job mode) — чтобы не приходилось каждый раз жать `i`/`a`.
vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
  pattern = "term://*",
  callback = function()
    -- Если процесс ещё жив, входим в режим ввода
    if vim.bo.buftype == "terminal" then
      vim.cmd("startinsert")
    end
  end,
})

-- vim.api.nvim_create_autocmd("VimEnter", {
--   callback = function()
--     vim.cmd("Neotree toggle filesystem left")
--   end
-- })

if vim.g.neovide then
  vim.api.nvim_create_autocmd("FocusGained", {
    callback = function()
      vim.fn.system("sketchybar --bar hidden=true")
    end,
  })
  vim.api.nvim_create_autocmd({ "FocusLost", "VimLeave" }, {
    callback = function()
      vim.fn.system("sketchybar --bar hidden=false")
    end,
  })
end

