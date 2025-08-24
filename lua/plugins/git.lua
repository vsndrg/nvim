return {
  {
    "tpope/vim-fugitive",
  },
  {
    "lewis6991/gitsigns.nvim",
    config = function()
      require("gitsigns").setup()

      local opts = { noremap = true, silent = true }

      vim.keymap.set("n", "<leader>gp", ":Gitsigns preview_hunk<CR>", opts)
      vim.keymap.set("n", "<leader>gt", ":Gitsigns toggle_current_line_blame<CR>", opts)
    end
  }
}

