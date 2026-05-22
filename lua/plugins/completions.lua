-- Completion engine: blink.cmp.
--
-- Sources, snippets, IDE-style ranking and Copilot Tab integration live here.
-- LSP capabilities come from blink.cmp (see lua/plugins/lsp.lua etc.).
-- Signature help is owned by noice.nvim — blink's signature is disabled to
-- avoid double popups.

return {
  -- Copilot — inline ghost suggestions, toggled via <leader>cp.
  -- Tab logic lives in blink.cmp keymap below so both interact cleanly.
  {
    'github/copilot.vim',
    init = function()
      vim.g.copilot_enabled = false
      vim.g.copilot_no_tab_map = true
      vim.g.copilot_hide_during_completion = false
    end,
    config = function()
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

      -- Accept one line of Copilot suggestion (whole-suggestion accept is Tab,
      -- handled in blink.cmp keymap).
      vim.keymap.set('i', '<C-l>', '<Plug>(copilot-accept-line)', { silent = true })
    end,
  },

  -- LuaSnip + friendly-snippets + user snippets at ~/.config/nvim/snippets/.
  {
    'L3MON4D3/LuaSnip',
    dependencies = { 'rafamadriz/friendly-snippets' },
    config = function()
      require('luasnip.loaders.from_vscode').lazy_load()
      require('luasnip.loaders.from_vscode').lazy_load({
        paths = { vim.fn.stdpath('config') .. '/snippets' },
      })
    end,
  },

  -- nvim-cmp source compatibility shim for plugins that still register their
  -- completion sources via the cmp API (cmp-conjure, crates.nvim).
  {
    'saghen/blink.compat',
    version = '*',
    lazy = true,
    opts = {},
  },

  -- blink.cmp — fast Rust-based completion + cmdline + documentation popups.
  {
    'saghen/blink.cmp',
    version = '*',
    dependencies = {
      'L3MON4D3/LuaSnip',
      'rafamadriz/friendly-snippets',
      'saghen/blink.compat',
    },
    event = { 'InsertEnter', 'CmdlineEnter' },
    config = function()
      -- ── C/C++ LSP filter ─────────────────────────────────────────────────
      -- Drop clangd's own Snippet items (luasnip owns snippets) and qualified
      -- items (`Foo::Bar`) when the user has NOT typed `::`. Kills the
      -- `std::ranges::*` / `std::errc::*` flood when typing bare `re`; those
      -- reappear once the user writes `std::re`, `ranges::re`, etc.
      local CIK = vim.lsp.protocol.CompletionItemKind
      local CPP_FTS = { c = true, cpp = true, objc = true, objcpp = true, cuda = true }

      -- True if cursor is inside a comment or string node (treesitter).
      -- Used to suppress keyword/snippet noise where it doesn't belong.
      local function in_comment_or_string()
        local ok, node = pcall(vim.treesitter.get_node)
        if not ok or not node then return false end
        local t = node:type()
        return t == 'comment'
            or t == 'line_comment'
            or t == 'block_comment'
            or t == 'string_literal'
            or t == 'raw_string_literal'
            or t == 'string'
            or t:find('comment$') ~= nil
      end

      -- True right after a member/scope-access operator (`.`, `->`, `::`).
      -- Only identifiers are grammatically valid in this position, so
      -- keyword / snippet sources have no business here — they'd interleave
      -- with the LSP's member list and break grouping.
      local function after_member_access_op()
        local col = vim.api.nvim_win_get_cursor(0)[2]
        local before = vim.api.nvim_get_current_line():sub(1, col)
        return before:match('%.[%w_]*$') ~= nil
            or before:match('%->[%w_]*$') ~= nil
            or before:match('::[%w_]*$') ~= nil
      end

      -- Single predicate for "is this a context where keyword-like sources
      -- (cpp_keywords, snippets) should fire?". Combines both rules above.
      local function keyword_context()
        return not in_comment_or_string() and not after_member_access_op()
      end

      local function cpp_filter_lsp_items(items)
        local col = vim.api.nvim_win_get_cursor(0)[2]
        local line = vim.api.nvim_get_current_line()
        local before = line:sub(1, col)
        local user_tok = before:match('([%w_:]+)$') or ''
        local user_qualified = user_tok:find('::', 1, true) ~= nil

        local out = {}
        for _, item in ipairs(items) do
          if item.kind ~= CIK.Snippet then
            -- Look up the scope ONLY in labelDetails.description — that's the
            -- official LSP slot ("std::" for std-namespaced items). Do NOT
            -- fall back to item.detail: that's the type signature (e.g.
            -- "std::ostream &" for a local named `os`), and using it as a
            -- qualifier wrongly drops every local with an std-typed value.
            local desc  = item.labelDetails and item.labelDetails.description or ''
            local label = item.label or ''
            local is_qualified = desc:find('::', 1, true) ~= nil
                              or label:find('::', 1, true) ~= nil
            if user_qualified or not is_qualified then
              out[#out + 1] = item
            end
          end
        end
        return out
      end

      require('blink.cmp').setup({
        -- ── Keymap (mirrors the old nvim-cmp config) ───────────────────────
        keymap = {
          preset = 'none',
          ['<A-Space>'] = { 'show', 'show_documentation', 'hide_documentation' },
          ['<A-l>'] = { 'select_and_accept', 'show' },
          ['<A-h>'] = { 'hide', 'fallback' },
          ['<A-j>'] = { 'select_next', 'fallback' },
          ['<A-k>'] = { 'select_prev', 'fallback' },
          ['<Down>'] = { 'select_next', 'fallback' },
          ['<Up>'] = { 'select_prev', 'fallback' },
          ['<C-b>'] = { 'scroll_documentation_up', 'fallback' },
          ['<C-f>'] = { 'scroll_documentation_down', 'fallback' },

          -- Enter: accept only if user explicitly selected an item; otherwise
          -- pass through so <CR> still inserts a newline.
          ['<CR>'] = { 'accept', 'fallback' },

          -- Tab: Copilot suggestion (if any) wins; then snippet jump / select+
          -- accept; finally fallback to a real tab character.
          ['<Tab>'] = {
            function(cmp)
              if vim.g.copilot_enabled then
                local ok, sug = pcall(vim.fn['copilot#GetDisplayedSuggestion'])
                if ok and sug and sug.text and sug.text ~= '' then
                  local keys = vim.fn['copilot#Accept']('')
                  if keys and keys ~= '' then
                    vim.api.nvim_feedkeys(keys, 'n', true)
                    return true
                  end
                end
              end
              if cmp.is_visible() then
                cmp.select_and_accept()
                return true
              end
              return false
            end,
            'snippet_forward',
            'fallback',
          },

          ['<S-Tab>'] = { 'snippet_backward', 'select_prev', 'fallback' },

          -- Esc: close popup AND leave insert mode (single press).
          ['<Esc>'] = {
            function(cmp)
              if cmp.is_visible() then cmp.hide() end
              vim.schedule(function() vim.cmd('stopinsert') end)
              return true
            end,
          },
        },

        snippets = { preset = 'luasnip' },

        appearance = {
          nerd_font_variant = 'mono',
          use_nvim_cmp_as_default = false,
        },

        completion = {
          -- Auto-add `()` after accepting a function — replaces the old
          -- nvim-autopairs/cmp confirm_done bridge.
          accept = {
            auto_brackets = { enabled = true },
          },
          -- Don't auto-select the first item: <CR> must remain a real newline
          -- unless the user explicitly picked something with <A-j>/<A-k>.
          list = {
            selection = { preselect = false, auto_insert = false },
          },
          menu = {
            border = 'none',
            scrollbar = false,
            min_width = 20,
            max_height = 12,
            draw = {
              treesitter = { 'lsp' },
              padding = { 0, 1 },
              gap = 1,
              columns = {
                { 'kind_icon' },
                { 'label', 'label_description', gap = 1 },
              },
            },
          },
          documentation = {
            auto_show = true,
            auto_show_delay_ms = 200,
            window = { border = 'none', max_width = 80 },
          },
          ghost_text = { enabled = false },
        },

        -- noice.nvim owns signature help.
        signature = { enabled = false },

        sources = {
          default = { 'lsp', 'snippets', 'path', 'buffer' },
          per_filetype = {
            c       = { 'lsp', 'cpp_keywords', 'snippets', 'path', 'buffer' },
            cpp     = { 'lsp', 'cpp_keywords', 'snippets', 'path', 'buffer' },
            objc    = { 'lsp', 'cpp_keywords', 'snippets', 'path', 'buffer' },
            objcpp  = { 'lsp', 'cpp_keywords', 'snippets', 'path', 'buffer' },
            cuda    = { 'lsp', 'cpp_keywords', 'snippets', 'path', 'buffer' },
            clojure       = { 'conjure', 'lsp', 'snippets', 'path', 'buffer' },
            clojurescript = { 'conjure', 'lsp', 'snippets', 'path', 'buffer' },
            fennel        = { 'conjure', 'lsp', 'snippets', 'path', 'buffer' },
            prolog  = { 'snippets', 'buffer', 'path' },
            toml    = { 'lsp', 'crates', 'path' },
          },
          providers = {
            lsp = {
              -- Run C/C++ flood-filter on clangd's items. No-op for everything
              -- else — items pass through untouched.
              transform_items = function(_, items)
                if CPP_FTS[vim.bo.filetype] then
                  return cpp_filter_lsp_items(items)
                end
                return items
              end,
            },
            buffer = {
              min_keyword_length = 3,
              score_offset = -3,
            },
            snippets = {
              score_offset = -1,
              enabled = keyword_context,
            },
            cpp_keywords = {
              name = 'cpp_keywords',
              module = 'lang.cpp_keywords',
              enabled = keyword_context,
            },
            -- cmp-conjure is a cmp source plugin; blink.compat wraps it.
            conjure = {
              name = 'conjure',
              module = 'blink.compat.source',
            },
            -- crates.nvim registers a cmp source when completion.cmp.enabled
            -- is set (see lua/plugins/rust.lua); blink.compat wraps it.
            crates = {
              name = 'crates',
              module = 'blink.compat.source',
            },
          },
        },

        -- Trust blink's default scoring (prefix-match + case-match + frecency
        -- + proximity). Frecency persists across sessions so frequently used
        -- members naturally rise to the top.
        fuzzy = {
          implementation = 'prefer_rust_with_warning',
        },

        cmdline = {
          enabled = true,
          keymap = {
            preset = 'cmdline',
            ['<A-j>'] = { 'select_next', 'fallback' },
            ['<A-k>'] = { 'select_prev', 'fallback' },
            ['<A-l>'] = { 'select_and_accept' },
            ['<A-h>'] = { 'hide', 'fallback' },
            ['<A-Space>'] = { 'show', 'fallback' },
          },
          completion = {
            menu = {
              auto_show = function()
                return vim.fn.getcmdtype() == ':'
              end,
            },
            ghost_text = { enabled = false },
          },
        },
      })
    end,
  },
}
