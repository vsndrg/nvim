return {
  'nvim-lualine/lualine.nvim',
  config = function()
    require('lualine').setup({
      options = {
        theme = 'dracula'
      }
    })
    require('lualine').hide()
    vim.o.laststatus = 0
    vim.o.cmdheight  = 0
  end
}
