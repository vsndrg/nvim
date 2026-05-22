-- Clojure / lisp plugin specs.
--
-- REPL workflow: start nREPL with `cnrepl` (alias for `clj -M:nrepl`) in any
-- directory containing .clj files. Conjure auto-connects to .nrepl-port.

local conjure_fts = { "clojure", "clojurescript", "fennel" }
local lisp_fts    = { "clojure", "clojurescript", "fennel", "lisp", "scheme" }

return {
  -- Conjure: nREPL-backed REPL integration.
  {
    "Olical/conjure",
    ft = conjure_fts,
    init = function()
      -- HUD: floating popup in the corner that surfaces eval results and
      -- errors from ,ee / ,ef / ,er without forcing you to open the log.
      vim.g["conjure#log#hud#enabled"]  = true
      vim.g["conjure#log#hud#anchor"]   = "SE"   -- pin to bottom-right
      vim.g["conjure#log#hud#width"]    = 0.4    -- 40% of editor width
      vim.g["conjure#log#hud#height"]   = 0.6    -- 60% of editor height
      vim.g["conjure#log#hud#border"]   = "rounded"
      vim.g["conjure#log#wrap"]         = true   -- wrap long error messages
      -- Open log splits relative to the current window (uses :split / :vsplit).
      -- Combined with vim's splitbelow=true (set in options.lua), ,ls puts the
      -- log right below the buffer you're in, not at the bottom of the editor.
      vim.g["conjure#log#botright"]     = false

      vim.g["conjure#mapping#doc_word"]    = "gk"
      vim.g["conjure#completion#omnifunc"] = true
    end,
  },

  -- Completion source backed by the live nREPL: completes symbols pulled in
  -- via (load-file ...) the moment they are evaluated. The plugin registers
  -- itself as an nvim-cmp source; blink.compat (loaded by completions.lua)
  -- provides the cmp API shim so it works under blink.cmp.
  {
    "PaterJason/cmp-conjure",
    ft = conjure_fts,
    dependencies = { "Olical/conjure", "saghen/blink.compat" },
  },

  -- Parinfer (Rust): keep parens balanced via indentation.
  -- The Rust implementation is dramatically faster than the pure-Lua port,
  -- which avoids per-keystroke freezes when holding a key in insert mode
  -- (especially noticeable inside comments).
  {
    "eraserhd/parinfer-rust",
    ft = lisp_fts,
    build = "cargo build --release",
  },

  -- Rainbow delimiters: color matching parens by depth.
  {
    "HiPhish/rainbow-delimiters.nvim",
    ft = lisp_fts,
    config = function()
      local rd = require("rainbow-delimiters")
      require("rainbow-delimiters.setup").setup({
        strategy = { [""] = rd.strategy["global"] },
        query    = { [""] = "rainbow-delimiters" },
      })
    end,
  },

  -- Structural editing: slurp / barf / splice / wrap / raise.
  {
    "guns/vim-sexp",
    ft = lisp_fts,
    init = function()
      vim.g.sexp_filetypes                  = table.concat(lisp_fts, ",")
      vim.g.sexp_enable_insert_mode_mappings = 0
      -- Default behaviour for ,w / ,i / ,[ / ,{ etc.: wrap and drop into
      -- insert mode. The no-insert variants live under ,,w / ,,i / ... and
      -- are defined in ftplugin/clojure.lua.
      vim.g.sexp_insert_after_wrap          = 1
      -- Free defaults that conflict with the regular-people remap below.
      vim.g.sexp_mappings = {
        sexp_put_before    = { n = "" },
        sexp_put_after     = { n = "" },
        sexp_replace       = { x = "", n = "" },
        sexp_replace_P     = { x = "", n = "" },
        sexp_put_before_op = { n = "" },
        sexp_put_after_op  = { n = "" },
        sexp_put_at_head   = { n = "" },
        sexp_put_at_tail   = { n = "" },
        sexp_replace_op    = { n = "" },
        sexp_replace_op_P  = { n = "" },
      }
    end,
  },
  {
    "tpope/vim-sexp-mappings-for-regular-people",
    ft = lisp_fts,
    dependencies = { "guns/vim-sexp", "tpope/vim-repeat" },
  },
}
