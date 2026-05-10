-- ==============
-- Key Mappings
-- ==============

local opts = { noremap = true, silent = true }
local km = vim.keymap

-- Save file command
km.set("n", "<leader>w", "<cmd>silent update<CR>", opts)
km.set("n", "<leader>q", ":q<CR>", opts)

km.set("n", "<leader>a", "ggVG", opts)

-- Add line after cursor in normal mode
km.set("n", "<leader>j", "o<Esc>k", opts)
-- Add line before cursor in normal mode
km.set("n", "<leader>k", "O<Esc>j", opts)
-- Add new line and place cursor after it in normal mode
km.set("n", "<leader>o", "o<Esc>o", opts)
km.set("n", "<leader>O", "O<Esc>O", opts)

km.set("n", "<leader>;", "A;<Esc>", opts)

-- Center cursor when searching
km.set('n', 'n', "nzzzv", opts)
km.set('n', 'N', "Nzzzv", opts)
km.set('n', '*', "*zzzv", opts)
km.set('n', '#', "#zzzv", opts)
km.set('n', 'g*', "g*zzzv", opts)
km.set('n', 'g#', "g#zzzv", opts)

-- Add space after cursor in normal mode
km.set("n", "<leader>-", "a <Esc><Left>", opts)
-- Add space before cursor in normal mode
km.set("n", "<leader>_", "i <Esc><Right>", opts)

-- Save init.lua file command
km.set("n", "<leader>s", ":source %<CR>", opts)

-- Move rest of the line on the next line command
km.set("n", "<leader><CR>", "i<CR><Esc>k$", opts)
-- Tab in normal mode command
km.set("n", "<leader><Tab>", "i<Tab><Esc><Right>", opts)

-- Move current line command
km.set('n', '<M-k>', ':m .-2<CR>==', opts)
km.set('n', '<M-j>', ':m .+1<CR>==', opts)

-- Switch between opened windows commands.
-- Insert-mode варианты выходят из insert и сразу переключают окно —
-- удобно при работе с REPL'ами/output-буферами, где постоянно прыгаешь
-- между insert (ввод query) и normal (просмотр результата).
-- Trade-off: ломается дефолтный <C-k> для диграфов (:help i_CTRL-K).
km.set('n', '<C-h>', '<C-w>h', opts)
km.set('n', '<C-j>', '<C-w>j', opts)
km.set('n', '<C-k>', '<C-w>k', opts)
km.set('n', '<C-l>', '<C-w>l', opts)
km.set('i', '<C-h>', '<Esc><C-w>h', opts)
km.set('i', '<C-j>', '<Esc><C-w>j', opts)
km.set('i', '<C-k>', '<Esc><C-w>k', opts)
km.set('i', '<C-l>', '<Esc><C-w>l', opts)

-- PageUp/Down
km.set('n', '<C-u>', '<C-u>zz', opts)
km.set('n', '<C-d>', '<C-d>zz', opts)
-- km.set('n', '<C-f>', '<C-f>zz', opts)
-- km.set('n', '<C-b>', '<C-b>zz', opts)

km.set('v', '<M-k>', ":m '<-2<CR>gv=gv", opts)
km.set('v', '<M-j>', ":m '>+1<CR>gv=gv", opts)
km.set('v', 'p', "\"_dP", opts)

vim.api.nvim_set_keymap('n', '<Leader>h', ':only<CR>:Vifm<CR>', opts)

km.set('n', 'gb', '<C-o>zz', opts)

-- Map shortcuts
vim.keymap.set('n', '<leader>c', ':Build<CR>', opts)
vim.keymap.set('n', '<leader>r', ':Run<CR>', opts)

-- Toggle inlay hints
km.set('n', '<leader>i', function()
  vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled())
end, { desc = 'Toggle inlay hints' })

-- Markview bindings (only for markdown files)
vim.api.nvim_create_autocmd("FileType", {
  pattern = "markdown",
  callback = function()
    local o = { noremap = true, silent = true, buffer = true }
    km.set('n', '<leader>mp', ':Markview toggle<CR>', vim.tbl_extend('force', o, { desc = 'Markview toggle' }))
    km.set('n', '<leader>ms', ':Markview splitToggle<CR>', vim.tbl_extend('force', o, { desc = 'Markview split' }))
    km.set('n', '<leader>mh', ':Markview HybridToggle<CR>', vim.tbl_extend('force', o, { desc = 'Markview hybrid' }))
  end,
})

-- Terminal mode: Esc → normal mode, C-h/j/k/l → navigate windows
km.set('t', '<Esc>',   '<C-\\><C-n>',          { noremap = true, silent = true })
km.set('t', '<C-h>',   '<C-\\><C-n><C-w>h',    { noremap = true, silent = true })
km.set('t', '<C-j>',   '<C-\\><C-n><C-w>j',    { noremap = true, silent = true })
km.set('t', '<C-k>',   '<C-\\><C-n><C-w>k',    { noremap = true, silent = true })
km.set('t', '<C-l>',   '<C-\\><C-n><C-w>l',    { noremap = true, silent = true })

-- Toggle terminal (persistent buffer)
local term_buf = nil
local term_win = nil

local function sync_terminal_state()
  vim.g.persistent_term_buf = term_buf or 0
  vim.g.persistent_term_win = term_win or 0
end

sync_terminal_state()

local function toggle_terminal()
  -- Если окно открыто — скрыть
  if term_win and vim.api.nvim_win_is_valid(term_win) then
    vim.api.nvim_win_close(term_win, false)
    term_win = nil
    sync_terminal_state()
    return
  end

  if term_buf and vim.api.nvim_buf_is_valid(term_buf) then
    local wins = vim.fn.win_findbuf(term_buf)
    if #wins > 0 and vim.api.nvim_win_is_valid(wins[1]) then
      term_win = wins[1]
      vim.api.nvim_set_current_win(term_win)
      sync_terminal_state()
      vim.cmd('startinsert')
      return
    end
  end

  -- Высота — процент от текущего окна (а не от всего экрана), чтобы при
  -- работе в split'ах терминал не съедал чужие окна.
  local pct = 0.38196601
  local height = math.max(5, math.floor(vim.api.nvim_win_get_height(0) * pct))
  vim.cmd('belowright ' .. height .. 'split')
  term_win = vim.api.nvim_get_current_win()

  -- Если буфер терминала жив — показать его
  if term_buf and vim.api.nvim_buf_is_valid(term_buf) then
    vim.api.nvim_win_set_buf(term_win, term_buf)
  else
    -- Создать новый терминал в cwd
    vim.cmd('terminal')
    term_buf = vim.api.nvim_get_current_buf()
    vim.bo[term_buf].buflisted = false
  end

  sync_terminal_state()
  vim.cmd('startinsert')
end

_G.toggle_persistent_terminal = toggle_terminal

vim.keymap.set('n', '<leader>t', toggle_terminal, { desc = 'Toggle terminal' })
vim.keymap.set('n', '<C-Space>', toggle_terminal, { desc = 'Toggle terminal' })
vim.keymap.set('i', '<C-Space>', toggle_terminal, { desc = 'Toggle terminal' })
vim.keymap.set('t', '<C-Space>', toggle_terminal, { desc = 'Toggle terminal' })

-- Some terminals send <C-Space> as <C-@>
vim.keymap.set('n', '<C-@>', toggle_terminal, { desc = 'Toggle terminal' })
vim.keymap.set('i', '<C-@>', toggle_terminal, { desc = 'Toggle terminal' })
vim.keymap.set('t', '<C-@>', toggle_terminal, { desc = 'Toggle terminal' })

local function open_symbol_picker()
  local ok, builtin = pcall(require, 'telescope.builtin')
  if ok then
    local ok_symbols = pcall(builtin.symbols, {
      sources = { 'emoji', 'kaomoji', 'gitmoji', 'math', 'latex' },
    })
    if ok_symbols then
      return
    end
  end

  vim.notify('Symbols picker is unavailable. Run :Lazy sync and restart Neovim.', vim.log.levels.WARN)
end

vim.keymap.set({ 'n', 'i', 't' }, '<C-D-Space>', open_symbol_picker, { desc = 'Open symbols picker' })
