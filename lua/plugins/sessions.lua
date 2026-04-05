return {
  'rmagatti/auto-session',
  lazy = false,
  config = function()
    -- Убираем "terminal" из sessionoptions: `:mksession` не будет сохранять
    -- терминальные буферы. Без этого при восстановлении сессии Neovim
    -- пытается воссоздать term:// буферы, что вызывает E937.
    vim.opt.sessionoptions:remove("terminal")

    local function close_terminals()
      -- Сначала закрываем окна, потом буферы.
      -- Если удалить буфер пока он отображается в окне, Neovim подставляет
      -- [No Name] в это окно. auto-session затем пытается вайпаутнуть [No Name]
      -- который "в использовании" → E937.
      local wins = {}
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == 'terminal' then
          table.insert(wins, win)
        end
      end
      for _, win in ipairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
          pcall(vim.cmd, "noautocmd " .. vim.fn.win_id2win(win) .. "wincmd q")
        end
      end
      -- Буфер теперь не в окне → [No Name] не появится
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].buftype == 'terminal' then
          pcall(vim.cmd, "noautocmd bdelete! " .. buf)
        end
      end
    end

    require('auto-session').setup({
      pre_save_cmds = { 'Neotree close', close_terminals },
      post_restore_cmds = { 'Neotree filesystem show' },
    })
    vim.keymap.set('n', '<leader>z', '<cmd>AutoSession search<CR>', { desc = 'Session search' })
  end,
}

