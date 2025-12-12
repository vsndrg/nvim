return {
  'rmagatti/auto-session',
  lazy = false,
  config = function()
    require('auto-session').setup({
      pre_save_cmds = { 'Neotree close' },
      post_restore_cmds = { 'Neotree filesystem show' },
    })
    vim.keymap.set('n', '<leader>z', '<cmd>AutoSession search<CR>', { desc = 'Session search' })
  end,
}

