return {
  {
    -- Темы
    "folke/tokyonight.nvim",            lazy = true,
  },
  {
    "ellisonleao/gruvbox.nvim",         lazy = true,
  },
  {
    "rebelot/kanagawa.nvim",            lazy = true,
  },
  {
    "rose-pine/neovim",
    name = "rose-pine",                 lazy = true,
  },
  {
    "shaunsingh/nord.nvim",             lazy = true,
  },
  {
    "Mofiqul/dracula.nvim",             lazy = true,
  },
  {
    "navarasu/onedark.nvim",            lazy = true,
  },
  {
    "EdenEast/nightfox.nvim",           lazy = true,
  },
  {
    "sainnhe/everforest",               lazy = true,
  },
  {
    "marko-cerovac/material.nvim",      lazy = true,
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
          -- Tokyonight variants
          { name = "Tokyo Night",          colorscheme = "tokyonight-night" },
          { name = "Tokyo Storm",          colorscheme = "tokyonight-storm" },
          { name = "Tokyo Moon",           colorscheme = "tokyonight-moon" },
          -- Gruvbox
          {
            name = "Gruvbox Dark",
            colorscheme = "gruvbox",
            before = [[ vim.opt.background = "dark" ]],
          },
          -- Kanagawa
          { name = "Kanagawa Wave",        colorscheme = "kanagawa-wave" },
          { name = "Kanagawa Dragon",      colorscheme = "kanagawa-dragon" },
          -- Rose Pine
          { name = "Rose Pine",            colorscheme = "rose-pine" },
          { name = "Rose Pine Moon",       colorscheme = "rose-pine-moon" },
          -- Nord
          { name = "Nord",                 colorscheme = "nord" },
          -- Dracula
          { name = "Dracula",              colorscheme = "dracula" },
          -- OneDark
          { name = "OneDark",              colorscheme = "onedark" },
          -- Nightfox dark variants
          { name = "Nightfox",             colorscheme = "nightfox" },
          { name = "Duskfox",              colorscheme = "duskfox" },
          { name = "Nordfox",              colorscheme = "nordfox" },
          { name = "Terafox",              colorscheme = "terafox" },
          { name = "Carbonfox",            colorscheme = "carbonfox" },
          -- Everforest Dark
          {
            name = "Everforest Dark",
            colorscheme = "everforest",
            before = [[ vim.opt.background = "dark" ]],
          },
          -- Material dark variants
          { name = "Material Darker",      colorscheme = "material",
            before = [[ vim.g.material_style = "darker" ]] },
          { name = "Material Oceanic",     colorscheme = "material",
            before = [[ vim.g.material_style = "oceanic" ]] },
          { name = "Material Palenight",   colorscheme = "material",
            before = [[ vim.g.material_style = "palenight" ]] },
          { name = "Material Deep Ocean",  colorscheme = "material",
            before = [[ vim.g.material_style = "deep ocean" ]] },

          -- ── Light themes ─────────────────────────────────────────────────
          { name = "Catppuccin Latte",     colorscheme = "catppuccin-latte" },
          { name = "Tokyo Day",            colorscheme = "tokyonight-day" },
          {
            name = "Gruvbox Light",
            colorscheme = "gruvbox",
            before = [[ vim.opt.background = "light" ]],
          },
          { name = "Kanagawa Lotus",       colorscheme = "kanagawa-lotus" },
          { name = "Rose Pine Dawn",       colorscheme = "rose-pine-dawn" },
          { name = "Dayfox",               colorscheme = "dayfox" },
          { name = "Dawnfox",              colorscheme = "dawnfox" },
          {
            name = "Everforest Light",
            colorscheme = "everforest",
            before = [[ vim.opt.background = "light" ]],
          },
          { name = "Material Lighter",     colorscheme = "material",
            before = [[ vim.g.material_style = "lighter" ]] },
        },
      })

      vim.keymap.set("n", "<leader>p", "<cmd>Themery<cr>",
        { desc = "Theme switcher", noremap = true, silent = true })
    end,
  },
}
