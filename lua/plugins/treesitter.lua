return {
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    config = function()
      -- nvim 0.12 dropped the legacy `all = false` flag on add_predicate /
      -- add_directive: handlers now always receive `match[id]` as TSNode[]
      -- (a list), not a single node. The archived master branch of
      -- nvim-treesitter still treats it as a single node and feeds the list
      -- straight into get_node_text, which crashes in treesitter.lua:196
      -- ("attempt to call method 'range' (a nil value)") when parsing
      -- markdown injections — fires on LSP K-hover and blink.cmp docs.
      --
      -- Re-register the affected predicates/directives, unwrapping list→node.
      local q = require("vim.treesitter.query")
      local function first(entry)
        if type(entry) == "table" then return entry[1] end
        return entry
      end
      local html_script_type_languages = {
        ["importmap"] = "json",
        ["module"] = "javascript",
        ["application/ecmascript"] = "javascript",
        ["text/ecmascript"] = "javascript",
      }
      local md_alias = {
        ex = "elixir", pl = "perl", sh = "bash", uxn = "uxntal", ts = "typescript",
      }
      q.add_directive("set-lang-from-mimetype!", function(match, _, bufnr, pred, metadata)
        local node = first(match[pred[2]])
        if not node then return end
        local text = vim.treesitter.get_node_text(node, bufnr)
        local configured = html_script_type_languages[text]
        if configured then
          metadata["injection.language"] = configured
        else
          local parts = vim.split(text, "/", {})
          metadata["injection.language"] = parts[#parts]
        end
      end, { force = true })
      q.add_directive("set-lang-from-info-string!", function(match, _, bufnr, pred, metadata)
        local node = first(match[pred[2]])
        if not node then return end
        local alias = vim.treesitter.get_node_text(node, bufnr):lower()
        local ft = vim.filetype.match({ filename = "a." .. alias })
        metadata["injection.language"] = ft or md_alias[alias] or alias
      end, { force = true })
      q.add_directive("downcase!", function(match, _, bufnr, pred, metadata)
        local id = pred[2]
        local node = first(match[id])
        if not node then return end
        local text = vim.treesitter.get_node_text(node, bufnr, { metadata = metadata[id] }) or ""
        if not metadata[id] then metadata[id] = {} end
        metadata[id].text = string.lower(text)
      end, { force = true })
      q.add_predicate("nth?", function(match, _, _, pred)
        local node = first(match[pred[2]])
        local n = tonumber(pred[3])
        if node and node:parent() and node:parent():named_child_count() > n then
          return node:parent():named_child(n) == node
        end
        return false
      end, { force = true })
      q.add_predicate("kind-eq?", function(match, _, _, pred)
        local node = first(match[pred[2]])
        if not node then return true end
        return vim.tbl_contains({ unpack(pred, 3) }, node:type())
      end, { force = true })
      q.add_predicate("is?", function(match, _, bufnr, pred)
        local node = first(match[pred[2]])
        if not node then return true end
        local _, _, kind = require("nvim-treesitter.locals").find_definition(node, bufnr)
        return vim.tbl_contains({ unpack(pred, 3) }, kind)
      end, { force = true })

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
          -- C/C++: используем cindent с Allman style.
          -- Prolog: оставляем встроенный $VIMRUNTIME/indent/prolog.vim,
          -- который корректно отступает после :- / --> / ( / ; и dedent'ит
          -- по . — treesitter indent для prolog ставит b:did_indent=1 и
          -- блокирует штатный indent file.
          disable = { "c", "cpp", "prolog" }
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

