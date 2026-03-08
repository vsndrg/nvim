vim.opt.clipboard:append("unnamedplus")
vim.opt.guifont = { "JetBrainsMono Nerd Font", ":h14" }

vim.opt.pumheight = 12

vim.o.number = true
vim.o.relativenumber = true

vim.o.expandtab = true
vim.o.shiftwidth = 2
vim.o.tabstop = 2
vim.o.smartindent = false

vim.o.ignorecase = true
vim.o.smartcase = true

vim.g.mapleader = " "

vim.o.winborder = 'rounded'
vim.o.guicursor = 'n-v-c-sm:block,i-ci-ve:ver25,r-cr-o:hor20,t:ver25'

vim.g.neovide_input_macos_option_key_is_meta = "both"

if vim.g.neovide then
  vim.g.neovide_refresh_rate = 120
  vim.g.neovide_scroll_animation_far_lines = 1
  vim.g.neovide_floating_blur_amount_x = 2.0
  vim.g.neovide_floating_blur_amount_y = 2.0
  vim.g.neovide_floating_shadow = true
  vim.g.neovide_floating_z_height = 10
  vim.g.neovide_light_angle_degrees = 45
  vim.g.neovide_light_radius = 5
  -- vim.g.neovide_opacity = 0.9
  -- vim.g.neovide_cursor_animation_length = 0.08
  -- vim.g.neovide_scroll_animation_length = 0.2
  -- vim.g.neovide_cursor_trail_size = 0.5
  vim.keymap.set('c', '<D-v>', '<C-R>+', { noremap = true })
  vim.keymap.set('i', '<D-v>', '<C-R>+', { noremap = true })
  vim.keymap.set('t', '<D-v>', '<C-\\><C-n>"+pi', { noremap = true })
end

vim.g.python3_host_prog = os.getenv("HOME") .. "/.local/share/venvs/pynvim/bin/python"

-- -- paste unnamed register with `p` in command-line
-- vim.keymap.set('c', 'p', '<C-R>"', { noremap = true, silent = true })
--
-- -- OR paste system clipboard with `p`
-- vim.keymap.set('c', 'p', '<C-R>+', { noremap = true, silent = true })
