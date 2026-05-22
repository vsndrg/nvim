vim.opt.clipboard:append("unnamedplus")
vim.opt.guifont = { "JetBrainsMono Nerd Font", ":h14" }

vim.opt.pumheight = 12
vim.opt.shortmess:append("F")

vim.o.number = true
vim.o.relativenumber = true

vim.o.expandtab = true
vim.o.shiftwidth = 2
vim.o.tabstop = 2
vim.o.smartindent = false

-- New :split opens below the current window (instead of above).
vim.o.splitbelow = true

-- Disable built-in matchparen: its searchpairpos()-based implementation
-- freezes on deeply-nested Lisp code. Replaced by monkoose/matchparen.nvim
-- (treesitter-driven, drop-in replacement) — see lua/plugins/treesitter.lua.
vim.g.loaded_matchparen = 1

vim.o.ignorecase = true
vim.o.smartcase = true

vim.g.mapleader      = " "
vim.g.maplocalleader = ","

vim.o.winborder = 'rounded'
vim.o.guicursor = 'n-v-c-sm:block,i-ci-ve:ver25,r-cr-o:hor20,t:ver25'

vim.g.neovide_input_macos_option_key_is_meta = "both"
vim.g.neovide_cursor_antialiasing = true
vim.g.neovide_macos_simple_fullscreen = true
-- vim.g.neovide_profiler = true
-- vim.g.neovide_fullscreen = true
-- vim.g.neovide_cursor_smooth_blink = true
-- vim.g.neovide_cursor_vfx_mode = "pixiedust"
-- vim.g.neovide_cursor_vfx_particle_density = 0.9

if vim.g.neovide then
  vim.g.neovide_refresh_rate = 120
  -- vim.g.neovide_scroll_animation_far_lines = 0
  vim.g.neovide_floating_blur_amount_x = 4.0
  vim.g.neovide_floating_blur_amount_y = 4.0
  vim.g.neovide_floating_shadow = true
  vim.g.neovide_opacity = 0.9
  vim.g.neovide_window_blurred = true
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
