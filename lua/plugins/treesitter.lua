return {
  "nvim-treesitter/nvim-treesitter",
  build = ":TSUpdate",
  config = function()
    local config = require("nvim-treesitter.configs")
    config.setup({
      auto_install = true,
      highlight = { enable = true },
      indent = {
        enable = true,
        -- Отключаем treesitter indent для C/C++ — используем cindent с Allman style
        disable = { "c", "cpp" }
      }
    })
  end
}

