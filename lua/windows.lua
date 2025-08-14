local km = vim.keymap
local opts = { noremap = true, silent = true }

local function resize_horizontal(amount)
  local winid = vim.api.nvim_get_current_win()

  -- Check if we're at the far right edge
  local at_right_edge = (vim.fn.winnr('l') == vim.fn.winnr()) -- no window to the right
  local at_left_edge  = (vim.fn.winnr('h') == vim.fn.winnr()) -- no window to the left

  -- Invert if at right edge
  if at_right_edge and not at_left_edge then
    amount = -amount
  end

  vim.cmd('vertical resize ' .. (vim.api.nvim_win_get_width(winid) + amount))
end

local function resize_vertical(amount)
  local winid = vim.api.nvim_get_current_win()

  -- Check if we're at the very bottom or top
  local at_bottom = (vim.fn.winnr('j') == vim.fn.winnr()) -- no window below
  local at_top    = (vim.fn.winnr('k') == vim.fn.winnr()) -- no window above

  -- Invert if at bottom edge
  if at_top and not at_bottom then
    amount = -amount
  end

  vim.cmd('resize ' .. (vim.api.nvim_win_get_height(winid) + amount))
end

-- Bindings
km.set('n', '<C-S-h>', function() resize_horizontal(-1) end, opts)
km.set('n', '<C-S-l>', function() resize_horizontal(1) end, opts)
km.set('n', '<C-S-j>', function() resize_vertical(-1) end, opts)
km.set('n', '<C-S-k>', function() resize_vertical(1) end, opts)

