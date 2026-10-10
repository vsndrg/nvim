vim.opt.clipboard:append("unnamedplus")
vim.opt.guifont = { "JetBrainsMono Nerd Font", ":h14" }

vim.opt.pumheight = 12

-- Hide statusline by default; <leader>u toggles lualine on/off.
vim.o.laststatus = 0
vim.o.cmdheight  = 0
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
-- vim.g.neovide_macos_simple_fullscreen = true
-- vim.g.neovide_profiler = true
-- vim.g.neovide_fullscreen = true
-- vim.g.neovide_cursor_smooth_blink = true
-- vim.g.neovide_cursor_vfx_mode = "pixiedust"
-- vim.g.neovide_cursor_vfx_particle_density = 0.9

if vim.g.neovide then
  vim.g.neovide_refresh_rate = 120
  -- vim.g.neovide_scroll_animation_far_lines = 0
  -- vim.g.neovide_floating_blur_amount_x = 4.0
  -- vim.g.neovide_floating_blur_amount_y = 4.0
  vim.g.neovide_floating_shadow = true
  -- vim.g.neovide_opacity = 0.9
  -- vim.g.neovide_window_blurred = true
  -- vim.g.neovide_cursor_animation_length = 0.08
  -- vim.g.neovide_scroll_animation_length = 0.2
  -- vim.g.neovide_cursor_trail_size = 0.5
  vim.keymap.set('c', '<D-v>', '<C-R>+', { noremap = true })
  vim.keymap.set('i', '<D-v>', '<C-R>+', { noremap = true })
  vim.keymap.set('t', '<D-v>', '<C-\\><C-n>"+pi', { noremap = true })

  -- Zoom: Cmd+= / Cmd++ bigger, Cmd+- smaller, Cmd+Ctrl+= back to 1.0.
  -- The scale survives restarts via a file in stdpath('state').
  local scale_file = vim.fn.stdpath("state") .. "/neovide_scale_factor"
  local saved = tonumber((vim.fn.filereadable(scale_file) == 1 and vim.fn.readfile(scale_file)[1]) or "")
  vim.g.neovide_scale_factor = saved or 1.0

  local function set_scale(scale)
    scale = math.min(math.max(scale, 0.5), 3.0)
    vim.g.neovide_scale_factor = scale
    vim.fn.writefile({ ("%.4f"):format(scale) }, scale_file)
  end

  local zoom_modes = { 'n', 'v', 'i', 'c', 't' }
  local zoom_in = function() set_scale(vim.g.neovide_scale_factor * 1.05) end
  vim.keymap.set(zoom_modes, '<D-=>', zoom_in, { desc = "Neovide: zoom in" })
  vim.keymap.set(zoom_modes, '<D-+>', zoom_in, { desc = "Neovide: zoom in" })
  vim.keymap.set(zoom_modes, '<D-->', function() set_scale(vim.g.neovide_scale_factor / 1.05) end,
    { desc = "Neovide: zoom out" })
  vim.keymap.set(zoom_modes, '<C-D-=>', function() set_scale(1.0) end, { desc = "Neovide: reset zoom" })

  -- -- 1. главный виновник: Neovim умножает каждое событие скролла на 3
  -- vim.o.mousescroll = "ver:1,hor:6"      -- по умолчанию ver:3
  --
  -- -- 2. инерционное сглаживание именно скролла (курсор/окна не трогает)
  -- vim.g.neovide_scroll_animation_length = 0
  -- vim.g.neovide_scroll_animation_far_lines = 0
end

vim.g.python3_host_prog = os.getenv("HOME") .. "/.local/share/venvs/pynvim/bin/python"

-- -- paste unnamed register with `p` in command-line
-- vim.keymap.set('c', 'p', '<C-R>"', { noremap = true, silent = true })
--
-- -- OR paste system clipboard with `p`
-- vim.keymap.set('c', 'p', '<C-R>+', { noremap = true, silent = true })
