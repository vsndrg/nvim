return {
  {
    -- Темы
    "folke/tokyonight.nvim",    lazy = true,
  },
  {
    "ellisonleao/gruvbox.nvim", lazy = true,
  },
  {
    "rebelot/kanagawa.nvim",    lazy = true,
  },
  {
    "rose-pine/neovim",
    name = "rose-pine",         lazy = true,
  },
  {
    -- Themery — интерактивный переключатель тем с live preview и persistence
    "zaldih/themery.nvim",
    lazy = false,
    config = function()
      require("themery").setup({
        livePreview = true,
        themes = {
          -- Catppuccin variants
          { name = "Catppuccin Mocha",     colorscheme = "catppuccin-mocha" },
          { name = "Catppuccin Macchiato", colorscheme = "catppuccin-macchiato" },
          { name = "Catppuccin Frappe",    colorscheme = "catppuccin-frappe" },
          { name = "Catppuccin Latte",     colorscheme = "catppuccin-latte" },
          -- Tokyonight variants
          { name = "Tokyo Night",          colorscheme = "tokyonight-night" },
          { name = "Tokyo Storm",          colorscheme = "tokyonight-storm" },
          { name = "Tokyo Moon",           colorscheme = "tokyonight-moon" },
          { name = "Tokyo Day",            colorscheme = "tokyonight-day" },
          -- Gruvbox
          {
            name = "Gruvbox Dark",
            colorscheme = "gruvbox",
            before = [[ vim.opt.background = "dark" ]],
          },
          {
            name = "Gruvbox Light",
            colorscheme = "gruvbox",
            before = [[ vim.opt.background = "light" ]],
          },
          -- Kanagawa
          { name = "Kanagawa Wave",        colorscheme = "kanagawa-wave" },
          { name = "Kanagawa Dragon",      colorscheme = "kanagawa-dragon" },
          { name = "Kanagawa Lotus",       colorscheme = "kanagawa-lotus" },
          -- Rose Pine
          { name = "Rose Pine",            colorscheme = "rose-pine" },
          { name = "Rose Pine Moon",       colorscheme = "rose-pine-moon" },
          { name = "Rose Pine Dawn",       colorscheme = "rose-pine-dawn" },
        },
      })

      vim.keymap.set("n", "<leader>p", "<cmd>Themery<cr>",
        { desc = "Theme switcher", noremap = true, silent = true })
    end,
  },
}
