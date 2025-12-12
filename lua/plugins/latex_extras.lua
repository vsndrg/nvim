return {
  -- Formula preview popup
  {
    "jbyuki/nabla.nvim",
    ft = { "tex", "markdown" },
    config = function()
      vim.keymap.set("n", "<leader>lp", function()
        require("nabla").popup({ border = "rounded" })
      end, { desc = "Preview LaTeX formula under cursor" })
    end,
  },
  -- Surround for $...$ and \[...\]
  {
    "kylechui/nvim-surround",
    event = "VeryLazy",
    config = true
  },
  -- Conceal for math
  {
    "KeitaNakamura/tex-conceal.vim",
    ft = { "tex" },
    config = function()
      vim.g.tex_conceal = "abdmg"
    end
  }
}
