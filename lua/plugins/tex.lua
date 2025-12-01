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

      -- Useful keymaps (leader is default '\', change if you use <space> leader)
      vim.api.nvim_set_keymap("n", "<leader>ll", ":VimtexCompile<CR>", { noremap = true, silent = true })
      vim.api.nvim_set_keymap("n", "<leader>lv", ":VimtexView<CR>", { noremap = true, silent = true })
      vim.api.nvim_set_keymap("n", "<leader>lf", ":VimtexForward<CR>", { noremap = true, silent = true })

      -- Optional: open viewer on compile success automatically
      vim.g.vimtex_compiler_callback_display = 1
    end,
  }

