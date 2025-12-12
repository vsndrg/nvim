  return {
    "lervag/vimtex",
    config = function()
      -- Use latexmk and enable synctex
      vim.g.vimtex_compiler_method = "latexmk"
      vim.g.vimtex_compiler_latexmk = {
        executable = "latexmk",
        options = { "-pdf", "-interaction=nonstopmode", "-synctex=1", "-file-line-error" },
      }

      -- Viewer: skim on MacOS (change if needed)
      vim.g.vimtex_view_method = "skim"
      -- Ensure Skim sync and explicit viewer binary (displayline)
      vim.g.vimtex_view_skim_sync = 1
      -- Do not steal focus from Neovim when opening Skim
      vim.g.vimtex_view_skim_activate = 0
      vim.g.vimtex_view_general_viewer = '/Applications/Skim.app/Contents/MacOS/Skim' -- '/Users/vsndrg/.config/nvim/scripts/skim_displayline_wrapper.sh'
      vim.g.vimtex_view_general_options = '-r @line @pdf @tex'

      -- Useful keymaps (leader is default '\', change if you use <space> leader)
      vim.api.nvim_set_keymap("n", "<leader>ll", ":VimtexCompile<CR>", { noremap = true, silent = true })
      vim.api.nvim_set_keymap("n", "<leader>lv", ":VimtexView<CR>", { noremap = true, silent = true })
      vim.api.nvim_set_keymap("n", "<leader>lf", ":VimtexForward<CR>", { noremap = true, silent = true })

      -- Open PDF and forward-search only if PDF exists (avoids "Viewer cannot read PDF file")
      local function view_and_forward()
        local pdf = vim.fn.expand('%:p:r') .. '.pdf'
        if vim.fn.filereadable(pdf) == 1 then
          -- open viewer without erroring; use silent to suppress messages
          pcall(vim.cmd, 'silent! VimtexView')
          -- Try forward-search; wrap in pcall and try common variants
          local ok = pcall(vim.cmd, 'silent! VimtexForward')
          if not ok then
            pcall(vim.cmd, 'silent! VimtexForwardSearch')
            pcall(vim.cmd, 'silent! VimtexForwardSearch!')
          end
        else
          vim.notify('PDF not found: ' .. pdf, vim.log.levels.ERROR)
        end
      end
      vim.keymap.set('n', '<leader>ls', view_and_forward, { noremap = true, silent = true })

      -- Optional: open viewer on compile success automatically
      vim.g.vimtex_compiler_callback_display = 1
    end,
  }

