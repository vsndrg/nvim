-- ==============
-- Key Mappings
-- ==============

local opts = { noremap = true, silent = true }
local km = vim.keymap

-- Save file command
km.set("n", "<leader>w", ":w<CR>", opts)
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

-- Switch between opened windows commands
km.set('n', '<C-h>', '<C-w>h', opts)
km.set('n', '<C-j>', '<C-w>j', opts)
km.set('n', '<C-k>', '<C-w>k', opts)
km.set('n', '<C-l>', '<C-w>l', opts)

-- PageUp/Down
km.set('n', '<C-u>', '<C-u>zz', opts)
km.set('n', '<C-d>', '<C-d>zz', opts)
-- km.set('n', '<C-f>', '<C-f>zz', opts)
-- km.set('n', '<C-b>', '<C-b>zz', opts)

km.set('v', '<M-k>', ":m '<-2<CR>gv=gv", opts)
km.set('v', '<M-j>', ":m '>+1<CR>gv=gv", opts)
km.set('v', 'p', "\"_dP", opts)

vim.api.nvim_set_keymap('n', '<Leader>h', ':only<CR>:Vifm<CR>', opts)

km.set('n', 'gb', '<C-o>', opts)

-- Map shortcuts
vim.keymap.set('n', '<leader>c', ':Build<CR>', opts)
vim.keymap.set('n', '<leader>r', ':Run<CR>', opts)

-- Open terminal by pressing <leader>t
vim.keymap.set('n', '<leader>t', function()
  -- get full path of the current buffer
  local filepath = vim.api.nvim_buf_get_name(0)
  -- extract the directory part
  local filedir  = vim.fn.fnamemodify(filepath, ':p:h')
  -- change Neovim’s working directory
  vim.cmd('lcd ' .. filedir)
  -- open a terminal
  vim.cmd('belowright split | terminal')
  vim.cmd('startinsert')
end, { desc = 'Open terminal in current file directory' })

