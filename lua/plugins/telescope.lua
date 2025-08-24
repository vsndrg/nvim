return {
  {
    'nvim-telescope/telescope.nvim', tag = '0.1.8',
    dependencies = { 'nvim-lua/plenary.nvim' },
    config = function()
      local builtin = require("telescope.builtin")
      vim.keymap.set('n', '<leader>f', builtin.find_files, {})
      vim.keymap.set('n', '<leader>l', builtin.live_grep, {})
      vim.keymap.set('n', '<leader>s', builtin.lsp_document_symbols, {})

      local actions = require("telescope.actions")
      require("telescope").setup{
        defaults = {
          mappings = {
            n = {
              ["l"] = actions.select_default,    -- press `l` to open selection (same as <CR>)
              -- keep <CR> if you want both:
              -- ["<CR>"] = actions.select_default,
              -- optional extras:
              -- ["L"] = actions.select_vertical, -- open in vertical split with Shift-l
              -- ["s"] = actions.select_horizontal, -- open in horizontal split
            },
          },
        },
      }
    end
  },
  {
    'nvim-telescope/telescope-ui-select.nvim',
    config = function()
      require("telescope").setup {
        extensions = {
          ["ui-select"] = {
            require("telescope.themes").get_dropdown {
              -- even more opts
            }
          }
        },
        defaults = {
          -- Lua patterns (escape dot with %)
          file_ignore_patterns = {
            "%.exe$", "%.dll$", "%.so$", "%.o$", "%.class$", "%.pyc$", "%.jar$",
            "%.bin$", "%.dat$", "%.lock$", "%.apk$", "%.dex$", "%.rmeta", "%.rlib",
            -- add any project-specific patterns
            "node_modules", "%.min%.js$", "%.map$"
          },
        }
      }

      require("telescope").load_extension("ui-select")
    end
  }
}

