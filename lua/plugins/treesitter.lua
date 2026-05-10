return {
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    config = function()
      local config = require("nvim-treesitter.configs")
      config.setup({
        auto_install = true,
        highlight = {
          enable = true,
          disable = { "latex" },
          additional_vim_regex_highlighting = { "latex", "markdown" },
        },
        indent = {
          enable = true,
          -- Отключаем treesitter indent для C/C++ — используем cindent с Allman style
          disable = { "c", "cpp" }
        }
      })
    end
  },

  -- Treesitter-driven matching-pair highlighter. Drop-in replacement for the
  -- built-in matchparen plugin (which we disable in lua/options.lua because
  -- searchpairpos() locks up on deeply-nested Lisp code).
  {
    "monkoose/matchparen.nvim",
    event = { "BufReadPost", "BufNewFile" },
    config = function()
      require("matchparen").setup()
    end,
  },
}

