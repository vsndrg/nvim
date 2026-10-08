return {
  {
    'nvim-telescope/telescope.nvim', version = '*',
    dependencies = {
      'nvim-lua/plenary.nvim',
      'nvim-telescope/telescope-symbols.nvim',
    },
    config = function()
      local builtin = require("telescope.builtin")
      vim.keymap.set('n', '<leader>f', builtin.find_files, {})
      vim.keymap.set('n', '<leader>l', builtin.live_grep, {})
      local actions = require("telescope.actions")
      vim.keymap.set('n', '<leader>s', function()
        builtin.lsp_document_symbols({
          -- center the screen on the symbol after jumping to it
          attach_mappings = function(_, map)
            local jump = actions.select_default + actions.center
            map({ 'i', 'n' }, '<CR>', jump)
            map('n', 'l', jump)
            return true
          end,
        })
      end, {})
      vim.keymap.set('n', '<leader>b', function()
        builtin.oldfiles({ initial_mode = "normal" })
      end, {})
      local md_files = require("utils.md_files")
      vim.keymap.set('n', '<leader>mf', md_files.pick, { desc = 'Markdown files (pin with <C-g> / m)' })
      vim.keymap.set('n', '<leader>mg', md_files.open_pinned, { desc = 'Open pinned markdown file' })
      -- <C-m> works only where it is not <CR> (Neovide, CSI-u terminals). Mapping it
      -- would also map <CR> unless <CR> is already mapped, so pin <CR> to itself
      -- first (:h vim_diff, "simplifiable key"); buffer-local <CR> maps still win.
      -- Tap: pinned file / back; hold: peek, the release comes back.
      for _, mode in ipairs({ 'n', 'i' }) do
        vim.keymap.set(mode, '<CR>', '<CR>')
        vim.keymap.set(mode, '<C-m>', function() return md_files.ctrl_m(mode == 'i') end,
          { expr = true, remap = true, desc = 'Pinned markdown file / back; hold to peek' })
      end
      -- Alternate file; held, it peeks: the release comes back (utils.peek).
      -- From Insert mode the alternate file stays in Insert mode.
      local peek = require("utils.peek")
      peek.watch('<C-b>')
      vim.keymap.set({ 'n', 'i' }, '<C-b>', function()
        peek.jump('<C-b>', function(mods) vim.cmd(mods .. 'edit #') end)
      end, {})

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
