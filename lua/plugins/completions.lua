return {
  {
    'hrsh7th/cmp-nvim-lsp'
  },
  -- cmp-latex-symbols removed: inserts unicode instead of LaTeX commands
  -- texlab LSP provides proper \alpha, \beta etc. completions
  {
    'github/copilot.vim',
    config = function()
      -- Toggle Copilot on/off
      vim.keymap.set('n', '<leader>cp', function()
        if vim.b.copilot_enabled == false or vim.g.copilot_enabled == false then
          vim.cmd('Copilot enable')
          vim.g.copilot_enabled = true
          vim.b.copilot_enabled = true
          print('Copilot enabled')
        else
          vim.cmd('Copilot disable')
          vim.g.copilot_enabled = false
          vim.b.copilot_enabled = false
          print('Copilot disabled')
        end
      end, { noremap = true, silent = true })
      
      -- Accept only one line of Copilot suggestion
      vim.keymap.set('i', '<C-l>', 'copilot#AcceptLine()', {
        expr = true,
        replace_keycodes = false,
        silent = true
      })
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
          -- Tab: use cmp when Copilot is disabled, otherwise fall back to Copilot/default
          ['<Tab>'] = cmp.mapping(function(fallback)
            local copilot_off = (vim.b.copilot_enabled == false) or (vim.g.copilot_enabled == false)
            if copilot_off then
              if cmp.visible() then
                cmp.confirm({ select = true })
              elseif luasnip.expand_or_jumpable() then
                luasnip.expand_or_jump()
              else
                cmp.complete()
              end
            else
              fallback()
            end
          end, { "i", "s" }),
          ['<S-Tab>'] = cmp.mapping(function(fallback)
            local copilot_off = (vim.b.copilot_enabled == false) or (vim.g.copilot_enabled == false)
            if copilot_off then
              if cmp.visible() then
                cmp.select_prev_item()
              elseif luasnip.locally_jumpable(-1) then
                luasnip.jump(-1)
              else
                fallback()
              end
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
