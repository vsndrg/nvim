return {
  {
    'hrsh7th/cmp-nvim-lsp'
  },
  -- cmp-latex-symbols removed: inserts unicode instead of LaTeX commands
  -- texlab LSP provides proper \alpha, \beta etc. completions
  {
    'github/copilot.vim',
    init = function()
      vim.g.copilot_enabled = false
      vim.g.copilot_no_tab_map = true
      vim.g.copilot_hide_during_completion = false
    end,
    config = function()
      -- Toggle Copilot on/off
      vim.keymap.set('n', '<leader>cp', function()
        if vim.g.copilot_enabled == false then
          vim.cmd('Copilot enable')
          vim.g.copilot_enabled = true
          print('Copilot enabled')
        else
          vim.cmd('Copilot disable')
          vim.g.copilot_enabled = false
          print('Copilot disabled')
        end
      end, { noremap = true, silent = true })
      
      -- Tab: accept Copilot suggestion if enabled, otherwise handled by cmp
      vim.keymap.set('i', '<Tab>', function()
        local cmp = require('cmp')
        local luasnip = require('luasnip')
        
        if vim.g.copilot_enabled then
          -- Copilot enabled: accept suggestion if available
          local suggestion = vim.fn['copilot#GetDisplayedSuggestion']()
          if suggestion.text ~= '' then
            return vim.fn['copilot#Accept']('')
          end
        end
        
        -- No Copilot suggestion or Copilot disabled: use cmp/snippets
        if cmp.visible() then
          vim.schedule(function()
            cmp.confirm({ select = true })
          end)
          return ''
        elseif luasnip.expand_or_jumpable() then
          vim.schedule(function()
            luasnip.expand_or_jump()
          end)
          return ''
        else
          return '\t'
        end
      end, {
        expr = true,
        replace_keycodes = false,
        silent = true
      })
      
      -- Accept one line of Copilot suggestion
      vim.keymap.set('i', '<C-l>', '<Plug>(copilot-accept-line)', { silent = true })
    end
  },
  {
    'L3MON4D3/LuaSnip',
    dependencies = {
      'saadparwaiz1/cmp_luasnip',
      'rafamadriz/friendly-snippets'
    },
    config = function()
      require("luasnip.loaders.from_vscode").lazy_load()
      -- Загружаем свои сниппеты из ~/.config/nvim/snippets/
      require("luasnip.loaders.from_vscode").lazy_load({ paths = { vim.fn.stdpath("config") .. "/snippets" } })
    end
  },
  {
    'onsails/lspkind.nvim',
    config = function()
      require('lspkind').init({
        mode = 'symbol_text',
        preset = 'codicons',
      })
    end
  },
  {
    'hrsh7th/nvim-cmp',
    dependencies = {
      'hrsh7th/cmp-buffer',
      'hrsh7th/cmp-path',
      'hrsh7th/cmp-cmdline',
      'onsails/lspkind.nvim',
    },
    config = function()
      local cmp = require("cmp")
      local lspkind = require("lspkind")
      local luasnip = require("luasnip")

      local types = require('cmp.types')
      local compare = cmp.config.compare

      cmp.setup({
        snippet = {
          expand = function(args)
            luasnip.lsp_expand(args.body)
          end,
        },
        window = {
          completion = cmp.config.window.bordered(),
          documentation = cmp.config.window.bordered(),
        },
        completion = {
          completeopt = 'menu,menuone,noselect',
          autocomplete = { require('cmp.types').cmp.TriggerEvent.TextChanged },
        },
        sorting = {
          priority_weight = 2,
          comparators = {
            -- 1. Exact prefix match first
            compare.exact,
            -- 2. Higher score (fuzzy match quality from LSP)
            compare.score,
            -- 3. Recently used completions
            compare.recently_used,
            -- 4. Nearby code locality (same scope/file)
            compare.locality,
            -- 5. Deprioritize Text completions
            function(entry1, entry2)
              local kind1 = entry1:get_kind()
              local kind2 = entry2:get_kind()
              local text_kind = types.lsp.CompletionItemKind.Text
              if kind1 == text_kind and kind2 ~= text_kind then
                return false
              end
              if kind1 ~= text_kind and kind2 == text_kind then
                return true
              end
              return nil
            end,
            -- 6. Sort by completion kind
            compare.kind,
            -- 7. Shorter completions first
            compare.length,
            -- 8. Alphabetical tiebreaker
            compare.sort_text,
            compare.order,
          },
        },
        formatting = {
          fields = { "kind", "abbr", "menu" },
          format = function(entry, vim_item)
            local kind = lspkind.cmp_format({
              mode = "symbol_text",
              maxwidth = 50,
            })(entry, vim_item)
            local strings = vim.split(kind.kind, "%s", { trimempty = true })
            kind.kind = " " .. (strings[1] or "") .. " "
            kind.menu = "  " .. (strings[2] or "")
            return kind
          end,
        },
        mapping = cmp.mapping.preset.insert({
          ['<C-b>'] = cmp.mapping.scroll_docs(-4),
          ['<C-f>'] = cmp.mapping.scroll_docs(4),
          ['<A-Space>'] = cmp.mapping.complete(),
          -- Tab handled by Copilot (see copilot.vim config above)
          ['<S-Tab>'] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_prev_item()
            elseif luasnip.locally_jumpable(-1) then
              luasnip.jump(-1)
            else
              fallback()
            end
          end, { "i", "s" }),
          ['<CR>'] = cmp.mapping.confirm({ select = false }),
          ['<A-h>'] = cmp.mapping.abort(),
          -- Esc: закрыть popup И перейти в normal mode
          ['<Esc>'] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.abort()
            end
            vim.cmd("stopinsert")
          end, { "i", "s" }),
          ['<A-l>'] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.confirm({ select = true })
            else
              cmp.complete()
            end
          end, { "i", "s" }),
          ['<A-j>'] = cmp.mapping.select_next_item(),
          ['<A-k>'] = cmp.mapping.select_prev_item(),
          ['<Down>'] = cmp.mapping.select_next_item(),
          ['<Up>'] = cmp.mapping.select_prev_item(),
        }),
        sources = cmp.config.sources({
          {
            name = 'nvim_lsp',
            priority = 1000,
            entry_filter = function(entry)
              return entry:get_kind() ~= 15
            end,
          },
          { name = 'luasnip', priority = 750 },
          { name = 'path', priority = 500 },
        }, {
          { name = 'buffer', priority = 250, keyword_length = 3 },
        }),
        experimental = {
          ghost_text = false,
        },
      })

      cmp.setup.filetype('toml', {
        sources = cmp.config.sources({
          { name = 'crates' },
          { name = 'nvim_lsp' },
          { name = 'path' },
        })
      })

      cmp.setup.cmdline('/', {
        mapping = cmp.mapping.preset.cmdline(),
        sources = { { name = 'buffer' } }
      })

      cmp.setup.cmdline(':', {
        mapping = cmp.mapping.preset.cmdline(),
        sources = cmp.config.sources(
          { { name = 'path' } },
          { { name = 'cmdline' } }
        )
      })
    end
  }
}
