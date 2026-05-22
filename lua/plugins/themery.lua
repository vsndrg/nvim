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
    -- JetBrains Darcula port: тёплый десатурированный фон, минимум кислоты.
    "xiantang/darcula-dark.nvim",       lazy = true,
    dependencies = { "nvim-treesitter/nvim-treesitter" },
  },
  {
    -- VS Code Dark+ / Light: соседнее «IDE-семейство» с похожей эстетикой.
    "Mofiqul/vscode.nvim",              lazy = true,
  },
  {
    -- JetBrains IDE color scheme (dark + light via background)
    "nickkadutskyi/jb.nvim",            lazy = true,
  },
  {
    -- Themery — интерактивный переключатель тем с live preview и persistence
    "zaldih/themery.nvim",
    lazy = false,
    config = function()
      -- vscode.nvim makes Pmenu / BlinkCmpMenu blend into the editor bg, so
      -- the completion popup is hard to see. Lift it to VS Code's actual menu
      -- bg (#252526 dark / #f3f3f3 light) and use VS Code's selection blue.
      -- Both Pmenu (builtin ins-completion-menu) and the BlinkCmpMenu* groups
      -- (blink.cmp's own popup) are set so all popups stay consistent.
      --
      -- IMPORTANT: this autocmd MUST be registered before themery.setup(),
      -- because themery.setup() restores the persisted theme synchronously
      -- (firing ColorScheme during setup). If we registered after, the event
      -- would fire before we listened.
      local function tweak_vscode_popups()
        local pmenu, sel, thumb
        if vim.o.background == "light" then
          pmenu, sel, thumb = "#e8e8e8", "#cce5ff", "#bdbdbd"
        else
          pmenu, sel, thumb = "#2d2d30", "#0a5a8a", "#5a5a5d"
        end
        vim.api.nvim_set_hl(0, "Pmenu",                 { bg = pmenu })
        vim.api.nvim_set_hl(0, "PmenuSel",              { bg = sel })
        vim.api.nvim_set_hl(0, "PmenuThumb",            { bg = thumb })
        vim.api.nvim_set_hl(0, "BlinkCmpMenu",          { bg = pmenu })
        vim.api.nvim_set_hl(0, "BlinkCmpMenuBorder",    { bg = pmenu })
        vim.api.nvim_set_hl(0, "BlinkCmpMenuSelection", { bg = sel })
        vim.api.nvim_set_hl(0, "BlinkCmpDoc",           { bg = pmenu })
        vim.api.nvim_set_hl(0, "BlinkCmpDocBorder",     { bg = pmenu })
      end
      vim.api.nvim_create_autocmd("ColorScheme", {
        pattern = "vscode",
        callback = tweak_vscode_popups,
      })
      -- If vscode is already the active colorscheme by the time this plugin
      -- loads, the ColorScheme event has already fired — apply once now.
      if vim.g.colors_name == "vscode" then tweak_vscode_popups() end

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
          -- JetBrains Darcula
          { name = "Darcula (JetBrains)",  colorscheme = "darcula-dark" },
          -- JetBrains IDE (nickkadutskyi/jb.nvim)
          { name = "JB Dark",              colorscheme = "jb",
            before = [[ vim.opt.background = "dark" ]] },
          -- VS Code dark variants
          { name = "VS Code Dark+",        colorscheme = "vscode",
            before = [[ vim.g.vscode_style = "dark" ]] },

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
          -- JetBrains IDE light
          { name = "JB Light",             colorscheme = "jb",
            before = [[ vim.opt.background = "light" ]] },
          -- VS Code light
          { name = "VS Code Light",        colorscheme = "vscode",
            before = [[ vim.g.vscode_style = "light" ]] },
        },
      })

      vim.keymap.set("n", "<leader>p", "<cmd>Themery<cr>",
        { desc = "Theme switcher", noremap = true, silent = true })

      -- Add `l` as an alias for <CR> in the picker (h/j/k/l navigation feel).
      -- `remap = true` lets it chain into themery's own <CR> -> closeAndSave.
      vim.api.nvim_create_autocmd("FileType", {
        pattern = "themery",
        callback = function(args)
          vim.keymap.set("n", "l", "<CR>", {
            buffer = args.buf, silent = true, remap = true,
          })
        end,
      })
    end,
  },
}
