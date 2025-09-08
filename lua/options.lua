vim.opt.clipboard:append("unnamedplus")
vim.opt.guifont = { "JetBrainsMono Nerd Font", ":h14" }

vim.opt.pumheight = 12

vim.o.number = true
vim.o.relativenumber = true

vim.o.expandtab = true
vim.o.shiftwidth = 2
vim.o.tabstop = 2
vim.o.smartindent = true

vim.o.ignorecase = true
vim.o.smartcase = true

vim.g.mapleader = " "

vim.o.winborder = 'rounded'

vim.g.neovide_input_macos_option_key_is_meta = "both"

vim.g.python3_host_prog = os.getenv("HOME") .. "/.local/share/venvs/pynvim/bin/python"

